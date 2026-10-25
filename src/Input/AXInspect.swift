import ApplicationServices
import Foundation

// ============================================================================
// 焦点指纹：识别「同一个应用里的哪个位置」
//
// Electron / Chromium 会把网页元素的 class 暴露成非标准属性 AXDOMClassList。
// 它跟界面语言、应用版本都无关，是判断「终端 / 编辑器 / AI 聊天框」最稳的标识；
// AXIdentifier 通常是空的，标题又是本地化的，都不能长期依赖。
// ============================================================================

struct FocusFingerprint {
    var role = ""
    var subrole = ""
    var identifier = ""
    var title = ""
    var placeholder = ""
    var ancestorTitles: [String] = []
    var ancestorIDs: [String] = []
    /// Chromium/Electron 暴露的 DOM class，比如 ["xterm-helper-textarea"]
    var domClasses: [String] = []
    /// 祖先的 DOM class，由近及远。
    ///
    /// 光有 `domClasses` 分不开同一个应用里的不同输入区：VS Code 的代码编辑器和
    /// Copilot 聊天框都报 `["native-edit-context"]`，往上第 3 层才分道扬镳
    /// （`editor-instance` vs `chat-input-container`）。所以祖先的 class 必须一起收。
    var ancestorClasses: [String] = []

    var summary: String {
        var s = "role=\(role)"
        if !subrole.isEmpty { s += " sub=\(subrole)" }
        if !identifier.isEmpty { s += " id=\(identifier)" }
        if !domClasses.isEmpty { s += " dom=\(domClasses)" }
        if !ancestorClasses.isEmpty { s += " ancDom=\(ancestorClasses.prefix(4))" }
        if !title.isEmpty { s += " title=\(title.prefix(40))" }
        if !placeholder.isEmpty { s += " ph=\(placeholder.prefix(30))" }
        if !ancestorTitles.isEmpty { s += " anc=\(ancestorTitles.prefix(3))" }
        return s
    }
}

func axString(_ el: AXUIElement, _ key: String) -> String {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, key as CFString, &v) == .success,
          let s = v as? String else { return "" }
    return s
}

func axStringArray(_ el: AXUIElement, _ key: String) -> [String] {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, key as CFString, &v) == .success,
          let a = v as? [String] else { return [] }
    return a.filter { !$0.isEmpty }
}

/// 取某个进程当前焦点元素。无辅助功能权限时返回 nil。
func focusedElement(pid: pid_t) -> AXUIElement? {
    guard pid > 0 else { return nil }
    let appEl = AXUIElementCreateApplication(pid)
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &v) == .success,
          let raw = v else { return nil }
    return (raw as! AXUIElement)
}

/// 读焦点元素并保留 AXError。
///
/// 区分两类失败至关重要：
///  - `.apiDisabled` / `.notTrusted`：真的是权限问题，只能让用户去勾选；
///  - `.cannotComplete` / `.invalidUIElement`：目标应用一时没应答（Electron 的
///    AX 服务偶尔卡住或正在切面板），等几十毫秒重试就能读到，不该当成「无法识别」。
func focusedElementResult(pid: pid_t) -> (element: AXUIElement?, error: AXError) {
    guard pid > 0 else { return (nil, .invalidUIElement) }
    let appEl = AXUIElementCreateApplication(pid)
    var v: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &v)
    guard err == .success, let raw = v else { return (nil, err) }
    return ((raw as! AXUIElement), .success)
}

/// 这个错误值不值得重试
func axErrorIsRetryable(_ e: AXError) -> Bool {
    switch e {
    case .cannotComplete, .invalidUIElement, .noValue, .attributeUnsupported:
        return true
    default:
        return false
    }
}

func axErrorName(_ e: AXError) -> String {
    switch e {
    case .success: return "success"
    case .failure: return "failure"
    case .illegalArgument: return "illegalArgument"
    case .invalidUIElement: return "invalidUIElement"
    case .invalidUIElementObserver: return "invalidUIElementObserver"
    case .cannotComplete: return "cannotComplete(目标应用未应答)"
    case .attributeUnsupported: return "attributeUnsupported"
    case .actionUnsupported: return "actionUnsupported"
    case .notificationUnsupported: return "notificationUnsupported"
    case .notImplemented: return "notImplemented"
    case .notificationAlreadyRegistered: return "notificationAlreadyRegistered"
    case .notificationNotRegistered: return "notificationNotRegistered"
    case .apiDisabled: return "apiDisabled(未授权辅助功能)"
    case .noValue: return "noValue"
    case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
    case .notEnoughPrecision: return "notEnoughPrecision"
    @unknown default: return "unknown(\(e.rawValue))"
    }
}

