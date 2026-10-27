import Cocoa

// MARK: - 菜单栏小面板（点击图标弹出的 hover 面板）

final class QuickPanelController: NSViewController {

    weak var app: AppActions?

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let bundleLabel = NSTextField(labelWithString: "")
    private let currentLabel = NSTextField(labelWithString: "")
    private let enabledSwitch = NSSwitch()
    private let rulePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var currentBundle: String?
    /// 「此处」那一行
    private let spotLabel = NSTextField(labelWithString: "")
    private let spotPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var currentFingerprint: FocusFingerprint?
    /// 每次刷新 +1：异步补读回来时，如果面板已经重新刷过就丢弃结果
    private var spotToken = 0
    private var spotRequest: FocusProbe.Request?
    /// 截图预览用：伪造一个焦点指纹（正常运行时永远是 nil）
    var demoFingerprint: FocusFingerprint?
    /// 仅本次打开面板的快照；不能用历史缓存代替可编辑的当前位置。
    var capturedBundle: String?
    var capturedFingerprint: FocusFingerprint?
    var didCaptureBeforeOpening = false

    private let panelWidth: CGFloat = 300
    private var contentWidth: CGFloat { panelWidth - 28 }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 200))

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 34).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 34).isActive = true

        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail

        bundleLabel.font = .systemFont(ofSize: 10)
        bundleLabel.textColor = .secondaryLabelColor
        bundleLabel.lineBreakMode = .byTruncatingMiddle

        let textStack = NSStackView(views: [nameLabel, bundleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        enabledSwitch.target = self
        enabledSwitch.action = #selector(toggleEnabled)

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let header = NSStackView(views: [iconView, textStack, headerSpacer, enabledSwitch])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        header.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

        currentLabel.font = .systemFont(ofSize: 12)
        currentLabel.textColor = .secondaryLabelColor
        currentLabel.lineBreakMode = .byTruncatingTail
        currentLabel.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

        let ruleLabel = NSTextField(labelWithString: L("panel.app"))
        ruleLabel.font = .systemFont(ofSize: 12)
        ruleLabel.setContentHuggingPriority(.required, for: .horizontal)

        rulePopup.font = .systemFont(ofSize: 12)
        rulePopup.target = self
        rulePopup.action = #selector(ruleChanged)
        rulePopup.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let ruleRow = NSStackView(views: [ruleLabel, rulePopup])
        ruleRow.orientation = .horizontal
        ruleRow.alignment = .centerY
        ruleRow.spacing = 8
        ruleRow.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

        // 「此处」：只给当前焦点所在的位置单独指定输入法
        spotLabel.font = .systemFont(ofSize: 12)
        spotLabel.lineBreakMode = .byTruncatingTail
        spotLabel.setContentHuggingPriority(.required, for: .horizontal)
        spotLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        spotPopup.font = .systemFont(ofSize: 12)
        spotPopup.target = self
        spotPopup.action = #selector(spotChanged)
        spotPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let spotRow = NSStackView(views: [spotLabel, spotPopup])
        spotRow.orientation = .horizontal
        spotRow.alignment = .centerY
        spotRow.spacing = 8
        spotRow.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

        let openBtn = NSButton(title: L("panel.settings"), target: self, action: #selector(openSettings))
        openBtn.bezelStyle = .rounded
        openBtn.controlSize = .small
        openBtn.setContentHuggingPriority(.required, for: .horizontal)

        let quitBtn = NSButton(title: L("panel.quit"), target: self, action: #selector(quitApp))
        quitBtn.isBordered = false
        quitBtn.font = .systemFont(ofSize: 11)
        quitBtn.contentTintColor = .secondaryLabelColor
        quitBtn.controlSize = .small
        quitBtn.setContentHuggingPriority(.required, for: .horizontal)

        let btnSpacer = NSView()
        btnSpacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let buttons = NSStackView(views: [openBtn, btnSpacer, quitBtn])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        buttons.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

        let sep1 = NSBox()
        sep1.boxType = .separator
        sep1.translatesAutoresizingMaskIntoConstraints = false
        sep1.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

        let sep2 = NSBox()
        sep2.boxType = .separator
        sep2.translatesAutoresizingMaskIntoConstraints = false
        sep2.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

        let stack = NSStackView(views: [header, currentLabel, sep1, ruleRow, spotRow, sep2, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: panelWidth),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        self.view = root
    }

    func refresh() {
        guard let app = app else { return }

        let bundle = capturedBundle ?? app.lastExternalBundle
            ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        currentBundle = bundle

        enabledSwitch.state = app.config.enabled ? .on : .off

        if let b = bundle, b != kBundleSelf {
            let info = appDisplayInfo(for: b)
            iconView.image = info.icon
            nameLabel.stringValue = info.name
            bundleLabel.stringValue = b
        } else {
            iconView.image = NSImage(named: NSImage.applicationIconName)
            nameLabel.stringValue = L("panel.unknown")
            bundleLabel.stringValue = "—"
        }

        currentLabel.stringValue = LF("status.current", currentSourceName())

        rulePopup.removeAllItems()
        rulePopup.addItem(withTitle: L("row.none"))
        rulePopup.lastItem?.representedObject = nil
        for s in typeableSources() {
            rulePopup.addItem(withTitle: s.name)
            rulePopup.lastItem?.representedObject = s.id
        }

        if let b = bundle, let rid = app.config.apps[b],
           !rulePopup.itemArray.contains(where: { ($0.representedObject as? String) == rid }) {
            rulePopup.addItem(withTitle: LF("source.unavailable", sourceName(rid) ?? rid))
            rulePopup.lastItem?.representedObject = rid
        }
        if let b = bundle, let rid = app.config.apps[b],
           let idx = rulePopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == rid }) {
            rulePopup.selectItem(at: idx)
        } else {
            rulePopup.selectItem(at: 0)
        }

        rulePopup.isEnabled = (bundle != nil && bundle != kBundleSelf)

        refreshSpot(bundle: bundle)

        // 尺寸随内容自适应
        view.layoutSubtreeIfNeeded()
        let h = view.fittingSize.height
        preferredContentSize = NSSize(width: panelWidth, height: h)
    }

    /// 「此处」那一行：把此刻焦点所在的位置单独指一个输入法。
    ///
    /// 抓不到焦点不等于「没有位置」。Electron 应用的 AX 树是懒建的，
    /// 点菜单栏图标这一瞬间去问，经常先拿到一个「目标未应答」，
    /// 隔几十毫秒再问就有了。所以这里分三步：异步读取与有限重试 → 上次位置兜底。
    private func refreshSpot(bundle: String?) {
        spotRequest?.cancel()
        spotPopup.removeAllItems()
        spotToken &+= 1
        let token = spotToken
        currentFingerprint = nil

        guard let b = bundle, b != kBundleSelf else {
            if let demo = demoFingerprint {
                applySpot(demo, bundle: "", interactive: true)
            } else {
                showSpotUnavailable(interactive: false)
            }
            return
        }

        // 截图预览用：显式指定了伪造指纹就以它为准
        if let demo = demoFingerprint {
            applySpot(demo, bundle: b, interactive: true)
            return
        }

        guard AXIsProcessTrusted() else {
            showSpotUnavailable(interactive: false)
            spotLabel.toolTip = L("accessibility.repair.hint")
            return
        }
        spotLabel.toolTip = nil

        if didCaptureBeforeOpening {
            if let fp = capturedFingerprint, capturedBundle == b {
                applySpot(fp, bundle: b, interactive: true)
            } else {
                showSpotUnavailable(interactive: false)
            }
            return
        }

        // 应用没在运行就没有焦点可读，别让用户看「读取中」干等
        guard FocusProbe.runningApp(bundle: b) != nil else {
            showSpotUnavailable(interactive: false)
            return
        }

        // 还没放弃：先显示「读取中」，后台继续问
        spotLabel.textColor = .tertiaryLabelColor
        spotLabel.stringValue = LF("panel.spot", L("spot.reading"))
        spotPopup.addItem(withTitle: L("spot.na"))
        spotPopup.lastItem?.representedObject = nil
        spotPopup.selectItem(at: 0)
        spotPopup.isEnabled = false
        resizeToFit()

        spotRequest = FocusProbe.retryAsync(bundle: b, diagnostic: true) { [weak self] fp in
            guard let self = self, token == self.spotToken else { return }
            self.applySpot(fp, bundle: b, interactive: true)
        } onGiveUp: { [weak self] in
            guard let self = self, token == self.spotToken else { return }
            // 彻底读不到时，退而展示上一次读到的位置（明确标注「上次」，
            // 并且禁用下拉 —— 不能拿一个可能过期的位置去写规则）
            if let cached = FocusProbe.cached(for: b) {
                self.applySpot(cached, bundle: b, interactive: false, labelKey: "panel.spot.last")
            } else {
                self.showSpotUnavailable(interactive: false)
            }
        }
    }

    deinit { spotRequest?.cancel() }

    /// 内容变了之后重算面板高度（异步补读回来时文字长度会变）
    private func resizeToFit() {
        view.layoutSubtreeIfNeeded()
        let h = view.fittingSize.height
        if abs(preferredContentSize.height - h) > 0.5 {
            preferredContentSize = NSSize(width: panelWidth, height: h)
        }
    }

    /// 位置读到了，铺内容
    private func applySpot(_ fp: FocusFingerprint, bundle: String,
                           interactive: Bool, labelKey: String = "panel.spot") {
        currentFingerprint = interactive ? fp : nil

        let matched = app.flatMap { ContextRuleEngine.best(in: $0.config.contextRules(for: bundle), for: fp) }
        spotLabel.textColor = interactive ? .labelColor : .secondaryLabelColor
        spotLabel.stringValue = LF(labelKey,
                                   ContextRuleEngine.displayLabel(fp, matchedNote: matched?.note))

        spotPopup.addItem(withTitle: L("spot.follow"))
        spotPopup.lastItem?.representedObject = nil
        for s in typeableSources() {
            spotPopup.addItem(withTitle: s.name)
            spotPopup.lastItem?.representedObject = s.id
        }

        if let rule = matched,
           !spotPopup.itemArray.contains(where: { ($0.representedObject as? String) == rule.source }) {
            spotPopup.addItem(withTitle: LF("source.unavailable", sourceName(rule.source) ?? rule.source))
            spotPopup.lastItem?.representedObject = rule.source
        }
        if let rule = matched,
           let idx = spotPopup.itemArray.firstIndex(where: {
               ($0.representedObject as? String) == rule.source
           }) {
            spotPopup.selectItem(at: idx)
        } else {
            spotPopup.selectItem(at: 0)
        }
        spotPopup.isEnabled = interactive
        resizeToFit()
    }

    /// 真的没有位置可用：区分「没授权」和「应用没应答」
    private func showSpotUnavailable(interactive: Bool) {
        currentFingerprint = nil
        spotLabel.stringValue = LF("panel.spot", L("spot.unknown"))
        spotLabel.textColor = .tertiaryLabelColor
        spotPopup.addItem(withTitle: AXIsProcessTrusted()
                          ? L("spot.na") : L("spot.needAX"))
        spotPopup.lastItem?.representedObject = nil
        spotPopup.selectItem(at: 0)
        spotPopup.isEnabled = false
        resizeToFit()
    }

    /// 只更新"当前输入法"那一行，避免面板打开时重置用户的选项
    func refreshCurrentOnly() {
        currentLabel.stringValue = LF("status.current", currentSourceName())
        enabledSwitch.state = (app?.config.enabled ?? true) ? .on : .off
    }

    @objc private func ruleChanged() {
        guard let app = app, let b = currentBundle, b != kBundleSelf else { return }
        let id = rulePopup.selectedItem?.representedObject as? String
        app.setAppRule(bundle: b, source: id)
        log("✎ 小面板设置 \(b) → \(id ?? "不设置")")
    }

    /// 在面板里给「此刻焦点所在的位置」指定输入法
    @objc private func spotChanged() {
        guard let app = app, let b = currentBundle, b != kBundleSelf,
              let fp = currentFingerprint else { return }
        let id = spotPopup.selectedItem?.representedObject as? String
        app.setSpotRule(bundle: b, source: id, fp: fp)
    }

    @objc private func toggleEnabled() {
        app?.setEnabled(enabledSwitch.state == .on)
    }

    @objc private func openSettings() {
        app?.closePopover()
        app?.openSettings()
    }

    @objc private func quitApp() {
        app?.quit()
    }
}
