import Cocoa

// MARK: - 设置窗口

/// 翻转坐标系的容器，让滚动内容从顶部开始排
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class RuleRow: NSView {
    let bundleID: String
    var onRemove: (() -> Void)?
    var onChange: ((String?) -> Void)?

    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)

    init(bundle: String, ruleID: String?, sources: [(id: String, name: String)], installed: Bool, displayName: String? = nil, detail: String? = nil, context: Bool = false, removalEnabled: Bool = true) {
        self.bundleID = bundle
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: context ? 44 : 48).isActive = true

        let info = appDisplayInfo(for: bundle)

        let icon = NSImageView()
        icon.image = info.icon
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.alphaValue = installed ? 1.0 : 0.35
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 26).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 26).isActive = true

        let nameLabel = NSTextField(labelWithString: displayName ?? info.name)
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.textColor = installed ? .labelColor : .secondaryLabelColor

        let idLabel = NSTextField(labelWithString: detail ?? (installed ? bundle : bundle + L("row.missing")))
        idLabel.font = .systemFont(ofSize: 10)
        idLabel.textColor = installed ? .secondaryLabelColor : .tertiaryLabelColor
        idLabel.lineBreakMode = .byTruncatingMiddle

        let textStack = NSStackView(views: [nameLabel, idLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.font = .systemFont(ofSize: 12)
        popup.removeAllItems()
        popup.addItem(withTitle: L("row.none"))
        popup.lastItem?.representedObject = nil
        for s in sources {
            popup.addItem(withTitle: s.name)
            popup.lastItem?.representedObject = s.id
        }
        if let rid = ruleID,
           let idx = popup.itemArray.firstIndex(where: { ($0.representedObject as? String) == rid }) {
            popup.selectItem(at: idx)
        } else {
            popup.selectItem(at: 0)
        }
        if let rid = ruleID, !sources.contains(where: { $0.id == rid }) {
            popup.addItem(withTitle: LF("source.unavailable", sourceName(rid) ?? rid))
            popup.lastItem?.representedObject = rid
            popup.selectItem(at: popup.numberOfItems - 1)
        }
        popup.target = self
        popup.action = #selector(popupChanged)
        popup.widthAnchor.constraint(equalToConstant: 148).isActive = true
        popup.setContentHuggingPriority(.required, for: .horizontal)

        let minus = NSButton(title: "−", target: self, action: #selector(removeTapped))
        minus.isEnabled = removalEnabled
        minus.isBordered = false
        minus.font = .systemFont(ofSize: 16)
        minus.contentTintColor = .tertiaryLabelColor
        minus.translatesAutoresizingMaskIntoConstraints = false
        minus.widthAnchor.constraint(equalToConstant: 20).isActive = true
        minus.setContentHuggingPriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        let h = NSStackView(views: [icon, textStack, spacer, popup, minus])
        h.orientation = .horizontal
        h.alignment = .centerY
        h.spacing = 10
        h.edgeInsets = NSEdgeInsets(top: 0, left: context ? 30 : 14, bottom: 0, right: 12)
        h.translatesAutoresizingMaskIntoConstraints = false
        addSubview(h)
        NSLayoutConstraint.activate([
            h.leadingAnchor.constraint(equalTo: leadingAnchor),
            h.trailingAnchor.constraint(equalTo: trailingAnchor),
            h.topAnchor.constraint(equalTo: topAnchor),
            h.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func popupChanged() {
        onChange?(popup.selectedItem?.representedObject as? String)
    }

    @objc private func removeTapped() {
        onRemove?()
    }
}
