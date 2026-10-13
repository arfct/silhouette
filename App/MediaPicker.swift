import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Model

/// One choice in a picker: a camera, a movie, an image, a web page, a colour.
struct PickerItem {
    enum Thumbnail {
        /// SF Symbol on a neutral tile.
        case symbol(String)
        case color(NSColor)
        /// An image or movie file; the thumbnail loads in the background.
        case file(URL)
        /// A web page: its favicon when one loads, otherwise a globe.
        case web(URL)
        /// A ready-made picture, such as the live camera frame or a page snapshot.
        case image(NSImage)
    }
    var value: String
    var title: String
    var thumbnail: Thumbnail
    var tooltip: String? = nil
    var removable = false
}

/// What a section's + button adds.
enum PickerAddKind {
    case file, video, web, color

    /// Kinds typed into a field in the popover rather than picked from a panel.
    var isEntry: Bool { self == .web || self == .color }
    var placeholder: String {
        switch self {
        case .web: "Web address, then Return"
        case .color: "#RRGGBB or #RRGGBBAA, then Return"
        default: ""
        }
    }
    var tooltip: String {
        switch self {
        case .file: "Add an image or movie file"
        case .video: "Add a movie file as the source"
        case .web: "Add a web page by its address"
        case .color: "Add a colour, typed as hex or picked"
        }
    }
}

struct PickerSection {
    var title: String
    var items: [PickerItem]
    var add: PickerAddKind? = nil
}

// MARK: - Labels

enum PickerLabel {
    /// A URL without its scheme, "www.", or a trailing slash.
    static func web(_ text: String) -> String {
        var t = text
        for prefix in ["https://", "http://"] where t.lowercased().hasPrefix(prefix) { t = String(t.dropFirst(prefix.count)) }
        if t.lowercased().hasPrefix("www.") { t = String(t.dropFirst(4)) }
        while t.hasSuffix("/") { t.removeLast() }
        return t
    }

    static func file(_ path: String) -> String { (path as NSString).lastPathComponent }

    static func isMovie(_ url: URL) -> Bool {
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }
}

// MARK: - Thumbnails

/// Loads and caches small thumbnails for files and web pages, off the main thread.
final class ThumbnailLoader {
    static let shared = ThumbnailLoader()
    /// Opens a sandboxed file for reading, through its saved bookmark when it has one.
    var access: ((URL) -> ScopedFile?)?

    private let cache = NSCache<NSString, NSImage>()
    private var failed = Set<String>()
    private var waiting: [String: [(NSImage?) -> Void]] = [:]
    private let queue = DispatchQueue(label: "\(VirtualCameraConstants.appBundleID).thumbnails", qos: .utility, attributes: .concurrent)
    static let maxPixels = 320

    func cached(_ key: String) -> NSImage? { cache.object(forKey: key as NSString) }

