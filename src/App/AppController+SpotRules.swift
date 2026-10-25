import Foundation

// 「此处」规则：给光标所在的那个位置单独指定输入法
extension AppController {

    /// source 传 nil 表示清除该位置的规则（回到「跟随应用」）
    func setSpotRule(bundle: String, source: String?, fp: FocusFingerprint) {
        let matched = ContextRuleEngine.best(in: config.contextRules(for: bundle), for: fp)
        // 备注按「此刻焦点在哪」现算，不要继承 matched 的：
        // 一旦 matched 是条误匹配的旧规则，新规则会被冠上别人的名字
        // （Copilot 聊天框被标成「编辑器」就是这么来的）
        let label = ContextRuleEngine.displayLabel(fp, matchedNote: matched?.note)
        let probe = ContextRuleEngine.make(bundle: bundle, source: source ?? "",
                                           fp: fp, note: label)

        // 同一个位置只留一条，避免越点越多
        config.contexts.removeAll { $0.bundle == bundle && ContextRuleEngine.sameSpot($0, probe) }

        if let source = source {
            var rule = probe
            rule.source = source
            config.contexts.append(rule)
            log("✎ 位置规则 \(bundle) [\(rule.note ?? "-")] → \(source)")
        } else {
            log("✎ 清除位置规则 \(bundle) [\(probe.note ?? "-")]")
        }

        saveConfig()
        refreshStatusTitle()
        settings.reload()
        // 面板是从下拉菜单里点出来的，先让菜单收起再重建，
        // 否则会在 NSPopUpButton 自己的 action 里销毁正在派发事件的那个控件
        DispatchQueue.main.async { [weak self] in self?.statusBar.refreshPanel() }
        engine.scheduleApply(reason: "位置规则变更")
    }

    func removeContextRule(at index: Int) {
        guard config.contexts.indices.contains(index) else { return }
        let rule = config.contexts.remove(at: index)
        saveConfig()
        log("✎ 删除位置规则 \(rule.bundle) [\(rule.note ?? "-")]")
        settings.reload()
        engine.scheduleApply(reason: "删除位置规则")
    }

    func clearContextRules(for bundle: String) {
        let n = config.contexts.filter { $0.bundle == bundle }.count
        guard n > 0 else { return }
        config.contexts.removeAll { $0.bundle == bundle }
        saveConfig()
        log("✎ 清除位置规则 \(bundle) ×\(n)")
        settings.reload()
        statusBar.refreshPanel()
        engine.scheduleApply(reason: "清除位置规则")
    }
}
