import Foundation

// 测试不读写真实用户配置或日志，也不切换实际输入法。
enum AppPaths {
    static let configURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("unused-config.json")
    static let configBackupURL = configURL.appendingPathExtension("bak")
}
func log(_ message: String) {}

var assertions = 0
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) {
    assertions += 1
    do {
        guard try condition() else { fatalError("FAIL: " + message) }
    } catch { fatalError("FAIL: " + message + ": \(error)") }
}

func rule(_ source: String = "ZH", className: String? = nil) -> ContextRule {
    var r = ContextRule(bundle: "app.a", source: source)
    r.classContains = className
    return r
}

func testRules() throws {
    var fp = FocusFingerprint()
    fp.role = "AXTextField"
    fp.domClasses = ["chat-input-container"]
    var empty = rule()
    check(!ContextRuleEngine.matches(empty, fp), "nil 条件不匹配")
    empty.role = " \n "
    empty.identifier = ""
    check(!ContextRuleEngine.matches(empty, fp), "空白条件不匹配")
    var base = rule(className: "chat-input-container")
    var extra = base
    extra.identifier = "nonexistent"
    extra.titleContains = "nonexistent"
    extra.role = "AXTextArea"
    check(ContextRuleEngine.matches(extra, fp), "class 优先语义")
    check(ContextRuleEngine.specificity(extra) == ContextRuleEngine.specificity(base), "忽略字段不参与计分")
    check(ContextRuleEngine.sameSpot(extra, base), "去重与匹配条件保持一致")
    check(ContextRuleEngine.best(in: [base, extra], for: fp)?.id == base.id, "同分保持先后顺序")
    base.classContains = "chat-input"
    check(ContextRuleEngine.matches(base, fp), "旧规则继续子串匹配")
    base.classExact = true
    check(!ContextRuleEngine.matches(base, fp), "完整 token 不误匹配前缀")
    base.classContains = "CHAT-INPUT-CONTAINER"
    check(ContextRuleEngine.matches(base, fp), "完整 token 大小写一致")
    let generated = ContextRuleEngine.make(bundle: "app.a", source: "ZH", fp: fp)
    check(generated.classExact, "新生成规则使用完整 class")
    var legacy = rule("EN", className: "chat")
    check(ContextRuleEngine.best(in: [legacy, generated], for: fp)?.id == generated.id, "完整 class 优先于旧子串规则")
    legacy.classContains = "chat-input-container"
    check(ContextRuleEngine.specificity(generated) > ContextRuleEngine.specificity(legacy), "完整匹配比子串具体")
    var byID = rule()
    byID.identifier = "chat"
    byID.role = "AXTextArea"
    fp.ancestorIDs = ["panel.chat"]
    check(ContextRuleEngine.matches(byID, fp), "identifier 优先时不受漂移 role 影响")
    var fallback = rule()
    fallback.role = "AXTextField"
    fallback.titleContains = "Chat"
    fp.ancestorTitles = ["Chat panel"]
    check(ContextRuleEngine.matches(fallback, fp), "role 和 title 联合匹配")
    fallback.titleContains = "Terminal"
    check(!ContextRuleEngine.matches(fallback, fp), "title 未命中不匹配")

    var config = Config()
    config.defaultSource = "DEFAULT"
    config.apps["app.a"] = "APP"
    config.contexts = [generated]
    check(SourceResolver.desired(for: "app.a", config: config, fingerprint: fp) == "ZH", "位置优先")
    fp.domClasses = ["other"]
    check(SourceResolver.desired(for: "app.a", config: config, fingerprint: fp) == "APP", "未命中位置回落应用")
    check(SourceResolver.desired(for: "app.b", config: config) == "DEFAULT", "应用缺省回落默认")
    check(config.ruleBundles.contains("app.a"), "规则列表包含应用")
    config.apps = [:]
    check(config.ruleBundles.contains("app.a"), "只有位置规则的应用仍可见")

    let old = Data(#"{"bundle":"app.a","source":"ZH","classContains":"chat"}"#.utf8)
    let migrated = try JSONDecoder().decode(ContextRule.self, from: old)
    check(!migrated.classExact, "旧配置保留匹配方式")
    let roundTrip = try JSONDecoder().decode(ContextRule.self, from: JSONEncoder().encode(migrated))
    check(migrated.id == roundTrip.id, "规则 ID 持久化")

    // 两个位置撞车时，两条规则必须分别收窄，而不是覆盖对方。
    var editor = FocusFingerprint()
    editor.domClasses = ["shared-input"]
    editor.ancestorClasses = ["editor-instance"]
    var chat = editor
    chat.ancestorClasses = ["chat-input-container"]
    var oldEditor = ContextRuleEngine.make(bundle: "app.a", source: "EN", fp: editor)
    let resolution = ContextRuleEngine.resolveSpot(bundle: "app.a", fp: chat, rules: [oldEditor])
    check(resolution.classForNew == "chat-input-container", "冲突时新位置收窄")
    check(resolution.narrowings.first?.to == "editor-instance", "冲突时旧位置也收窄")
    oldEditor.classContains = resolution.narrowings.first?.to
    check(!ContextRuleEngine.matches(oldEditor, chat), "旧位置不再覆盖新位置")
}

/// 复用本机现有规则的字段形态，覆盖 VS Code 的 Monaco 编辑器、
/// Copilot 输入框、ProseMirror 扩展聊天框以及终端之间的往返。
func testVSCodeContexts() throws {
    let data = Data(#"""
    {
      "apps": {"com.microsoft.VSCode": "com.sogou.inputmethod.sogou.pinyin"},
      "learn": false,
      "contexts": [
        {"bundle":"com.microsoft.VSCode","classContains":"xterm-helper-textarea","classExact":false,"role":"AXTextField","source":"com.apple.keylayout.ABC"},
        {"bundle":"com.microsoft.VSCode","classContains":"ProseMirror","classExact":false,"role":"AXTextArea","source":"com.sogou.inputmethod.sogou.pinyin"},
        {"bundle":"com.microsoft.VSCode","classContains":"editor-instance","classExact":false,"source":"com.apple.keylayout.ABC"}
      ]
    }
    """#.utf8)
    let config = try JSONDecoder().decode(Config.self, from: data).validated()
    let bundle = "com.microsoft.VSCode"
    let english = "com.apple.keylayout.ABC"
    let chinese = "com.sogou.inputmethod.sogou.pinyin"
    var editor = FocusFingerprint()
    editor.role = "AXTextArea"
    editor.domClasses = ["native-edit-context"]
    editor.ancestorClasses = ["editor-instance", "monaco-workbench"]
    var copilot = editor
    copilot.ancestorClasses = ["chat-input-container", "interactive-input-part", "monaco-workbench"]
    var extensionChat = FocusFingerprint()
    extensionChat.role = "AXTextArea"
    extensionChat.domClasses = ["ProseMirror", "tiptap"]
    // 扩展聊天位于编辑器 Webview 内：聊天 class 必须优先于编辑器祖先。
    extensionChat.ancestorClasses = ["editor-instance", "monaco-workbench"]
    var terminal = FocusFingerprint()
    terminal.role = "AXTextArea" // Electron 更新后 role 漂移仍能匹配旧 class 规则。
    terminal.domClasses = ["xterm-helper-textarea"]
    for _ in 0..<5 {
        check(SourceResolver.desired(for: bundle, config: config, fingerprint: editor) == english, "VS Code 编辑器使用 ABC")
        check(SourceResolver.desired(for: bundle, config: config, fingerprint: copilot) == chinese, "Copilot 输入框使用应用中文兜底")
        check(SourceResolver.desired(for: bundle, config: config, fingerprint: extensionChat) == chinese, "ProseMirror 聊天优先于其编辑器祖先")
        check(SourceResolver.desired(for: bundle, config: config, fingerprint: terminal) == english, "终端 role 漂移仍使用 ABC")
    }
    let chatRule = ContextRuleEngine.make(bundle: bundle, source: chinese, fp: copilot)
    check(chatRule.classContains == "chat-input-container", "Monaco 聊天生成位置容器规则")
    check(!ContextRuleEngine.matches(chatRule, editor), "聊天新规则不会吞掉编辑器")
    check(ContextRuleEngine.matches(chatRule, copilot), "聊天新规则可以命中自身")
    let editorRule = ContextRuleEngine.make(bundle: bundle, source: english, fp: editor)
    check(editorRule.classContains == "editor-instance", "编辑器规则越过通用输入类")
    check(!ContextRuleEngine.matches(editorRule, copilot), "编辑器规则不会吞掉 Copilot")
}

func testConfig() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let main = directory.appendingPathComponent("config.json")
    let backup = directory.appendingPathComponent("config.bak")
    var config = Config()
    config.apps["app.a"] = "ZH"
    config.contexts = [rule(className: "chat")]
    check(ConfigStore.save(config, url: main, backup: backup), "首次保存成功")
    let saved = ConfigStore.load(url: main, backup: backup)!
    check(saved.contexts[0].id == config.contexts[0].id, "存盘保留稳定 ID")
    config.apps["app.a"] = "EN"
    check(ConfigStore.save(config, url: main, backup: backup), "第二次保存成功")
    let goodBackup = try Data(contentsOf: backup)
    try Data("broken".utf8).write(to: main)
    let restored = ConfigStore.load(url: main, backup: backup)
    check(restored?.apps["app.a"] == "ZH", "主配置损坏恢复备份")
    check(try Data(contentsOf: backup) == goodBackup, "恢复不覆盖有效备份")
    check(ConfigStore.load(url: main, backup: backup)?.apps["app.a"] == "ZH", "恢复后的主配置可读")

    // 用目录作为目标文件，确定性模拟恢复写入失败。
    let recoveredDespiteFailure = ConfigStore.load(url: directory, backup: backup)
    check(recoveredDespiteFailure?.apps["app.a"] == "ZH", "恢复写入失败仍可使用备份")
    check(try Data(contentsOf: backup) == goodBackup, "恢复写入失败保留原备份")
    check(!ConfigStore.save(config, url: directory.appendingPathComponent("missing/config"), backup: backup), "保存失败明确返回 false")
    try Data("broken again".utf8).write(to: main)
    check(ConfigStore.save(config, url: main, backup: backup), "损坏主文件可被新配置替换")
    check(try Data(contentsOf: backup) == goodBackup, "损坏主文件不污染备份")

    config.watchdogInterval = -1
    config.verifyDelays = [-1, 0, 0.06, .infinity, 99]
    config.apps["bad"] = "  "
    config.contexts.append(rule())
    var duplicate = config.contexts[0]
    duplicate.classContains = "editor"
    config.contexts.append(duplicate)
    let valid = config.validated()
    check(valid.watchdogInterval == Config().watchdogInterval, "非法定时间隔回落")
    check(valid.verifyDelays == [0.06], "过滤非法重试间隔")
    check(valid.apps["bad"] == nil, "过滤空输入源")
    check(valid.contexts.count == 2, "过滤无条件规则")
    check(Set(valid.contexts.map(\.id)).count == 2, "修复重复 ID")
    check(valid.apps["app.a"] == "EN", "保留暂不可用输入源以便用户修复")
}

final class Harness {
    var config = Config()
    var bundle = "app.a"
    var pid: pid_t = 1
    var current = "EN"
    var secure = false
    var instant = Date(timeIntervalSince1970: 100)
    var selected: [String] = []
    var tasks: [(Date, () -> Void)] = []
    var delayedResolve = false
    var resolutions: [(String?) -> Void] = []
    var engine: SwitchEngine!

    init() {
        config.apps["app.a"] = "ZH"
        config.apps["app.b"] = "ZH"
        var environment = SwitchEnvironment()
        environment.now = { [unowned self] in instant }
        environment.frontmost = { [unowned self] in (bundle, pid) }
        environment.currentSource = { [unowned self] in current }
        // 故意不改变 current，模拟宿主应用把输入法抢回的情况。
        environment.select = { [unowned self] source in selected.append(source); return true }
        environment.secureInput = { [unowned self] in secure }
        environment.schedule = { [unowned self] delay, action in tasks.append((instant.addingTimeInterval(delay), action)) }
        environment.resolve = { [unowned self] bundle, config, completion in
            if delayedResolve { resolutions.append(completion) }
            else { completion(SourceResolver.desired(for: bundle, config: config)) }
            return nil
        }
        engine = SwitchEngine(environment: environment)
        engine.configProvider = { [unowned self] in config }
    }

    func next() {
        guard let index = tasks.indices.min(by: { tasks[$0].0 < tasks[$1].0 }) else { return }
        let task = tasks.remove(at: index)
        instant = task.0
        task.1()
    }
    func drain() { for _ in 0..<30 { if tasks.isEmpty { break }; next() } }
}

func testSwitching() {
    let paused = Harness()
    paused.engine.applyNow(reason: "test")
    paused.config.enabled = false
    paused.drain()
    check(paused.selected == ["ZH"], "暂停后旧链不重试")

    let secure = Harness()
    secure.engine.applyNow(reason: "test")
    secure.secure = true
    secure.drain()
    check(secure.selected.count == 1, "进入安全输入不重试")

    let changed = Harness()
    changed.engine.applyNow(reason: "test")
    changed.config.apps["app.a"] = "JP"
    changed.drain()
    check(changed.selected == ["ZH"], "目标变化不重推旧输入法")

    let cancelled = Harness()
    cancelled.engine.applyNow(reason: "test")
    cancelled.engine.cancelPendingApply()
    cancelled.drain()
    check(cancelled.selected.count == 1, "取消已开始的校验链")

    let scheduled = Harness()
    scheduled.engine.scheduleApply(reason: "test")
    scheduled.engine.cancelPendingApply()
    scheduled.drain()
    check(scheduled.selected.isEmpty, "取消防抖任务")

    let noTarget = Harness()
    noTarget.engine.applyNow(reason: "test")
    noTarget.config.apps = [:]
    noTarget.engine.scheduleApply(reason: "焦点变化")
    noTarget.drain()
    check(noTarget.selected.count == 1, "新上下文无目标也使旧链失效")

    let manual = Harness()
    manual.engine.applyNow(reason: "test")
    manual.engine.markUserOverride(bundle: "app.a", for: 2.5)
    manual.engine.applyNow(reason: "test")
    manual.drain()
    check(manual.selected.count == 1, "手动保护阻止同应用纠正")
    manual.bundle = "app.b"
    manual.pid = 2
    manual.engine.applyNow(reason: "test")
    check(manual.selected.count == 2, "A 应用保护不影响 B 应用")

    let expired = Harness()
    expired.engine.markUserOverride(bundle: "app.a", for: 2.5)
    expired.instant = expired.instant.addingTimeInterval(3)
    expired.engine.applyNow(reason: "test")
    check(expired.selected == ["ZH"], "保护到期恢复自动切换")

    let restarted = Harness()
    restarted.engine.applyNow(reason: "test")
    restarted.pid = 99
    restarted.drain()
    check(restarted.selected.count == 1, "PID 改变不接受旧任务")

    let late = Harness()
    late.delayedResolve = true
    late.engine.applyNow(reason: "test")
    late.engine.cancelPendingApply()
    late.resolutions.removeFirst()("ZH")
    check(late.selected.isEmpty, "取消后忽略迟到的 AX 结果")

    let slowAX = Harness()
    slowAX.delayedResolve = true
    slowAX.engine.applyNow(reason: "test")
    slowAX.engine.watchdogTick()
    check(slowAX.resolutions.count == 1, "看门狗不打断尚未完成的 AX 读取")
    slowAX.resolutions.removeFirst()("ZH")
    check(slowAX.selected == ["ZH"], "慢速 AX 读取可以完成切换")
    slowAX.engine.watchdogTick()
    check(slowAX.resolutions.count == 1, "AX 完成后看门狗可继续判定")

    let request = FocusProbe.Request()
    check(!request.cancelled, "焦点请求初始有效")
    request.cancel()
    check(request.cancelled, "焦点请求可取消")

    let successful = Harness()
    successful.engine.applyNow(reason: "test")
    successful.current = "ZH"
    successful.drain()
    check(successful.selected.count == 1, "输入法保持目标时不重试")
    check(successful.engine.isSelfInflicted("ZH"), "自己的 TIS 通知可识别")
    successful.bundle = "app.b"
    check(!successful.engine.isSelfInflicted("ZH"), "自发切换标志不跨应用")

    let bounded = Harness()
    bounded.engine.applyNow(reason: "test")
    bounded.drain()
    check(bounded.selected.count == 4, "初次切换加三次重试，有限结束")
    check(bounded.tasks.isEmpty, "重试结束后无残留任务")
}

func testLearning() {
    var policy = LearningPolicy()
    let start = Date(timeIntervalSince1970: 100)
    policy.activated("app.a", at: start)
    var config = Config()
    config.apps["app.a"] = "EN"
    config.learn = false
    check(policy.shouldRespectChange(bundle: "app.a", config: config, at: start.addingTimeInterval(2)), "关闭学习仍尊重手动切换")
    check(!policy.shouldLearn(bundle: "app.a", config: config), "关闭学习不写盘")
    check(!policy.shouldRespectChange(bundle: "app.a", config: config, at: start.addingTimeInterval(0.5)), "激活窗口忽略应用自行恢复")
    config.learn = true
    config.contexts = [rule(className: "chat")]
    check(policy.shouldRespectChange(bundle: "app.a", config: config, at: start.addingTimeInterval(2)), "有位置规则仍尊重手动切换")
    check(!policy.shouldLearn(bundle: "app.a", config: config), "位置规则不污染应用兜底")
    config.contexts = []
    check(policy.shouldLearn(bundle: "app.a", config: config), "已有应用规则可学习")
    check(!policy.shouldLearn(bundle: "app.b", config: config), "默认不自动创建新规则")
    config.learnCreatesRules = true
    check(policy.shouldLearn(bundle: "app.b", config: config), "允许创建时可学习新规则")
}

try testRules()
try testVSCodeContexts()
try testConfig()
testSwitching()
testLearning()
print("通过 \(assertions) 项回归断言")
