import Cocoa

final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    weak var app: AppActions?

    private var window: NSWindow?
    private var listStack: NSStackView!
    private var enabledSwitch: NSSwitch!
    private var learnSwitch: NSSwitch!
    private var loginCheck: NSButton!
    private var languagePopup: NSPopUpButton!
    private var statusLabel: NSTextField!
    private var emptyLabel: NSTextField!
    private var cleanBtn: NSButton!

    var contentViewForSnapshot: NSView? { window?.contentView }

    func show() {
        if window == nil { build() }
        reload()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        log("show(): window=\(window != nil) visible=\(window?.isVisible ?? false) frame=\(window?.frame.debugDescription ?? "nil")")
    }

    private func build() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 588),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        w.title = L("app.name")
        w.center()
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.minSize = NSSize(width: 560, height: 470)

        let content = NSView()

        let title = NSTextField(labelWithString: L("app.name"))
        title.font = .systemFont(ofSize: 16, weight: .semibold)

        let subtitle = NSTextField(labelWithString: L("window.subtitle"))
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor

        let titleStack = NSStackView(views: [title, subtitle])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2

        let enableLabel = NSTextField(labelWithString: L("window.enable"))
        enableLabel.font = .systemFont(ofSize: 12)

        enabledSwitch = NSSwitch()
        enabledSwitch.target = self
        enabledSwitch.action = #selector(toggleEnabled)

        let topRow = NSStackView(views: [titleStack, NSView(), enableLabel, enabledSwitch])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 8
        topRow.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        listStack = NSStackView()
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 0
        listStack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        // 文档视图必须是翻转的，否则规则少于可视高度时会沉到列表底部
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(listStack)
        scroll.documentView = doc
        NSLayoutConstraint.activate([
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            listStack.topAnchor.constraint(equalTo: doc.topAnchor),
            listStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            listStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])

        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 1
        box.cornerRadius = 8
        box.fillColor = .controlBackgroundColor
        box.borderColor = .separatorColor
        box.translatesAutoresizingMaskIntoConstraints = false
        box.contentViewMargins = .zero
        box.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 1),
            scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -1),
            scroll.topAnchor.constraint(equalTo: box.topAnchor, constant: 1),
            scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -1),
        ])

        emptyLabel = NSTextField(labelWithString: L("empty.hint"))
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let addBtn = NSButton(title: L("btn.add"), target: self, action: #selector(addCurrent))
        addBtn.bezelStyle = .rounded

        let refreshBtn = NSButton(title: L("btn.refresh"), target: self, action: #selector(refreshTapped))
        refreshBtn.bezelStyle = .rounded

        let configBtn = NSButton(title: L("btn.config"), target: self, action: #selector(openConfig))
        configBtn.bezelStyle = .rounded

        cleanBtn = NSButton(title: L("btn.clean"), target: self, action: #selector(cleanInvalid))
        cleanBtn.bezelStyle = .rounded
        cleanBtn.isEnabled = false

        loginCheck = NSButton(checkboxWithTitle: L("checkbox.login"), target: self, action: #selector(toggleLogin))
        loginCheck.font = .systemFont(ofSize: 12)

        learnSwitch = NSSwitch()
        learnSwitch.target = self
        learnSwitch.action = #selector(toggleLearn)
        learnSwitch.controlSize = .small
        let learnLabel = NSTextField(labelWithString: L("label.learn"))
        learnLabel.font = .systemFont(ofSize: 12)

        // 语言选择：跟随系统 / 简体中文 / English
        let langLabel = NSTextField(labelWithString: L("label.language"))
        langLabel.font = .systemFont(ofSize: 12)

        languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        languagePopup.font = .systemFont(ofSize: 12)
        languagePopup.controlSize = .small
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)
        let langOptions: [(String, String?)] = [
            (L("lang.system"), nil),
            ("简体中文", "zh-Hans"),
            ("English", "en"),
        ]
        for (title, code) in langOptions {
            languagePopup.addItem(withTitle: title)
            languagePopup.lastItem?.representedObject = code
        }
        languagePopup.widthAnchor.constraint(equalToConstant: 116).isActive = true

        // 第一行：动作按钮
        let actionRow = NSStackView(views: [addBtn, refreshBtn, configBtn, cleanBtn, NSView()])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 10
        actionRow.translatesAutoresizingMaskIntoConstraints = false

        // 分隔线
        let footerSep = NSBox()
        footerSep.boxType = .separator
        footerSep.translatesAutoresizingMaskIntoConstraints = false

        // 第二行：设置项（语言 / 学习 / 开机启动）统一放一排
        let settingsRow = NSStackView(views: [
            langLabel, languagePopup, NSView(), learnLabel, learnSwitch, loginCheck,
        ])
        settingsRow.orientation = .horizontal
        settingsRow.alignment = .centerY
        settingsRow.spacing = 8
        settingsRow.translatesAutoresizingMaskIntoConstraints = false

        for v in [topRow, statusLabel, box, actionRow, footerSep, settingsRow, emptyLabel] as [NSView] {
            content.addSubview(v)
        }

        NSLayoutConstraint.activate([
            topRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            topRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            topRow.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),

            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            statusLabel.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: 8),

            box.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            box.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            box.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            box.bottomAnchor.constraint(equalTo: actionRow.topAnchor, constant: -14),

            actionRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            actionRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            footerSep.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            footerSep.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            footerSep.topAnchor.constraint(equalTo: actionRow.bottomAnchor, constant: 12),

            settingsRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            settingsRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            settingsRow.topAnchor.constraint(equalTo: footerSep.bottomAnchor, constant: 10),
            settingsRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),

            emptyLabel.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])

        w.contentView = content
        window = w
    }

    func reload() {
        guard let app = app, listStack != nil else { return }
        enabledSwitch.state = app.config.enabled ? .on : .off
        learnSwitch.state = app.config.learn ? .on : .off
        loginCheck.state = app.loginInstalled ? .on : .off

        if let idx = languagePopup.itemArray.firstIndex(where: {
            ($0.representedObject as? String) == app.config.language
        }) {
            languagePopup.selectItem(at: idx)
        } else {
            languagePopup.selectItem(at: 0)
        }

        let ax = AXIsProcessTrusted() ? L("status.ax.granted") : L("status.ax.denied")
        statusLabel.stringValue = LF("status.line",
                                     LF("status.current", currentSourceName()),
                                     ax,
                                     LF("status.rules", app.config.apps.count))

        for v in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }

        let sources = typeableSources()
        let bundles = app.config.apps.keys.sorted {
            appDisplayInfo(for: $0).name.localizedStandardCompare(appDisplayInfo(for: $1).name) == .orderedAscending
        }

        emptyLabel.isHidden = !bundles.isEmpty

        let stale = bundles.filter { !appExists($0) }
        cleanBtn.isEnabled = !stale.isEmpty
        cleanBtn.title = stale.isEmpty ? L("btn.clean") : LF("btn.clean.n", stale.count)

        for b in bundles {
            let row = RuleRow(bundle: b, ruleID: app.config.apps[b], sources: sources,
                              installed: appExists(b))
            row.onRemove = { [weak self] in
                app.setAppRule(bundle: b, source: nil)
                log("✎ 删除规则 \(b)（剩余 \(app.config.apps.count) 条）")
                self?.reload()
            }
            row.onChange = { [weak self] newID in
                app.setAppRule(bundle: b, source: newID)
                log("✎ 改规则 \(b) → \(newID ?? "不设置")")
                self?.reload()
            }
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true

            let line = NSBox()
            line.boxType = .separator
            line.translatesAutoresizingMaskIntoConstraints = false
            listStack.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        }
    }

    @objc private func toggleEnabled() {
        app?.setEnabled(enabledSwitch.state == .on)
        reload()
    }

    @objc private func toggleLearn() {
        app?.setLearn(learnSwitch.state == .on)
        reload()
    }

    @objc private func toggleLogin() {
        app?.toggleLogin()
        reload()
    }

    @objc private func languageChanged() {
        guard let app = app else { return }
        let code = languagePopup.selectedItem?.representedObject as? String
        guard code != app.config.language else { return }

        app.setLanguage(code)
        log("language -> \(code ?? "system")")

        // 文案是在建视图时取出来的，必须整窗重建；
        // 放到下一个 runloop，避免在 popup 自己的 action 里销毁它
        DispatchQueue.main.async {
            setAppLanguage(code)
            self.rebuild()
            app.refreshStatusTitle()
            app.closePopover()
        }
    }

    /// 语言变了之后整窗重建（build() 里的文案是取快照的）
    func rebuild() {
        let old = window
        window = nil
        old?.orderOut(nil)
        old?.close()
        build()
        reload()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func refreshTapped() { reload() }

    @objc private func cleanInvalid() {
        guard let app = app else { return }
        let stale = app.config.apps.keys.filter { !appExists($0) }.sorted()
        guard !stale.isEmpty else { NSSound.beep(); return }

        let alert = NSAlert()
        alert.messageText = LF("alert.clean.title", stale.count)
        alert.informativeText = stale.map { "· \($0)" }.joined(separator: "\n")
            + "\n\n" + L("alert.clean.body")
        alert.addButton(withTitle: L("alert.clean.ok"))
        alert.addButton(withTitle: L("alert.cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            for b in stale { app.setAppRule(bundle: b, source: nil) }
            log("✎ 清理无效规则 \(stale.count) 条：\(stale.joined(separator: ", "))（剩余 \(app.config.apps.count) 条）")
            reload()
        }
    }

    @objc private func openConfig() { app?.openConfig() }

    @objc private func addCurrent() {
        guard let app = app else { return }
        let bundle = app.lastExternalBundle
            ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard let b = bundle, b != kBundleSelf else {
            NSSound.beep()
            return
        }
        app.setAppRule(bundle: b, source: currentSourceID() ?? "com.apple.keylayout.ABC")
        log("✎ 添加规则 \(b) → \(app.config.apps[b] ?? "?")（共 \(app.config.apps.count) 条）")
        reload()
    }
}
