import AppKit

/// A circular Liquid Glass button over a picture, in the clear style meant
/// for controls over video. The glyph is white; a toggle that is on turns the
/// glass light with a dark glyph.
final class OverlayButton: NSView {
    static let size: CGFloat = 28
    /// Toggles show their state; plain buttons leave it off.
    var isOn = false { didSet { updateLook() } }
    var target: AnyObject? { get { button.target } set { button.target = newValue } }
    var action: Selector? { get { button.action } set { button.action = newValue } }
    var isEnabled: Bool { get { button.isEnabled } set { button.isEnabled = newValue } }
    override var toolTip: String? { didSet { button.toolTip = toolTip } }

    private let button = NSButton()
    private let glass = NSGlassEffectView()
    private var text: String?

    init(symbol: String? = nil, text: String? = nil, tip: String) {
        self.text = text
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.title = ""
        button.translatesAutoresizingMaskIntoConstraints = false
        if let symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.imagePosition = .imageOnly
        }
        button.setAccessibilityLabel(text ?? tip)

        let g = glass
        g.style = .clear
        g.cornerRadius = Self.size / 2
        g.contentView = button
        g.translatesAutoresizingMaskIntoConstraints = false
        addSubview(g)
        let host: NSView = g
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size),
            heightAnchor.constraint(equalToConstant: Self.size),
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        toolTip = tip
        updateLook()
    }

    required init?(coder: NSCoder) { fatalError() }

    func setSymbol(_ name: String, description: String) {
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: description)
        updateLook()
    }

    func setText(_ newText: String) {
        text = newText
        button.setAccessibilityLabel(newText)
        updateLook()
    }

    private func updateLook() {
        // Off: clear glass with a white glyph, which reads on video. On: light
        // glass with a dark glyph, so the state shows without a colour.
        let glyph: NSColor = isOn ? .black : .white
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
            .applying(.init(paletteColors: [glyph]))
        if let text {
            let shadow = NSShadow(); shadow.shadowColor = .black.withAlphaComponent(isOn ? 0 : 0.5); shadow.shadowBlurRadius = 2
            button.attributedTitle = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .heavy), .foregroundColor: glyph, .shadow: shadow])
        }
        glass.tintColor = isOn ? NSColor.white.withAlphaComponent(0.85) : NSColor.black.withAlphaComponent(0.25)
        button.setAccessibilityValue(isOn ? "on" : "off")
    }
}

/// One of the Background, Source, and Foreground tiles above the preview: the
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
    /// Hide the option buttons, e.g. while the layer has nothing chosen.
    var optionsHidden = false { didSet { options.isHidden = optionsHidden } }

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
