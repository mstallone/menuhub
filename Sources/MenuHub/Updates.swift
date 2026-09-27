import Foundation

/// Checks the app for updates. Given one, the hub adds Check for Updates…: in the app's own menu it runs the
/// app's usual check, and in a combined menu one item checks every app that has an updater. `MenuHubSparkle`
/// provides one that uses Sparkle.
@MainActor
public protocol Updater: AnyObject {
    /// False while a check can't be started.
    var canCheckForUpdates: Bool { get }
    /// Checks and shows the outcome, whatever it is.
    func checkForUpdates()
    /// Checks and shows an update if there is one, and nothing otherwise, returning what it found.
    func checkForUpdatesQuietly() async -> UpdateCheckResult
}

/// What a quiet check found.
public enum UpdateCheckResult: Codable, Equatable, Sendable {
    /// An update, now shown to the user.
    case available
    case upToDate
    /// The check couldn't be made, for the reason given.
    case failed(String)
}

/// One Check for Updates across the apps sharing a menu. An app that finds an update shows it itself; the
/// others are summed up in a single alert rather than one each.
struct UpdateRound {
    struct Answer: Equatable {
        let pid: Int32
        let name: String
        let version: String
        let result: UpdateCheckResult
    }

    let id = UUID().uuidString
    /// The apps yet to answer, by process, with their names.
    private(set) var waiting: [Int32: String]
    private(set) var answers: [Answer] = []

    init(apps: [Int32: String]) {
        waiting = apps
    }

    var isComplete: Bool { waiting.isEmpty }

    mutating func record(_ result: UpdateCheckResult, version: String, from pid: Int32) {
        guard let name = waiting.removeValue(forKey: pid) else { return }
        answers.append(Answer(pid: pid, name: name, version: version, result: result))
    }

    /// Every app in the round that hasn't quit, by name, for the alert's icon.
    var apps: [Int32] {
        (answers.map { ($0.pid, $0.name) } + waiting.map { ($0.key, $0.value) })
            .sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }.map(\.0)
    }

    /// An app that quit before answering.
    mutating func drop(_ pid: Int32) {
        waiting.removeValue(forKey: pid)
    }

    /// The alert once the round is over, counting apps that haven't answered as failed. Nil when no app failed
    /// and at least one is showing an update, which says enough.
    var summary: (title: String, text: String)? {
        let failed = answers.compactMap { answer -> (name: String, reason: String)? in
            if case let .failed(reason) = answer.result { (answer.name, reason) } else { nil }
        } + waiting.values.map { ($0, "It didn’t respond.") }
        let current = answers.filter { $0.result == .upToDate }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        if failed.isEmpty {
            guard !current.isEmpty, current.count == answers.count else { return nil }
            let versions = current.map { "\($0.name) \($0.version)" }.formatted(.list(type: .and))
            return ("You’re up to date!", current.count == 1
                ? "\(versions) is currently the newest version available."
                : "\(versions) are currently the newest versions available.")
        }
        let sorted = failed.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var text = sorted.count == 1 ? sorted[0].reason : sorted.map { "\($0.name): \($0.reason)" }.joined(separator: "\n")
        if !current.isEmpty {
            let names = current.map(\.name).formatted(.list(type: .and))
            text += "\n\n\(names) \(current.count == 1 ? "is" : "are") up to date."
        }
        return ("Couldn’t check \(sorted.map(\.name).formatted(.list(type: .and))) for updates", text)
    }
}
