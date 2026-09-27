import MenuHub
import Sparkle

/// Updates the app with Sparkle, configured by its Info.plist (`SUFeedURL`, `SUPublicEDKey`, and the rest), and
/// starts Sparkle's scheduled checks. Pass it to `MenuHub` for its Check for Updates… item.
@MainActor
public final class SparkleUpdater: NSObject, Updater {
    private var controller: SPUStandardUpdaterController!
    private var foundUpdate = false
    private var cycleEnded: [CheckedContinuation<NSError?, Never>] = []

    override public init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    public var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    public func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Probes the feed, then shows an update through Sparkle's usual window if there is one. A session already
    /// under way is let finish first, or brought forward if it's showing something.
    public func checkForUpdatesQuietly() async -> UpdateCheckResult {
        let updater = controller.updater
        while updater.sessionInProgress {
            if updater.canCheckForUpdates {
                checkForUpdates()
                return .available
            }
            _ = await nextCycleEnd()
        }
        foundUpdate = false
        updater.checkForUpdateInformation()
        let error = await nextCycleEnd()
        if foundUpdate {
            checkForUpdates()
            return .available
        }
        if let error, error.code != Int(SUError.noUpdateError.rawValue) { return .failed(error.localizedDescription) }
        return .upToDate
    }

    private func nextCycleEnd() async -> NSError? {
        await withCheckedContinuation { cycleEnded.append($0) }
    }
}

extension SparkleUpdater: SPUUpdaterDelegate {
    public func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        foundUpdate = true
    }

    public func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        let waiting = cycleEnded
        cycleEnded = []
        for continuation in waiting { continuation.resume(returning: error as NSError?) }
    }
}
