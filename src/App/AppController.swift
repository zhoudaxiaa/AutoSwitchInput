import Cocoa
import ApplicationServices

/// 应用内核：持有配置与运行时状态，向上给界面提供 AppActions，向下驱动切换引擎。
final class AppController: NSObject, AppActions {

    /// 界面通过 AppActions 只读；内部各 extension 直接改。
    /// 每次改动都要跟一次 saveConfig()。
    var config = Config()
    var lastExternalBundle: String?

    let engine = SwitchEngine()
    let triggers = TriggerCenter()
    let statusBar = StatusBarController()

    var settings: SettingsWindowController { .shared }

    /// 只有真正加载了配置的主实例才允许写盘。
    /// 否则「被 launchctl 拉起的第二实例」会在退出时用空默认值覆盖配置。
    private var isPrimary = false
    private var isFirstRun = false

    /// 激活时间与激活应用：用来区分「用户手动切换」和「应用自己在恢复输入法」
    private var learningPolicy = LearningPolicy()
    private var refreshScheduled = false
    private var accessibilityTrusted = false
    private var diagnosticRequest: FocusProbe.Request?
    private var diagnosticPending = false

    // MARK: - 启动与退出

    func start() {
        isPrimary = true
        loadConfig()
        if !FileManager.default.fileExists(atPath: AppPaths.configURL.path) {
            isFirstRun = true
            ConfigStore.importLegacyRules(into: &config)
            saveConfig()
        }

        // 界面语言要在建任何 UI 之前定下来
        setAppLanguage(config.language)

        engine.configProvider = { [unowned self] in self.config }
        statusBar.host = self
        statusBar.install()
        settings.app = self
        wireTriggers()

        if DebugHooks.runIfNeeded(controller: self) { return }

        log("=== 启动 | 规则 \(config.apps.count) 条 | learn=\(config.learn) | args=\(CommandLine.arguments) ===")

        // 只在第一次运行（还没有配置文件）时把设置窗口亮出来，之后安静待在菜单栏
        if isFirstRun && !CommandLine.arguments.contains("--silent") {
            settings.show()
        }

        promptAccessibilityOnce()
        accessibilityTrusted = AXIsProcessTrusted()
        // 更新签名可能使原授权失效：有位置规则时必须明确展示恢复入口。
        if !accessibilityTrusted && !config.contexts.isEmpty && !CommandLine.arguments.contains("--silent") {
            settings.show()
        }

        if let front = NSWorkspace.shared.frontmostApplication { handleAppActivated(front) }
        engine.startWatchdog()
        refreshStatusTitle()
    }

    func shutdown() {
        guard isPrimary else { return }
        engine.stopWatchdog()
        triggers.stop()
        saveConfig()
        log("=== 退出 ===")
    }

    /// 辅助功能授权：只在首次启动时弹一次系统提示，之后靠界面里的状态提示
    private func promptAccessibilityOnce() {
        guard !AXIsProcessTrusted() else { return }
        let key = "didPromptAccessibility"
        if !UserDefaults.standard.bool(forKey: key) {
            UserDefaults.standard.set(true, forKey: key)
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        log("⚠️ 未获得辅助功能权限，焦点级触发不可用（应用切换触发仍工作）")
    }

    // MARK: - 配置

    private func loadConfig() {
        if let c = ConfigStore.load() { config = c }
    }

    func saveConfig() {
        guard isPrimary else { return }
        config = config.validated()
        ConfigStore.save(config)
    }

    /// 配置变更统一取消旧任务、持久化，并在下一轮事件循环合并刷新。
    /// 避免在下拉控件派发 action 时销毁控件自身。
    func commitConfig(reason: String, apply: Bool = true) {
        engine.cancelPendingApply()
        saveConfig()
        if !refreshScheduled {
            refreshScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.refreshScheduled = false
                self.refreshStatusTitle()
                self.settings.reload()
                self.statusBar.refreshPanel()
            }
        }
        if apply { engine.scheduleApply(reason: reason) }
    }

    func setAppRule(bundle: String, source: String?) {
        if let source = source {
            config.apps[bundle] = source
        } else {
            config.apps.removeValue(forKey: bundle)
        }
        engine.clearUserOverride()
        commitConfig(reason: "应用规则变更")
    }

    // MARK: - 开关

    func setEnabled(_ on: Bool) {
        config.enabled = on
        commitConfig(reason: "启用状态变更", apply: on)
        log("enabled = \(config.enabled)")
    }

    func setLearn(_ on: Bool) {
        config.learn = on
        commitConfig(reason: "学习状态变更", apply: false)
    }

    var loginInstalled: Bool { LaunchAgent.isInstalled }

    func toggleLogin() {
        LaunchAgent.toggle()
        settings.reload()
    }

    func setLanguage(_ code: String?) {
        config.language = code
        commitConfig(reason: "语言变更", apply: false)
    }

    // MARK: - 界面与外部动作

    func openSettings() { settings.show() }

    func reloadSettingsWindow() { settings.reload() }

    func refreshStatusTitle() { statusBar.refreshTitle() }

    func openConfig() {
        if !FileManager.default.fileExists(atPath: AppPaths.configURL.path) { saveConfig() }
        NSWorkspace.shared.open(AppPaths.configURL)
    }

    func openLog() { NSWorkspace.shared.open(AppPaths.logFileURL) }

    func closePopover() { statusBar.closePopover() }

    func quit() { NSApp.terminate(nil) }