    /// Calls back on the main thread, at once when cached.
    func thumbnail(for url: URL, completion: @escaping (NSImage?) -> Void) {
        let key = "file:" + url.path
        if let hit = cached(key) { completion(hit); return }
        if failed.contains(key) { completion(nil); return }
        guard begin(key, completion) else { return }
        let scoped = access?(url)
        let target = scoped?.url ?? url
        if PickerLabel.isMovie(target) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: target))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: Self.maxPixels, height: Self.maxPixels)
            generator.requestedTimeToleranceBefore = .positiveInfinity
            generator.requestedTimeToleranceAfter = .positiveInfinity
            generator.generateCGImageAsynchronously(for: CMTime(seconds: 0.5, preferredTimescale: 600)) { [weak self] cg, _, _ in
                withExtendedLifetime(scoped) {}
                self?.finish(key, cg.map { NSImage(cgImage: $0, size: .zero) })
            }
        } else {
            queue.async { [weak self] in
                var image: NSImage?
                if let source = CGImageSourceCreateWithURL(target as CFURL, nil) {
                    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                    kCGImageSourceCreateThumbnailWithTransform: true,
                                                    kCGImageSourceThumbnailMaxPixelSize: Self.maxPixels]
                    if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                        image = NSImage(cgImage: cg, size: .zero)
                    }
                }
                withExtendedLifetime(scoped) {}
                self?.finish(key, image)
            }
        }
    }

    /// The site's /favicon.ico, when it has one.
    func favicon(for url: URL, completion: @escaping (NSImage?) -> Void) {
        guard let host = url.host, let icon = URL(string: "https://\(host)/favicon.ico") else { completion(nil); return }
        let key = "favicon:" + host
        if let hit = cached(key) { completion(hit); return }
        if failed.contains(key) { completion(nil); return }
        guard begin(key, completion) else { return }
        var request = URLRequest(url: icon, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 8)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            let image = ok ? data.flatMap(NSImage.init(data:)) : nil
            self?.finish(key, image.flatMap { $0.isValid && $0.size.width > 0 ? $0 : nil })
        }.resume()
    }

    /// True when this caller should start the load; false when one is already running.
    private func begin(_ key: String, _ completion: @escaping (NSImage?) -> Void) -> Bool {
        if waiting[key] != nil { waiting[key]!.append(completion); return false }
        waiting[key] = [completion]
        return true
    }

    private func finish(_ key: String, _ image: NSImage?) {
        DispatchQueue.main.async { [self] in
            if let image { cache.setObject(image, forKey: key as NSString) } else { failed.insert(key) }
            let callbacks = waiting.removeValue(forKey: key) ?? []
            callbacks.forEach { $0(image) }
        }
    }
}

/// Draws a thumbnail into a layer: aspect-filled pictures, centred symbols and
/// favicons on a neutral fill, colours over a checkerboard when translucent.
final class ThumbnailView: NSView {
    private let pictureLayer = CALayer()
    private let symbolView = NSImageView()
    private var token = 0
    var symbolPointSize: CGFloat = 22 { didSet { symbolView.symbolConfiguration = .init(pointSize: symbolPointSize, weight: .regular) } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.masksToBounds = true
        pictureLayer.contentsGravity = .resizeAspectFill
        pictureLayer.masksToBounds = true
        layer?.addSublayer(pictureLayer)
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.contentTintColor = .secondaryLabelColor
        symbolView.imageScaling = .scaleProportionallyDown
        addSubview(symbolView)
        NSLayoutConstraint.activate([
            symbolView.centerXAnchor.constraint(equalTo: centerXAnchor),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbolView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.6),
            symbolView.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, multiplier: 0.6),
        ])
        symbolPointSize = 22
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        pictureLayer.frame = bounds
        CATransaction.commit()
    }

    override func updateLayer() {
        super.updateLayer()
        if fill == nil { layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor }
    }
    override var wantsUpdateLayer: Bool { true }

    private var fill: NSColor?

    func show(_ thumbnail: PickerItem.Thumbnail) {
        token += 1
        let mine = token
        pictureLayer.contents = nil
        symbolView.image = nil
        fill = nil
        switch thumbnail {
        case .symbol(let name):
            symbol(name)
        case .color(let color):
            fill = color
            if color.alphaComponent < 1 {
                pictureLayer.contents = Self.checkerboard(over: color)
                pictureLayer.contentsGravity = .resize
            } else {
                layer?.backgroundColor = color.cgColor
            }
        case .image(let image):
            picture(image)
        case .file(let url):
            symbol(PickerLabel.isMovie(url) ? "film" : "photo")
            ThumbnailLoader.shared.thumbnail(for: url) { [weak self] image in
                guard let self, mine == token, let image else { return }
                symbolView.image = nil
                picture(image)
            }
        case .web(let url):
            symbol("globe")
            ThumbnailLoader.shared.favicon(for: url) { [weak self] image in
                guard let self, mine == token, let image else { return }
                symbolView.contentTintColor = nil
                symbolView.image = image
            }
        }
        needsDisplay = true
        needsLayout = true
    }

    private func symbol(_ name: String) {
        symbolView.contentTintColor = .secondaryLabelColor
        symbolView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    private func picture(_ image: NSImage) {
        pictureLayer.contentsGravity = .resizeAspectFill
        pictureLayer.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil) ?? image
    }

    /// A colour with alpha drawn over grey checks, so translucency shows.
    private static func checkerboard(over color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 64, height: 36), flipped: false) { rect in
            NSColor(white: 0.85, alpha: 1).setFill(); rect.fill()
            NSColor(white: 0.65, alpha: 1).setFill()
            let s: CGFloat = 6
            for y in stride(from: 0, to: rect.height, by: s) {
                for x in stride(from: 0, to: rect.width, by: s) where (Int(x / s) + Int(y / s)) % 2 == 0 {
                    NSRect(x: x, y: y, width: s, height: s).fill()
                }
            }
            color.setFill(); rect.fill(using: .sourceOver)
            return true
        }
    }
}

