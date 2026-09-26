import AppKit

/// One app's part of the menu. The hub adds the app's version and Quit item.
public struct MenuSection {
    public var header: MenuHeader?
    public var items: [MenuItem]
    /// Whether the app is doing its job. The icon is faded while it isn't.
    public var isActive: Bool

    /// `header` is optional when the app has the menu to itself. When menus are combined, a section
    /// without one is headed by the app's name.
    public init(header: MenuHeader? = nil, items: [MenuItem], isActive: Bool = true) {
        self.header = header
        self.items = items
        self.isActive = isActive
    }
}

/// A heading row: a title, with a short status on the right or a sentence underneath.
public struct MenuHeader: Codable, Equatable, Sendable {
    public enum Detail: Codable, Equatable, Sendable {
        case battery(Int)
        /// A word or two, on the right like the battery.
        case status(String)
        /// A sentence, under the title.
        case message(String)
    }

    public var title: String
    public var detail: Detail?

    public init(title: String, detail: Detail? = nil) {
        self.title = title
        self.detail = detail
    }
}

public struct MenuItem: Codable, Equatable {
    enum Kind: Codable { case action, info, separator }

    let kind: Kind
    let title: String
    let keyEquivalent: String
    let modifiers: UInt
    let isOn: Bool?
    let isAlternate: Bool
    /// Runs in the app that described the item, wherever the menu is shown.
    var perform: (@MainActor () -> Void)?

    public static func action(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command,
                              isOn: Bool? = nil, perform: @escaping @MainActor () -> Void) -> MenuItem {
        MenuItem(kind: .action, title: title, keyEquivalent: key, modifiers: modifiers.rawValue, isOn: isOn,
                 isAlternate: false, perform: perform)
    }

    /// Replaces the item before it while Option is held.
    public static func alternate(_ title: String, perform: @escaping @MainActor () -> Void) -> MenuItem {
        MenuItem(kind: .action, title: title, keyEquivalent: "", modifiers: NSEvent.ModifierFlags.option.rawValue,
                 isOn: nil, isAlternate: true, perform: perform)
    }

    /// A line of text that can't be chosen.
    public static func info(_ title: String, isOn: Bool? = nil) -> MenuItem {
        MenuItem(kind: .info, title: title, keyEquivalent: "", modifiers: 0, isOn: isOn, isAlternate: false)
    }

    public static var separator: MenuItem {
        MenuItem(kind: .separator, title: "", keyEquivalent: "", modifiers: 0, isOn: nil, isAlternate: false)
    }

    private enum CodingKeys: String, CodingKey { case kind, title, keyEquivalent, modifiers, isOn, isAlternate }

    public static func == (lhs: MenuItem, rhs: MenuItem) -> Bool {
        (lhs.kind, lhs.title, lhs.keyEquivalent, lhs.modifiers, lhs.isOn, lhs.isAlternate)
            == (rhs.kind, rhs.title, rhs.keyEquivalent, rhs.modifiers, rhs.isOn, rhs.isAlternate)
    }
}
