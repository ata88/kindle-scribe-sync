import AppKit
import CoreSpotlight
import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import KSSCore
import UniformTypeIdentifiers
import UserNotifications

/// Watches the power source and keeps background syncing reliable:
///
/// * On AC power the app opts out of App Nap (so timers fire on time while the
///   window is closed) and – if enabled – keeps the Mac from idle-sleeping, so
///   new notes reach Apple Notes/iCloud (and the iPhone) while you are away.
///   A closed lid still sends a MacBook to sleep; macOS does not let apps change that.
/// * On battery nothing is held: macOS naps the app and timers are coalesced.
@MainActor
final class PowerManager: ObservableObject {
    @Published private(set) var state = PowerState.current()
    @Published private(set) var holdingAwake = false
    var onChange: ((PowerState) -> Void)?
    var keepAwakeOnAC = true { didSet { apply() } }

    private var activity: NSObjectProtocol?
    private var assertion: IOPMAssertionID = 0
    private var runLoopSource: CFRunLoopSource?

    func start() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<PowerManager>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.refresh() }
        }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
            runLoopSource = src
        }
        refresh()
    }

    func stop() {
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .defaultMode) }
        runLoopSource = nil
        releaseAll()
    }

    func refresh() {
        let new = PowerState.current()
        let changed = new != state
        state = new
        apply()
        if changed { onChange?(new) }
    }

    private func apply() {
        if !state.onBattery {
            if activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiatedAllowingIdleSystemSleep],
                    reason: L("Regelmäßige Synchronisierung am Netzteil"))
            }
            if keepAwakeOnAC && assertion == 0 {
                var id: IOPMAssertionID = 0
                let ok = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     L("Scribe Sync synchronisiert am Netzteil im Hintergrund") as CFString,
                                                     &id)
                if ok == kIOReturnSuccess { assertion = id }
            } else if !keepAwakeOnAC && assertion != 0 {
                IOPMAssertionRelease(assertion); assertion = 0
            }
        } else {
            releaseAll()
        }
        holdingAwake = assertion != 0
    }

    private func releaseAll() {
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
        holdingAwake = false
    }
}

/// A simple, cancellable sync loop. Interval comes from the settings; on battery
/// the system may stretch it (App Nap), on AC it fires on time.
@MainActor
final class SyncScheduler {
    private var task: Task<Void, Never>?
    private(set) var nextRun: Date?

    func start(interval: @escaping @MainActor () -> TimeInterval, tick: @escaping @MainActor () async -> Void) {
        task?.cancel()
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let seconds = interval()
                self?.nextRun = Date().addingTimeInterval(seconds)
                try? await Task.sleep(for: .seconds(seconds), tolerance: .seconds(min(60, seconds / 5)))
                if Task.isCancelled { break }
                await tick()
            }
        }
    }

    func stop() { task?.cancel(); task = nil; nextRun = nil }
}

// MARK: - Notifications

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onOpenNotebook: ((String) -> Void)?

    func setUp() { UNUserNotificationCenter.current().delegate = self }

    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func notifyRecognized(_ notebooks: [(id: String, title: String, pages: Int)]) {
        guard !notebooks.isEmpty else { return }
        let content = UNMutableNotificationContent()
        if notebooks.count == 1, let nb = notebooks.first {
            content.title = nb.title
            content.body = nb.pages == 1 ? L("1 Seite neu erkannt") : L("%ld Seiten neu erkannt", nb.pages)
            content.userInfo = ["notebook": nb.id]
        } else {
            content.title = L("Neue Notizen erkannt")
            content.body = notebooks.prefix(3).map(\.title).joined(separator: ", ")
                + (notebooks.count > 3 ? " …" : "")
            content.userInfo = ["notebook": notebooks[0].id]
        }
        content.threadIdentifier = "recognized"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func notifyAttention(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "attention", content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["notebook"] as? String
        Task { @MainActor in
            if let id { self.onOpenNotebook?(id) }
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}

// MARK: - Spotlight

enum SpotlightIndex {
    static let domain = "io.github.ata88.scribesync.notebooks"

    static func index(_ notebooks: [NotebookRecord]) {
        let items = notebooks.map { nb -> CSSearchableItem in
            let attrs = CSSearchableItemAttributeSet(contentType: .text)
            attrs.title = nb.title
            attrs.contentDescription = nb.pages.first?.text.prefix(300).description
            attrs.textContent = nb.pages.map(\.text).joined(separator: "\n\n")
            attrs.keywords = ["Kindle Scribe"] + nb.folderPath
            attrs.contentModificationDate = nb.syncedAt
            return CSSearchableItem(uniqueIdentifier: nb.id, domainIdentifier: domain, attributeSet: attrs)
        }
        CSSearchableIndex.default().indexSearchableItems(items) { _ in }
    }

    static func removeAll() {
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in }
    }
}
