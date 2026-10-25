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

    static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    /// 匹配、排序、位置去重共用同一组有效条件，避免忽略的字段影响优先级。
    private enum Condition {
        case domClass(String, Bool)
        case identifier(String)
        case fallback(String?, String?)
    }

    private static func condition(_ r: ContextRule) -> Condition {
        if let c = nonempty(r.classContains) { return .domClass(c, r.classExact) }
        if let i = nonempty(r.identifier) { return .identifier(i) }
        return .fallback(nonempty(r.role), nonempty(r.titleContains))
    }

    static func specificity(_ r: ContextRule) -> Int {
        switch condition(r) {
        case let .domClass(c, exact): return isGenericClass(c) ? 2 : (exact ? 9 : 8)
        case .identifier: return 4
        case let .fallback(role, title): return (role == nil ? 0 : 1) + (title == nil ? 0 : 2)
        }
    }

    static func matches(_ r: ContextRule, _ fp: FocusFingerprint) -> Bool {
        switch condition(r) {
        case let .domClass(c, exact):
            return (fp.domClasses + fp.ancestorClasses).contains {
                exact ? $0.caseInsensitiveCompare(c) == .orderedSame : $0.localizedCaseInsensitiveContains(c)
            }
        case let .identifier(id):
            return ([fp.identifier] + fp.ancestorIDs).contains { $0.localizedCaseInsensitiveContains(id) }
        case let .fallback(role, title):
            guard role != nil || title != nil else { return false }
            if let role = role, fp.role != role { return false }
            if let title = title {
                return ([fp.title, fp.placeholder] + fp.ancestorTitles).contains { $0.localizedCaseInsensitiveContains(title) }
            }
            return true
        }
    }

    static func conditionDescription(_ r: ContextRule) -> String {
        switch condition(r) {
        case let .domClass(c, exact): return "class \(exact ? "=" : "⊃") \(c)"
        case let .identifier(id): return "identifier ⊃ \(id)"
        case let .fallback(role, title):
            return [role, title.map { "title ⊃ " + $0 }].compactMap { $0 }.joined(separator: " · ")
        }
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
        switch condition(r) {
        case let .domClass(c, exact): return "class:\(exact):" + c.lowercased()
        case let .identifier(i): return "id:" + i.lowercased()
        case let .fallback(role, title): return "role:\(role ?? "")|\(title?.lowercased() ?? "")"
        }
    }

    static func sameSpot(_ a: ContextRule, _ b: ContextRule) -> Bool {
        spotKey(a) == spotKey(b)
    }

    /// 用当前焦点生成一条「尽量窄但别太脆」的规则。
    /// DOM class / identifier 已经能唯一确定位置，就不再加 role ——
    /// role 会随 Electron 版本漂移，多写一个条件只是多一个失效点。
    ///
    /// - Parameter classOverride: 差异定位算出来的 class，优先于自动挑选
    static func make(bundle: String, source: String, fp: FocusFingerprint,
                     note: String? = nil, classOverride: String? = nil) -> ContextRule {
        var rule = ContextRule(bundle: bundle, source: source)
        if let cls = classOverride ?? distinguishingClass(fp) {
            rule.classContains = cls
            rule.classExact = true
        } else if !fp.identifier.isEmpty {
            rule.identifier = fp.identifier
        } else {
            rule.role = fp.role
            if let t = fp.ancestorTitles.first(where: { !$0.isEmpty && $0.count <= 40 }) {
                rule.titleContains = t
            }
        }
        rule.note = note ?? displayLabel(fp, matchedNote: nil)
        rule.signature = signature(of: fp)
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

    // MARK: - 差异定位
    //
    // 通用类名单总有漏项（`showUnused` 就是这么漏的）。与其不停补名单，
    // 不如在「两个位置撞车」时把两条祖先链摆在一起比：
    // 谁独有的那个 class，就是谁的位置标识。
    // 通用类在两条链里都有，会自动落进「公共部分」被跳过 —— 不用名单也知道它们通用。

    static func signature(of fp: FocusFingerprint) -> SpotSignature {
        SpotSignature(role: fp.role,
                      identifier: fp.identifier,
                      domClasses: fp.domClasses,
                      ancestorClasses: fp.ancestorClasses,
                      ancestorTitles: fp.ancestorTitles)
    }

    /// 老规则（1.4.4 之前存的）没有快照。至少把它显式用过的条件
    /// 当成「它占住的 class」，免得新位置又挑到同一个。
    static func pseudoSignature(of rule: ContextRule) -> SpotSignature {
        var s = SpotSignature()
        s.role = rule.role ?? ""
        s.identifier = rule.identifier ?? ""
        s.domClasses = [rule.classContains, rule.titleContains].compactMap { $0 }
        return s
    }

    /// 找一个「本位置有、别人都没有」的 class，用来把自己和别人分开。
    /// 由近及远取第一个，所以拿到的是最贴近焦点的那个区分点。
    static func exclusiveClass(in sig: SpotSignature,
                               excluding others: [SpotSignature]) -> String? {
        for c in sig.allClasses where !c.isEmpty && c.count <= 60 && !isGenericClass(c) {
            if others.allSatisfy({ !$0.allClasses.contains(c) }) { return c }
        }
        return nil
    }

    /// 一次「添加位置规则」要做的调整：新位置用哪个 class，哪些旧规则要收窄。
    struct SpotResolution {
        /// 新位置该用的 class（nil 表示退回 identifier / role）
        var classForNew: String?
        /// 需要收窄的旧规则：索引 → 新 class
        var narrowings: [(index: Int, from: String?, to: String)] = []
        /// 给日志用的说明
        var notes: [String] = []
    }

    /// 这条规则是不是就代表「当前这个位置」？
    ///
    /// 不能只比条件字符串：两个位置特征撞车时（都算出同一个 class），
    /// 字符串相等会把「别人」误判成「自己」，于是完全不触发收窄 ——
    /// 那正是两个位置共用一条规则、改一个两边一起变的原因。
    ///
    /// 有快照就以快照为准：快照里那些能区分位置的 class，当前焦点必须也都有。
    static func isSameSpot(_ rule: ContextRule, _ fp: FocusFingerprint) -> Bool {
        let fpClasses = Set(fp.domClasses + fp.ancestorClasses)

        if let sig = rule.signature {
            let markers = sig.allClasses.filter { !isGenericClass($0) }
            if !markers.isEmpty {
                return markers.allSatisfy { fpClasses.contains($0) }
            }
            // 快照里全是通用 class，没有可用于区分的依据，只能当作同一个位置
            return true
        }

        // 老规则没有快照：退回「条件与当前候选相同」这个近似判断
        if let c = rule.classContains, !c.isEmpty,
           let base = distinguishingClass(fp) {
            return c.caseInsensitiveCompare(base) == .orderedSame
        }
        return false
    }

    /// 冲突消解：算出「当前位置」和已有规则各自该退到哪个 class。
    ///
    /// 光给新位置挑个更窄的 class 不够 —— 那条旧规则还留在原地继续吃掉新位置，
    /// 两个位置就共用同一个输入法了。所以必须两头一起收窄。
    ///
    /// - Parameter rules: 该应用现有的全部位置规则
    static func resolveSpot(bundle: String, fp: FocusFingerprint,
                            rules: [ContextRule]) -> SpotResolution {
        let sig = signature(of: fp)
        let baseClass = distinguishingClass(fp)

        var rivals: [SpotSignature] = []
        var narrowable: [(index: Int, sig: SpotSignature)] = []

        for (i, rule) in rules.enumerated() where rule.bundle == bundle {
            guard matches(rule, fp) else { continue }
            // 这条就是「当前位置」本身（用户只是改它的输入法），不算撞车
            if isSameSpot(rule, fp) { continue }
            if let other = rule.signature {
                rivals.append(other)
                narrowable.append((i, other))
            } else {
                // 老规则没有快照，收窄不了，但至少要占住它已经用掉的 class，
                // 否则新位置又挑到同一个，等于白收窄
                rivals.append(pseudoSignature(of: rule))
            }
        }

        var out = SpotResolution(classForNew: baseClass)
        guard !rivals.isEmpty else { return out }

        if let c = exclusiveClass(in: sig, excluding: rivals), c != baseClass {
            out.classForNew = c
            out.notes.append("位置撞车，新位置改用 \(c)（原候选 \(baseClass ?? "nil")）")
        }

        // 旧规则各自退到「自己有、新位置没有」的 class
        for (i, other) in narrowable {
            guard let c = exclusiveClass(in: other, excluding: [sig]) else { continue }
            let old = rules[i].classContains
            guard old != c else { continue }
            out.narrowings.append((i, old, c))
            out.notes.append("收窄旧规则 [\(rules[i].note ?? "-")]：\(old ?? "nil") → \(c)")
        }
        return out
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
