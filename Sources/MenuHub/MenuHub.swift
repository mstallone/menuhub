import AppKit
import OSLog

/// Shares one menu-bar icon among cooperating apps. Each app describes its part of the menu; the app that
/// has been running longest shows the icon, and its menu holds every running app's section. An app on
/// its own shows its own icon and menu, exactly as if it didn't share.
///
/// Apps talk over distributed notifications, which carry no sender identity: any process in the session
/// could post a fake click. Menu items should do nothing a local process couldn't already ask for.
@MainActor
public final class MenuHub: NSObject {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MenuHub", category: "MenuHub")

    /// Called with true when the shared menu opens, in whichever app shows it, and with false when it closes.
    /// An app with global hot keys should release them meanwhile: a hot key takes its keystroke before the
    /// menu sees it, even when the menu shows that keystroke as an item's key equivalent.
    public var onMenuOpen: (@MainActor (Bool) -> Void)?

    private let symbol: String
    private let content: @MainActor () -> MenuSection
    private let version: String
    private var mine: Member
    private var others: [Int32: Member] = [:]
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private var menuDelegate: MenuDelegate?
    private var menuIsOpen = false
    /// The app whose menu is open, if any.
    private var openMenuOwner: Int32?
    /// False for a moment after launch, while the other apps answer, so an app that is about to be a
    /// guest never flashes its own icon.
    private var isPastStartupGrace = false
    private var workspaceObservation: NSKeyValueObservation?

