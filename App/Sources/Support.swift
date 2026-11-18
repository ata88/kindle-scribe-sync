import AppKit
import Foundation
import IOKit.ps
import KSSCore
import Security

// MARK: - Settings

enum BatteryMode: String, CaseIterable, Identifiable {
    case normal            // fetch and recognize on battery too
    case deferRecognition  // fetch on battery, recognize when plugged in
    case pause             // do nothing on battery
    var id: String { rawValue }
    var label: String {
        switch self {
        case .normal: return L("Normal weiterarbeiten")
        case .deferRecognition: return L("Nur abrufen, Texterkennung am Netzteil")
        case .pause: return L("Pausieren bis zum Netzteil")
        }
    }
}

/// UserDefaults-backed settings (no secrets in here).
final class AppSettings: ObservableObject {
    private let d = UserDefaults.standard

    @Published var language: AppLanguage { didSet { d.set(language.rawValue, forKey: Loc.defaultsKey); applyLanguage() } }
    @Published var syncIntervalMinutes: Int { didSet { d.set(syncIntervalMinutes, forKey: "syncIntervalMinutes") } }
    @Published var batteryMode: BatteryMode { didSet { d.set(batteryMode.rawValue, forKey: "batteryMode") } }
    @Published var minBatteryPercent: Int { didSet { d.set(minBatteryPercent, forKey: "minBatteryPercent") } }
    @Published var keepAwakeOnAC: Bool { didSet { d.set(keepAwakeOnAC, forKey: "keepAwakeOnAC") } }
    @Published var notifications: Bool { didSet { d.set(notifications, forKey: "notifications") } }
    @Published var spotlight: Bool { didSet { d.set(spotlight, forKey: "spotlight") } }
    @Published var notesEnabled: Bool { didSet { d.set(notesEnabled, forKey: "notesEnabled") } }
    @Published var notesAccount: String { didSet { d.set(notesAccount, forKey: "notesAccount") } }
    @Published var notesFolder: String { didSet { d.set(notesFolder, forKey: "notesFolder") } }
    @Published var attachPageImages: Bool { didSet { d.set(attachPageImages, forKey: "attachPageImages") } }
    @Published var modelID: String { didSet { d.set(modelID, forKey: "modelID") } }

    init() {
        d.register(defaults: [
            Loc.defaultsKey: AppLanguage.system.rawValue,
            "syncIntervalMinutes": 5, "batteryMode": BatteryMode.normal.rawValue, "minBatteryPercent": 25,
            "keepAwakeOnAC": true, "notifications": true, "spotlight": true,
            "notesEnabled": true, "notesAccount": "iCloud", "notesFolder": "Kindle Scribe",
            "attachPageImages": false, "modelID": ModelCatalog.defaultModelID,
        ])
        language = AppLanguage(rawValue: d.string(forKey: Loc.defaultsKey) ?? "") ?? .system
        syncIntervalMinutes = max(1, d.integer(forKey: "syncIntervalMinutes"))
        batteryMode = BatteryMode(rawValue: d.string(forKey: "batteryMode") ?? "") ?? .normal
        minBatteryPercent = d.integer(forKey: "minBatteryPercent")
        keepAwakeOnAC = d.bool(forKey: "keepAwakeOnAC")
        notifications = d.bool(forKey: "notifications")
        spotlight = d.bool(forKey: "spotlight")
        notesEnabled = d.bool(forKey: "notesEnabled")
        notesAccount = d.string(forKey: "notesAccount") ?? "iCloud"
        notesFolder = d.string(forKey: "notesFolder") ?? "Kindle Scribe"
        attachPageImages = d.bool(forKey: "attachPageImages")
        modelID = d.string(forKey: "modelID") ?? ModelCatalog.defaultModelID
    }

    /// System menus (Edit, Window …) follow AppleLanguages – takes effect after a restart.
    private func applyLanguage() {
        switch language {
        case .system: d.removeObject(forKey: "AppleLanguages")
        case .de: d.set(["de"], forKey: "AppleLanguages")
        case .en: d.set(["en"], forKey: "AppleLanguages")
        }
    }

    var syncSettings: SyncSettings {
        var s = SyncSettings()
        s.notesEnabled = notesEnabled
        s.notesRootFolder = notesFolder.isEmpty ? "Kindle Scribe" : notesFolder
        s.attachPageImages = attachPageImages
        return s
    }
}

// MARK: - Paths

enum AppPaths {
    static var support: URL {
        // SCRIBE_SYNC_HOME: separate data folder (CI screenshots/tests)
        let url = ProcessInfo.processInfo.environment["SCRIBE_SYNC_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Scribe Sync", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static var library: URL { support.appendingPathComponent("Library", isDirectory: true) }
    static var models: URL { support.appendingPathComponent("Models", isDirectory: true) }
    static var logFile: URL { support.appendingPathComponent("activity.log") }
}

// MARK: - Keychain (Amazon session)

enum Keychain {
    static let service = "io.github.ata88.scribesync"

    static func save(_ data: Data, account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(account: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func delete(account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

/// The Amazon web session (cookies + browser user agent + working marketplace id).
struct AmazonSession: Codable {
    var jar: CookieJar
    var userAgent: String
    var marketplaceID: String?
    var savedAt: Date

    static let account = "amazon-session"

    static func load() -> AmazonSession? {
        guard let data = Keychain.load(account: account) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(AmazonSession.self, from: data)
    }

    func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(self) { Keychain.save(data, account: Self.account) }
    }

    static func clear() { Keychain.delete(account: account) }
}

// MARK: - Power

struct PowerState: Equatable {
    var onBattery: Bool
    var batteryPercent: Int?
    var lowPowerMode: Bool

    static func current() -> PowerState {
        var onBattery = false
        var percent: Int?
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() {
            if let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? {
                onBattery = (type == kIOPSBatteryPowerValue)
            }
            if let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
                for src in list {
                    if let desc = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any],
                       let cur = desc[kIOPSCurrentCapacityKey] as? Int, let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 {
                        percent = cur * 100 / max
                    }
                }
            }
        }
        return PowerState(onBattery: onBattery, batteryPercent: percent,
                          lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    var description: String {
        if !onBattery { return L("Netzteil") }
        var s = L("Akku")
        if let p = batteryPercent { s += " \(p) %" }
        if lowPowerMode { s += ", " + L("Stromsparmodus") }
        return s
    }
}

// MARK: - Memory

enum ProcessMemory {
    /// Physical footprint of this process (what Activity Monitor shows as "Memory").
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}
