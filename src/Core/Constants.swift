import Foundation

/// 本应用的 bundle id（与 Info.plist / 签名 identifier 保持一致）
let kBundleSelf = "com.local.autoswitchinput"

/// 第二实例拉起时，用它通知已在运行的实例把设置窗口亮出来
let kShowWindowNote = Notification.Name("com.local.autoswitchinput.showWindow")