    /// `symbol` names the SF Symbol shown when the app has the icon to itself. `content` is asked for the
    /// app's section whenever it may be shown; call `update()` when something in it changes.
    public init(symbol: String, content: @escaping @MainActor () -> MenuSection) {
        let info = Bundle.main.infoDictionary ?? [:]
        self.symbol = symbol
        self.content = content
        version = info["CFBundleShortVersionString"] as? String ?? ""
        mine = Member(
            pid: ProcessInfo.processInfo.processIdentifier,
            name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? ProcessInfo.processInfo.processName,
            launched: NSRunningApplication.current.launchDate ?? Date(),
            revision: 0, isActive: true, symbol: nil, toolTip: nil, header: nil, items: []
        )
        super.init()
        menuDelegate = MenuDelegate(
            needsUpdate: { [unowned self] in
                post(.hubRefresh) // the others answer while the menu opens, and it updates in place
                update()
                build()
            },
            isOpen: { [unowned self] open in
                menuIsOpen = open
                post(.hubMenuOpen, ["open": open])
                menuOpenChanged(open, in: mine.pid)
            }
        )
        menu.delegate = menuDelegate

        let center = DistributedNotificationCenter.default()
        for name in [Notification.Name.hubMember, .hubRefresh, .hubClick, .hubMenuOpen, .hubLeave] {
            center.addObserver(self, selector: #selector(received), name: name, object: nil, suspensionBehavior: .deliverImmediately)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(willTerminate),
                                               name: NSApplication.willTerminateNotification, object: nil)
        // Catches an app that quits without saying so, like after a crash. NSWorkspace doesn't post
        // termination notifications for menu-bar apps, but its list of running apps changes; each member's
        // process is then checked directly, since the list can trail an app that just launched.
        workspaceObservation = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
            Task { @MainActor in self?.forget { kill($0, 0) != 0 } }
        }

        update()
        post(.hubRefresh)
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            isPastStartupGrace = true
            render()
        }
    }

    /// Re-reads this app's section and shares it.
    public func update() {
        let section = content()
        var next = mine
        next.isActive = section.isActive
        next.symbol = section.symbol
        next.toolTip = section.toolTip
        next.header = section.header
        next.items = section.items
        if !next.hasSameContent(as: mine) { next.revision += 1 }
        mine = next
        post(.hubMember, ["member": try! JSONEncoder().encode(mine)])
        render()
    }

    // MARK: Messages

    private func post(_ name: Notification.Name, _ info: [String: Any] = [:]) {
        DistributedNotificationCenter.default().postNotificationName(
            name, object: nil, userInfo: info.merging(["pid": mine.pid]) { $1 }, deliverImmediately: true)
    }

    @objc private func received(_ note: Notification) {
        guard let info = note.userInfo, let sender = info["pid"] as? Int32, sender != mine.pid else { return }
        switch note.name {
        case .hubMember:
            guard let data = info["member"] as? Data, let member = try? JSONDecoder().decode(Member.self, from: data) else { return }
            let previous = others.updateValue(member, forKey: sender)
            if previous == nil { Self.logger.notice("\(member.name, privacy: .public) joined") }
            if previous.map({ !$0.hasSameContent(as: member) }) ?? true { render() }
        case .hubRefresh:
            update()
        case .hubClick:
            guard info["target"] as? Int32 == mine.pid else { return }
            if info["quit"] as? Bool == true { return NSApp.terminate(nil) }
            // A click on a menu drawn from an earlier description is dropped rather than misrouted.
            guard info["revision"] as? Int == mine.revision, let path = info["item"] as? [Int] else { return }
            MenuItem.at(path, in: mine.items)?.action.perform()
        case .hubMenuOpen:
            menuOpenChanged(info["open"] as? Bool == true, in: sender)
        case .hubLeave:
            forget { $0 == sender }
        default:
            break
        }
    }

    private func menuOpenChanged(_ open: Bool, in pid: Int32) {
        let wasOpen = openMenuOwner != nil
        if open { openMenuOwner = pid } else if openMenuOwner == pid { openMenuOwner = nil }
        if (openMenuOwner != nil) != wasOpen { onMenuOpen?(openMenuOwner != nil) }
    }

    @objc private func willTerminate() {
        post(.hubLeave)
    }

    private func forget(where gone: (Int32) -> Bool) {
        let leaving = others.keys.filter(gone)
        guard !leaving.isEmpty else { return }
        for pid in leaving {
            let name = others.removeValue(forKey: pid)?.name ?? ""
            Self.logger.notice("\(name, privacy: .public) left")
            // An app that quits with its menu open never says the menu closed.
            menuOpenChanged(false, in: pid)
        }
        render()
    }

    // MARK: Icon

    /// Shows or hides this app's status item, and redraws it and any open menu.
    private func render() {
        guard isPastStartupGrace else { return }
        let isHost = Member.host(among: [mine] + others.values) == mine.pid
        if isHost, statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            statusItem?.menu = menu
            Self.logger.notice("Showing the menu-bar icon")
        } else if !isHost, let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
            Self.logger.notice("Handing the menu-bar icon to another app")
        }
        guard let button = statusItem?.button else { return }
        let members = sortedMembers
        // An app's own symbol shows while it has the icon to itself, or while it asks to be seen.
        if let member = others.isEmpty ? mine : members.first(where: { $0.symbol != nil }) {
            let name = member.pid == mine.pid ? mine.symbol ?? symbol : member.symbol!
            button.image = Self.icon(name, active: member.isActive, description: member.toolTip ?? member.name)
            button.toolTip = member.toolTip
        } else {
            button.image = Self.icon("square.grid.2x2", active: members.contains(where: \.isActive),
                                     description: members.map(\.name).formatted(.list(type: .and)))
            button.toolTip = nil
        }
        if menuIsOpen { build() }
    }

    /// Full strength while active, faded otherwise. Drawn at partial opacity rather than with
    /// `appearsDisabled`, so the level is the same on every menu bar; still a template, so it's tinted.
    private static func icon(_ name: String, active: Bool, description: String) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: active ? 1 : 0.4)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = active ? description : "\(description), inactive"
        return image
    }

    // MARK: Menu

    private var sortedMembers: [Member] {
        ([mine] + others.values).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func build() {
        Self.populate(menu, with: sortedMembers, version: version, target: self)
    }

    /// Fills `menu` with the members' sections. On its own, an app gets its section, `version` and Quit, as
    /// an unshared menu would have. Combined, each app gets a headed section, and a Quit at the bottom.
    /// Items are enabled explicitly, as their descriptions say, rather than by AppKit's validation.
    static func populate(_ menu: NSMenu, with members: [Member], version: String, target: MenuHub?) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        if members.count == 1, let member = members.first {
            add(member, header: member.header, to: menu, target: target)
            if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
            menu.addItem(withTitle: "\(member.name) \(version)", action: nil, keyEquivalent: "").isEnabled = false
            menu.addItem(withTitle: "Quit \(member.name)", action: #selector(NSApplication.terminate), keyEquivalent: "q")
            return
        }
        for member in members {
            add(member, header: member.header ?? MenuHeader(title: member.name), to: menu, target: target)
            let divider = NSMenuItem()
            divider.view = SectionDividerView()
            menu.addItem(divider)
        }
        for member in members {
            let quit = menu.addItem(withTitle: "Quit \(member.name)", action: #selector(choose), keyEquivalent: "")
            quit.target = target
            quit.representedObject = Choice(pid: member.pid, revision: member.revision, item: nil)
            quit.view = FlushMenuRowView(title: quit.title)
        }
    }

    private static func add(_ member: Member, header: MenuHeader?, to menu: NSMenu, target: MenuHub?) {
        if let header {
            let row = NSMenuItem()
            row.view = MenuHeaderView(header)
            menu.addItem(row)
        }
        add(member.items, at: [], of: member, to: menu, target: target)
    }

    /// Adds `items`, whose position in the member's section is `path`, recursing into submenus.
    private static func add(_ items: [MenuItem], at path: [Int], of member: Member, to menu: NSMenu, target: MenuHub?) {
        for (index, item) in items.enumerated() {
            let row: NSMenuItem
            switch item.kind {
            case .separator:
                menu.addItem(.separator())
                continue
            case .heading:
                row = .sectionHeader(title: item.title)
            case .info:
                row = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
            case .submenu:
                row = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                submenu.autoenablesItems = false
                add(item.children ?? [], at: path + [index], of: member, to: submenu, target: target)
                row.submenu = submenu
            case .action:
                row = NSMenuItem(title: item.title, action: #selector(choose), keyEquivalent: item.keyEquivalent)
                row.target = target
                row.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: item.modifiers)
                row.isAlternate = item.isAlternate
                row.representedObject = Choice(pid: member.pid, revision: member.revision, item: path + [index])
            }
            row.state = item.isOn == true ? .on : .off
            row.isEnabled = item.isEnabled
            if #available(macOS 14.4, *), let subtitle = item.subtitle { row.subtitle = subtitle }
            menu.addItem(row)
        }
    }

    private struct Choice {
        let pid: Int32
        let revision: Int
        /// The item's path through nested submenus; nil for the app's Quit item.
        let item: [Int]?
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? Choice else { return }
        if choice.pid == mine.pid {
            guard let path = choice.item else { return NSApp.terminate(nil) }
            if choice.revision == mine.revision { MenuItem.at(path, in: mine.items)?.action.perform() }
        } else if let path = choice.item {
            post(.hubClick, ["target": choice.pid, "revision": choice.revision, "item": path])
        } else {
            post(.hubClick, ["target": choice.pid, "quit": true])
        }
    }
}

/// Keeps the menu delegate methods out of MenuHub's public interface.
private final class MenuDelegate: NSObject, NSMenuDelegate {
    private let needsUpdate: @MainActor () -> Void
    private let isOpen: @MainActor (Bool) -> Void

    init(needsUpdate: @escaping @MainActor () -> Void, isOpen: @escaping @MainActor (Bool) -> Void) {
        self.needsUpdate = needsUpdate
        self.isOpen = isOpen
    }

    func menuNeedsUpdate(_ menu: NSMenu) { needsUpdate() }
    func menuWillOpen(_ menu: NSMenu) { isOpen(true) }
    func menuDidClose(_ menu: NSMenu) { isOpen(false) }
}

/// What each app shares: who it is, and its section of the menu.
struct Member: Codable, Equatable {
    let pid: Int32
    let name: String
    let launched: Date
    var revision: Int
    var isActive: Bool
    var symbol: String?
    var toolTip: String?
    var header: MenuHeader?
    var items: [MenuItem]

    func hasSameContent(as other: Member) -> Bool {
        (isActive, symbol, toolTip, header, items) == (other.isActive, other.symbol, other.toolTip, other.header, other.items)
    }

    /// The app that shows the icon: the one running longest, so the icon stays put as others come and go.
    static func host(among members: [Member]) -> Int32? {
        members.min { ($0.launched, $0.pid) < ($1.launched, $1.pid) }?.pid
    }
}

/// Every message carries the sender's `pid`. The 2 is the protocol version: changing a message or `Member`
/// changes it, so apps built against incompatible versions ignore each other instead of misreading.
private extension Notification.Name {
    /// A member's description: `member`, JSON-encoded `Member`.
    static let hubMember = Notification.Name("com.mattstallone.menuhub.2.member")
    /// Asks every member to send its description again.
    static let hubRefresh = Notification.Name("com.mattstallone.menuhub.2.refresh")
    /// A chosen item, for `target`: `revision` and `item` (a path), or `quit`.
    static let hubClick = Notification.Name("com.mattstallone.menuhub.2.click")
    /// The sender's menu opened or closed: `open`.
    static let hubMenuOpen = Notification.Name("com.mattstallone.menuhub.2.menu-open")
    /// The sender is quitting.
    static let hubLeave = Notification.Name("com.mattstallone.menuhub.2.leave")
}
