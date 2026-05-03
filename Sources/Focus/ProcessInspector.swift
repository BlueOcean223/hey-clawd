import AppKit
import Darwin
import Foundation

struct FocusProcessIdentity: Equatable, Sendable {
    let pid: pid_t
    let bundleIdentifier: String?
    let executablePath: String?
    let launchDate: Date?

    var hasStableFields: Bool {
        bundleIdentifier != nil || executablePath != nil || launchDate != nil
    }

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

@MainActor
protocol ProcessInspecting: AnyObject {
    func captureApplicationIdentity(for pid: pid_t) -> FocusProcessIdentity?
    func isProcessAlive(_ pid: pid_t) -> Bool
    func parentPid(of pid: pid_t) -> pid_t?
}

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

        guard result == 0, size >= MemoryLayout<kinfo_proc>.stride else {
            return nil
        }

        return info.kp_eproc.e_ppid
    }
}

extension ProcessInspecting {
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