// MARK: - Sidebar button

/// Full-width button in the sidebar showing the current choice; opens the picker.
final class PickerButton: NSButton {
    private let thumb = ThumbnailView(frame: .zero)
    private let label = NSTextField(labelWithString: "")
    private let chevron = NSImageView()

    init() {
        super.init(frame: .zero)
        title = ""
        bezelStyle = .push
        setButtonType(.momentaryPushIn)
        thumb.translatesAutoresizingMaskIntoConstraints = false
        thumb.symbolPointSize = 10
        thumb.layer?.cornerRadius = 3
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)
        chevron.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        chevron.contentTintColor = .secondaryLabelColor
        for v in [thumb, label, chevron] as [NSView] { addSubview(v) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            thumb.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            thumb.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumb.widthAnchor.constraint(equalToConstant: 32),
            thumb.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -6),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ item: PickerItem) {
        label.stringValue = item.title
        toolTip = item.tooltip ?? item.title
        thumb.show(item.thumbnail)
    }
}

// MARK: - Popover

/// A grid of 16:9 tiles with labels, in sections with + buttons, shown in a popover.
final class PickerPopover: NSObject, NSPopoverDelegate {
    var onSelect: ((String) -> Void)?
    var onRemove: ((String) -> Void)?
    /// For entry kinds, the typed text; nil for panel kinds.
    var onAdd: ((PickerAddKind, String?) -> Void)?

    private let popover = NSPopover()
    private var controller: PickerViewController?

    var isShown: Bool { popover.isShown }

    func show(title: String, sections: [PickerSection], selected: String?, from view: NSView, openEntry: PickerAddKind? = nil) {
        let vc = PickerViewController(title: title, sections: sections, selected: selected)
        vc.onSelect = { [weak self] value in self?.close(); self?.onSelect?(value) }
        vc.onRemove = { [weak self] value in self?.onRemove?(value) }
        vc.onAdd = { [weak self] kind, text in
            self?.close()
            self?.onAdd?(kind, text)
        }
        vc.onEntryOpened = { [weak self] color in self?.popover.behavior = color ? .semitransient : .transient }
        controller = vc
        popover.contentViewController = vc
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxX)
        if let openEntry { vc.openEntry(openEntry) }
    }

    /// Rebuild in place, e.g. after an item is removed.
    func update(sections: [PickerSection], selected: String?) {
        guard popover.isShown else { return }
        controller?.reload(sections: sections, selected: selected)
    }

    func close() { popover.performClose(nil) }

    func popoverDidClose(_ notification: Notification) {
        if NSColorPanel.sharedColorPanelExists { NSColorPanel.shared.orderOut(nil) }
        controller = nil
        popover.contentViewController = nil
    }
}

