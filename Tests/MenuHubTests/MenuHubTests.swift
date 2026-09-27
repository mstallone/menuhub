import XCTest
@testable import MenuHub

final class MenuHubTests: XCTestCase {
    private func member(pid: Int32, launched: TimeInterval, yieldsIcon: Bool = false, items: [MenuItem] = []) -> Member {
        Member(pid: pid, name: "App \(pid)", launched: Date(timeIntervalSinceReferenceDate: launched), yieldsIcon: yieldsIcon,
               checksForUpdates: false,
               revision: 0, isActive: true, symbol: nil, toolTip: nil, header: MenuHeader(title: "Mouse", detail: .battery(83)),
               items: items)
    }

    @MainActor
    func testDescriptionsRoundTripWithoutTheirActions() throws {
        var ran = 0
        let items: [MenuItem] = [
            .action("Capture Selection", key: "4", modifiers: [.shift, .command]) { ran += 1 },
            .alternate("Reset Permission…") {},
            .separator,
            .info("Screen Recording Allowed", isOn: true),
            .heading("Last Dictation"),
            .submenu("Microphone", subtitle: "System Default", items: [.action("Built-in", isOn: true) {}]),
        ]
        let original = member(pid: 7, launched: 100, items: items)
        let decoded = try JSONDecoder().decode(Member.self, from: JSONEncoder().encode(original))

        XCTAssertEqual(decoded, original)
        decoded.items[0].action.perform()
        XCTAssertEqual(ran, 0)
        original.items[0].action.perform()
        XCTAssertEqual(ran, 1)
        XCTAssertEqual(decoded.items[0].modifiers, NSEvent.ModifierFlags([.shift, .command]).rawValue)
        XCTAssertTrue(decoded.items[1].isAlternate)
    }

    @MainActor
    func testPathsReachItemsInsideSubmenus() {
        var chosen: [String] = []
        let items: [MenuItem] = [
            .action("Settings…") { chosen.append("settings") },
            .submenu("Show in Finder", items: [.action("Dictations") {}, .action("Corrections") { chosen.append("corrections") }]),
        ]
        MenuItem.at([1, 1], in: items)?.action.perform()
        MenuItem.at([0], in: items)?.action.perform()
        XCTAssertEqual(chosen, ["corrections", "settings"])
        XCTAssertNil(MenuItem.at([1, 5], in: items))
        XCTAssertNil(MenuItem.at([], in: items))
    }

    @MainActor
    func testContentComparisonIgnoresActionsAndRevision() {
        var a = member(pid: 1, launched: 0, items: [.action("Turn Gestures Off") {}])
        let b = member(pid: 1, launched: 0, items: [.action("Turn Gestures Off") {}])
        a.revision = 3
        XCTAssertTrue(a.hasSameContent(as: b))
        a.isActive = false
        XCTAssertFalse(a.hasSameContent(as: b))
        XCTAssertNotEqual(MenuItem.action("Ready", subtitle: "Esc cancels") {}, MenuItem.action("Ready") {})
    }

    func testTheLongestRunningAppHostsWithPIDBreakingTies() {
        XCTAssertEqual(Member.host(among: [member(pid: 5, launched: 20), member(pid: 9, launched: 10)]), 9)
        XCTAssertEqual(Member.host(among: [member(pid: 5, launched: 10), member(pid: 3, launched: 10)]), 3)
        XCTAssertEqual(Member.host(among: [member(pid: 4, launched: 0)]), 4)
    }

    func testAnAppThatYieldsHostsOnlyWhenNoOtherCan() {
        let yielding = member(pid: 1, launched: 0, yieldsIcon: true)
        XCTAssertEqual(Member.host(among: [yielding, member(pid: 2, launched: 10)]), 2)
        XCTAssertEqual(Member.host(among: [yielding]), 1)
        XCTAssertEqual(Member.host(among: [yielding, member(pid: 3, launched: 5, yieldsIcon: true)]), 1)
    }
}