/// 把元素身上所有能读出来的属性列一遍（诊断用，用来发现 AXDOMClassList 这类非标准属性）
func axAllAttributes(_ el: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyAttributeNames(el, &names) == .success,
          let arr = names as? [String] else { return [] }

    var out: [String] = []
    for n in arr.sorted() {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, n as CFString, &v) == .success, let val = v else { continue }
        if let s = val as? String, !s.isEmpty {
            out.append("\(n)=\(s.prefix(90))")
        } else if let a = val as? [String], !a.isEmpty {
            out.append("\(n)=\(a.prefix(6))")
        } else if let num = val as? NSNumber {
            out.append("\(n)=\(num)")
        }
    }
    return out
}

/// 取某个进程当前焦点元素的指纹。无辅助功能权限时返回 nil。
func focusedFingerprint(pid: pid_t) -> FocusFingerprint? {
    guard let cur = focusedElement(pid: pid) else { return nil }
    return fingerprintOfElement(cur)
}

/// 从一个已拿到的 AX 元素采集指纹。
///
/// 单独拆出来是为了让重试逻辑复用：重试时元素已经在手上了，
/// 不必再从 pid 走一遍 `AXFocusedUIElement`。
func fingerprintOfElement(_ cur0: AXUIElement) -> FocusFingerprint? {
    var cur = cur0

    var fp = FocusFingerprint()
    fp.role = axString(cur, kAXRoleAttribute)
    fp.subrole = axString(cur, kAXSubroleAttribute)
    fp.identifier = axString(cur, kAXIdentifierAttribute)
    fp.title = axString(cur, kAXTitleAttribute)
    fp.placeholder = axString(cur, kAXPlaceholderValueAttribute)
    if fp.title.isEmpty { fp.title = axString(cur, kAXDescriptionAttribute) }
    fp.domClasses = axStringArray(cur, "AXDOMClassList")

    // 连 role 都读不出来，说明这个元素是坏的（应用正在重建 AX 树），
    // 交给上层重试，别拿一个空指纹去匹配规则 —— 空指纹会匹配到一切
    if fp.role.isEmpty && fp.domClasses.isEmpty && fp.identifier.isEmpty && fp.title.isEmpty {
        return nil
    }

    // 往上爬，收集祖先的标题 / identifier —— 面板名、webview 名往往在这里
    for _ in 0..<12 {
        var p: CFTypeRef?
        guard AXUIElementCopyAttributeValue(cur, kAXParentAttribute as CFString, &p) == .success,
              let pv = p else { break }
        cur = pv as! AXUIElement

        let t = axString(cur, kAXTitleAttribute)
        let d = axString(cur, kAXDescriptionAttribute)
        let i = axString(cur, kAXIdentifierAttribute)
        if !t.isEmpty { fp.ancestorTitles.append(t) }
        if !d.isEmpty && d != t { fp.ancestorTitles.append(d) }
        if !i.isEmpty { fp.ancestorIDs.append(i) }

        // Monaco 的编辑器内部（overflow-guard / monaco-editor / showUnused 这类状态类）
        // 在代码编辑器、聊天框、搜索框里完全一样，只有「跳出这一层」之后才是真正的位置。
        // 与其穷举这些会变的 class 名，不如按结构判断：碰到 AXCodeStyleGroup
        // 就把之前收的 class 全丢掉，从它往上重新算。
        if axString(cur, kAXSubroleAttribute) == "AXCodeStyleGroup" {
            fp.ancestorClasses.removeAll()
            continue
        }

        // 祖先的 DOM class 也要收：这是区分「同一个应用里不同输入区」的关键
        fp.ancestorClasses.append(contentsOf: axStringArray(cur, "AXDOMClassList"))
    }
    return fp
}
