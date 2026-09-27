import AppKit

/// One app's part of the menu. The hub adds the app's Quit item, and its version while the app has the menu
/// to itself.
public struct MenuSection {
    public var header: MenuHeader?
    public var items: [MenuItem]
    /// Whether the app is doing its job. The icon is faded while it isn't.
    public var isActive: Bool
    /// An SF Symbol shown instead of the app's usual one while set, for a state worth seeing at a glance,
    /// like recording or an error. When menus are combined it replaces the shared icon too.
    public var symbol: String?
    /// The icon's tooltip while this app's symbol is shown.
    public var toolTip: String?

    /// `header` is optional when the app has the menu to itself. When menus are combined, a section
    /// without one is headed by the app's name.
    public init(header: MenuHeader? = nil, items: [MenuItem], isActive: Bool = true, symbol: String? = nil,
                toolTip: String? = nil) {
        self.header = header
        self.items = items
        self.isActive = isActive
        self.symbol = symbol
        self.toolTip = toolTip
    }
}

/// A heading row: a title, with a short status on the right or a sentence underneath.
public struct MenuHeader: Codable, Hashable, Sendable {
    public enum Detail: Codable, Hashable, Sendable {
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

/// A row of the menu. Two items are equal when they look the same; their actions aren't compared.
public struct MenuItem: Codable, Equatable {
    enum Kind: Codable { case action, info, heading, submenu, separator }

    struct Action: Equatable {
        let perform: @MainActor () -> Void
        init(_ perform: @escaping @MainActor () -> Void) { self.perform = perform }
        static func == (lhs: Action, rhs: Action) -> Bool { true }
    }

    let kind: Kind
    var title = ""
    var subtitle: String?
    var keyEquivalent = ""
    var modifiers: UInt = 0
    var isOn: Bool?
    var isAlternate = false
    var isEnabled = true
    var children: [MenuItem]?
    /// Runs in the app that described the item, wherever the menu is shown. Not sent to other apps, so an item
    /// decoded from another app's description does nothing.
    var action = Action {}

    public static func action(_ title: String, subtitle: String? = nil, key: String = "",
                              modifiers: NSEvent.ModifierFlags = .command, isOn: Bool? = nil, isEnabled: Bool = true,
                              perform: @escaping @MainActor () -> Void) -> MenuItem {
        MenuItem(kind: .action, title: title, subtitle: subtitle, keyEquivalent: key, modifiers: modifiers.rawValue,
                 isOn: isOn, isEnabled: isEnabled, action: Action(perform))
    }

    /// Replaces the item before it while Option is held.
    public static func alternate(_ title: String, perform: @escaping @MainActor () -> Void) -> MenuItem {
        MenuItem(kind: .action, title: title, modifiers: NSEvent.ModifierFlags.option.rawValue, isAlternate: true,
                 action: Action(perform))
    }

    /// A line of text that can't be chosen.
    public static func info(_ title: String, subtitle: String? = nil, isOn: Bool? = nil) -> MenuItem {
        MenuItem(kind: .info, title: title, subtitle: subtitle, isOn: isOn, isEnabled: false)
    }

    /// A small heading over the items that follow, within the section.
    public static func heading(_ title: String) -> MenuItem {
        MenuItem(kind: .heading, title: title, isEnabled: false)
    }

    public static func submenu(_ title: String, subtitle: String? = nil, items: [MenuItem]) -> MenuItem {
        MenuItem(kind: .submenu, title: title, subtitle: subtitle, children: items)
    }

    public static var separator: MenuItem {
        MenuItem(kind: .separator, isEnabled: false)
    }

    private enum CodingKeys: String, CodingKey {
        case kind, title, subtitle, keyEquivalent, modifiers, isOn, isAlternate, isEnabled, children
    }

    /// The item at `path`, a list of indexes into nested submenus.
    static func at(_ path: [Int], in items: [MenuItem]) -> MenuItem? {
        guard let first = path.first, items.indices.contains(first) else { return nil }
        return path.count == 1 ? items[first] : at(Array(path.dropFirst()), in: items[first].children ?? [])
    }
}
