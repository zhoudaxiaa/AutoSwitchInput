import Foundation

/// 细分规则的匹配、生成与归一化。
/// 纯函数，不碰配置读写也不碰 UI —— 所有「这条规则算不算命中」的判断都集中在这里。
enum ContextRuleEngine {

    /// 通用容器 class：同一个应用里**多个位置共用**，拿它当位置标识必然误判。
    ///
    /// 典型例子：VS Code 的代码编辑器和 Copilot 聊天框，焦点元素都是
    /// `native-edit-context`，中间几层都是 `overflow-guard` / `monaco-editor`，
    /// 再上面还有 `showUnused` 这类**状态类** —— 它们跟「在哪儿」毫无关系。
    /// 真正的区分点是再往上的 `editor-instance` / `chat-input-container`。
    ///
    /// 这份名单只是第二道防线（第一道是按 `AXCodeStyleGroup` 结构判断），
    /// 所以宁可多列一些：错杀一个通用类没有损失，漏掉一个就会让两个位置串味。
    private static let genericClasses: Set<String> = [
        "native-edit-context",   // Monaco 所有文本输入：编辑器 / 聊天框 / 搜索框
        "overflow-guard",        // Monaco 内部滚动容器
        "monaco-editor",
        "monaco-split-view2",
        "monaco-grid-view",
        "monaco-workbench",
        "split-view-view",
        "split-view-container",
        "no-user-select",
        "separator-border",
        "floating-editor-outer-top",
        "editor-tabs-multiple",
        // Monaco 的状态 / 主题类，跟着设置和界面状态变，与位置无关
        "mac", "vs", "vs-dark", "focused", "visible", "working",
        "showunused", "showdeprecated",
        // 太宽泛，几乎每个分区都有
        "part", "composite", "editor",
    ]

    static func isGenericClass(_ c: String) -> Bool {
        genericClasses.contains { $0.caseInsensitiveCompare(c) == .orderedSame }
    }

    /// 规则越具体越优先：具体 DOM class > identifier > 标题词 > 通用 class > 只看 role
    static func specificity(_ r: ContextRule) -> Int {
        var s = 0
        if let c = r.classContains, !c.isEmpty {
            // 用通用容器当条件的位置规则，实际区分能力等同于「只看了 role」
            s += isGenericClass(c) ? 2 : 8
        }
        if let i = r.identifier, !i.isEmpty { s += 4 }
        if let t = r.titleContains, !t.isEmpty { s += 2 }
        if let role = r.role, !role.isEmpty { s += 1 }
        return s
    }

    static func matches(_ r: ContextRule, _ fp: FocusFingerprint) -> Bool {
        // 条件全空的规则等于匹配一切，直接忽略，免得一条空规则吃满整个应用
        if r.role == nil && r.identifier == nil && r.titleContains == nil && r.classContains == nil {
            return false
        }

        // 有 DOM class 就以它为准。role 会随 Electron / VS Code 版本漂移，
        // 让它一起参与判断只会把本来能命中的规则否掉（「全是 ABC」就是这么来的）。
        // 自身和祖先的 class 都要查：区分位置的信息往往在祖先身上。
        if let c = r.classContains, !c.isEmpty {
            let hay = fp.domClasses + fp.ancestorClasses
            return hay.contains { $0.localizedCaseInsensitiveContains(c) }
        }

        if let role = r.role, !role.isEmpty, fp.role != role { return false }
        if let id = r.identifier, !id.isEmpty {
            let hit = fp.identifier.localizedCaseInsensitiveContains(id)
                || fp.ancestorIDs.contains { $0.localizedCaseInsensitiveContains(id) }
            if !hit { return false }
        }
        if let t = r.titleContains, !t.isEmpty {
            let hay = ([fp.title, fp.placeholder] + fp.ancestorTitles).joined(separator: "\u{1F}")
            if !hay.localizedCaseInsensitiveContains(t) { return false }
        }
        return true
    }

