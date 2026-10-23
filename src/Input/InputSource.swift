import Carbon
import Foundation

// ============================================================================
// TIS（Text Input Source）封装
//
// 核心约束：**绝不缓存 TISInputSource 引用**。
// 输入法进程重启后旧引用会变成死对象，此时 TISSelectInputSource 静默失败 ——
// 这正是旧版「经常失效」的根因。所有操作都按 ID 现查现用。
// ============================================================================

func tisString(_ src: TISInputSource, _ key: CFString) -> String {
    guard let p = TISGetInputSourceProperty(src, key) else { return "" }
    return (Unmanaged<CFTypeRef>.fromOpaque(p).takeUnretainedValue() as? String) ?? ""
}

func tisID(_ src: TISInputSource) -> String { tisString(src, kTISPropertyInputSourceID) }
func tisName(_ src: TISInputSource) -> String { tisString(src, kTISPropertyLocalizedName) }

/// 已启用且可被选中的输入源
func enabledSelectableSources() -> [TISInputSource] {
    guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
        return []
    }
    return list
}

/// 全部输入源（含未启用的），仅在按 ID 查找时兜底
func allSources() -> [TISInputSource] {
    guard let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] else {
        return []
    }
    return list
}

/// 可用于「打字」的输入源：排除表情、手写板、输入法面板等辅助项
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

/// 按 ID 查显示名（找不到返回 nil）
func sourceName(_ id: String) -> String? {
    for s in enabledSelectableSources() where tisID(s) == id {
        let n = tisName(s)
        return n.isEmpty ? nil : n
    }
    return nil
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

/// 密码框等安全输入期间，系统会临时接管键盘，这时切输入法只会打断用户
func secureInputActive() -> Bool { IsSecureEventInputEnabled() }
