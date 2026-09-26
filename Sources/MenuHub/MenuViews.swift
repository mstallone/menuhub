import AppKit

/// A heading row. A view rather than a disabled item, so it reads in full-strength text and never
/// highlights. Aligned with the titles and key equivalents of the items below it.
public final class MenuHeaderView: NSView {
    /// Where AppKit starts item titles, and ends key equivalents, in a menu with a checkmark column.
    private static let titleInset: CGFloat = 30
    private static let trailingInset: CGFloat = 16

    public init(_ header: MenuHeader) {
        let title = header.title
        super.init(frame: .zero)
        let size = NSFont.menuFont(ofSize: 0).pointSize
        let titleLabel = label(title, font: .systemFont(ofSize: size, weight: .semibold), color: .labelColor)
        titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.titleInset).isActive = true
        titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 3).isActive = true
        var bottom = titleLabel.bottomAnchor
        var accessibility = title

        switch header.detail {
        case let .battery(percent):
            let text = label("\(percent)%", font: .systemFont(ofSize: size), color: .secondaryLabelColor)
            let glyph = NSImageView(image: Self.batteryImage(percent, pointSize: size))
            glyph.contentTintColor = percent <= 10 ? .systemRed : .secondaryLabelColor
            glyph.translatesAutoresizingMaskIntoConstraints = false
            addSubview(glyph)
            NSLayoutConstraint.activate([
                glyph.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.trailingInset),
                glyph.centerYAnchor.constraint(equalTo: text.centerYAnchor),
                text.trailingAnchor.constraint(equalTo: glyph.leadingAnchor, constant: -5),
                text.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
                text.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 16),
            ])
            accessibility += ", battery \(percent)%"
        case let .status(status):
            let text = label(status, font: .systemFont(ofSize: size), color: .secondaryLabelColor)
            NSLayoutConstraint.activate([
                text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.trailingInset),
                text.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
                text.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 16),
            ])
            accessibility += ", \(status)"
        case let .message(message):
            let text = label(message, font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor)
            text.preferredMaxLayoutWidth = 170
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.trailingInset),
                text.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            ])
            bottom = text.bottomAnchor
            accessibility += ", \(message)"
        case nil:
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.trailingInset).isActive = true
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

    private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = color
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        return label
    }

    /// The system's battery glyphs come in quarters; round to the nearest.
    private static func batteryImage(_ percent: Int, pointSize: CGFloat) -> NSImage {
        let quarter = min(4, (percent + 12) / 25) * 25
        return NSImage(systemSymbolName: "battery.\(quarter)percent", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))!
    }
}

/// The line between two apps' sections: full width and darker than a separator, which stays for the
/// groups within a section.
final class SectionDividerView: NSView {
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: 15))
        autoresizingMask = .width
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.setFill()
        NSRect(x: 12, y: (bounds.midY - 0.5).rounded(), width: bounds.width - 24, height: 1).fill()
    }
}
