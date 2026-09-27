import MenuHub
import Sparkle

/// Updates the app with Sparkle, configured by its Info.plist (`SUFeedURL`, `SUPublicEDKey`, and the rest), and
/// starts Sparkle's scheduled checks. Pass it to `MenuHub` for its Check for Updates… item.
@MainActor
public final class SparkleUpdater: NSObject, Updater {
    private var controller: SPUStandardUpdaterController!
    private var foundUpdate = false
    private var cycleEnded: [CheckedContinuation<NSError?, Never>] = []
    private var sessionObservation: NSKeyValueObservation?

    override public init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    public var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    public func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Probes the feed, then shows an update through Sparkle's usual window if there is one. A session already
    /// showing something is brought forward instead, and one checking in the background is let finish first.
    public func checkForUpdatesQuietly() async -> UpdateCheckResult {
        let updater = controller.updater
        while updater.sessionInProgress {
            if updater.canCheckForUpdates {
                checkForUpdates()
                return .available
            }
            await sessionEnded()
        }
        foundUpdate = false
        updater.checkForUpdateInformation()
        let error = await withCheckedContinuation { cycleEnded.append($0) }
        if foundUpdate {
            await sessionEnded() // the probe's session closes only after its cycle ends
            checkForUpdates()
            return .available
        }
        if let error, error.code != Int(SUError.noUpdateError.rawValue) { return .failed(error.localizedDescription) }
        return .upToDate
    }

    /// Returns once no session is in progress. Sparkle announces the end through `canCheckForUpdates`, which
    /// is KVO-compliant; `sessionInProgress` isn't.
    private func sessionEnded() async {
        while controller.updater.sessionInProgress {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                sessionObservation = controller.updater.observe(\.canCheckForUpdates) { [weak self] _, _ in
                    MainActor.assumeIsolated {
                        self?.sessionObservation = nil
                        continuation.resume()
                    }
                }
            }
        }
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
