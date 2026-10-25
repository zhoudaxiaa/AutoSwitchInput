import Cocoa

/// 菜单栏图标、左键小面板、右键菜单。
///
/// 分工：左键面板负责「改规则」（应用级 + 此处），右键菜单只放
/// 开关类与清理入口，两边不重复同一件事。
final class StatusBarController: NSObject, NSMenuDelegate, NSPopoverDelegate {

    weak var host: AppActions?

    private var statusItem: NSStatusItem!
    private var popover: NSPopover?
    private var quickPanel: QuickPanelController?
    private var popoverLastClosed: Date = .distantPast

    func install() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }

        button.font = .systemFont(ofSize: 12, weight: .medium)
        // 菜单栏用单色 template 图标，自动适配深浅色菜单栏
        if let url = Bundle.main.resourceURL?.appendingPathComponent("MenuBarIcon.png"),
           let img = NSImage(contentsOf: url) {
            img.size = NSSize(width: 18, height: 18)
            img.isTemplate = true
            button.image = img
            button.imagePosition = .imageLeading
        }
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func statusItemClicked() {
        if let e = NSApp.currentEvent, e.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    // MARK: - 小面板

    func togglePopover() {
        guard let button = statusItem?.button, let host = host else { return }

        if let p = popover, p.isShown {
            p.performClose(nil)
            return
        }
        // transient 面板会先因「点击外部」关闭再触发 action，避免反复开合
        if Date().timeIntervalSince(popoverLastClosed) < 0.25 { return }

        let panel = QuickPanelController()
        panel.app = host
        panel.refresh()

        let p = NSPopover()
        p.contentViewController = panel
        p.behavior = .transient
        p.animates = true
        p.delegate = self

        quickPanel = panel
        popover = p

        NSApp.activate(ignoringOtherApps: true)
        p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        p.contentViewController?.view.window?.makeKey()
    }

    func closePopover() {
        popover?.performClose(nil)
    }

    var isPopoverShown: Bool { popover?.isShown ?? false }

    func popoverDidClose(_ notification: Notification) {
        popoverLastClosed = Date()
        popover = nil
        quickPanel = nil
    }

    /// 整块重刷（规则或语言变化后）
    func refreshPanel() {
        if isPopoverShown { quickPanel?.refresh() }
    }

    /// 只更新「当前输入法」那一行，避免面板打开时重置用户正在选的项
    func refreshPanelCurrentOnly() {
        if isPopoverShown { quickPanel?.refreshCurrentOnly() }
    }

    // MARK: - 状态栏标题

    func refreshTitle() {
        guard let host = host, let button = statusItem?.button else { return }
        let name = currentSourceName()
        let mark: String
        if name.contains("搜狗") || name.contains("拼音") || name.contains("简体") || name.contains("注音") {
            mark = "中"
        } else if name.uppercased().contains("ABC") || name.contains("英文") || name.contains("U.S") {
            mark = "英"
        } else {
            mark = String(name.prefix(1))
        }
        button.title = host.config.enabled ? " " + mark : " " + L("statusbar.off")
        button.alphaValue = host.config.enabled ? 1.0 : 0.45
        button.toolTip = LF("statusbar.tip", name)

        // 面板开着时，同步它的「当前输入法」那一行
        refreshPanelCurrentOnly()
    }

    // MARK: - 右键菜单

    private func showContextMenu() {
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let host = host else { return }

        // 菜单是从状态栏点开的，此刻「前台」可能已经是本应用自己，
        // 所以要优先用最后激活的外部应用。
        let target = menuTargetBundle()
        let appName = target.map { appDisplayInfo(for: $0).name } ?? L("panel.unknown")

        let open = NSMenuItem(title: L("menu.settings"),
                              action: #selector(openSettings), keyEquivalent: ",")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())

        // 只读状态行：当前应用 → 当前输入法
        let head = NSMenuItem(title: "\(appName) → \(currentSourceName())", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)

        // 已配的位置规则：留作清理入口（面板只能删「光标所在的那一处」）
        if let bundle = target {
            let indices = host.config.contexts.indices.filter { host.config.contexts[$0].bundle == bundle }
            if !indices.isEmpty {
                let sub = NSMenu()
                for i in indices {
                    let r = host.config.contexts[i]
                    let item = NSMenuItem(title: "\(r.note ?? "-") → \(sourceName(r.source) ?? r.source)",
                                          action: #selector(deleteContextRule(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = r.id
                    sub.addItem(item)
                }
                sub.addItem(.separator())
                let clearAll = NSMenuItem(title: L("menu.clearContexts"),
                                          action: #selector(clearContexts), keyEquivalent: "")
                clearAll.target = self
                sub.addItem(clearAll)

                let parent = NSMenuItem(title: LF("menu.contexts", indices.count), action: nil, keyEquivalent: "")
                parent.submenu = sub
                menu.addItem(parent)
            }
        }

        // 诊断项：只有 Support 目录里存在 debug-ax 文件时才出现
        if FileManager.default.fileExists(atPath: AppPaths.debugAXMarkerURL.path) {
            let dump = NSMenuItem(title: L("menu.axdump"),
                                  action: #selector(dumpFocusNow), keyEquivalent: "")
            dump.target = self
            menu.addItem(dump)
        }

        menu.addItem(.separator())

        let toggle = NSMenuItem(title: L("menu.enabled"), action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = host.config.enabled ? .on : .off
        menu.addItem(toggle)

        let learn = NSMenuItem(title: L("menu.learn"), action: #selector(toggleLearn), keyEquivalent: "")
        learn.target = self
        learn.state = host.config.learn ? .on : .off
        menu.addItem(learn)

        let login = NSMenuItem(title: L("menu.login"), action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = host.loginInstalled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        let cfg = NSMenuItem(title: L("menu.config"), action: #selector(openConfig), keyEquivalent: "")
        cfg.target = self
        menu.addItem(cfg)

        let logItem = NSMenuItem(title: L("menu.log"), action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: L("menu.quit"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func openSettings() { host?.openSettings() }
    @objc private func toggleEnabled() { host?.setEnabled(!(host?.config.enabled ?? true)) }
    @objc private func toggleLearn() { host?.setLearn(!(host?.config.learn ?? true)) }
    @objc private func toggleLogin() { host?.toggleLogin() }
    @objc private func openConfig() { host?.openConfig() }
    @objc private func openLog() { host?.openLog() }
    @objc private func quit() { host?.quit() }
    @objc private func dumpFocusNow() { host?.dumpFocusNow() }

    @objc private func deleteContextRule(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        host?.removeContextRule(id: id)
    }

    @objc private func clearContexts() {
        guard let bundle = menuTargetBundle() else { return }
        host?.clearContextRules(for: bundle)
    }

    /// 菜单要操作的那个应用：最后激活的外部应用优先，
    /// 否则退回当前前台（排除自己）。
    private func menuTargetBundle() -> String? {
        if let b = host?.lastExternalBundle, b != kBundleSelf, appExists(b) { return b }
        return FocusProbe.frontmostExternal()?.bundle
    }
}
