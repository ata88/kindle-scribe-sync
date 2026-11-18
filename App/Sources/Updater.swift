import Combine
import Foundation
import Sparkle

/// Sparkle updates from GitHub Releases (appcast.xml attached to each release).
/// Sparkle runs inside the app; nothing keeps running after Quit.
@MainActor
final class UpdaterController: ObservableObject {
    private let controller: SPUStandardUpdaterController?
    @Published private(set) var canCheckForUpdates = false
    private var cancellable: AnyCancellable?

    init() {
        // local debug builds carry no signing key – don't start Sparkle there
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        if key.isEmpty {
            controller = nil
        } else {
            let c = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            controller = c
            cancellable = c.updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main)
                .sink { [weak self] in self?.canCheckForUpdates = $0 }
        }
    }

    var isAvailable: Bool { controller != nil }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue; objectWillChange.send() }
    }

    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }
}