private final class PickerViewController: NSViewController, NSTextFieldDelegate {
    var onSelect: ((String) -> Void)?
    var onRemove: ((String) -> Void)?
    var onAdd: ((PickerAddKind, String?) -> Void)?
    var onEntryOpened: ((Bool) -> Void)?

    private let pickerTitle: String
    private var sections: [PickerSection]
    private var selected: String?
    private let stack = NSStackView()
    private var entryRows: [PickerAddKind: NSView] = [:]
    private var entryFields: [PickerAddKind: NSTextField] = [:]
    private var colorWell: NSColorWell?

    static let columns = 3
    static let tileWidth: CGFloat = 132
    static let spacing: CGFloat = 10
    static let inset: CGFloat = 14
    static var contentWidth: CGFloat { CGFloat(columns) * tileWidth + CGFloat(columns - 1) * spacing }

    init(title: String, sections: [PickerSection], selected: String?) {
        pickerTitle = title
        self.sections = sections
        self.selected = selected
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: Self.inset, left: Self.inset, bottom: Self.inset, right: Self.inset)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedClipDocument()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        view = scroll
        rebuild()
    }

    func reload(sections: [PickerSection], selected: String?) {
        self.sections = sections
        self.selected = selected
        rebuild()
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        entryRows = [:]; entryFields = [:]; colorWell = nil

        let heading = NSTextField(labelWithString: pickerTitle)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(heading)
        stack.setCustomSpacing(10, after: heading)

        for (index, section) in sections.enumerated() {
            let header = NSTextField(labelWithString: section.title.uppercased())
            header.font = .systemFont(ofSize: 10, weight: .semibold)
            header.textColor = .secondaryLabelColor
            header.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            var headerViews: [NSView] = [header]
            if let add = section.add {
                let plus = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: add.tooltip)!, target: self, action: #selector(addTapped(_:)))
                plus.bezelStyle = .accessoryBarAction
                plus.isBordered = false
                plus.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
                plus.contentTintColor = .controlAccentColor
                plus.toolTip = add.tooltip
                plus.tag = index
                headerViews.append(plus)
            }
            let headerRow = NSStackView(views: headerViews)
            headerRow.distribution = .fill
            stack.addArrangedSubview(headerRow)
            headerRow.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
            stack.setCustomSpacing(6, after: headerRow)

            if let add = section.add, add.isEntry {
                let row = entryRow(add)
                row.isHidden = true
                entryRows[add] = row
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
            }

            var row: NSStackView?
            for (i, item) in section.items.enumerated() {
                if i % Self.columns == 0 {
                    row = NSStackView()
                    row!.spacing = Self.spacing
                    row!.alignment = .top
                    stack.addArrangedSubview(row!)
                }
                let tile = TileView(item: item, selected: item.value == selected)
                tile.onClick = { [weak self] in self?.onSelect?(item.value) }
                tile.onRemove = item.removable ? { [weak self] in self?.remove(item.value) } : nil
                row!.addArrangedSubview(tile)
            }
            if section.items.isEmpty && section.add != nil {
                let hint = NSTextField(labelWithString: "None yet. Use + to add one.")
                hint.font = .systemFont(ofSize: 11)
                hint.textColor = .tertiaryLabelColor
                stack.addArrangedSubview(hint)
            }
            if index < sections.count - 1, let last = stack.arrangedSubviews.last { stack.setCustomSpacing(16, after: last) }
        }

        // Size: the grid's width, and as tall as the content up to a limit.
        stack.layoutSubtreeIfNeeded()
        let height = min(stack.fittingSize.height, 520)
        preferredContentSize = NSSize(width: Self.contentWidth + 2 * Self.inset, height: height)
    }

    private func entryRow(_ kind: PickerAddKind) -> NSView {
        let field = NSTextField()
        field.placeholderString = kind.placeholder
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.controlSize = .small
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.target = self
        field.action = #selector(entryCommitted(_:))
        field.tag = kind == .web ? 0 : 1
        entryFields[kind] = field
        var views: [NSView] = [field]
        if kind == .color {
            let well = NSColorWell(style: .minimal)
            well.supportsAlpha = true
            well.target = self
            well.action = #selector(colorPicked(_:))
            well.widthAnchor.constraint(equalToConstant: 38).isActive = true
            colorWell = well
            views.append(well)
        }
        let row = NSStackView(views: views)
        row.spacing = 6
        return row
    }

    func openEntry(_ kind: PickerAddKind) {
        guard let row = entryRows[kind] else { return }
        row.isHidden = false
        view.window?.makeFirstResponder(entryFields[kind])
        onEntryOpened?(kind == .color)
        stack.layoutSubtreeIfNeeded()
        preferredContentSize.height = min(stack.fittingSize.height, 520)
        row.scrollToVisible(row.bounds.insetBy(dx: 0, dy: -40))   // the Colors field can sit below the fold
    }

    @objc private func addTapped(_ sender: NSButton) {
        guard sections.indices.contains(sender.tag), let kind = sections[sender.tag].add else { return }
        if kind.isEntry {
            if entryRows[kind]?.isHidden == false { entryRows[kind]?.isHidden = true; onEntryOpened?(false) } else { openEntry(kind) }
        } else {
            onAdd?(kind, nil)
        }
    }

    @objc private func entryCommitted(_ sender: NSTextField) {
        let text = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onAdd?(sender.tag == 0 ? .web : .color, text)
    }

    @objc private func colorPicked(_ sender: NSColorWell) {
        guard let c = sender.color.usingColorSpace(.sRGB) else { return }
        func h(_ v: CGFloat) -> String { String(format: "%02X", Int((min(max(v, 0), 1) * 255).rounded())) }
        var hex = "#" + h(c.redComponent) + h(c.greenComponent) + h(c.blueComponent)
        if c.alphaComponent < 1 { hex += h(c.alphaComponent) }
        entryFields[.color]?.stringValue = hex
    }

    private func remove(_ value: String) {
        onRemove?(value)
    }
}