@MainActor
final class MenuLayoutTests: XCTestCase {
    private func member(_ name: String, pid: Int32, header: MenuHeader? = nil, checksForUpdates: Bool = false) -> Member {
        Member(pid: pid, name: name, launched: Date(), yieldsIcon: false, checksForUpdates: checksForUpdates, revision: 0,
               isActive: true, symbol: nil, toolTip: nil, header: header,
               items: [.action("Turn Gestures Off") {}, .separator, .info("Screen Recording Allowed", isOn: true),
                       .action("Open at Login", isEnabled: false) {}])
    }

    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.map {
            switch $0.view {
            case is MenuHeaderView: "[header]"
            case is SectionDividerView: "==="
            default: $0.isSeparatorItem ? "—" : $0.title
            }
        }
    }

    func testAnAppOnItsOwnKeepsItsUsualMenu() {
        let menu = NSMenu()
        MenuHub.populate(menu, with: [member("MXSwipe", pid: 1)], version: "1.2", canCheckForUpdates: true, target: nil)
        XCTAssertEqual(titles(menu), [
            "Turn Gestures Off", "—", "Screen Recording Allowed", "Open at Login", "—", "MXSwipe 1.2", "Quit MXSwipe",
        ])
        XCTAssertEqual(menu.items.last?.keyEquivalent, "q")
    }

    func testAnAppWithAnUpdaterChecksUnderItsVersion() {
        let menu = NSMenu()
        MenuHub.populate(menu, with: [member("MXSwipe", pid: 1, checksForUpdates: true)], version: "1.2",
                         canCheckForUpdates: false, target: nil)
        XCTAssertEqual(titles(menu).suffix(3), ["MXSwipe 1.2", "Check for Updates…", "Quit MXSwipe"])
        XCTAssertFalse(menu.items[menu.items.count - 2].isEnabled)
    }

    func testItemsAreEnabledAsDescribed() {
        let menu = NSMenu()
        MenuHub.populate(menu, with: [member("MXSwipe", pid: 1)], version: "1.2", canCheckForUpdates: true, target: nil)
        XCTAssertFalse(menu.autoenablesItems)
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.isEnabled), [true, false, false, false, true])
    }

    @available(macOS 14.4, *)
    func testSubmenusHeadingsAndSubtitlesRender() {
        let menu = NSMenu()
        var verbatim = member("Verbatim", pid: 3)
        verbatim.items = [
            .info("Ready", subtitle: "Esc cancels"), .heading("Last Dictation"),
            .submenu("Microphone", subtitle: "System Default", items: [.action("Built-in", isOn: true) {}, .separator]),
        ]
        MenuHub.populate(menu, with: [verbatim], version: "0.1", canCheckForUpdates: true, target: nil)
        XCTAssertEqual(menu.items[0].subtitle, "Esc cancels")
        XCTAssertTrue(menu.items[1].isSectionHeader)
        let microphone = menu.items[2]
        XCTAssertEqual(microphone.subtitle, "System Default")
        XCTAssertEqual(microphone.submenu?.items.map(\.title), ["Built-in", ""])
        XCTAssertEqual(microphone.submenu?.items.first?.state, .on)
        XCTAssertFalse(microphone.submenu?.autoenablesItems ?? true)
    }

    func testAnOutOfRangeBatteryReadingIsClamped() {
        for percent in [-500, -1, 0, 100, 101, 5000] {
            _ = MenuHeaderView(MenuHeader(title: "MX Master 4", detail: .battery(percent)))
        }
    }

    func testCombinedMenusHeadEachSectionAndQuitEachApp() {
        let menu = NSMenu()
        let members = [member("MXSwipe", pid: 1, header: MenuHeader(title: "MX Master 4")), member("RetinaShot", pid: 2)]
        MenuHub.populate(menu, with: members, version: "1.2", canCheckForUpdates: true, target: nil)
        XCTAssertEqual(titles(menu), [
            "[header]", "Turn Gestures Off", "—", "Screen Recording Allowed", "Open at Login", "===",
            "[header]", "Turn Gestures Off", "—", "Screen Recording Allowed", "Open at Login", "===",
            "Quit MXSwipe", "Quit RetinaShot",
        ])
    }

    func testCombinedMenusShareOneCheckForUpdates() {
        let menu = NSMenu()
        let members = [member("MXSwipe", pid: 1, checksForUpdates: true), member("RetinaShot", pid: 2, checksForUpdates: true),
                       member("Verbatim", pid: 3)]
        MenuHub.populate(menu, with: members, version: "1.2", canCheckForUpdates: true, target: nil)
        XCTAssertEqual(titles(menu).suffix(4), ["Check for Updates…", "Quit MXSwipe", "Quit RetinaShot", "Quit Verbatim"])
        XCTAssertEqual(titles(menu).filter { $0 == "Check for Updates…" }.count, 1)
    }
}

final class UpdateRoundTests: XCTestCase {
    private func round(_ apps: [Int32: String]) -> UpdateRound { UpdateRound(apps: apps) }

    func testEveryAppUpToDateGetsOneAlert() {
        var round = round([1: "MXSwipe", 2: "RetinaShot"])
        round.record(.upToDate, version: "1.5.0", from: 2)
        XCTAssertFalse(round.isComplete)
        round.record(.upToDate, version: "0.3.2", from: 1)
        XCTAssertTrue(round.isComplete)
        XCTAssertEqual(round.summary?.title, "You’re up to date!")
        XCTAssertEqual(round.summary?.text, "MXSwipe 0.3.2 and RetinaShot 1.5.0 are currently the newest versions available.")
    }

    func testAnUpdateOnScreenNeedsNoAlert() {
        var round = round([1: "MXSwipe", 2: "RetinaShot"])
        round.record(.available, version: "0.3.1", from: 1)
        round.record(.upToDate, version: "1.5.0", from: 2)
        XCTAssertNil(round.summary)
    }

    func testFailuresAndSilenceAreReported() {
        var round = round([1: "MXSwipe", 2: "RetinaShot", 3: "Verbatim"])
        round.record(.failed("The feed couldn’t be read."), version: "1.5.0", from: 2)
        round.record(.upToDate, version: "0.3.2", from: 1)
        round.record(.upToDate, version: "0.3.2", from: 1) // a repeat is ignored
        XCTAssertEqual(round.answers.count, 2)
        XCTAssertEqual(round.summary?.title, "Couldn’t check RetinaShot and Verbatim for updates")
        XCTAssertEqual(round.summary?.text, "RetinaShot: The feed couldn’t be read.\nVerbatim: It didn’t respond.\n\nMXSwipe is up to date.")
    }

    func testAnAppThatQuitsIsNotWaitedFor() {
        var round = round([1: "MXSwipe", 2: "RetinaShot"])
        round.record(.failed("Offline."), version: "0.3.2", from: 1)
        round.drop(2)
        XCTAssertTrue(round.isComplete)
        XCTAssertEqual(round.summary?.title, "Couldn’t check MXSwipe for updates")
        XCTAssertEqual(round.summary?.text, "Offline.")
    }
}
