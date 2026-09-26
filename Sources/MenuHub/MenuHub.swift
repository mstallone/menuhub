import AppKit
import OSLog

/// Shares one menu-bar icon among cooperating apps. Each app describes its part of the menu; the app that
/// has been running longest shows the icon, and its menu holds every running app's section. An app on
/// its own shows its own icon and menu, exactly as if it didn't share.
///
/// Apps talk over distributed notifications, which carry no sender identity: any process in the session
/// could post a fake click. Menu items should do nothing a local process couldn't already ask for.
@MainActor
public final class MenuHub: NSObject, NSMenuDelegate {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MenuHub", category: "MenuHub")

    private let icon: NSImage
    private let content: @MainActor () -> MenuSection
    private var mine: Member
    private var others: [Int32: Member] = [:]
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private var menuIsOpen = false
    /// False for a moment after launch, while the other apps answer, so an app that is about to be a
    /// guest never flashes its own icon.
    private var hasHeardFromOthers = false
    private var workspaceObservation: NSKeyValueObservation?

    /// `icon` is a template image, shown when the app has the icon to itself. `content` is asked for the
    /// app's section whenever it may be shown; call `update()` when something in it changes.
    public init(icon: NSImage, content: @escaping @MainActor () -> MenuSection) {
        let info = Bundle.main.infoDictionary ?? [:]
        self.icon = icon
        self.content = content
        mine = Member(
            pid: ProcessInfo.processInfo.processIdentifier,
            name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? ProcessInfo.processInfo.processName,
            version: info["CFBundleShortVersionString"] as? String ?? "",
            launched: NSRunningApplication.current.launchDate ?? Date(),
            revision: 0, isActive: true, header: nil, items: []
        )
        super.init()
        menu.delegate = self

        let center = DistributedNotificationCenter.default()
        for name in [Notification.Name.hubMember, .hubRefresh, .hubClick, .hubLeave] {
            center.addObserver(self, selector: #selector(received), name: name, object: nil, suspensionBehavior: .deliverImmediately)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(willTerminate),
                                               name: NSApplication.willTerminateNotification, object: nil)
        // Catches an app that quits without saying so, like after a crash.
        workspaceObservation = NSWorkspace.shared.observe(\.runningApplications) { [weak self] workspace, _ in
            let running = Set(workspace.runningApplications.map(\.processIdentifier))
            Task { @MainActor in self?.forget { !running.contains($0) } }
        }

        update()
        post(.hubRefresh)
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            hasHeardFromOthers = true
            render()
        }
    }

    /// Re-reads this app's section and shares it.
    public func update() {
        let section = content()
        var next = mine
        next.isActive = section.isActive
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
            if info["quit"] as? Bool == true { NSApp.terminate(nil) }
            // A click on a menu drawn from an earlier description is dropped rather than misrouted.
            guard info["revision"] as? Int == mine.revision, let index = info["item"] as? Int,
                  mine.items.indices.contains(index) else { return }
            mine.items[index].perform?()
        case .hubLeave:
            forget { $0 == sender }
        default:
            break
        }
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
        }
        render()
    }

    // MARK: Icon

    /// Shows or hides this app's status item, and redraws it and any open menu.
    private func render() {
        guard hasHeardFromOthers else { return }
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
        if others.isEmpty {
            button.image = Self.icon(icon, active: mine.isActive, description: mine.name)
        } else {
            let members = sortedMembers
            let symbol = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)!
            button.image = Self.icon(symbol, active: members.contains(where: \.isActive),
                                     description: members.map(\.name).formatted(.list(type: .and)))
        }
        if menuIsOpen { build() }
    }

    /// Full strength while active, faded otherwise. Drawn at partial opacity rather than with
    /// `appearsDisabled`, so the level is the same on every menu bar; still a template, so it's tinted.
    private static func icon(_ symbol: NSImage, active: Bool, description: String) -> NSImage {
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: active ? 1 : 0.4)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = active ? description : "\(description), inactive"
        return image
    }

    // MARK: Menu

    public func menuNeedsUpdate(_ menu: NSMenu) {
        post(.hubRefresh) // the others answer while the menu opens, and it updates in place
        update()
        build()
    }

    public func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }
    public func menuDidClose(_ menu: NSMenu) { menuIsOpen = false }

    private var sortedMembers: [Member] {
        ([mine] + others.values).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func build() {
        Self.populate(menu, with: sortedMembers, mine: mine.pid, target: self)
    }

    /// Fills `menu` with the members' sections. On its own, an app gets its section, version and Quit, as
    /// an unshared menu would have. Combined, each app gets a headed section, and a Quit at the bottom.
    static func populate(_ menu: NSMenu, with members: [Member], mine: Int32, target: MenuHub?) {
        menu.removeAllItems()
        if members.count == 1, let member = members.first {
            add(member, header: member.header, to: menu, target: target)
            menu.addItem(.separator())
            menu.addItem(withTitle: "\(member.name) \(member.version)", action: nil, keyEquivalent: "")
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
        }
    }

    private static func add(_ member: Member, header: MenuHeader?, to menu: NSMenu, target: MenuHub?) {
        if let header {
            let row = NSMenuItem()
            row.view = MenuHeaderView(header)
            menu.addItem(row)
        }
        for (index, item) in member.items.enumerated() {
            switch item.kind {
            case .separator:
                menu.addItem(.separator())
            case .info:
                menu.addItem(withTitle: item.title, action: nil, keyEquivalent: "").state = item.isOn == true ? .on : .off
            case .action:
                let row = menu.addItem(withTitle: item.title, action: #selector(choose), keyEquivalent: item.keyEquivalent)
                row.target = target
                row.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: item.modifiers)
                row.isAlternate = item.isAlternate
                row.state = item.isOn == true ? .on : .off
                row.representedObject = Choice(pid: member.pid, revision: member.revision, item: index)
            }
        }
    }

    private struct Choice {
        let pid: Int32
        let revision: Int
        /// Nil for the app's Quit item.
        let item: Int?
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? Choice else { return }
        if choice.pid == mine.pid {
            guard let item = choice.item else { return NSApp.terminate(nil) }
            if choice.revision == mine.revision { mine.items[item].perform?() }
        } else if let item = choice.item {
            post(.hubClick, ["target": choice.pid, "revision": choice.revision, "item": item])
        } else {
            post(.hubClick, ["target": choice.pid, "quit": true])
        }
    }
}

/// What each app shares: who it is, and its section of the menu.
struct Member: Codable, Equatable {
    let pid: Int32
    let name: String
    let version: String
    let launched: Date
    var revision: Int
    var isActive: Bool
    var header: MenuHeader?
    var items: [MenuItem]

    func hasSameContent(as other: Member) -> Bool {
        (isActive, header, items) == (other.isActive, other.header, other.items)
    }

    /// The app that shows the icon: the one running longest, so the icon stays put as others come and go.
    static func host(among members: [Member]) -> Int32? {
        members.min { ($0.launched, $0.pid) < ($1.launched, $1.pid) }?.pid
    }
}

private extension Notification.Name {
    /// A member's description: `member`, JSON-encoded `Member`.
    static let hubMember = Notification.Name("com.mattstallone.menuhub.member")
    /// Asks every member to send its description again.
    static let hubRefresh = Notification.Name("com.mattstallone.menuhub.refresh")
    /// A chosen item, for `target`: `revision` and `item`, or `quit`.
    static let hubClick = Notification.Name("com.mattstallone.menuhub.click")
    /// The sender is quitting.
    static let hubLeave = Notification.Name("com.mattstallone.menuhub.leave")
}