private final class FlippedClipDocument: NSView {
    override var isFlipped: Bool { true }
}

/// A 16:9 thumbnail with its label below. Click to choose; right-click to remove a recent.
private final class TileView: NSView {
    var onClick: (() -> Void)?
    var onRemove: (() -> Void)?
    private let thumb = ThumbnailView(frame: .zero)
    private let label = NSTextField(labelWithString: "")
    private let selected: Bool
    private var hovering = false { didSet { updateBorder() } }

    init(item: PickerItem, selected: Bool) {
        self.selected = selected
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        thumb.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = item.title
        label.font = .systemFont(ofSize: 11)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.textColor = selected ? .labelColor : .secondaryLabelColor
        toolTip = item.tooltip ?? item.title
        addSubview(thumb); addSubview(label)
        let w = PickerViewController.tileWidth
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: w),
            thumb.topAnchor.constraint(equalTo: topAnchor),
            thumb.leadingAnchor.constraint(equalTo: leadingAnchor),
            thumb.trailingAnchor.constraint(equalTo: trailingAnchor),
            thumb.heightAnchor.constraint(equalTo: thumb.widthAnchor, multiplier: 9.0 / 16.0),
            label.topAnchor.constraint(equalTo: thumb.bottomAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        thumb.show(item.thumbnail)
        updateBorder()
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.title)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateBorder() {
        thumb.layer?.borderWidth = selected ? 2.5 : (hovering ? 1.5 : 0.5)
        thumb.layer?.borderColor = (selected ? NSColor.controlAccentColor : (hovering ? NSColor.secondaryLabelColor : NSColor.separatorColor)).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { updateBorder() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard onRemove != nil else { return nil }
        let menu = NSMenu()
        menu.addItem(withTitle: "Remove from Recents", action: #selector(removeTapped), keyEquivalent: "").target = self
        return menu
    }
    @objc private func removeTapped() { onRemove?() }
}
