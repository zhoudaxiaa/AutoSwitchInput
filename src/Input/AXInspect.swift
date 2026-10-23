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

    var summary: String {
        var s = "role=\(role)"
        if !subrole.isEmpty { s += " sub=\(subrole)" }
        if !identifier.isEmpty { s += " id=\(identifier)" }
        if !domClasses.isEmpty { s += " dom=\(domClasses)" }
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
    guard let cur0 = focusedElement(pid: pid) else { return nil }
    var cur = cur0

    var fp = FocusFingerprint()
    fp.role = axString(cur, kAXRoleAttribute)
    fp.subrole = axString(cur, kAXSubroleAttribute)
    fp.identifier = axString(cur, kAXIdentifierAttribute)
    fp.title = axString(cur, kAXTitleAttribute)
    fp.placeholder = axString(cur, kAXPlaceholderValueAttribute)
    if fp.title.isEmpty { fp.title = axString(cur, kAXDescriptionAttribute) }
    fp.domClasses = axStringArray(cur, "AXDOMClassList")

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
    }
    return fp
}
