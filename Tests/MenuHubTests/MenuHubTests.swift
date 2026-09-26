import XCTest
@testable import MenuHub

final class MenuHubTests: XCTestCase {
    private func member(pid: Int32, launched: TimeInterval, items: [MenuItem] = []) -> Member {
        Member(pid: pid, name: "App \(pid)", version: "1.0", launched: Date(timeIntervalSinceReferenceDate: launched),
               revision: 0, isActive: true, header: MenuHeader(title: "Mouse", detail: .battery(83)), items: items)
    }

    @MainActor
    func testDescriptionsRoundTripWithoutTheirActions() throws {
        let items: [MenuItem] = [
            .action("Capture Selection", key: "4", modifiers: [.shift, .command]) {},
            .alternate("Reset Permission…") {},
            .separator,
            .info("Screen Recording Allowed", isOn: true),
        ]
        let original = member(pid: 7, launched: 100, items: items)
        let decoded = try JSONDecoder().decode(Member.self, from: JSONEncoder().encode(original))

        XCTAssertEqual(decoded, original)
        XCTAssertNotNil(original.items[0].perform)
        XCTAssertNil(decoded.items[0].perform)
        XCTAssertEqual(decoded.items[0].modifiers, NSEvent.ModifierFlags([.shift, .command]).rawValue)
        XCTAssertTrue(decoded.items[1].isAlternate)
    }

    @MainActor
    func testContentComparisonIgnoresActionsAndRevision() {
        var a = member(pid: 1, launched: 0, items: [.action("Turn Gestures Off") {}])
        let b = member(pid: 1, launched: 0, items: [.action("Turn Gestures Off") {}])
        a.revision = 3
        XCTAssertTrue(a.hasSameContent(as: b))
        a.isActive = false
        XCTAssertFalse(a.hasSameContent(as: b))
    }

    func testTheLongestRunningAppHostsWithPIDBreakingTies() {
        XCTAssertEqual(Member.host(among: [member(pid: 5, launched: 20), member(pid: 9, launched: 10)]), 9)
        XCTAssertEqual(Member.host(among: [member(pid: 5, launched: 10), member(pid: 3, launched: 10)]), 3)
        XCTAssertEqual(Member.host(among: [member(pid: 4, launched: 0)]), 4)
    }
}

@MainActor
final class MenuLayoutTests: XCTestCase {
    private func member(_ name: String, pid: Int32, header: MenuHeader? = nil) -> Member {
        Member(pid: pid, name: name, version: "1.2", launched: Date(), revision: 0, isActive: true, header: header,
               items: [.action("Turn Gestures Off") {}, .separator, .info("Screen Recording Allowed", isOn: true)])
    }

    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "—" : $0.view is MenuHeaderView ? "[header]" : $0.title }
    }

    func testAnAppOnItsOwnKeepsItsUsualMenu() {
        let menu = NSMenu()
        MenuHub.populate(menu, with: [member("MXSwipe", pid: 1)], mine: 1, target: nil)
        XCTAssertEqual(titles(menu), ["Turn Gestures Off", "—", "Screen Recording Allowed", "—", "MXSwipe 1.2", "Quit MXSwipe"])
        XCTAssertEqual(menu.items.last?.keyEquivalent, "q")
    }

    func testCombinedMenusHeadEachSectionAndQuitEachApp() {
        let menu = NSMenu()
        let members = [member("MXSwipe", pid: 1, header: MenuHeader(title: "MX Master 4")), member("RetinaShot", pid: 2)]
        MenuHub.populate(menu, with: members, mine: 1, target: nil)
        XCTAssertEqual(titles(menu), [
            "[header]", "Turn Gestures Off", "—", "Screen Recording Allowed", "—",
            "[header]", "Turn Gestures Off", "—", "Screen Recording Allowed", "—",
            "Quit MXSwipe", "Quit RetinaShot",
        ])
    }
}
