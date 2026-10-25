import AppKit
import Foundation

/// 抓焦点的两个入口，区别只在「是否要求该应用处于前台」。
///
/// 为什么不是「读一次拿不到就算了」：
/// Chromium / Electron（VS Code、各种 AI 客户端）的 AX 树是**懒构建**的 ——
/// 第一次被问「焦点元素是谁」时才现搭树，这一问往往直接返回
/// `cannotComplete`（-25204）。此时权限是好的、应用也是好的，单纯再问一次就有。
/// 点菜单栏图标那一瞬间正好撞上这种情况，面板就会显示「此处 · 无法识别」。
/// 所以这里统一做「有限重试 + 记住上一次成功值」。
enum FocusProbe {

    /// 最近一次成功读到的指纹，只用于界面显示（规则判定绝不使用缓存值，
    /// 否则会拿过期位置去决定切哪个输入法）。
    private struct Entry {
        let fingerprint: FocusFingerprint
        let at: Date
    }
    private static var cache: [String: Entry] = [:]
    /// 超过这个时间的缓存只当作「无」，不展示成当前位置
    private static let cacheLifetime: TimeInterval = 120

    static func runningApp(bundle: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
    }

    // MARK: - 缓存（仅显示用）

    static func remember(_ fp: FocusFingerprint, for bundle: String) {
        cache[bundle] = Entry(fingerprint: fp, at: Date())
    }

    static func cached(for bundle: String) -> FocusFingerprint? {
        guard let e = cache[bundle] else { return nil }
        guard Date().timeIntervalSince(e.at) < cacheLifetime else {
            cache.removeValue(forKey: bundle)
            return nil
        }
        return e.fingerprint
    }

    static func forget(_ bundle: String) {
        cache.removeValue(forKey: bundle)
    }

    // MARK: - 同步读取

    /// 判定规则用：必须确认该应用就是当前前台，
    /// 否则拿到的可能是它失焦前的残留焦点元素，会误判位置。
    static func fingerprint(ofFrontmost bundle: String) -> FocusFingerprint? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier == bundle else { return nil }
        let fp = readWithRetry(pid: front.processIdentifier, bundle: bundle, attempts: 3)
        if let fp = fp { remember(fp, for: bundle) }
        return fp
    }

    /// 面板展示用：不管前台是谁，只要在运行就抓
    static func fingerprint(ofRunning bundle: String) -> FocusFingerprint? {
        guard let app = runningApp(bundle: bundle) else { return nil }
        let fp = readWithRetry(pid: app.processIdentifier, bundle: bundle, attempts: 2)
        if let fp = fp { remember(fp, for: bundle) }
        return fp
    }

    /// 当前前台应用（排除本应用）
    static func frontmostExternal() -> (bundle: String, pid: pid_t)? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundle = front.bundleIdentifier,
              bundle != kBundleSelf else { return nil }
        return (bundle, front.processIdentifier)
    }

    // MARK: - 异步补读（不阻塞界面）

    /// 同步读失败后调用：在后台间隔重试几次，拿到就回调。
    /// 面板用这个把「无法识别」自动补成真实位置，用户不用再点一次。
    static func retryAsync(bundle: String,
                           delays: [Double] = [0.06, 0.18, 0.45, 0.9],
                           completion: @escaping (FocusFingerprint) -> Void,
                           onGiveUp: @escaping () -> Void = {}) {
        // 先把「请构建无障碍树」的招呼打出去，Electron 建树要几百毫秒
        if let app = runningApp(bundle: bundle) {
            askForFullAXTree(pid: app.processIdentifier)
        }
        scheduleRetry(bundle: bundle, index: 0, delays: delays,
                      completion: completion, onGiveUp: onGiveUp)
    }

    private static func scheduleRetry(bundle: String, index: Int, delays: [Double],
                                      completion: @escaping (FocusFingerprint) -> Void,
                                      onGiveUp: @escaping () -> Void) {
        guard index < delays.count else { onGiveUp(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delays[index]) {
            guard let app = runningApp(bundle: bundle) else { onGiveUp(); return }
            let result = focusedElementResult(pid: app.processIdentifier)
            if let el = result.element, let fp = fingerprintOfElement(el) {
                remember(fp, for: bundle)
                completion(fp)
                return
            }
            // 权限没开 / 元素彻底无效，再试也没意义
            if !axErrorIsRetryable(result.error) { onGiveUp(); return }
            scheduleRetry(bundle: bundle, index: index + 1, delays: delays,
                          completion: completion, onGiveUp: onGiveUp)
        }
    }

    // MARK: - 底层

    /// 已经打过「请构建无障碍树」招呼的进程，避免每次都重复发
    private static var manualAXAsked: Set<pid_t> = []

    /// Chromium / Electron 的无障碍树是**按需构建**的。
    ///
    /// 它们平时只维护一个极简骨架，所以 `AXFocusedWindow` 能读到，
    /// 但 `AXFocusedUIElement` 直接返回 `noValue` —— 看起来像「应用不支持 AX」，
    /// 其实是它还没开始建树。客户端把 `AXManualAccessibility` 置为 true 之后，
    /// Chromium 才会真正把整棵树（含 DOM class）建出来。
    ///
    /// 这是 Electron 应用「有时能识别位置、有时不能」的根源：树建好之前是读不到的。
    /// 对非 Chromium 应用这个属性不受支持，设置失败无副作用。
    private static func askForFullAXTree(pid: pid_t) {
        guard !manualAXAsked.contains(pid) else { return }
        // 防止 pid 反复变化时无限增长
        if manualAXAsked.count > 64 { manualAXAsked.removeAll() }
        manualAXAsked.insert(pid)
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// 应用刚激活时先打一声招呼，让它开始建无障碍树。
    /// 这样等用户真去点面板、或规则需要读焦点时，树已经建好了。
    static func prepare(bundle: String) {
        guard let app = runningApp(bundle: bundle) else { return }
        askForFullAXTree(pid: app.processIdentifier)
    }

    private static func readWithRetry(pid: pid_t, bundle: String, attempts: Int) -> FocusFingerprint? {
        for i in 0..<max(1, attempts) {
            let result = focusedElementResult(pid: pid)
            if let el = result.element, let fp = fingerprintOfElement(el) {
                return fp
            }
            guard axErrorIsRetryable(result.error), i + 1 < attempts else {
                return nil
            }
            // 第一次失败就把「请建树」的招呼打出去，后面几次给它时间建
            if i == 0 { askForFullAXTree(pid: pid) }
            // 目标应用正在搭 AX 树，等一下再问。总等待只有几十毫秒。
            usleep(useconds_t(35_000 * (i + 1)))
        }
        return nil
    }
}
