import Cocoa
import Carbon
import ApplicationServices

// ============================================================================
// 自动切换输入法 (AutoSwitchInput NG)
// 按应用自动切换输入法 —— 针对旧版 AutoSwitchInput Lite 的失效原因重写
//
//  1. 永不缓存 TISInputSource 引用 —— 输入法重启后旧引用会变成死对象，
//     调用 TISSelectInputSource 静默失败。每次切换都按 ID 重新解析。
//  2. 三重触发：应用激活 / 焦点元素变化(AX) / 定时看门狗。
//  3. 切换后多轮校验 + 重试，专门对付"目标 App 抢回自己的输入法"的竞态。
//  4. 识别用户手动切换并学习，避免和用户对着干。
//  5. 安全键盘输入（密码框）期间主动跳过，不打断系统行为。
// ============================================================================

let kBundleSelf = "com.local.autoswitchinput"
let kShowWindowNote = Notification.Name("com.local.autoswitchinput.showWindow")

// MARK: - 日志

let logFileURL: URL = {
    let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("AutoSwitchInput.log")
}()

private let logFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MM-dd HH:mm:ss.SSS"
    return f
}()

func log(_ msg: String) {
    let line = "[\(logFormatter.string(from: Date()))] \(msg)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
       let size = attrs[.size] as? Int, size > 1_000_000 {
        try? FileManager.default.removeItem(at: logFileURL)
    }
    if let h = try? FileHandle(forWritingTo: logFileURL) {
        h.seekToEndOfFile()
        h.write(data)
        try? h.close()
    } else {
        try? data.write(to: logFileURL)
    }
}

// MARK: - TIS 输入源工具（无缓存）

func tisString(_ src: TISInputSource, _ key: CFString) -> String {
    guard let p = TISGetInputSourceProperty(src, key) else { return "" }
    return (Unmanaged<CFTypeRef>.fromOpaque(p).takeUnretainedValue() as? String) ?? ""
}

func tisID(_ src: TISInputSource) -> String { tisString(src, kTISPropertyInputSourceID) }
func tisName(_ src: TISInputSource) -> String { tisString(src, kTISPropertyLocalizedName) }

func enabledSelectableSources() -> [TISInputSource] {
    guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
        return []
    }
    return list
}

func allSources() -> [TISInputSource] {
    guard let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] else {
        return []
    }
    return list
}

/// 可用于"打字"的输入源（排除表情、手写板等辅助项）
func typeableSources() -> [(id: String, name: String)] {
    var out: [(String, String)] = []
    for s in enabledSelectableSources() {
        let type = tisString(s, kTISPropertyInputSourceType)
        guard type == "TISTypeKeyboardLayout" || type == "TISTypeKeyboardInputMode" else { continue }
        let id = tisID(s)
        guard !id.isEmpty else { continue }
        out.append((id, tisName(s)))
    }
    return out.sorted { $0.1 < $1.1 }
}

func currentSourceID() -> String? {
    guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
    let i = tisID(src)
    return i.isEmpty ? nil : i
}

func currentSourceName() -> String {
    guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return "?" }
    let n = tisName(src)
    return n.isEmpty ? "?" : n
}

/// 关键：每次都重新解析，绝不缓存
func findSource(_ id: String) -> TISInputSource? {
    for s in enabledSelectableSources() where tisID(s) == id { return s }
    for s in allSources() where tisID(s) == id { return s }
    return nil
}

@discardableResult
func selectSource(_ id: String) -> Bool {
    guard let src = findSource(id) else {
        log("✗ 找不到输入源 \(id)（可能已被删除或未启用）")
        return false
    }
    let status = TISSelectInputSource(src)
    if status != noErr {
        log("✗ TISSelectInputSource(\(id)) 返回 \(status)")
        return false
    }
    return true
}

func secureInputActive() -> Bool { IsSecureEventInputEnabled() }

/// 本地已安装应用索引：bundleID -> .app 路径（LaunchServices 偶尔查不到时兜底）
var appURLIndex: [String: URL] = {
    var map: [String: URL] = [:]
    let fm = FileManager.default
    let roots = ["/Applications", "/System/Applications", "/Applications/Utilities",
                 NSHomeDirectory() + "/Applications"]
    for root in roots {
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
        for e in entries where e.hasSuffix(".app") {
            let url = URL(fileURLWithPath: root).appendingPathComponent(e)
            if let bid = Bundle(url: url)?.bundleIdentifier { map[bid] = url }
        }
    }
    return map
}()

