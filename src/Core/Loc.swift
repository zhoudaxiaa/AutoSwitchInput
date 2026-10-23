import Foundation

// ============================================================================
// 极简本地化层
// 资源在 <lang>.lproj/Localizable.strings。
// 默认跟随系统；用户在设置里选了具体语言时，切到对应 .lproj 的 Bundle。
// 找不到 key 时原样返回 key，方便发现漏翻。
// ============================================================================

/// 用户手动指定的语言，nil 表示跟随系统
private(set) var appLanguageOverride: String?

/// 当前生效的本地化 Bundle
private var activeBundle: Bundle?

/// 切换界面语言。code 为 "zh-Hans" / "en"，传 nil 恢复跟随系统。
/// 必须在重建 UI 之前调用 —— 文案是在建视图时取出来的。
func setAppLanguage(_ code: String?) {
    guard let code = code, !code.isEmpty else {
        appLanguageOverride = nil
        activeBundle = nil
        return
    }
    if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
       let b = Bundle(path: path) {
        appLanguageOverride = code
        activeBundle = b
    } else {
        // 语言包不存在（比如手工改了配置），退回跟随系统
        appLanguageOverride = nil
        activeBundle = nil
    }
}

private func localized(_ key: String) -> String {
    (activeBundle ?? Bundle.main).localizedString(forKey: key, value: key, table: nil)
}

/// 普通取词
func L(_ key: String) -> String {
    localized(key)
}

/// 带参数的取词，例如 LF("status.rules", 3)
func LF(_ key: String, _ args: CVarArg...) -> String {
    String(format: localized(key), locale: Locale.current, arguments: args)
}
