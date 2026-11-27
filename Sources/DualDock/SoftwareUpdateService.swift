import AppKit
import Combine

#if SWIFT_PACKAGE
import Sparkle
#endif

/// Keep a single update session alive even if the user closes Settings.
@MainActor
final class SoftwareUpdateService: NSObject, ObservableObject {
    static let shared = SoftwareUpdateService()

    /// Accept only the established HTTPS feed embedded in a production DualDock bundle.
    static func configuredFeed(bundleID: String?, info: [String: Any]?) -> String? {
        let feed = "https://raw.githubusercontent.com/autumncry/DualDock/main/updates/appcast.xml"
        guard bundleID == LocalPreviewConfiguration.releaseBundleID,
              info?["SUFeedURL"] as? String == feed else { return nil }
        return feed
    }

    #if SWIFT_PACKAGE
    private let feed = configuredFeed(bundleID: Bundle.main.bundleIdentifier, info: Bundle.main.infoDictionary)
    var supportsUpdates: Bool { feed != nil }
    @Published private(set) var canCheck = false
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    private var availability: AnyCancellable?
    private var started = false
    #else
    // The standalone settings renderer has no application bundle or installer.
    let supportsUpdates = false
    let canCheck = false
    #endif
    @Published private(set) var startupError: String?
    var beforeRelaunch: (() -> Void)?

    private override init() {
        super.init()
        #if SWIFT_PACKAGE
        canCheck = supportsUpdates
        #endif
    }

    func check() {
        #if SWIFT_PACKAGE
        guard supportsUpdates else { return }
        let updater = controller.updater
        if !started {
            do {
                try updater.start()
                started = true
                availability = updater.publisher(for: \.canCheckForUpdates)
                    .removeDuplicates()
                    .sink { [weak self] in self?.canCheck = $0 }
            } catch {
                startupError = error.localizedDescription
                return
            }
        }
        startupError = nil
        guard updater.canCheckForUpdates else { return }
        updater.checkForUpdates()
        #endif
    }
}

#if SWIFT_PACKAGE
extension SoftwareUpdateService: SPUUpdaterDelegate {
    /// Use the feed distributed with this bundle. Sparkle also supports a
    /// legacy defaults override, which DualDock has never used.
    func feedURLString(for updater: SPUUpdater) -> String? {
        feed
    }

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        false
    }

    /// Enforce manual checks even if an older preferences domain contains
    /// an automatic-check setting. Sparkle handles the interactive download
    /// and requests confirmation before replacing and relaunching the app.
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard updateCheck == .updates else { throw CancellationError() }
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        beforeRelaunch?()
    }
}
#endif