    /// 在候选规则里挑出最具体的一条；同分时保持配置里的先后顺序
    static func best(in rules: [ContextRule], for fp: FocusFingerprint) -> ContextRule? {
        guard !rules.isEmpty else { return nil }
        let ordered = rules.enumerated().sorted {
            let a = specificity($0.element), b = specificity($1.element)
            return a == b ? $0.offset < $1.offset : a > b
        }
        return ordered.first { matches($0.element, fp) }?.element
    }

    /// 规则「指向哪个位置」的归一化标识：以最能区分位置的那个条件为准。
    /// 新旧规则用这个比较，避免同一个位置因为 role 不同而并存两条互相打架的规则。
    static func spotKey(_ r: ContextRule) -> String {
        if let c = r.classContains, !c.isEmpty { return "class:" + c.lowercased() }
        if let i = r.identifier, !i.isEmpty { return "id:" + i.lowercased() }
        return "role:\(r.role ?? "")|\(r.titleContains ?? "")"
    }

    static func sameSpot(_ a: ContextRule, _ b: ContextRule) -> Bool {
        spotKey(a) == spotKey(b)
    }

    /// 用当前焦点生成一条「尽量窄但别太脆」的规则。
    /// DOM class / identifier 已经能唯一确定位置，就不再加 role ——
    /// role 会随 Electron 版本漂移，多写一个条件只是多一个失效点。
    static func make(bundle: String, source: String, fp: FocusFingerprint, note: String? = nil) -> ContextRule {
        var rule = ContextRule(bundle: bundle, source: source)
        if let cls = distinguishingClass(fp) {
            rule.classContains = cls
        } else if !fp.identifier.isEmpty {
            rule.identifier = fp.identifier
        } else {
            rule.role = fp.role
            if let t = fp.ancestorTitles.first(where: { !$0.isEmpty && $0.count <= 40 }) {
                rule.titleContains = t
            }
        }
        rule.note = note ?? displayLabel(fp, matchedNote: nil)
        return rule
    }

    /// 挑一个「能区分位置」的 class。
    ///
    /// 先看焦点元素自身的 class；如果自身是通用容器（Monaco 的
    /// `native-edit-context` 之类），就往上找第一个非通用的 —— 那才是位置本身。
    /// 一个都找不到就返回 nil，让调用方退回 identifier / role，
    /// **绝不拿通用 class 凑数**：那会让这个应用里所有位置共用一条规则。
    static func distinguishingClass(_ fp: FocusFingerprint) -> String? {
        let usable: (String) -> Bool = { !$0.isEmpty && $0.count <= 60 && !isGenericClass($0) }
        if let c = fp.domClasses.first(where: usable) { return c }
        return fp.ancestorClasses.first(where: usable)
    }

    /// 给用户看的位置名称：优先看祖先里的「位置容器」（比焦点元素自身更能说明这是哪儿），
    /// 其次用已命中规则的备注，最后退回原始属性。
    static func displayLabel(_ fp: FocusFingerprint, matchedNote: String?) -> String {
        // 自身就有辨识度很高的 class
        for c in fp.domClasses {
            if c.localizedCaseInsensitiveContains("xterm") { return L("spot.terminal") }
            if c.localizedCaseInsensitiveContains("ProseMirror") { return L("spot.chat") }
        }
        // 祖先里的位置容器：编辑器和聊天框的焦点元素长得一样，只能靠这一层分开
        for c in fp.ancestorClasses {
            if c.localizedCaseInsensitiveContains("chat-input-container") { return L("spot.chat") }
            if c.localizedCaseInsensitiveContains("interactive-input") { return L("spot.chat") }
            if c.localizedCaseInsensitiveContains("editor-instance") { return L("spot.editor") }
        }
        // 兜底：Monaco 的通用文本输入区，按编辑器叫
        for c in fp.domClasses {
            if c.localizedCaseInsensitiveContains("native-edit-context") { return L("spot.editor") }
        }
        if let note = matchedNote, !note.isEmpty { return note }
        if let c = fp.domClasses.first { return c }
        if let c = fp.ancestorClasses.first { return c }
        if !fp.identifier.isEmpty { return fp.identifier }
        return fp.role.isEmpty ? L("spot.unknown") : fp.role
    }
}
