import AppKit
import Darwin
import Foundation

/// 进程身份指纹：把"这个 PID 当时是谁"凝固成可对比的稳定字段。
///
/// macOS PID 复用很激进，hook 上送的数字 PID 在窗口被激活时可能已经不是同一个进程。
/// 因此采集 bundleID/可执行路径/启动时间组合，作为后续 `matches(_:)` 校验的快照。
struct FocusProcessIdentity: Equatable, Sendable {
    let pid: pid_t
    let bundleIdentifier: String?
    let executablePath: String?
    let launchDate: Date?

    /// 至少有一项稳定字段才能充当指纹；空指纹无法做防复用判断，等同于没采集。
    var hasStableFields: Bool {
        bundleIdentifier != nil || executablePath != nil || launchDate != nil
    }

    /// 与当前运行中的 `NSRunningApplication` 比对：PID 一致 + 各非空字段一致。
    /// `launchDate` 用 1ms 容差兼容 AppKit 不同 API 路径返回的精度差异。
    func matches(_ app: NSRunningApplication) -> Bool {
        guard app.processIdentifier == pid, !app.isTerminated, hasStableFields else {
            return false
        }

        if let bundleIdentifier, app.bundleIdentifier != bundleIdentifier {
            return false
        }

        if let executablePath, app.executableURL?.path != executablePath {
            return false
        }

        if let launchDate, let currentLaunchDate = app.launchDate,
           abs(currentLaunchDate.timeIntervalSince(launchDate)) > 0.001 {
            return false
        }

        return true
    }
}

/// 进程相关查询的协议抽象，方便单测注入桩。
@MainActor
protocol ProcessInspecting: AnyObject {
    /// 给定 PID 抓取指纹快照；进程已退出或不可见时返回 nil。
    func captureApplicationIdentity(for pid: pid_t) -> FocusProcessIdentity?
    /// 进程是否还在运行（包括无权限读取但确认存在的情形）。
    func isProcessAlive(_ pid: pid_t) -> Bool
    /// 父进程 PID；越过 launchd（pid 1）后返回 nil。
    func parentPid(of pid: pid_t) -> pid_t?
}

/// 生产环境实现：包装 AppKit + sysctl。
@MainActor
final class SystemProcessInspector: ProcessInspecting {
    static let shared = SystemProcessInspector()

    private init() {}

    func captureApplicationIdentity(for pid: pid_t) -> FocusProcessIdentity? {
        guard
            let app = NSRunningApplication(processIdentifier: pid),
            !app.isTerminated
        else {
            return nil
        }

        return FocusProcessIdentity(
            pid: pid,
            bundleIdentifier: app.bundleIdentifier,
            executablePath: app.executableURL?.path,
            launchDate: app.launchDate
        )
    }

    /// 用 `kill(pid, 0)` 试探：成功表示存活；失败时 `EPERM` 也算存活——
    /// 这意味着进程存在但当前用户无权发信号（例如 root 拥有的进程）。
    func isProcessAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else {
            return false
        }

        errno = 0
        if Darwin.kill(pid, 0) == 0 {
            return true
        }

        return errno == EPERM
    }

    /// 通过 sysctl 查询 `kinfo_proc.kp_eproc.e_ppid`。
    /// 这是 macOS 上不需要特殊权限就能读取父 PID 的标准方式。
    func parentPid(of pid: pid_t) -> pid_t? {
        guard pid > 0 else {
            return nil
        }

        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let mibCount = u_int(mib.count)

        let result = mib.withUnsafeMutableBufferPointer { mibPointer in
            sysctl(mibPointer.baseAddress, mibCount, &info, &size, nil, 0)
        }

        // size < stride 表示内核没填满记录，PID 可能已退出；视作未知。
        guard result == 0, size >= MemoryLayout<kinfo_proc>.stride else {
            return nil
        }

        return info.kp_eproc.e_ppid
    }
}

extension ProcessInspecting {
    /// 沿父进程链向上爬，验证 `possibleAncestor` 是否真的是 `child` 的祖先。
    /// `maxDepth=12` 避免恶意构造的进程链导致死循环；遇到 launchd（pid 1）或自指立即终止。
    func isAncestor(_ possibleAncestor: pid_t, of child: pid_t, maxDepth: Int = 12) -> Bool {
        guard possibleAncestor > 0, child > 0 else {
            return false
        }

        var current = child
        for _ in 0..<maxDepth {
            if current == possibleAncestor {
                return true
            }

            guard
                let parent = parentPid(of: current),
                parent > 1,
                parent != current
            else {
                return false
            }

            current = parent
        }

        return false
    }
}
