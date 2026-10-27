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
    /// 在主线程记录诊断，避免在 AX 工作队列并发写日志。
    private static var lastDiagnostic: [String: (String, Date)] = [:]

    private static func diagnose(_ bundle: String, _ message: String) {
        if let previous = lastDiagnostic[bundle], previous.0 == message,
           Date().timeIntervalSince(previous.1) < 10 { return }
        if lastDiagnostic.count > 64 { lastDiagnostic.removeAll() }
        lastDiagnostic[bundle] = (message, Date())
        log("AX 焦点 \(bundle): \(message)")
    }

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
                           diagnostic: Bool = false,
                           completion: @escaping (FocusFingerprint) -> Void,
                           onGiveUp: @escaping () -> Void = {}) -> Request {
        let request = Request()
        guard AXIsProcessTrusted() else {
            if diagnostic { diagnose(bundle, "未获得辅助功能权限") }
            onGiveUp(); return request
        }
        let target = requireFrontmost ? NSWorkspace.shared.frontmostApplication : runningApp(bundle: bundle)
        guard let target = target, target.bundleIdentifier == bundle else {
            onGiveUp()
            return request
        }
        scheduleRetry(request, bundle: bundle, pid: target.processIdentifier, index: 0, delays: delays,
                      requireFrontmost: requireFrontmost, diagnostic: diagnostic, completion: completion, onGiveUp: onGiveUp)
        return request
    }

    private static func scheduleRetry(_ request: Request, bundle: String, pid: pid_t,
                                      index: Int, delays: [Double], requireFrontmost: Bool,
                                      diagnostic: Bool,
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
                let treeError = askForFullAXTree(pid: pid)
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
                        if diagnostic {
                            diagnose(bundle, "pid=\(pid) 成功 role=\(fp.role) dom=\(fp.domClasses) ancestors=\(fp.ancestorClasses) tree=\(treeError.map(axErrorName) ?? "已请求")")
                        }
                        remember(fp, for: bundle)
                        completion(fp)
                    } else if result.error == .success || axErrorIsRetryable(result.error) {
                        if diagnostic {
                            diagnose(bundle, "pid=\(pid) 第\(index + 1)次读取失败 error=\(axErrorName(result.error)) 空指纹=\(result.element != nil) tree=\(treeError.map(axErrorName) ?? "已请求")")
                        }
                        scheduleRetry(request, bundle: bundle, pid: pid, index: index + 1, delays: delays,
                                      requireFrontmost: requireFrontmost, diagnostic: diagnostic, completion: completion, onGiveUp: onGiveUp)
                    } else {
                        if diagnostic { diagnose(bundle, "pid=\(pid) 不可重试 error=\(axErrorName(result.error))") }
                        onGiveUp()
                    }
                }
            }
        }
    }

    @discardableResult
    private static func askForFullAXTree(pid: pid_t) -> AXError? {
        guard !manualAXAsked.contains(pid) else { return nil }
        if manualAXAsked.count > 64 { manualAXAsked.removeAll() }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.15)
        let error = AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if error == .success { manualAXAsked.insert(pid) }
        return error
    }

    static func prepare(bundle: String) {
        guard let app = runningApp(bundle: bundle) else { return }
        let pid = app.processIdentifier
        queue.async { askForFullAXTree(pid: pid) }
    }
}
