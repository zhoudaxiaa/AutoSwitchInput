import AppKit
import Foundation

/// 所有外部操作均可注入，竞态验证无需操作系统输入法。
struct SwitchEnvironment {
    var now: () -> Date = { Date() }
    var frontmost: () -> (bundle: String, pid: pid_t)? = {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundle = app.bundleIdentifier else { return nil }
        return (bundle, app.processIdentifier)
    }
    var currentSource: () -> String? = currentSourceID
    var select: (String) -> Bool = selectSource
    var secureInput: () -> Bool = secureInputActive
    var resolve: (String, Config, @escaping (String?) -> Void) -> FocusProbe.Request? = {
        SourceResolver.resolve(for: $0, config: $1, completion: $2)
    }
    var schedule: (Double, @escaping () -> Void) -> Void = { delay, action in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
    }
}

/// 主线程拥有状态。每次上下文变更立即使旧的防抖、AX 读取、校验链失效。
final class SwitchEngine {
    var configProvider: () -> Config = { Config() }
    var onWatchdog: (() -> Void)?
    private let environment: SwitchEnvironment
    private var expectedID: String?
    private var expectedBundle: String?
    private var expectedUntil: Date = .distantPast
    private var overrideBundle: String?
    private var overrideUntil: Date = .distantPast
    private var applyToken = 0
    private var focusRequest: FocusProbe.Request?
    private var resolvingToken: Int?
    private var watchdog: Timer?

    init(environment: SwitchEnvironment = SwitchEnvironment()) { self.environment = environment }

    func markUserOverride(bundle: String, for seconds: TimeInterval) {
        cancelPendingApply()
        overrideBundle = bundle
        overrideUntil = environment.now().addingTimeInterval(seconds)
    }

    func clearUserOverride() {
        overrideBundle = nil
        overrideUntil = .distantPast
    }

    private func isUserOverriding(_ bundle: String) -> Bool {
        bundle == overrideBundle && environment.now() < overrideUntil
    }

    func isSelfInflicted(_ current: String?) -> Bool {
        expectedID == current && expectedID != nil && environment.now() < expectedUntil
            && environment.frontmost()?.bundle == expectedBundle
    }

    func clearExpected() { expectedID = nil; expectedBundle = nil }

    func cancelPendingApply() {
        applyToken &+= 1
        focusRequest?.cancel()
        focusRequest = nil
        resolvingToken = nil
        // 不清 expected：迟到的 TIS 通知仍属于自己的切换，不能学入规则。
    }

    func scheduleApply(reason: String, delay: Double = 0.03) {
        cancelPendingApply()
        let token = applyToken
        environment.schedule(delay) { [weak self] in
            guard let self = self, self.applyToken == token else { return }
            self.applyNow(reason: reason)
        }
    }

    func applyNow(reason: String) {
        cancelPendingApply()
        let token = applyToken
        guard let target = environment.frontmost(), eligible(target.bundle) else { return }
        resolve(bundle: target.bundle, token: token) { [weak self] desired in
            guard let self = self, let desired = desired,
                  self.isCurrent(bundle: target.bundle, pid: target.pid, token: token),
                  self.environment.currentSource() != desired else { return }
            log("⇄ [\(reason)] \(target.bundle) → \(desired)")
            self.applyWithVerify(desired, bundle: target.bundle, pid: target.pid, attempt: 0, token: token)
        }
    }

    private func eligible(_ bundle: String) -> Bool {
        let config = configProvider()
        return config.enabled && bundle != kBundleSelf && !config.excluded.contains(bundle)
            && !isUserOverriding(bundle) && !environment.secureInput()
    }

    private func isCurrent(bundle: String, pid: pid_t, token: Int) -> Bool {
        let front = environment.frontmost()
        return token == applyToken && front?.bundle == bundle && front?.pid == pid && eligible(bundle)
    }

    private func resolve(bundle: String, token: Int, completion: @escaping (String?) -> Void) {
        resolvingToken = token
        focusRequest = environment.resolve(bundle, configProvider()) { [weak self] desired in
            guard let self = self, self.applyToken == token else { return }
            self.resolvingToken = nil
            completion(desired)
        }
    }

    private func applyWithVerify(_ desired: String, bundle: String, pid: pid_t, attempt: Int, token: Int) {
        guard isCurrent(bundle: bundle, pid: pid, token: token) else { return }
        expectedID = desired
        expectedBundle = bundle
        expectedUntil = environment.now().addingTimeInterval(1.5)
        guard environment.select(desired) else { clearExpected(); return }

        let delays = configProvider().validated().verifyDelays
        guard attempt < delays.count else { return }
        environment.schedule(delays[attempt]) { [weak self] in
            guard let self = self, self.isCurrent(bundle: bundle, pid: pid, token: token),
                  self.environment.currentSource() != desired else { return }
            // 再读一次最新位置，不能把旧位置的目标强加给新焦点。
            self.resolve(bundle: bundle, token: token) { [weak self] latest in
                guard let self = self, latest == desired,
                      self.isCurrent(bundle: bundle, pid: pid, token: token) else { return }
                log("↺ 第 \(attempt + 1) 次重试 \(bundle)")
                self.applyWithVerify(desired, bundle: bundle, pid: pid, attempt: attempt + 1, token: token)
            }
        }
    }

    func startWatchdog() {
        stopWatchdog()
        watchdog = Timer.scheduledTimer(withTimeInterval: configProvider().validated().watchdogInterval,
                                       repeats: true) { [weak self] _ in
            self?.watchdogTick()
        }
    }

    func watchdogTick() {
        onWatchdog?()
        // AX 较慢时让已有的有限读取完成，避免每次 tick 取消造成永久饥饿。
        guard resolvingToken == nil else { return }
        applyNow(reason: "看门狗")
    }

    func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
        cancelPendingApply()
    }
}
