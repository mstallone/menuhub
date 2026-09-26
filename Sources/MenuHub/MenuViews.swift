import AppKit

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
final class MenuHeaderView: NSView {
    init(_ header: MenuHeader) {
        let title = header.title
        super.init(frame: .zero)
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

        // The menu widens the row to its own width; this is only the minimum it asks for.
        frame.size = fittingSize
        autoresizingMask = .width
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(accessibility)
    }

    required init?(coder: NSCoder) { nil }

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
final class SectionDividerView: NSView {
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: 15))
        autoresizingMask = .width
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

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
final class FlushMenuRowView: NSView {
    private let selection = NSVisualEffectView()
    private let label: NSTextField

    init(title: String) {
        label = NSTextField(labelWithString: title)
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
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -MenuMetrics.trailing),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        frame.size.width = fittingSize.width
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        label.appearance = plainAppearance(matching: self)
    }

    /// The menu redraws the row when its highlight changes.
    override func viewWillDraw() {
        let highlighted = enclosingMenuItem?.isHighlighted == true
        selection.isHidden = !highlighted
        label.textColor = highlighted ? .selectedMenuItemTextColor : .labelColor
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
        guard let item = enclosingMenuItem, let menu = item.menu else { return }
        menu.cancelTracking()
        menu.performActionForItem(at: menu.index(of: item))
    }
}

/// Menus resolve colors in a vibrant appearance, meant for text AppKit draws with a vibrancy blend. A custom
/// view doesn't get the blend, so its colors come out washed out; in the plain light or dark appearance
/// they match native item text.
@MainActor private func plainAppearance(matching view: NSView?) -> NSAppearance? {
    let dark = view?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    return NSAppearance(named: dark ? .darkAqua : .aqua)
}
