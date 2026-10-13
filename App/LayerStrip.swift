import AppKit

/// A round or capsule button drawn over a tile's picture: white glyph on a
/// dark translucent backing, accent backing while a toggle is on.
final class OverlayButton: NSButton {
    static let size: CGFloat = 24
    /// Toggles show their state; plain buttons leave it off.
    var isOn = false { didSet { updateLook() } }

    init(symbol: String? = nil, text: String? = nil, tip: String) {
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = Self.size / 2
        title = text ?? ""
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            symbolConfiguration = .init(pointSize: 11, weight: .semibold)
            imagePosition = .imageOnly
        }
        font = .systemFont(ofSize: 10, weight: .bold)
        toolTip = tip
        setAccessibilityLabel(text ?? tip)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.size).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: Self.size).isActive = true
        if text != nil { widthAnchor.constraint(equalToConstant: 30).isActive = true }
        updateLook()
    }

    required init?(coder: NSCoder) { fatalError() }

    func setSymbol(_ name: String, description: String) {
        image = NSImage(systemSymbolName: name, accessibilityDescription: description)
    }

    private func updateLook() {
        layer?.backgroundColor = (isOn ? NSColor.controlAccentColor : NSColor.black.withAlphaComponent(0.5)).cgColor
        contentTintColor = .white
        attributedTitle = NSAttributedString(string: title, attributes: [.font: font ?? .systemFont(ofSize: 10), .foregroundColor: NSColor.white])
        setAccessibilityValue(isOn ? "on" : "off")
    }
}

/// One of the Source, Background, and Foreground tiles above the preview: the
/// current picture at 16:9, its name, a picker button at the top right, and
/// the layer's own option buttons at the bottom right.
final class LayerTile: NSView {
    let pickerButton = OverlayButton(symbol: "square.grid.2x2", tip: "Choose…")
    var onPick: (() -> Void)?

    private let thumb = ThumbnailView(frame: .zero)
    private let titleLabel = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")
    private let options = NSStackView()
    private let topScrim = CAGradientLayer()
    private let bottomScrim = CAGradientLayer()

    init(title: String, options optionButtons: [NSView]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5

        thumb.translatesAutoresizingMaskIntoConstraints = false
        thumb.layer?.cornerRadius = 0
        thumb.symbolPointSize = 26
        addSubview(thumb)

        for scrim in [topScrim, bottomScrim] {
            scrim.colors = [NSColor.black.withAlphaComponent(0.45).cgColor, NSColor.black.withAlphaComponent(0).cgColor]
            layer?.addSublayer(scrim)
        }
        bottomScrim.startPoint = CGPoint(x: 0.5, y: 0); bottomScrim.endPoint = CGPoint(x: 0.5, y: 1)
        topScrim.startPoint = CGPoint(x: 0.5, y: 1); topScrim.endPoint = CGPoint(x: 0.5, y: 0)

        titleLabel.stringValue = title.uppercased()
        titleLabel.font = .systemFont(ofSize: 10, weight: .bold)
        titleLabel.textColor = .white
        nameLabel.font = .systemFont(ofSize: 11, weight: .medium)
        nameLabel.textColor = .white
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for label in [titleLabel, nameLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            let shadow = NSShadow(); shadow.shadowColor = .black.withAlphaComponent(0.6); shadow.shadowBlurRadius = 2; shadow.shadowOffset = .zero
            label.shadow = shadow
            addSubview(label)
        }

        pickerButton.target = self
        pickerButton.action = #selector(pickTapped)
        pickerButton.toolTip = "Choose the \(title.lowercased())"
        addSubview(pickerButton)

        options.translatesAutoresizingMaskIntoConstraints = false
        options.spacing = 5
        optionButtons.forEach(options.addArrangedSubview)
        addSubview(options)

        let pad: CGFloat = 7
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalTo: widthAnchor, multiplier: 9.0 / 16.0),
            thumb.leadingAnchor.constraint(equalTo: leadingAnchor),
            thumb.trailingAnchor.constraint(equalTo: trailingAnchor),
            thumb.topAnchor.constraint(equalTo: topAnchor),
            thumb.bottomAnchor.constraint(equalTo: bottomAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad + 2),
            titleLabel.centerYAnchor.constraint(equalTo: pickerButton.centerYAnchor),
            pickerButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            pickerButton.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            options.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            options.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad + 2),
            nameLabel.centerYAnchor.constraint(equalTo: options.centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: options.leadingAnchor, constant: -6),
        ])
        options.heightAnchor.constraint(equalToConstant: OverlayButton.size).isActive = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let h = min(bounds.height * 0.42, 44)
        bottomScrim.frame = CGRect(x: 0, y: 0, width: bounds.width, height: h)
        topScrim.frame = CGRect(x: 0, y: bounds.height - h, width: bounds.width, height: h)
        CATransaction.commit()
    }

    override func updateLayer() {
        super.updateLayer()
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
    override var wantsUpdateLayer: Bool { true }

    /// The current choice: its name and thumbnail.
    func show(_ item: PickerItem) {
        nameLabel.stringValue = item.title
        nameLabel.toolTip = item.tooltip ?? item.title
        thumb.show(item.thumbnail)
    }

    @objc private func pickTapped() { onPick?() }

    /// A click on the picture opens the picker too.
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPick?() }
    }
}
