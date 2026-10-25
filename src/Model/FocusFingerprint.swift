import Foundation

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

