import AppKit
import Foundation

/// 执行「把输入法切到目标值」并做多轮校验重试。
///
/// 为什么要重试：很多应用（Electron、部分 IME 宿主）会在激活瞬间把自己记着的
/// 输入法再抢回去。切完就验、发现被回滚就再推一次，能盖住这类竞态。
///
/// 为什么要令牌：激活、焦点变化、看门狗三条路径可能同时发起切换，
/// 各起一条延迟校验链并行推同一个值，会互相判定对方「被回滚」而反复重试。
/// 每次发起切换换一个令牌，旧链看到令牌变了就自行退出，永远只有最新一条在跑。
final class SwitchEngine {

    /// 由上层注入，每次判定时取最新配置
    var configProvider: () -> Config = { Config() }

    private var expectedID: String?
    private var expectedUntil: Date = .distantPast
    private var userOverrideUntil: Date = .distantPast
    private var applyToken = 0
    private var pending: DispatchWorkItem?
    private var watchdog: Timer?

    // MARK: - 用户手动切换的保护窗

    var isUserOverriding: Bool { Date() < userOverrideUntil }

    /// 识别到用户手动切了输入法后，一段时间内别再跟他对着干
    func markUserOverride(for seconds: TimeInterval) {
        userOverrideUntil = Date().addingTimeInterval(seconds)
    }

    /// 这次输入法变化是不是我们自己刚造成的（用来避免把自己的切换学成用户操作）
    func isSelfInflicted(_ current: String?) -> Bool {
        guard let exp = expectedID, Date() < expectedUntil else { return false }
        return current == exp
    }

    func clearExpected() { expectedID = nil }

    // MARK: - 切换

    func scheduleApply(reason: String, delay: Double = 0.03) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applyNow(reason: reason) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func applyNow(reason: String) {
        let config = configProvider()
        guard config.enabled else { return }
        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundle = front.bundleIdentifier else { return }
        guard bundle != kBundleSelf, !config.excluded.contains(bundle) else { return }
        guard !isUserOverriding else { return }
        guard let desired = SourceResolver.desired(for: bundle, config: config) else { return }

        let current = currentSourceID()
        guard current != desired else { return }

        if secureInputActive() {
            log("⏭ \(bundle) 处于安全键盘输入状态，跳过（避免打断密码输入）")
            return
        }

        log("⇄ [\(reason)] \(bundle): \(current ?? "nil") → \(desired)")
        applyWithVerify(desired, bundle: bundle, attempt: 0, token: nextToken())
    }

    private func nextToken() -> Int {
        applyToken &+= 1
        return applyToken
    }

    private func applyWithVerify(_ desired: String, bundle: String, attempt: Int, token: Int) {
        guard token == applyToken else { return }

        expectedID = desired
        expectedUntil = Date().addingTimeInterval(1.5)

        if !selectSource(desired) {
            expectedID = nil
            return
        }

        let delays = configProvider().verifyDelays
        guard attempt < delays.count else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + delays[attempt]) { [weak self] in
            guard let self = self else { return }
            // 期间又发起了新的切换，这条链已经过期，别再推一遍
            guard token == self.applyToken else { return }
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle else { return }
            guard !self.isUserOverriding else { return }
            guard currentSourceID() != desired else { return }

            log("↺ 被目标应用回滚，第 \(attempt + 1) 次重试 \(bundle)")
            self.applyWithVerify(desired, bundle: bundle, attempt: attempt + 1, token: token)
        }
    }

    // MARK: - 看门狗

    /// 兜底：AX 观察可能因为权限/版本失效，定时对一遍账
    func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: configProvider().watchdogInterval,
                                       repeats: true) { [weak self] _ in
            self?.watchdogTick()
        }
    }

    func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    private func watchdogTick() {
        let config = configProvider()
        guard config.enabled else { return }
        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundle = front.bundleIdentifier,
              bundle != kBundleSelf, !config.excluded.contains(bundle),
              let desired = SourceResolver.desired(for: bundle, config: config) else { return }
        guard !isUserOverriding else { return }
        guard currentSourceID() != desired else { return }
        guard !secureInputActive() else { return }

        log("🛡 看门狗纠正 \(bundle) → \(desired)")
        applyWithVerify(desired, bundle: bundle, attempt: 0, token: nextToken())
    }
}