func appDisplayInfo(for bundle: String) -> (name: String, icon: NSImage) {
    let fallbackIcon = NSImage(named: NSImage.applicationIconName) ?? NSImage()

    // 正在运行的进程能直接给出本地化名称和图标（最准）
    if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first {
        let name = running.localizedName ?? bundle
        return (name, running.icon ?? fallbackIcon)
    }
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
        ?? appURLIndex[bundle] {
        let name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        return (name, NSWorkspace.shared.icon(forFile: url.path))
    }
    return (bundle, fallbackIcon)
}

/// 该 bundle id 在本机是否存在（规则可能是旧版遗留的僵尸项）
func appExists(_ bundle: String) -> Bool {
    if !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty { return true }
    if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) != nil { return true }
    return appURLIndex[bundle] != nil
}

// MARK: - 配置

struct Config: Codable {
    var enabled: Bool = true
    var learn: Bool = true
    var learnCreatesRules: Bool = false
    var defaultSource: String? = nil
    var apps: [String: String] = [:]
    var excluded: [String] = [
        "com.apple.loginwindow",
        "com.apple.SecurityAgent",
        kBundleSelf,
    ]
    var verifyDelays: [Double] = [0.06, 0.18, 0.45]
    var watchdogInterval: Double = 1.5
    /// 界面语言："zh-Hans" / "en"，nil = 跟随系统
    var language: String? = nil

    init() {}

    // 手写解码器：字段缺失时回落到默认值，避免手工改配置后整份配置失效
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        learn = try c.decodeIfPresent(Bool.self, forKey: .learn) ?? d.learn
        learnCreatesRules = try c.decodeIfPresent(Bool.self, forKey: .learnCreatesRules) ?? d.learnCreatesRules
        defaultSource = try c.decodeIfPresent(String.self, forKey: .defaultSource)
        apps = try c.decodeIfPresent([String: String].self, forKey: .apps) ?? d.apps
        excluded = try c.decodeIfPresent([String].self, forKey: .excluded) ?? d.excluded
        verifyDelays = try c.decodeIfPresent([Double].self, forKey: .verifyDelays) ?? d.verifyDelays
        watchdogInterval = try c.decodeIfPresent(Double.self, forKey: .watchdogInterval) ?? d.watchdogInterval
        language = try c.decodeIfPresent(String.self, forKey: .language)
    }
}

