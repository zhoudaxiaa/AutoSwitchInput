import AppKit
import Foundation

/// AX 调用在串行工作队列执行；结果与缓存只在主线程处理。
enum FocusProbe {
    final class Request {
        private let lock = NSLock()
        private var isCancelled = false
        var cancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return isCancelled
        }
        func cancel() {
            lock.lock()
            isCancelled = true
            lock.unlock()
        }
    }

    private struct Entry {
        let fingerprint: FocusFingerprint
        let pid: pid_t
        let at: Date
    }
    private static var cache: [String: Entry] = [:]
    private static let queue = DispatchQueue(label: "com.local.autoswitchinput.focus", qos: .userInitiated)
    /// 仅由 queue 访问。权限恢复后，失败的请求可以再次尝试。
    private static var manualAXAsked: Set<pid_t> = []

    static func runningApp(bundle: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
    }

    static func remember(_ fp: FocusFingerprint, for bundle: String) {
        guard let pid = runningApp(bundle: bundle)?.processIdentifier else { return }
        cache[bundle] = Entry(fingerprint: fp, pid: pid, at: Date())
    }

    static func cached(for bundle: String) -> FocusFingerprint? {
        guard let entry = cache[bundle] else { return nil }
        guard Date().timeIntervalSince(entry.at) < 120,
              runningApp(bundle: bundle)?.processIdentifier == entry.pid else {
            cache.removeValue(forKey: bundle)
            return nil
        }
        return entry.fingerprint
    }

    static func forget(_ bundle: String) { cache.removeValue(forKey: bundle) }

    /// 授权发生变化后，丢弃展示缓存并让 Electron 重新启用完整 AX 树。
    static func invalidate() {
        cache.removeAll()
        queue.async { manualAXAsked.removeAll() }
    }

    static func frontmostExternal() -> (bundle: String, pid: pid_t)? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundle = front.bundleIdentifier, bundle != kBundleSelf else { return nil }
        return (bundle, front.processIdentifier)
    }

    /// 请求绑定启动时的 PID；应用重启或前台改变后不接受旧结果。
    @discardableResult
    static func retryAsync(bundle: String,
                           delays: [Double] = [0, 0.06, 0.18, 0.45],
                           requireFrontmost: Bool = false,
                           completion: @escaping (FocusFingerprint) -> Void,
                           onGiveUp: @escaping () -> Void = {}) -> Request {
        let request = Request()
        guard AXIsProcessTrusted() else { onGiveUp(); return request }
        let target = requireFrontmost ? NSWorkspace.shared.frontmostApplication : runningApp(bundle: bundle)
        guard let target = target, target.bundleIdentifier == bundle else {
            onGiveUp()
            return request
        }
        scheduleRetry(request, bundle: bundle, pid: target.processIdentifier, index: 0, delays: delays,
                      requireFrontmost: requireFrontmost, completion: completion, onGiveUp: onGiveUp)
        return request
    }

    private static func scheduleRetry(_ request: Request, bundle: String, pid: pid_t,
                                      index: Int, delays: [Double], requireFrontmost: Bool,
                                      completion: @escaping (FocusFingerprint) -> Void,
                                      onGiveUp: @escaping () -> Void) {
        guard !request.cancelled else { return }
        guard index < delays.count else { onGiveUp(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delays[index]) {
            guard !request.cancelled else { return }
            guard NSRunningApplication.runningApplications(withBundleIdentifier: bundle).contains(where: { $0.processIdentifier == pid }),
                  !requireFrontmost || NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                onGiveUp()
                return
            }
            queue.async {
                guard !request.cancelled else { return }
                askForFullAXTree(pid: pid)
                let result = focusedElementResult(pid: pid)
                let fp = result.element.flatMap(fingerprintOfElement)
                DispatchQueue.main.async {
                    guard !request.cancelled else { return }
                    guard NSRunningApplication.runningApplications(withBundleIdentifier: bundle).contains(where: { $0.processIdentifier == pid }),
                          !requireFrontmost || NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                        onGiveUp()
                        return
                    }
                    if let fp = fp {
                        remember(fp, for: bundle)
                        completion(fp)
                    } else if result.error == .success || axErrorIsRetryable(result.error) {
                        scheduleRetry(request, bundle: bundle, pid: pid, index: index + 1, delays: delays,
                                      requireFrontmost: requireFrontmost, completion: completion, onGiveUp: onGiveUp)
                    } else {
                        onGiveUp()
                    }
                }
            }
        }
    }

    private static func askForFullAXTree(pid: pid_t) {
        guard !manualAXAsked.contains(pid) else { return }
        if manualAXAsked.count > 64 { manualAXAsked.removeAll() }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.15)
        let error = AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if error == .success { manualAXAsked.insert(pid) }
    }

    static func prepare(bundle: String) {
        guard let app = runningApp(bundle: bundle) else { return }
        let pid = app.processIdentifier
        queue.async { askForFullAXTree(pid: pid) }
    }
}
