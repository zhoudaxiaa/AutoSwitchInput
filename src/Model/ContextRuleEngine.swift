import Foundation

/// 细分规则的匹配、生成与归一化。
/// 纯函数，不碰配置读写也不碰 UI —— 所有「这条规则算不算命中」的判断都集中在这里。
enum ContextRuleEngine {

    /// 规则越具体越优先：DOM class > identifier > 标题词 > 只看 role
    static func specificity(_ r: ContextRule) -> Int {
        var s = 0
        if let c = r.classContains, !c.isEmpty { s += 8 }
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
        if let c = r.classContains, !c.isEmpty {
            return fp.domClasses.contains { $0.localizedCaseInsensitiveContains(c) }
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
        if let cls = fp.domClasses.first(where: { !$0.isEmpty && $0.count <= 60 }) {
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

    /// 给用户看的位置名称：优先按 DOM class 猜（跟着界面语言走），
    /// 其次用已命中规则的备注，最后退回原始属性。
    static func displayLabel(_ fp: FocusFingerprint, matchedNote: String?) -> String {
        for c in fp.domClasses {
            if c.localizedCaseInsensitiveContains("xterm") { return L("spot.terminal") }
            if c.localizedCaseInsensitiveContains("ProseMirror") { return L("spot.chat") }
            if c.localizedCaseInsensitiveContains("native-edit-context") { return L("spot.editor") }
        }
        if let note = matchedNote, !note.isEmpty { return note }
        if let c = fp.domClasses.first { return c }
        if !fp.identifier.isEmpty { return fp.identifier }
        return fp.role.isEmpty ? L("spot.unknown") : fp.role
    }
}