    // MARK: - 触发器接线

    private func wireTriggers() {
        triggers.onAppActivated = { [weak self] app in self?.handleAppActivated(app) }
        triggers.onFocusChanged = { [weak self] in
            self?.engine.scheduleApply(reason: "焦点变化", delay: 0.08)
        }
        triggers.onInputSourceChanged = { [weak self] in self?.handleInputSourceChanged() }
        engine.onWatchdog = { [weak self] in
            self?.refreshAccessibilityStatus()
            guard let front = NSWorkspace.shared.frontmostApplication,
                  let bundle = front.bundleIdentifier, bundle != kBundleSelf else { return }
            self?.triggers.attachAXObserver(pid: front.processIdentifier, bundle: bundle)
            // debug-ax 存在时主动采样，未配置位置规则也能定位采集失败。
            if let self = self, !self.diagnosticPending,
               FileManager.default.fileExists(atPath: AppPaths.debugAXMarkerURL.path) {
                self.diagnosticPending = true
                self.diagnosticRequest = FocusProbe.retryAsync(bundle: bundle, requireFrontmost: true,
                                                               diagnostic: true) { [weak self] _ in
                    self?.diagnosticPending = false
                } onGiveUp: { [weak self] in
                    self?.diagnosticPending = false
                }
            }
        }
        triggers.start()
    }

    private func refreshAccessibilityStatus() {
        let trusted = AXIsProcessTrusted()
        guard trusted != accessibilityTrusted else { return }
        accessibilityTrusted = trusted
        engine.cancelPendingApply()
        FocusProbe.invalidate()
        triggers.resetAXObserver()
        settings.reload()
        statusBar.refreshPanel()
        log(trusted ? "✓ 辅助功能授权已恢复，重新挂载焦点观察" : "⚠️ 辅助功能授权已失效，位置规则暂不可用")
        if trusted, let front = NSWorkspace.shared.frontmostApplication,
           let bundle = front.bundleIdentifier, bundle != kBundleSelf {
            FocusProbe.prepare(bundle: bundle)
        }
    }

    private func handleAppActivated(_ app: NSRunningApplication) {
        guard let bundle = app.bundleIdentifier, bundle != kBundleSelf else { return }

        lastExternalBundle = bundle
        log("→ 激活 \(bundle) (pid \(app.processIdentifier))")

        learningPolicy.activated(bundle)
        engine.clearUserOverride()

        // 提前让 Electron 类应用开始构建无障碍树：
        // 它们的树是按需建的，不先打招呼，稍后读焦点只会拿到 noValue
        if config.hasContextRules(for: bundle) {
            FocusProbe.prepare(bundle: bundle)
        }

        triggers.attachAXObserver(pid: app.processIdentifier, bundle: bundle)
        engine.scheduleApply(reason: "激活", delay: 0.04)
    }

    /// 识别「用户自己切了输入法」并学习。
    /// 与引擎的自我切换区分开，否则会把自己的切换学成用户操作，规则越学越乱。
    private func handleInputSourceChanged() {
        let now = Date()
        let current = currentSourceID()
        refreshStatusTitle()

        // 自己造成的切换：TIS 有时连发两次通知，不能第一次就清标志，
        // 否则第二次会漏到「学习」里污染规则
        if engine.isSelfInflicted(current) { return }
        engine.clearExpected()

        guard !secureInputActive(), let current = current,
              let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              learningPolicy.shouldRespectChange(bundle: bundle, config: config, at: now) else { return }

        engine.markUserOverride(bundle: bundle, for: 2.5)
        guard learningPolicy.shouldLearn(bundle: bundle, config: config) else { return }
        if config.apps[bundle] != current {
            config.apps[bundle] = current
            commitConfig(reason: "手动学习", apply: false)
            log("✎ 学习：\(bundle) → \(current)")
        }
    }

    // MARK: - 诊断

    func dumpFocusNow() {
        var out = "\n--- \(Date()) ---\n"

        var bundle = lastExternalBundle
        var pid = bundle.flatMap { FocusProbe.runningApp(bundle: $0)?.processIdentifier } ?? 0
        // 前台变成了自己（点图标时偶尔会这样），退回最后激活的外部应用
        if bundle == kBundleSelf || pid <= 0 {
            if let front = FocusProbe.frontmostExternal() {
                bundle = front.bundle
                pid = front.pid
            }
        }
        guard pid > 0 else {
            out += "no frontmost app\n"
            appendText(out, to: AppPaths.focusDumpURL)
            return
        }

        out += "app: \(bundle ?? "?") pid=\(pid)\n"
        if let fp = focusedFingerprint(pid: pid) {
            out += "  \(fp.summary)\n"
            out += "  ancestorTitles: \(fp.ancestorTitles)\n"
            out += "  ancestorIDs: \(fp.ancestorIDs)\n"
        } else {
            out += "  <nil>\n"
        }
        if let el = focusedElement(pid: pid) {
            for line in axAllAttributes(el) { out += "    · \(line)\n" }
        }
        appendText(out, to: AppPaths.focusDumpURL)
        log("ax focus dumped -> \(AppPaths.focusDumpURL.path)")
    }

    // MARK: - 供调试钩子使用

    func startWatchdog() { engine.startWatchdog() }
    func togglePopover() { statusBar.togglePopover() }
    var popoverShown: Bool { statusBar.isPopoverShown }
    func rebuildSettingsWindow() { settings.rebuild() }
}
