import AppKit
import ApplicationServices
import Carbon
import Foundation

/// 三条触发源：
///  1. 应用激活（NSWorkspace 通知）
///  2. 焦点元素变化（AX 观察者，能感知「同一个应用里换了个输入区」）
///  3. 输入法变化（TIS 分布式通知，用来识别用户手动切换）
///
/// 这里只负责「收到信号 → 回调」，具体怎么处理交给上层。
final class TriggerCenter: NSObject {

    var onAppActivated: ((NSRunningApplication) -> Void)?
    var onFocusChanged: (() -> Void)?
    var onInputSourceChanged: (() -> Void)?

    private var started = false
    private var axObserver: AXObserver?
    private var observedPID: pid_t = 0

    func start() {
        guard !started else { return }
        started = true
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil)

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDistributedCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer = observer else { return }
                let me = Unmanaged<TriggerCenter>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { me.onInputSourceChanged?() }
            },
            kTISNotifySelectedKeyboardInputSourceChanged,
            nil,
            .deliverImmediately)
    }

    func stop() {
        guard started else { return }
        started = false
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetDistributedCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(kTISNotifySelectedKeyboardInputSourceChanged), nil)
        resetAXObserver()
    }

    func resetAXObserver() {
        if let observer = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        axObserver = nil
        observedPID = 0
    }

    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        onAppActivated?(app)
    }

    /// 把 AX 观察者挂到当前前台应用上（换了应用就重新挂）
    func attachAXObserver(pid: pid_t, bundle: String) {
        guard AXIsProcessTrusted() else {
            if let observer = axObserver {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
            axObserver = nil
            observedPID = 0
            return
        }
        guard pid > 0, pid != observedPID else { return }

        if let old = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old), .commonModes)
            axObserver = nil
        }
        observedPID = 0

        var obs: AXObserver?
        let err = AXObserverCreate(pid, { _, _, _, refcon in
            guard let refcon = refcon else { return }
            let me = Unmanaged<TriggerCenter>.fromOpaque(refcon).takeUnretainedValue()
            DispatchQueue.main.async { me.onFocusChanged?() }
        }, &obs)

        guard err == .success, let obs = obs else {
            log("AXObserverCreate 失败(\(bundle)) err=\(err.rawValue)")
            return
        }

        let appEl = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let e1 = AXObserverAddNotification(obs, appEl, kAXFocusedUIElementChangedNotification as CFString, refcon)
        let e2 = AXObserverAddNotification(obs, appEl, kAXFocusedWindowChangedNotification as CFString, refcon)
        if e1 != .success && e2 != .success {
            log("AX 通知注册失败(\(bundle))：\(e1.rawValue)/\(e2.rawValue)（多半是未授权辅助功能）")
            return
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        axObserver = obs
        observedPID = pid
    }
}
