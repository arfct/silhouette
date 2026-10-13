import AppKit

/// A circular button over a tile's picture: Liquid Glass on macOS 26, a dark
/// translucent circle before that. Toggles tint with the accent colour while on.
final class OverlayButton: NSButton {
    static let size: CGFloat = 28
    /// Toggles show their state; plain buttons leave it off.
    var isOn = false { didSet { updateLook() } }
    private let glass: Bool

    init(symbol: String? = nil, text: String? = nil, tip: String) {
        if #available(macOS 26.0, *) { glass = true } else { glass = false }
        super.init(frame: .zero)
        title = text ?? ""
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            symbolConfiguration = .init(pointSize: 12, weight: .semibold)
            imagePosition = .imageOnly
        }
        font = .systemFont(ofSize: 10, weight: .bold)
        if #available(macOS 26.0, *) {
            bezelStyle = .glass
            borderShape = .circle
        } else {
            isBordered = false
            wantsLayer = true
            layer?.cornerRadius = Self.size / 2
        }
        toolTip = tip
        setAccessibilityLabel(text ?? tip)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Self.size).isActive = true
        heightAnchor.constraint(equalToConstant: Self.size).isActive = true
        updateLook()
    }

    required init?(coder: NSCoder) { fatalError() }

    func setSymbol(_ name: String, description: String) {
        image = NSImage(systemSymbolName: name, accessibilityDescription: description)
    }

    private func updateLook() {
        if glass {
            bezelColor = isOn ? .controlAccentColor : nil
            // Glass ignores the content tint for glyphs, so colour them directly: white on the accent.
            let base = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            symbolConfiguration = isOn ? base.applying(.init(paletteColors: [.white])) : base
            let font = self.font ?? .systemFont(ofSize: 10, weight: .bold)
            attributedTitle = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: isOn ? NSColor.white : NSColor.labelColor])
        } else {
            layer?.backgroundColor = (isOn ? NSColor.controlAccentColor : NSColor.black.withAlphaComponent(0.5)).cgColor
            contentTintColor = .white
            attributedTitle = NSAttributedString(string: title, attributes: [.font: font ?? .systemFont(ofSize: 10), .foregroundColor: NSColor.white])
        }
        setAccessibilityValue(isOn ? "on" : "off")
    }
}

/// One of the Source, Background, and Foreground tiles above the preview: the
/// current picture at 16:9 with the layer's option buttons at its bottom
/// right. A click on the picture opens the picker. The caption, the layer's
/// name and the current choice, sits above the tile in the title bar.
final class LayerTile: NSView {
    var onPick: (() -> Void)?
    /// "SOURCE  Sample video", for the window to place above the tile.
    let caption = NSTextField(labelWithString: "")
    /// The tile and its caption stacked, as one column of the strip.
    private(set) var column: NSStackView!

    private let title: String
    private let thumb = ThumbnailView(frame: .zero)
    private let options = NSStackView()

    init(title: String, options optionButtons: [NSView]) {
        self.title = title
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

        caption.lineBreakMode = .byTruncatingTail
        caption.maximumNumberOfLines = 1
        caption.cell?.truncatesLastVisibleLine = true
        caption.cell?.usesSingleLineMode = true
        caption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        caption.toolTip = "Click the picture to choose the \(title.lowercased())."

        options.translatesAutoresizingMaskIntoConstraints = false
        options.spacing = 6
        optionButtons.forEach(options.addArrangedSubview)
        addSubview(options)

        let pad: CGFloat = 7
        NSLayoutConstraint.activate([
            // At least 16:9; taller when the window has height to spare, cropped to the centre.
            heightAnchor.constraint(greaterThanOrEqualTo: widthAnchor, multiplier: 9.0 / 16.0),
            thumb.leadingAnchor.constraint(equalTo: leadingAnchor),
            thumb.trailingAnchor.constraint(equalTo: trailingAnchor),
            thumb.topAnchor.constraint(equalTo: topAnchor),
            thumb.bottomAnchor.constraint(equalTo: bottomAnchor),
            options.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            options.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
        ])
        // 16:9 by default. Above the content pane's hug (480) so a wide window grows
        // the preview, below its fill-height (490) so a narrow one grows the tiles.
        let natural = heightAnchor.constraint(equalTo: widthAnchor, multiplier: 9.0 / 16.0)
        natural.priority = NSLayoutConstraint.Priority(485)
        natural.isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Choose the \(title.lowercased())")

        let column = NSStackView(views: [caption, self])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        // A long file name truncates rather than widening the column (and the window).
        column.setClippingResistancePriority(.defaultLow, for: .horizontal)
        column.setHuggingPriority(.defaultLow, for: .horizontal)
        column.setHuggingPriority(NSLayoutConstraint.Priority(800), for: .vertical)
        widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        caption.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor).isActive = true
        self.column = column
        show(PickerItem(value: "", title: "", thumbnail: .symbol("nosign")))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        super.updateLayer()
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
    override var wantsUpdateLayer: Bool { true }

    /// The current choice: its name in the caption, its picture in the tile.
    func show(_ item: PickerItem) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail   // one line; a long name ends in an ellipsis
        let text = NSMutableAttributedString(string: title.uppercased(), attributes: [
            .paragraphStyle: style,
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor])
        if !item.title.isEmpty {
            text.append(NSAttributedString(string: "   " + item.title, attributes: [
                .paragraphStyle: style,
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]))
        }
        caption.attributedStringValue = text
        caption.toolTip = item.tooltip ?? item.title
        setAccessibilityValue(item.title)
        thumb.show(item.thumbnail)
    }

    @objc private func pickTapped() { onPick?() }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPick?() }
    }
    override func accessibilityPerformPress() -> Bool { onPick?(); return true }
}
