import Foundation

// ============================================================================
// 极简本地化层
// 资源在 <lang>.lproj/Localizable.strings，由系统按「App 语言」/系统语言自动选择。
// 找不到 key 时原样返回 key，方便发现漏翻。
// ============================================================================

/// 普通取词
func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

/// 带参数的取词，例如 LF("status.rules", 3)
func LF(_ key: String, _ args: CVarArg...) -> String {
    let format = Bundle.main.localizedString(forKey: key, value: key, table: nil)
    return String(format: format, locale: Locale.current, arguments: args)
}
