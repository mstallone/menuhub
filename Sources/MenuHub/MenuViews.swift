import AppKit

/// A row drawn by MenuHub. An open menu doesn't draw a view put into it, so when a menu is updated while open,
/// a row that changed shows the new content in place rather than being replaced.
protocol MenuRow: NSView {
    /// What the row shows, to tell whether it changed.
    var content: AnyHashable { get }
    /// Shows what `row`, a new row of the same kind, shows.
    func show(contentOf row: NSView)
}

/// Where AppKit draws a menu item's parts, for the rows drawn here to line up with native ones.
enum MenuMetrics {
    /// Where checkmarks start.
    static let leading: CGFloat = 14
    /// Where key equivalents end.
    static let trailing: CGFloat = 16
    /// The selection highlight's inset from the menu's sides.
    static let highlightInset: CGFloat = 5
    static let rowHeight: CGFloat = 24
}

/// A heading row. A view rather than a disabled item, so it reads in full-strength text and never
/// highlights. It starts where the checkmarks do, left of the item titles, and ends with the key equivalents.
final class MenuHeaderView: NSView, MenuRow {
    private var header: MenuHeader
    var content: AnyHashable { header }

    init(_ header: MenuHeader) {
        self.header = header
        super.init(frame: .zero)
        autoresizingMask = .width
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        build()
    }

    required init?(coder: NSCoder) { nil }

    func show(contentOf row: NSView) {
        guard let row = row as? MenuHeaderView else { return }
        header = row.header
        build()
    }

    private func build() {
        subviews.forEach { $0.removeFromSuperview() }
        let title = header.title
        let size = NSFont.menuFont(ofSize: 0).pointSize
        let titleLabel = label(title, font: .systemFont(ofSize: size, weight: .semibold), color: .labelColor)
        titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MenuMetrics.leading).isActive = true
        titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 3).isActive = true
        var bottom = titleLabel.bottomAnchor
        var accessibility = title

        switch header.detail {
        case let .battery(percent):
            let text = label("\(percent)%", font: .systemFont(ofSize: size), color: .tertiaryLabelColor)
            let glyph = NSImageView(image: Self.batteryImage(percent, pointSize: size))
            glyph.contentTintColor = percent <= 10 ? .systemRed : .tertiaryLabelColor
            glyph.translatesAutoresizingMaskIntoConstraints = false
            addSubview(glyph)
            NSLayoutConstraint.activate([
                glyph.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MenuMetrics.trailing),
                glyph.centerYAnchor.constraint(equalTo: text.centerYAnchor),
                text.trailingAnchor.constraint(equalTo: glyph.leadingAnchor, constant: -5),
                text.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
                text.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 16),
            ])
            accessibility += ", battery \(percent)%"
        case let .status(status):
            let text = label(status, font: .systemFont(ofSize: size), color: .tertiaryLabelColor)
            NSLayoutConstraint.activate([
                text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MenuMetrics.trailing),
                text.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
                text.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 16),
            ])
            accessibility += ", \(status)"
        case let .message(message):
            let text = label(message, font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor)
            text.preferredMaxLayoutWidth = 170
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -MenuMetrics.trailing),
                text.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            ])
            bottom = text.bottomAnchor
            accessibility += ", \(message)"
        case nil:
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -MenuMetrics.trailing).isActive = true
        }
        bottom.constraint(equalTo: bottomAnchor, constant: -4).isActive = true

        // The menu widens the row to its own width; the fitting width is only the minimum it asks for.
        let fitting = fittingSize
        setFrameSize(NSSize(width: max(frame.width, fitting.width), height: fitting.height))
        setAccessibilityLabel(accessibility)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        appearance = plainAppearance(matching: superview)
    }

    private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = color
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        return label
    }

    /// The system's battery glyphs come in quarters; round to the nearest. The reading may come from another
    /// process, so it's clamped rather than trusted.
    private static func batteryImage(_ percent: Int, pointSize: CGFloat) -> NSImage {
        let quarter = (min(max(percent, 0), 100) + 12) / 25 * 25
        return NSImage(systemSymbolName: "battery.\(quarter)percent", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))!
    }
}

/// The break between two apps' sections: a gap of slightly deeper glass, so each app's items read as their
/// own pane. Separators stay for the groups within a section.
final class SectionDividerView: NSView, MenuRow {
    let content: AnyHashable = 0

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: 15))
        autoresizingMask = .width
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    func show(contentOf row: NSView) {}

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let gap = NSRect(x: 0, y: bounds.midY.rounded() - 4, width: bounds.width, height: 8)
        NSColor.black.withAlphaComponent(dark ? 0.16 : 0.06).setFill()
        gap.fill()
    }
}

