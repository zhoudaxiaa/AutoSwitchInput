import Foundation

/// UI 层（设置窗口 / 小面板 / 状态栏菜单）对应用内核的全部依赖。
///
/// 界面只读配置、只通过方法请求改动，不直接持有引擎与触发器，
/// 这样 UI 文件和运行时逻辑可以各自独立演进。
protocol AppActions: AnyObject {

    /// 只读快照。要改规则请走下面的方法，别直接改这个结构体。
    var config: Config { get }

    /// 最近一个活跃的外部应用（菜单/面板打开时前台可能是本应用自己）
    var lastExternalBundle: String? { get set }

    var loginInstalled: Bool { get }

    // MARK: 规则

    func setAppRule(bundle: String, source: String?)
    func setSpotRule(bundle: String, source: String?, fp: FocusFingerprint)
    func removeContextRule(at index: Int)
    func clearContextRules(for bundle: String)

    // MARK: 开关

    func setEnabled(_ on: Bool)
    func setLearn(_ on: Bool)
    func toggleLogin()
    func setLanguage(_ code: String?)

    // MARK: 界面与外部动作

    func openSettings()
    func reloadSettingsWindow()
    func refreshStatusTitle()
    func openConfig()
    func openLog()
    func closePopover()
    func quit()

    /// 诊断：把当前焦点特征写到 ax-focus.txt
    func dumpFocusNow()
}