let supportDir: URL = {
    let d = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/InputGuard")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}()

let configURL = supportDir.appendingPathComponent("config.json")

// MARK: - 设置窗口

/// 翻转坐标系的容器，让滚动内容从顶部开始排
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class RuleRow: NSView {
    let bundleID: String
    var onRemove: (() -> Void)?
    var onChange: ((String?) -> Void)?

    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)

    init(bundle: String, ruleID: String?, sources: [(id: String, name: String)], installed: Bool) {
        self.bundleID = bundle
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 48).isActive = true

        let info = appDisplayInfo(for: bundle)

        let icon = NSImageView()
        icon.image = info.icon
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.alphaValue = installed ? 1.0 : 0.35
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 26).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 26).isActive = true

        let nameLabel = NSTextField(labelWithString: info.name)
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.textColor = installed ? .labelColor : .secondaryLabelColor

        let idLabel = NSTextField(labelWithString: installed ? bundle : bundle + L("row.missing"))
        idLabel.font = .systemFont(ofSize: 10)
        idLabel.textColor = installed ? .secondaryLabelColor : .tertiaryLabelColor
        idLabel.lineBreakMode = .byTruncatingMiddle

        let textStack = NSStackView(views: [nameLabel, idLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.font = .systemFont(ofSize: 12)
        popup.removeAllItems()
        popup.addItem(withTitle: L("row.none"))
        popup.lastItem?.representedObject = nil
        for s in sources {
            popup.addItem(withTitle: s.name)
            popup.lastItem?.representedObject = s.id
        }
        if let rid = ruleID,
           let idx = popup.itemArray.firstIndex(where: { ($0.representedObject as? String) == rid }) {
            popup.selectItem(at: idx)
        } else {
            popup.selectItem(at: 0)
        }
        popup.target = self
        popup.action = #selector(popupChanged)
        popup.widthAnchor.constraint(equalToConstant: 148).isActive = true
        popup.setContentHuggingPriority(.required, for: .horizontal)

        let minus = NSButton(title: "−", target: self, action: #selector(removeTapped))
        minus.isBordered = false
        minus.font = .systemFont(ofSize: 16)
        minus.contentTintColor = .tertiaryLabelColor
        minus.translatesAutoresizingMaskIntoConstraints = false
        minus.widthAnchor.constraint(equalToConstant: 20).isActive = true
        minus.setContentHuggingPriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        let h = NSStackView(views: [icon, textStack, spacer, popup, minus])
        h.orientation = .horizontal
        h.alignment = .centerY
        h.spacing = 10
        h.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 12)
        h.translatesAutoresizingMaskIntoConstraints = false
        addSubview(h)
        NSLayoutConstraint.activate([
            h.leadingAnchor.constraint(equalTo: leadingAnchor),
            h.trailingAnchor.constraint(equalTo: trailingAnchor),
            h.topAnchor.constraint(equalTo: topAnchor),
            h.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func popupChanged() {
        onChange?(popup.selectedItem?.representedObject as? String)
    }

    @objc private func removeTapped() {
        onRemove?()
    }
}

final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    weak var app: AppDelegate?

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
        loginCheck.state = app.loginItemInstalled() ? .on : .off

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
                app.config.apps.removeValue(forKey: b)
                app.saveConfig()
                log("✎ 删除规则 \(b)（剩余 \(app.config.apps.count) 条）")
                self?.reload()
            }
            row.onChange = { [weak self] newID in
                if let newID = newID {
                    app.config.apps[b] = newID
                } else {
                    app.config.apps.removeValue(forKey: b)
                }
                app.saveConfig()
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
        app?.config.enabled = enabledSwitch.state == .on
        app?.saveConfig()
        app?.refreshStatusTitle()
        reload()
    }

    @objc private func toggleLearn() {
        app?.config.learn = learnSwitch.state == .on
        app?.saveConfig()
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

        app.config.language = code
        app.saveConfig()
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
            for b in stale { app.config.apps.removeValue(forKey: b) }
            app.saveConfig()
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
        app.config.apps[b] = currentSourceID() ?? "com.apple.keylayout.ABC"
        app.saveConfig()
        log("✎ 添加规则 \(b) → \(app.config.apps[b] ?? "?")（共 \(app.config.apps.count) 条）")
        reload()
    }
}

// MARK: - 菜单栏小面板（点击图标弹出的 hover 面板）

final class QuickPanelController: NSViewController {

    weak var app: AppDelegate?

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let bundleLabel = NSTextField(labelWithString: "")
    private let currentLabel = NSTextField(labelWithString: "")
    private let enabledSwitch = NSSwitch()
    private let rulePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var currentBundle: String?

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

        let stack = NSStackView(views: [header, currentLabel, sep1, ruleRow, sep2, buttons])
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

        let bundle = app.lastExternalBundle
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
           let idx = rulePopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == rid }) {
            rulePopup.selectItem(at: idx)
        } else {
            rulePopup.selectItem(at: 0)
        }

        rulePopup.isEnabled = (bundle != nil && bundle != kBundleSelf)

        // 尺寸随内容自适应
        view.layoutSubtreeIfNeeded()
        let h = view.fittingSize.height
        preferredContentSize = NSSize(width: panelWidth, height: h)
    }

    /// 只更新"当前输入法"那一行，避免面板打开时重置用户的选项
    func refreshCurrentOnly() {
        currentLabel.stringValue = LF("status.current", currentSourceName())
        enabledSwitch.state = (app?.config.enabled ?? true) ? .on : .off
    }

    @objc private func ruleChanged() {
        guard let app = app, let b = currentBundle, b != kBundleSelf else { return }
        if let id = rulePopup.selectedItem?.representedObject as? String {
            app.config.apps[b] = id
        } else {
            app.config.apps.removeValue(forKey: b)
        }
        app.saveConfig()
        app.reloadSettingsWindow()
        log("✎ 小面板设置 \(b) → \(rulePopup.selectedItem?.representedObject as? String ?? "不设置")")
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

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSPopoverDelegate {

    var config = Config()
    var statusItem: NSStatusItem!
    var axObserver: AXObserver?
    var observedPID: pid_t = 0
    var watchdog: Timer?

    var expectedID: String?
    var expectedUntil: Date = .distantPast
    var userOverrideUntil: Date = .distantPast
    var lastAppliedBundle: String?

    var pendingApply: DispatchWorkItem?

    var lastActivationAt: Date = .distantPast
    var activationBundle: String?
    var lastExternalBundle: String?

    var popover: NSPopover?
    var quickPanel: QuickPanelController?
    var popoverLastClosed: Date = .distantPast

    /// 只有真正加载了配置的主实例才允许写盘。
    /// 否则"被 launchctl 拉起的第二实例"会在退出时用空默认值覆盖配置。
    private var isPrimaryInstance = false

    private var settings: SettingsWindowController { .shared }

    func reloadSettingsWindow() { settings.reload() }

    var settingsContentView: NSView? { settings.contentViewForSnapshot }

    func snapshotWindow(to path: String) {
        // 截图时临时变成普通应用并让窗口成为 key window，
        // 否则 NSSwitch 会按「窗口非活跃」渲染成灰色
        NSApp.setActivationPolicy(.regular)
        settings.show()
        let win = settings.contentViewForSnapshot?.window
        win?.makeKeyAndOrderFront(nil)
        // 反复尝试抢焦点：从终端/LaunchServices 拉起时第一次 activate 常被系统忽略，
        // 抢不到焦点 NSSwitch 就会渲染成灰色，截图看着像「已关闭」
        for _ in 0..<12 {
            NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
            NSApp.activate(ignoringOtherApps: true)
            win?.makeKey()
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            if NSApp.isActive && (win?.isKeyWindow ?? false) { break }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        log("snapshot: isActive=\(NSApp.isActive) isKey=\(win?.isKeyWindow ?? false) policy=\(NSApp.activationPolicy().rawValue)")

        guard let v = settings.contentViewForSnapshot else { return }
        v.layoutSubtreeIfNeeded()
        let bounds = v.bounds
        // 2x 渲染，保证 README 里在 Retina 屏上不糊
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(bounds.width * scale),
                                         pixelsHigh: Int(bounds.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = bounds.size
        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current = ctx
        ctx?.cgContext.scaleBy(x: scale, y: scale)
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        v.cacheDisplay(in: bounds, to: rep)
        NSGraphicsContext.restoreGraphicsState()
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            log("window snapshot -> \(path) size=\(bounds.size)@\(Int(scale))x")
        }
    }

    func snapshotPanel(to path: String, demoBundle: String? = nil) {
        let panel = QuickPanelController()
        panel.app = self
        // 截图时固定展示某个应用，避免抓到的正好是当前前台的小工具
        if let b = demoBundle { lastExternalBundle = b }
        let v = panel.view
        panel.refresh()
        v.layoutSubtreeIfNeeded()
        let size = v.fittingSize
        v.frame = NSRect(origin: .zero, size: size)
        v.layoutSubtreeIfNeeded()
        // 2x 渲染，和窗口截图保持一致
        let scale: CGFloat = 2
        guard let hi = NSBitmapImageRep(bitmapDataPlanes: nil,
                                        pixelsWide: Int(v.bounds.width * scale),
                                        pixelsHigh: Int(v.bounds.height * scale),
                                        bitsPerSample: 8, samplesPerPixel: 4,
                                        hasAlpha: true, isPlanar: false,
                                        colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0) else { return }
        hi.size = v.bounds.size
        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: hi)
        NSGraphicsContext.current = ctx
        ctx?.cgContext.scaleBy(x: scale, y: scale)
        NSColor.windowBackgroundColor.setFill()
        v.bounds.fill()
        v.cacheDisplay(in: v.bounds, to: hi)
        NSGraphicsContext.restoreGraphicsState()
        if let data = hi.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            log("panel snapshot -> \(path) size=\(size)@\(Int(scale))x")
        }
    }

    func setEnabled(_ on: Bool) {
        config.enabled = on
        saveConfig()
        refreshStatusTitle()
        settings.reload()
        quickPanel?.refresh()
        log("enabled = \(config.enabled)")
        if on { scheduleApply(reason: "启用") }
    }

    // MARK: 生命周期

    func applicationWillFinishLaunching(_ note: Notification) {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(showWindowNote),
            name: kShowWindowNote, object: nil, suspensionBehavior: .deliverImmediately)

        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleReopenEvent(_:withReply:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEReopenApplication))
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 单实例：已经在跑就通知它弹窗，然后自己退出
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: kBundleSelf)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty {
            DistributedNotificationCenter.default().postNotificationName(
                kShowWindowNote, object: nil, userInfo: nil, deliverImmediately: true)
            NSApp.terminate(nil)
            return
        }

        isPrimaryInstance = true
        loadConfig()
        if !FileManager.default.fileExists(atPath: configURL.path) {
            importLegacyRules()
            saveConfig()
        }

        // 界面语言要在建任何 UI 之前定下来
        setAppLanguage(config.language)

        setupStatusItem()
        setupTriggers()
        settings.app = self

        // 调试用：把菜单栏小面板渲染成 PNG 后退出
        let env = ProcessInfo.processInfo.environment
        if let shot = env["AUTOSWITCH_PANEL_SHOT"], !shot.isEmpty {
            snapshotPanel(to: shot)
            NSApp.terminate(nil)
            return
        }

        // 调试用：把主窗口渲染成 PNG 后退出
        // （走环境变量是为了能被 open 启动，从而拿到窗口激活态）
        if let shot = env["AUTOSWITCH_WINDOW_SHOT"], !shot.isEmpty {
            snapshotWindow(to: shot)
            NSApp.terminate(nil)
            return
        }

        // 调试用：用信号文件触发截图。open 启动时无法透传命令行参数，
        // 所以把目标路径写进 /tmp/autoswitch_shot.txt，启动时读一次就删。
        let shotFile = "/tmp/autoswitch_shot.txt"
        if let content = try? String(contentsOfFile: shotFile, encoding: .utf8) {
            try? FileManager.default.removeItem(atPath: shotFile)
            let lines = content
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if let target = lines.first, !target.isEmpty {
                // 第 4 行可以指定语言，用来验证「切换语言 → 整窗重建」这条路径
                if lines.count > 3, !lines[3].isEmpty, lines[3] != "system" {
                    setAppLanguage(lines[3])
                    settings.rebuild()
                    log("debug: language=\(lines[3]) rebuilt=\(settings.contentViewForSnapshot != nil)")
                }
                if lines.count > 1, lines[1] == "panel" {
                    snapshotPanel(to: target, demoBundle: lines.count > 2 ? lines[2] : nil)
                } else {
                    snapshotWindow(to: target)
                }
                NSApp.terminate(nil)
                return
            }
        }

        // 调试用：把菜单栏小面板渲染成 PNG 后退出
        if let idx = CommandLine.arguments.firstIndex(of: "--panel-snapshot"),
           idx + 1 < CommandLine.arguments.count {
            snapshotPanel(to: CommandLine.arguments[idx + 1])
            NSApp.terminate(nil)
            return
        }

        // 调试用：把主窗口渲染成 PNG 后退出
        if let idx = CommandLine.arguments.firstIndex(of: "--window-snapshot"),
           idx + 1 < CommandLine.arguments.count {
            snapshotWindow(to: CommandLine.arguments[idx + 1])
            NSApp.terminate(nil)
            return
        }

        // 调试用：验证 popover 能否弹出
        if CommandLine.arguments.contains("--popover-demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.togglePopover()
                log("popover demo: shown=\(self.popover?.isShown ?? false) "
                    + "win=\(self.popover?.contentViewController?.view.window?.frame.debugDescription ?? "nil")")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { NSApp.terminate(nil) }
            }
            startWatchdog()
            refreshStatusTitle()
            return
        }

        log("=== 启动 | 规则 \(config.apps.count) 条 | learn=\(config.learn) | args=\(CommandLine.arguments) ===")

        if !CommandLine.arguments.contains("--silent") {
            settings.show()
        }

        // 辅助功能授权：只在首次启动时弹一次系统提示，之后靠界面里的状态提示
        if !AXIsProcessTrusted() {
            let key = "didPromptAccessibility"
            if !UserDefaults.standard.bool(forKey: key) {
                UserDefaults.standard.set(true, forKey: key)
                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(opts)
            }
            log("⚠️ 未获得辅助功能权限，焦点级触发不可用（应用切换触发仍工作）")
        }

        startWatchdog()
        refreshStatusTitle()
    }

    func applicationWillTerminate(_ note: Notification) {
        guard isPrimaryInstance else { return }
        saveConfig()
        log("=== 退出 ===")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show()
        return true
    }

    /// LSUIElement 应用不会走 applicationShouldHandleReopen，
    /// 必须自己接管「重新打开」Apple Event，否则窗口关掉后再点 App 没反应。
    @objc func handleReopenEvent(_ event: NSAppleEventDescriptor,
                                 withReply reply: NSAppleEventDescriptor) {
        settings.show()
    }

    @objc func showWindowNote() {
        DispatchQueue.main.async { self.settings.show() }
    }

    // MARK: 配置

    func loadConfig() {
        if let data = try? Data(contentsOf: configURL),
           let c = try? JSONDecoder().decode(Config.self, from: data) {
            config = c
            return
        }
        // 主配置缺失或损坏时，回退到上一次的备份
        let backup = configURL.deletingPathExtension().appendingPathExtension("json.bak")
        if let data = try? Data(contentsOf: backup),
           let c = try? JSONDecoder().decode(Config.self, from: data) {
            config = c
            log("⚠️ 主配置读取失败，已从备份恢复（\(c.apps.count) 条规则）")
            saveConfig()
        }
    }

    func saveConfig() {
        // 落盘前先留一份备份，任何时候都能手工恢复
        if FileManager.default.fileExists(atPath: configURL.path) {
            let backup = configURL.deletingPathExtension().appendingPathExtension("json.bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: configURL, to: backup)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let d = try? enc.encode(config) {
            try? d.write(to: configURL, options: .atomic)
        }
    }

    /// 从旧版 AutoSwitchInput Lite 的沙盒容器里读取规则，无缝迁移
    func importLegacyRules() {
        let p = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Containers/cn.better365.AutoSwitchInputLite/Data/Library/Preferences/cn.better365.AutoSwitchInputLite.plist")
        guard let dict = NSDictionary(contentsOf: p),
              let autoInput = dict["autoInput"] as? [String: Any] else {
            log("未找到旧应用配置，从空白开始")
            return
        }
        var n = 0
        for (bundle, v) in autoInput {
            if let d = v as? [String: Any], let id = d["id"] as? String, !id.isEmpty {
                config.apps[bundle] = id
                n += 1
            }
        }
        log("已从旧版迁移 \(n) 条规则")
    }

    // MARK: 状态栏

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.font = .systemFont(ofSize: 12, weight: .medium)
            // 菜单栏用单色 template 图标，自动适配深浅色菜单栏
            if let url = Bundle.main.resourceURL?.appendingPathComponent("MenuBarIcon.png"),
               let img = NSImage(contentsOf: url) {
                img.size = NSSize(width: 18, height: 18)
                img.isTemplate = true
                button.image = img
                button.imagePosition = .imageLeading
            }
            // 左键弹小面板，右键弹完整菜单
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc func statusItemClicked() {
        if let e = NSApp.currentEvent, e.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    // MARK: 小面板

    func togglePopover() {
        guard let button = statusItem.button else { return }

        if let p = popover, p.isShown {
            p.performClose(nil)
            return
        }
        // transient 面板会先因"点击外部"关闭再触发 action，避免反复开合
        if Date().timeIntervalSince(popoverLastClosed) < 0.25 { return }

        let panel = QuickPanelController()
        panel.app = self
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

    func popoverDidClose(_ notification: Notification) {
        popoverLastClosed = Date()
        popover = nil
        quickPanel = nil
    }

    func showContextMenu() {
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    func refreshStatusTitle() {
        guard let button = statusItem.button else { return }
        let name = currentSourceName()
        let mark: String
        if name.contains("搜狗") || name.contains("拼音") || name.contains("简体") || name.contains("注音") {
            mark = "中"
        } else if name.uppercased().contains("ABC") || name.contains("英文") || name.contains("U.S") {
            mark = "英"
        } else {
            mark = String(name.prefix(1))
        }
        button.title = config.enabled ? " " + mark : " " + L("statusbar.off")
        button.alphaValue = config.enabled ? 1.0 : 0.45
        button.toolTip = LF("statusbar.tip", name)
        if popover?.isShown == true { quickPanel?.refreshCurrentOnly() }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()

        let front = NSWorkspace.shared.frontmostApplication
        let bundle = front?.bundleIdentifier ?? "-"
        let appName = front?.localizedName ?? L("panel.unknown")

        let open = NSMenuItem(title: L("menu.settings"), action: #selector(openSettings), keyEquivalent: ",")
        open.target = self
        menu.addItem(open)

        menu.addItem(.separator())

        let head = NSMenuItem(title: "\(appName) → \(currentSourceName())", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)

        let assign = NSMenuItem(title: LF("menu.assign", currentSourceName()),
                                action: #selector(assignCurrent), keyEquivalent: "")
        assign.target = self
        assign.isEnabled = front != nil && bundle != kBundleSelf
        menu.addItem(assign)

        let clear = NSMenuItem(title: L("menu.clear"), action: #selector(clearCurrent), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = config.apps[bundle] != nil
        menu.addItem(clear)

        menu.addItem(.separator())

        let toggle = NSMenuItem(title: L("menu.enabled"), action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = config.enabled ? .on : .off
        menu.addItem(toggle)

        let learn = NSMenuItem(title: L("menu.learn"), action: #selector(toggleLearn), keyEquivalent: "")
        learn.target = self
        learn.state = config.learn ? .on : .off
        menu.addItem(learn)

        let login = NSMenuItem(title: L("menu.login"), action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = loginItemInstalled() ? .on : .off
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

    // MARK: 菜单动作

    @objc func openSettings() { settings.show() }

    @objc func assignCurrent() {
        guard let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              let cur = currentSourceID() else { return }
        config.apps[bundle] = cur
        saveConfig()
        log("✎ 手动指定 \(bundle) → \(cur)")
        settings.reload()
    }

    @objc func clearCurrent() {
        guard let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return }
        config.apps.removeValue(forKey: bundle)
        saveConfig()
        log("✎ 清除规则 \(bundle)")
        settings.reload()
    }

    @objc func toggleEnabled() {
        setEnabled(!config.enabled)
    }

    @objc func toggleLearn() {
        config.learn.toggle()
        saveConfig()
        settings.reload()
    }

    @objc func openConfig() {
        if !FileManager.default.fileExists(atPath: configURL.path) { saveConfig() }
        NSWorkspace.shared.open(configURL)
    }

    @objc func openLog() { NSWorkspace.shared.open(logFileURL) }

    @objc func quit() { NSApp.terminate(nil) }

    // MARK: 触发源

    func setupTriggers() {
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
                let me = Unmanaged<AppDelegate>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { me.onExternalInputSourceChange() }
            },
            kTISNotifySelectedKeyboardInputSourceChanged,
            nil,
            .deliverImmediately)
    }

    @objc func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let bundle = app.bundleIdentifier ?? "-"

        if bundle == kBundleSelf { return }
        lastExternalBundle = bundle
        log("→ 激活 \(bundle) (pid \(app.processIdentifier))")

        lastActivationAt = Date()
        activationBundle = bundle

        attachAXObserver(pid: app.processIdentifier, bundle: bundle)
        scheduleApply(reason: "激活", delay: 0.04)
    }

    func onFocusChanged() {
        scheduleApply(reason: "焦点变化", delay: 0.08)
    }

    func attachAXObserver(pid: pid_t, bundle: String) {
        guard pid > 0, pid != observedPID else { return }

        if let old = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(old), .defaultMode)
            axObserver = nil
        }
        observedPID = pid

        var obs: AXObserver?
        let err = AXObserverCreate(pid, { _, _, _, refcon in
            guard let refcon = refcon else { return }
            let me = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
            DispatchQueue.main.async { me.onFocusChanged() }
        }, &obs)

        guard err == .success, let obs = obs else {
            log("AXObserverCreate 失败(\(bundle)) err=\(err.rawValue)")
            return
        }

        let appEl = AXUIElementCreateApplication(pid)
        let rc = Unmanaged.passUnretained(self).toOpaque()
        let e1 = AXObserverAddNotification(obs, appEl, kAXFocusedUIElementChangedNotification as CFString, rc)
        let e2 = AXObserverAddNotification(obs, appEl, kAXFocusedWindowChangedNotification as CFString, rc)
        if e1 != .success && e2 != .success {
            log("AX 通知注册失败(\(bundle))：\(e1.rawValue)/\(e2.rawValue)（多半是未授权辅助功能）")
        }

        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
        axObserver = obs
    }

    // MARK: 学习 / 识别用户操作

    func onExternalInputSourceChange() {
        let now = Date()
        let cur = currentSourceID()
        refreshStatusTitle()

        if let exp = expectedID, now < expectedUntil, cur == exp {
            expectedID = nil
            return
        }
        expectedID = nil

        guard config.enabled, config.learn, let cur = cur else { return }
        guard let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return }
        guard bundle != kBundleSelf, !config.excluded.contains(bundle) else { return }

        // 激活后 1 秒内的变更属于"系统/应用自己在恢复输入法"，不是用户操作
        guard Date().timeIntervalSince(lastActivationAt) > 1.0 else { return }
        guard bundle == activationBundle else { return }

        // 默认只修正已有规则，不凭空新建规则（避免规则被污染）
        guard config.apps[bundle] != nil || config.learnCreatesRules else { return }

        userOverrideUntil = now.addingTimeInterval(2.5)
        if config.apps[bundle] != cur {
            config.apps[bundle] = cur
            saveConfig()
            log("✎ 学习：\(bundle) → \(cur)")
        }
    }

    // MARK: 应用规则

    func scheduleApply(reason: String, delay: Double = 0.03) {
        pendingApply?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applyNow(reason: reason) }
        pendingApply = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func applyNow(reason: String) {
        guard config.enabled else { return }
        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundle = front.bundleIdentifier else { return }
        guard bundle != kBundleSelf, !config.excluded.contains(bundle) else { return }
        guard Date() >= userOverrideUntil else { return }

        guard let desired = config.apps[bundle] ?? config.defaultSource else { return }
        let cur = currentSourceID()
        guard cur != desired else { return }

        if secureInputActive() {
            log("⏭ \(bundle) 处于安全键盘输入状态，跳过（避免打断密码输入）")
            return
        }

        log("⇄ [\(reason)] \(bundle): \(cur ?? "nil") → \(desired)")
        lastAppliedBundle = bundle
        applyWithVerify(desired, bundle: bundle, attempt: 0)
    }

    func applyWithVerify(_ desired: String, bundle: String, attempt: Int) {
        expectedID = desired
        expectedUntil = Date().addingTimeInterval(1.5)

        if !selectSource(desired) {
            expectedID = nil
            return
        }

        guard attempt < config.verifyDelays.count else { return }
        let delay = config.verifyDelays[attempt]

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle else { return }
            guard Date() >= self.userOverrideUntil else { return }
            guard currentSourceID() != desired else { return }

            log("↺ 被目标应用回滚，第 \(attempt + 1) 次重试 \(bundle)")
            self.applyWithVerify(desired, bundle: bundle, attempt: attempt + 1)
        }
    }

    // MARK: 看门狗

    func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: config.watchdogInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard self.config.enabled else { return }
            guard let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                  bundle != kBundleSelf, !self.config.excluded.contains(bundle),
                  let desired = self.config.apps[bundle] ?? self.config.defaultSource else { return }
            guard Date() >= self.userOverrideUntil else { return }
            guard currentSourceID() != desired else { return }
            if secureInputActive() { return }

            log("🛡 看门狗纠正 \(bundle) → \(desired)")
            self.lastAppliedBundle = bundle
            self.applyWithVerify(desired, bundle: bundle, attempt: 0)
        }
    }

    // MARK: 开机启动

    var loginItemURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(kBundleSelf).plist")
    }

    func loginItemInstalled() -> Bool {
        FileManager.default.fileExists(atPath: loginItemURL.path)
    }

    @objc func toggleLogin() {
        if loginItemInstalled() {
            launchctl(["bootout", "gui/\(getuid())", loginItemURL.path])
            try? FileManager.default.removeItem(at: loginItemURL)
            log("✎ 关闭开机启动")
        } else {
            let exe = Bundle.main.executablePath ?? "/Applications/自动切换输入法.app/Contents/MacOS/AutoSwitchInput"
            let plist: [String: Any] = [
                "Label": kBundleSelf,
                "ProgramArguments": [exe, "--silent"],
                "RunAtLoad": true,
                "KeepAlive": false,
                "ProcessType": "Interactive",
            ]
            let dir = loginItemURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                try? data.write(to: loginItemURL)
                // 注意：这里**不能** bootstrap。bootstrap 会立刻拉起第二个实例，
                // 而第二实例退出时会用空配置覆盖 config.json（v1.2 丢配置的根因）。
                // 只写 plist，下次登录由 launchd 加载即可。
                log("✎ 开启开机启动（下次登录生效）")
            }
        }
        settings.reload()
    }

    func launchctl(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}

// MARK: - 入口

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
