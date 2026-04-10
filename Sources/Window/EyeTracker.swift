import AppKit
import Foundation

/// 眼球追踪只负责“算偏移”和“按需发偏移”。
/// 具体怎么改渲染层由 PetView / CALayer 处理，这样算法和渲染能分开。
@MainActor
final class EyeTracker {
    private static let timerIntervalMs: Int = 100
    private static let maxDistance: CGFloat = 300
    private static let maxEyeOffset: CGFloat = 3
    private static let maxEyeYOffset: CGFloat = 1.5
    private static let quantizeStep: CGFloat = 0.5

    private let isEnabled: @MainActor () -> Bool
    private let eyeCenterProvider: @MainActor () -> NSPoint?
    private let onOffsetChange: @MainActor (CGFloat, CGFloat) -> Void
    private let timer: DispatchSourceTimer

    private var lastSentOffset: CGPoint?
    private var forceEyeResend = true
    private var isStopped = false
    private var isPaused = false

    init(
        isEnabled: @escaping @MainActor () -> Bool,
        eyeCenterProvider: @escaping @MainActor () -> NSPoint?,
        onOffsetChange: @escaping @MainActor (CGFloat, CGFloat) -> Void
    ) {
        self.isEnabled = isEnabled
        self.eyeCenterProvider = eyeCenterProvider
        self.onOffsetChange = onOffsetChange

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + .milliseconds(Self.timerIntervalMs),
            repeating: .milliseconds(Self.timerIntervalMs)
        )
        self.timer = timer

        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        timer.resume()
    }

    func stop() {
        guard !isStopped else {
            return
        }

        // DispatchSource 处于 suspend 状态时不能直接 cancel。
        // 先补一层 resume，把引用计数配平，再安全销毁。
        if isPaused {
            timer.resume()
            isPaused = false
        }

        isStopped = true
        timer.setEventHandler {}
        timer.cancel()
    }

    /// 交互 reaction 或窗口隐藏时，连 50ms timer 本身一起挂起。
    /// 这里只 suspend source，不靠 tick 内部早退，这样主线程不会继续被周期性唤醒。
    func pause() {
        guard !isStopped, !isPaused else {
            return
        }

        isPaused = true
        timer.suspend()
    }

    /// 恢复后强制补发一次，确保 SVG 切换或窗口重现后眼球位置立刻同步。
    func resume() {
        guard !isStopped, isPaused else {
            return
        }

        isPaused = false
        forceEyeResend = true
        timer.resume()
    }

    /// SVG 刚切换完成时 DOM transform 会回到初始值。
    /// 这里强制补发一次，避免“眼球逻辑还是旧位置，但新 SVG 还没收到 transform”。
    func forceResend() {
        forceEyeResend = true
    }

    private func tick() {
        guard
            isEnabled(),
            let eyeCenter = eyeCenterProvider()
        else {
            return
        }

        let nextOffset = Self.calculateOffset(cursor: NSEvent.mouseLocation, eyeCenter: eyeCenter)
        if !forceEyeResend, let lastSentOffset, lastSentOffset == nextOffset {
            return
        }

        forceEyeResend = false
        lastSentOffset = nextOffset
        onOffsetChange(nextOffset.x, nextOffset.y)
    }

    private static func calculateOffset(cursor: NSPoint, eyeCenter: NSPoint) -> CGPoint {
        let relX = cursor.x - eyeCenter.x
        let relY = cursor.y - eyeCenter.y
        let distance = hypot(relX, relY)

        guard distance > 0 else {
            return .zero
        }

        let scale = min(1, distance / maxDistance)
        let dx = (relX / distance) * maxEyeOffset * scale
        let dy = (relY / distance) * maxEyeOffset * scale

        let quantizedDx = quantize(dx)
        let quantizedDy = min(max(quantize(dy), -maxEyeYOffset), maxEyeYOffset)
        return CGPoint(x: quantizedDx, y: quantizedDy)
    }

    private static func quantize(_ value: CGFloat) -> CGFloat {
        (value / quantizeStep).rounded() * quantizeStep
    }
}