/// Draws a menu item so its title starts at the checkmark column, like the headers; native items always
/// leave room for a checkmark. It highlights with the same selection material native items use, and a
/// click sends the item's action. Return does not: AppKit ignores it on items with views.
final class FlushMenuRowView: NSView, MenuRow {
    private var title: String
    private var detail: String?
    var content: AnyHashable { [title, detail] }

    private let selection = NSVisualEffectView()
    private let label = NSTextField(labelWithString: "")
    private var capsule: CapsuleView?
    private var labelEnd: NSLayoutConstraint?

    /// `detail`, like an app's version, is shown in a faint capsule where key equivalents go.
    init(title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: MenuMetrics.rowHeight))
        autoresizingMask = .width

        selection.material = .selection
        selection.state = .active
        selection.isEmphasized = true
        selection.wantsLayer = true
        selection.layer?.cornerRadius = 6
        selection.layer?.cornerCurve = .continuous
        selection.isHidden = true
        label.font = .menuFont(ofSize: 0)
        for view in [selection, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            selection.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MenuMetrics.highlightInset),
            selection.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MenuMetrics.highlightInset),
            selection.topAnchor.constraint(equalTo: topAnchor),
            selection.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MenuMetrics.leading),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        build()
    }

    required init?(coder: NSCoder) { nil }

    func show(contentOf row: NSView) {
        guard let row = row as? FlushMenuRowView else { return }
        title = row.title
        detail = row.detail
        build()
    }

    private func build() {
        label.stringValue = title
        capsule?.removeFromSuperview()
        labelEnd?.isActive = false
        capsule = detail.map(CapsuleView.init)
        if let capsule {
            capsule.translatesAutoresizingMaskIntoConstraints = false
            capsule.appearance = label.appearance
            addSubview(capsule)
            labelEnd = label.trailingAnchor.constraint(lessThanOrEqualTo: capsule.leadingAnchor, constant: -16)
            NSLayoutConstraint.activate([
                capsule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MenuMetrics.trailing),
                capsule.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        } else {
            labelEnd = label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -MenuMetrics.trailing)
        }
        labelEnd?.isActive = true
        frame.size.width = max(frame.width, fittingSize.width)
        setAccessibilityLabel(detail.map { "\(title), \($0)" } ?? title)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        label.appearance = plainAppearance(matching: self)
        capsule?.appearance = label.appearance
    }

    /// The menu redraws the row when its highlight changes.
    override func viewWillDraw() {
        let highlighted = enclosingMenuItem?.isHighlighted == true
        selection.isHidden = !highlighted
        label.textColor = enclosingMenuItem?.isEnabled == false ? .tertiaryLabelColor
            : highlighted ? .selectedMenuItemTextColor : .labelColor
        capsule?.isHighlighted = highlighted
        super.viewWillDraw()
    }

    override func mouseUp(with event: NSEvent) {
        choose()
    }

    override func accessibilityPerformPress() -> Bool {
        choose()
        return true
    }

    private func choose() {
        guard let item = enclosingMenuItem, item.isEnabled, let menu = item.menu else { return }
        menu.cancelTracking()
        menu.performActionForItem(at: menu.index(of: item))
    }
}

/// Short text in a faint capsule, like an app's version beside its Quit item.
final class CapsuleView: NSView {
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private let text: String
    var isHighlighted = false {
        didSet { if isHighlighted != oldValue { needsDisplay = true } }
    }

    init(_ text: String) {
        self.text = text
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        let size = (text as NSString).size(withAttributes: [.font: Self.font])
        return NSSize(width: ceil(size.width) + 12, height: 17)
    }

    override func draw(_ dirtyRect: NSRect) {
        (isHighlighted ? NSColor.white.withAlphaComponent(0.2) : NSColor.labelColor.withAlphaComponent(0.07)).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let string = NSAttributedString(string: text, attributes: [
            .font: Self.font, .foregroundColor: isHighlighted ? NSColor.selectedMenuItemTextColor : NSColor.secondaryLabelColor,
        ])
        let size = string.size()
        string.draw(at: NSPoint(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded()))
    }
}

/// Menus resolve colors in a vibrant appearance, meant for text AppKit draws with a vibrancy blend. A custom
/// view doesn't get the blend, so its colors come out washed out; in the plain light or dark appearance
/// they match native item text.
@MainActor private func plainAppearance(matching view: NSView?) -> NSAppearance? {
    let dark = view?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    return NSAppearance(named: dark ? .darkAqua : .aqua)
}
