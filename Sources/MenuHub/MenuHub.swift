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

    /// Called with true when this app's menu opens and with false when it closes. While a process tracks a
    /// menu, its global hot keys are held until the menu closes; an app can release them meanwhile, so the
    /// menu's own key equivalents take the keystrokes instead.
    public var onMenuOpen: (@MainActor (Bool) -> Void)?

    private let symbol: String
    private let content: @MainActor () -> MenuSection
    private let updater: (any Updater)?
    private var mine: Member
    private var others: [Int32: Member] = [:]
    private var statusItem: NSStatusItem?
    /// Redraws the icon while the member whose symbol is shown asks for the moving wave.
    private var waveTimer: Timer?
    private var wave = (active: true, description: "")
    private let menu = NSMenu()
    private var menuDelegate: MenuDelegate?
    private var menuIsOpen = false
    /// False for a moment after launch, while the other apps answer, so an app that is about to be a
    /// guest never flashes its own icon.
    private var isPastStartupGrace = false
    private var workspaceObservation: NSKeyValueObservation?
    /// The Check for Updates this app started in a combined menu, while it waits for the answers.
    private var updateRound: UpdateRound?

    /// `symbol` names the SF Symbol shown when the app has the icon to itself. `content` is asked for the
    /// app's section whenever it may be shown; call `update()` when something in it changes.
    ///
    /// With `yieldsIcon`, the app shows the icon only when no app that doesn't yield is running. An app whose
    /// global hot keys must work while the menu is open should yield: a process tracking a menu gets its hot
    /// keys only after the menu closes.
    ///
    /// `updater` adds Check for Updates…, shared with the other apps that have one.
    public init(symbol: String, yieldsIcon: Bool = false, updater: (any Updater)? = nil,
                content: @escaping @MainActor () -> MenuSection) {
        let info = Bundle.main.infoDictionary ?? [:]
        self.symbol = symbol
        self.content = content
        self.updater = updater
        mine = Member(
            pid: ProcessInfo.processInfo.processIdentifier,
            name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? ProcessInfo.processInfo.processName,
            version: info["CFBundleShortVersionString"] as? String ?? "",
            launched: NSRunningApplication.current.launchDate ?? Date(), yieldsIcon: yieldsIcon, checksForUpdates: updater != nil,
            revision: 0, isActive: true, symbol: nil, toolTip: nil, animatesIcon: false, header: nil, items: []
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
                onMenuOpen?(open)
            }
        )
        menu.delegate = menuDelegate

        let center = DistributedNotificationCenter.default()
        for name in [Notification.Name.hubMember, .hubRefresh, .hubClick, .hubLeave, .hubCheckForUpdates, .hubUpdateResult] {
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
        next.animatesIcon = section.animatesIcon
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
        case .hubLeave:
            forget { $0 == sender }
        case .hubCheckForUpdates:
            guard let updater, let round = info["check"] as? String else { return }
            Task {
                let result = await updater.checkForUpdatesQuietly()
                post(.hubUpdateResult, ["target": sender, "check": round, "result": try! JSONEncoder().encode(result)])
            }
        case .hubUpdateResult:
            guard info["target"] as? Int32 == mine.pid, let round = info["check"] as? String, let data = info["result"] as? Data,
                  let result = try? JSONDecoder().decode(UpdateCheckResult.self, from: data) else { return }
            record(result, from: sender, in: round)
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
            updateRound?.drop(pid)
        }
        if let round = updateRound, round.isComplete { finish(round.id) }
        render()
    }

    // MARK: Updates

    /// On its own, or when no other app has an updater, the app runs its usual check. Otherwise every app
    /// with an updater checks quietly, and what they found is summed up once they've all answered.
    @objc private func checkForUpdates() {
        let apps = ([mine] + others.values).filter(\.checksForUpdates)
        if apps.map(\.pid) == [mine.pid] {
            updater?.checkForUpdates()
            return
        }
        let round = UpdateRound(apps: Dictionary(uniqueKeysWithValues: apps.map { ($0.pid, ($0.name, $0.version)) }))
        updateRound = round
        post(.hubCheckForUpdates, ["check": round.id])
        if let updater {
            Task { record(await updater.checkForUpdatesQuietly(), from: mine.pid, in: round.id) }
        }
        Task {
            try? await Task.sleep(for: .seconds(30))
            finish(round.id)
        }
    }

    private func record(_ result: UpdateCheckResult, from pid: Int32, in round: String) {
        guard updateRound?.id == round else { return }
        updateRound?.record(result, from: pid)
        if updateRound?.isComplete == true { finish(round) }
    }

    private func finish(_ round: String) {
        guard let finished = updateRound, finished.id == round else { return }
        updateRound = nil
        guard let summary = finished.summary else { return }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = summary.title
        alert.informativeText = summary.text
        alert.icon = Self.stackedIcon(finished.apps.compactMap { NSRunningApplication(processIdentifier: $0)?.icon })
        alert.runModal()
    }

    /// The apps' icons overlapping from the top left, for an alert that speaks for all of them.
    private static func stackedIcon(_ icons: [NSImage]) -> NSImage? {
        guard icons.count > 1 else { return icons.first }
        let canvas: CGFloat = 64, side = canvas * 0.72
        let step = (canvas - side) / CGFloat(icons.count - 1)
        return NSImage(size: NSSize(width: canvas, height: canvas), flipped: true) { _ in
            for (index, icon) in icons.enumerated() {
                let offset = CGFloat(index) * step
                icon.draw(in: NSRect(x: offset, y: offset, width: side, height: side))
            }
            return true
        }
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
            let description = member.toolTip ?? member.name
            if member.animatesIcon && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                animateWave(active: member.isActive, description: description)
            } else {
                stopWave()
                button.image = Self.icon(name, active: member.isActive, description: description)
            }
            button.toolTip = member.toolTip
        } else {
            stopWave()
            button.image = Self.icon("square.grid.2x2", active: members.contains(where: \.isActive),
                                     description: members.map(\.name).formatted(.list(type: .and)))
            button.toolTip = nil
        }
        if menuIsOpen { build() }
    }

    private func animateWave(active: Bool, description: String) {
        wave = (active, description)
        drawWave()
        guard waveTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.drawWave() }
        }
        RunLoop.main.add(timer, forMode: .common)  // keeps moving while the menu is open
        waveTimer = timer
    }

    private func drawWave() {
        statusItem?.button?.image = Self.wave(at: Date.timeIntervalSinceReferenceDate, active: wave.active,
                                              description: wave.description)
    }

    private func stopWave() {
        waveTimer?.invalidate()
        waveTimer = nil
    }

    /// The bars of SF Symbols' `waveform` at menu-bar size (15 × 16 pt): x of each 1 pt bar and its resting height.
    /// The moving wave keeps exactly these positions, so it's the same width as the still icon it replaces.
    private static let bars: [(x: CGFloat, height: CGFloat)] = [(1.9, 3.1), (3.9, 8.5), (6, 13.9), (8, 6.9), (10.1, 10.9), (12.1, 4.1)]

    /// How fast the wave moves: at 0.4 a bar rises and falls about once every two seconds, a calm pulse (at 1 it
    /// flickered).
    private static let waveSpeed = 0.4

    /// The `waveform` symbol's bars rising and falling out of step, like a voice level. Each bar swings on its own slow
    /// cycle (two sines mixed, so it never looks mechanical) between a dot and a little past its resting height.
    static func wave(at time: TimeInterval, active: Bool, description: String) -> NSImage {
        let size = NSSize(width: 15, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.withAlphaComponent(active ? 1 : 0.4).setFill()
            for (i, bar) in bars.enumerated() {
                let k = Double(i), t = time * Self.waveSpeed
                let swing = 0.5 + 0.3 * sin(t * (6.3 + 1.9 * k.truncatingRemainder(dividingBy: 3)) + k * 2.1)
                    + 0.2 * sin(t * (9.7 - 1.3 * k) + k * 0.9)
                let height = max(1.5, min(14.5, CGFloat(swing) * (bar.height * 0.6 + 6)))
                NSBezierPath(roundedRect: NSRect(x: bar.x, y: (size.height - height) / 2, width: 1, height: height),
                             xRadius: 0.5, yRadius: 0.5).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
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
        let canCheck = others.isEmpty ? updater?.canCheckForUpdates ?? false : updateRound == nil
        let fresh = NSMenu()
        Self.populate(fresh, with: sortedMembers, canCheckForUpdates: canCheck, target: self)
        Self.show(fresh, in: menu, whileOpen: menuIsOpen)
    }

    /// Moves the rows built in `fresh` into `menu`. Replacing the items of an open menu makes AppKit measure it
    /// again, and it jumps to another width, so an open menu with the same rows is updated in place instead.
    static func show(_ fresh: NSMenu, in menu: NSMenu, whileOpen: Bool) {
        let items = fresh.items
        fresh.removeAllItems()
        menu.autoenablesItems = false  // as on `fresh`: items are enabled as described, not by AppKit
        if whileOpen, menu.items.count == items.count, zip(menu.items, items).allSatisfy(isSameKind) {
            for (item, new) in zip(menu.items, items) { update(item, to: new) }
        } else {
            menu.removeAllItems()
            items.forEach(menu.addItem)
        }
    }

    private static func isSameKind(_ item: NSMenuItem, _ new: NSMenuItem) -> Bool {
        item.isSeparatorItem == new.isSeparatorItem && item.isSectionHeader == new.isSectionHeader
            && (item.submenu == nil) == (new.submenu == nil)
            && item.view.map { type(of: $0) } == new.view.map { type(of: $0) }
    }

    private static func update(_ item: NSMenuItem, to new: NSMenuItem) {
        if let row = new.view as? MenuRow, let old = item.view as? MenuRow, old.content != row.content {
            old.show(contentOf: row)
        }
        if item.title != new.title { item.title = new.title }
        if #available(macOS 14.4, *), item.subtitle != new.subtitle { item.subtitle = new.subtitle }
        item.state = new.state
        item.isEnabled = new.isEnabled
        item.keyEquivalent = new.keyEquivalent
        item.keyEquivalentModifierMask = new.keyEquivalentModifierMask
        item.isAlternate = new.isAlternate
        item.target = new.target
        item.action = new.action
        item.representedObject = new.representedObject
        if let submenu = new.submenu {
            new.submenu = nil
            item.submenu = submenu
        }
    }

    /// Fills `menu` with the members' sections. On its own, an app gets its section, its version, Check for
    /// Updates… if it has an updater, and Quit, as an unshared menu would have. Combined, each app gets a
    /// headed section, and at the bottom one Check for Updates… and a Quit for each app, beside its version. Items are enabled
    /// explicitly, as their descriptions say, rather than by AppKit's validation.
    static func populate(_ menu: NSMenu, with members: [Member], canCheckForUpdates: Bool, target: MenuHub?) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        if members.count == 1, let member = members.first {
            add(member, header: member.header, to: menu, target: target)
            if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
            menu.addItem(withTitle: "\(member.name) \(member.version)", action: nil, keyEquivalent: "").isEnabled = false
            if member.checksForUpdates {
                let check = menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
                check.target = target
                check.isEnabled = canCheckForUpdates
            }
            menu.addItem(withTitle: "Quit \(member.name)", action: #selector(NSApplication.terminate), keyEquivalent: "q")
            return
        }
        for member in members {
            add(member, header: member.header ?? MenuHeader(title: member.name), to: menu, target: target)
            let divider = NSMenuItem()
            divider.view = SectionDividerView()
            menu.addItem(divider)
        }
        if members.contains(where: \.checksForUpdates) {
            let check = menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
            check.target = target
            check.isEnabled = canCheckForUpdates
            check.view = FlushMenuRowView(title: check.title)
        }
        for member in members {
            let quit = menu.addItem(withTitle: "Quit \(member.name)", action: #selector(choose), keyEquivalent: "")
            quit.target = target
            quit.representedObject = Choice(pid: member.pid, revision: member.revision, item: nil)
            quit.view = FlushMenuRowView(title: quit.title, detail: member.version)
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
    let version: String
    let launched: Date
    let yieldsIcon: Bool
    let checksForUpdates: Bool
    var revision: Int
    var isActive: Bool
    var symbol: String?
    var toolTip: String?
    var animatesIcon: Bool
    var header: MenuHeader?
    var items: [MenuItem]

    enum CodingKeys: String, CodingKey {
        case pid, name, version, launched, yieldsIcon, checksForUpdates, revision, isActive, symbol, toolTip,
             animatesIcon, header, items
    }

    init(pid: Int32, name: String, version: String, launched: Date, yieldsIcon: Bool, checksForUpdates: Bool,
         revision: Int, isActive: Bool, symbol: String? = nil, toolTip: String? = nil, animatesIcon: Bool = false,
         header: MenuHeader?, items: [MenuItem]) {
        (self.pid, self.name, self.version, self.launched, self.yieldsIcon) = (pid, name, version, launched, yieldsIcon)
        (self.checksForUpdates, self.revision, self.isActive) = (checksForUpdates, revision, isActive)
        (self.symbol, self.toolTip, self.animatesIcon, self.header, self.items) = (symbol, toolTip, animatesIcon, header, items)
    }

    /// Fields added since protocol 4 began default when an older app's message lacks them.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            pid: c.decode(Int32.self, forKey: .pid), name: c.decode(String.self, forKey: .name),
            version: c.decode(String.self, forKey: .version), launched: c.decode(Date.self, forKey: .launched),
            yieldsIcon: c.decode(Bool.self, forKey: .yieldsIcon), checksForUpdates: c.decode(Bool.self, forKey: .checksForUpdates),
            revision: c.decode(Int.self, forKey: .revision), isActive: c.decode(Bool.self, forKey: .isActive),
            symbol: c.decodeIfPresent(String.self, forKey: .symbol), toolTip: c.decodeIfPresent(String.self, forKey: .toolTip),
            animatesIcon: c.decodeIfPresent(Bool.self, forKey: .animatesIcon) ?? false,
            header: c.decodeIfPresent(MenuHeader.self, forKey: .header), items: c.decode([MenuItem].self, forKey: .items))
    }

    func hasSameContent(as other: Member) -> Bool {
        (isActive, symbol, toolTip, animatesIcon, header, items)
            == (other.isActive, other.symbol, other.toolTip, other.animatesIcon, other.header, other.items)
    }

    /// The app that shows the icon: the one running longest, so the icon stays put as others come and go,
    /// among the apps that don't yield it if there are any.
    static func host(among members: [Member]) -> Int32? {
        let candidates = members.filter { !$0.yieldsIcon }
        return (candidates.isEmpty ? members : candidates).min { ($0.launched, $0.pid) < ($1.launched, $1.pid) }?.pid
    }
}

/// Every message carries the sender's `pid`. The 4 is the protocol version. Apps built against different MenuHub
/// releases share one menu as long as it stays the same, so it changes only for an incompatible change: a field
/// removed, renamed or given a new meaning. A new field is added without one: older apps ignore keys they don't know
/// (JSON decoding skips them), and `Member` decodes a missing one to its default (an older host shows a still icon
/// where a newer one animates it).
private extension Notification.Name {
    /// A member's description: `member`, JSON-encoded `Member`.
    static let hubMember = Notification.Name("com.mattstallone.menuhub.4.member")
    /// Asks every member to send its description again.
    static let hubRefresh = Notification.Name("com.mattstallone.menuhub.4.refresh")
    /// A chosen item, for `target`: `revision` and `item` (a path), or `quit`.
    static let hubClick = Notification.Name("com.mattstallone.menuhub.4.click")
    /// The sender is quitting.
    static let hubLeave = Notification.Name("com.mattstallone.menuhub.4.leave")
    /// Asks every app with an updater to check quietly: `check`, the round's ID.
    static let hubCheckForUpdates = Notification.Name("com.mattstallone.menuhub.4.check-for-updates")
    /// What an app found, for `target`: `check`, and `result`, a JSON-encoded `UpdateCheckResult`.
    static let hubUpdateResult = Notification.Name("com.mattstallone.menuhub.4.update-result")
}
