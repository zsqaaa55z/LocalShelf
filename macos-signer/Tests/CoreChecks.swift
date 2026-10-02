import Foundation

@main
struct CoreChecks {
    static var count = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try value() else { throw SignerError.message("FAIL: \(name)") }
        count += 1; print("PASS: \(name)")
    }
    static func rejects(_ name: String, _ work: () throws -> Void) throws {
        do { try work() } catch { count += 1; print("PASS: \(name)"); return }
        throw SignerError.message("FAIL: \(name)")
    }
    static let team = "TESTTEAM01"
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func fixture(team: String = team, app: String = Settings.bundle, development: Bool = true,
                        expiry: Date = now.addingTimeInterval(7 * 86400)) -> [String: Any] {
        ["ExpirationDate": expiry, "TeamIdentifier": [team], "UUID": UUID().uuidString,
         "ProvisionedDevices": ["PHONE"],
         "Entitlements": ["application-identifier": "\(team).\(app)", "get-task-allow": development]]
    }
    static func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    static func main() {
        setbuf(stdout, nil)
        do { try run() }
        catch { FileHandle.standardError.write(Data("FAILED: \(error.localizedDescription)\n".utf8)); exit(1) }
    }
    static func run() throws {
        let args = CommandLine.arguments
        guard args.count == 1 else { throw SignerError.message("Only synthetic checks are supported") }
        let good = try SigningProfile(plist: fixture())
        try check(good.matches(team: team, bundle: Settings.bundle), "exact team and application match")
        try check(!good.matches(team: "OTHERTEAM1", bundle: Settings.bundle), "reject different team")
        try check(!good.matches(team: team, bundle: "other.bundle"), "reject different bundle")
        try check(!SigningProfile(plist: fixture(app: "*")).matches(team: team, bundle: Settings.bundle), "never touch wildcard profile")
        try check(!SigningProfile(plist: fixture(development: false)).matches(team: team, bundle: Settings.bundle), "never touch distribution profile")
        try rejects("malformed profile") { _ = try SigningProfile(plist: [:]) }
        try check(!RenewalPolicy.due(expiry: nil, now: now), "unknown expiry never auto-renews")
        try check(!RenewalPolicy.due(expiry: now.addingTimeInterval(48 * 3600 + 1), now: now), "not due before threshold")
        try check(RenewalPolicy.due(expiry: now.addingTimeInterval(48 * 3600), now: now), "due at threshold")
        try check(RenewalPolicy.due(expiry: now.addingTimeInterval(-1), now: now), "expired is due")
        var settings = Settings(project: "/tmp/My Project.xcodeproj", referenceApp: "", team: team, device: "PHONE")
        try check(!RenewalPolicy.mayRun(settings: settings, referenceExpiry: now, now: now), "auto off by default")
        settings.automatic = true
        try check(RenewalPolicy.mayRun(settings: settings, referenceExpiry: now, now: now), "auto runs when due")
        settings.nextAttempt = now.addingTimeInterval(1)
        try check(!RenewalPolicy.mayRun(settings: settings, referenceExpiry: now, now: now), "retry backoff enforced")
        settings.nextAttempt = now
        try check(RenewalPolicy.mayRun(settings: settings, referenceExpiry: now, now: now), "retry boundary")
        settings.installedExpiry = now.addingTimeInterval(7 * 86400)
        try check(!RenewalPolicy.mayRun(settings: settings, referenceExpiry: now, now: now), "installed receipt overrides old reference")
        settings.installedExpiry = nil; settings.device = ""
        try check(!RenewalPolicy.mayRun(settings: settings, referenceExpiry: now, now: now), "no target device no auto run")
        try RenewalPolicy.validate(good, team: team, udid: "PHONE", previousExpiry: now, now: now)
        count += 1; print("PASS: valid new profile")
        try rejects("same expiration is not renewal") { try RenewalPolicy.validate(good, team: team, udid: "PHONE", previousExpiry: good.expiry, now: now) }
        try RenewalPolicy.validate(good, team: team, udid: "PHONE", previousExpiry: good.expiry.addingTimeInterval(-1), now: now)
        count += 1; print("PASS: strictly later expiration accepted without arbitrary minute threshold")
        try rejects("earlier expiration is not renewal") { try RenewalPolicy.validate(good, team: team, udid: "PHONE", previousExpiry: good.expiry.addingTimeInterval(1), now: now) }
        try rejects("missing device stops installation") { try RenewalPolicy.validate(good, team: team, udid: "OTHER", previousExpiry: nil, now: now) }
        try rejects("wrong signing team stops installation") { try RenewalPolicy.validate(good, team: "OTHERTEAM1", udid: "PHONE", previousExpiry: nil, now: now) }
        try rejects("short expiry stops installation") { try RenewalPolicy.validate(SigningProfile(plist: fixture(expiry: now.addingTimeInterval(3600))), team: team, udid: "PHONE", previousExpiry: nil, now: now) }
        let command = RenewalPolicy.buildArguments(project: "/tmp/a b; touch bad.xcodeproj", team: team, derived: "/tmp/derived data")
        try check(command[2] == "/tmp/a b; touch bad.xcodeproj", "project is a literal argument, not shell input")
        try check(command.contains("-allowProvisioningUpdates"), "Xcode can request renewed profile")
        try check(command.firstIndex(of: "clean")! < command.firstIndex(of: "build")!, "clean precedes build to invalidate stale resource signature")
        try check(command[command.firstIndex(of: "-derivedDataPath")! + 1] == "/tmp/derived data", "clean is scoped to helper's dedicated DerivedData")
        try check(command.filter { $0 == "clean" }.count == 1, "exactly one clean per renewal")
        let phone: [String: Any] = ["identifier": "PHONE", "hardwareProperties": ["platform": "iOS", "deviceType": "iPhone", "udid": "UDID"], "deviceProperties": ["name": "Test Phone", "developerModeStatus": "enabled"], "connectionProperties": ["pairingState": "paired", "tunnelState": "disconnected"]]
        var watch = phone; watch["hardwareProperties"] = ["platform": "watchOS", "deviceType": "appleWatch", "udid": "WATCH"]
        let phones = try DeviceJSON.phones(data(["info": ["outcome": "success"], "result": ["devices": [phone, watch]]]))
        try check(phones.count == 1, "filter out Apple Watch")
        try check(!phones[0].connected && phones[0].developerEnabled, "paired is not connected")
        try rejects("device JSON failure rejected") { _ = try DeviceJSON.result(data(["info": ["outcome": "failure"], "result": [:]])) }
        try rejects("device JSON schema failure rejected") { _ = try DeviceJSON.phones(data(["info": ["outcome": "success"], "result": [:]])) }
        let apps = try data(["info": ["outcome": "success"], "result": ["apps": [["bundleIdentifier": Settings.bundle, "bundleVersion": "24"]]]])
        try check(DeviceJSON.installed(apps, bundle: Settings.bundle)?["bundleVersion"] as? String == "24", "installed version parsed")
        try check(DeviceJSON.installed(apps, bundle: "other") == nil, "missing app detected")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SignerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("cache"), root = folder.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, value) in [("ours", fixture()), ("other", fixture(app: "other")), ("wildcard", fixture(app: "*")), ("distribution", fixture(development: false))] {
            try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: cache.appendingPathComponent(name + ".mobileprovision"))
        }
        try Data().write(to: cache.appendingPathComponent("empty.mobileprovision"))
        try rejects("empty CMS is safely rejected") { _ = try SigningProfile.read(cache.appendingPathComponent("empty.mobileprovision")) }
        let backups = ProfileBackup(root: root, cacheRoots: [cache]) { url in
            try SigningProfile(plist: PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as! [String: Any])
        }
        try check(backups.prepare(team: team) == 1, "back up only exact app development profile")
        try check(!FileManager.default.fileExists(atPath: cache.appendingPathComponent("ours.mobileprovision").path), "matching cached profile moved")
        try check(FileManager.default.fileExists(atPath: cache.appendingPathComponent("other.mobileprovision").path), "other app profile untouched")
        try backups.recover()
        try check(FileManager.default.fileExists(atPath: cache.appendingPathComponent("ours.mobileprovision").path), "failure or crash recovery restores profile")
        try check(!FileManager.default.fileExists(atPath: backups.journal.path), "recovery clears journal")
        _ = try backups.prepare(team: team)
        try Data("replacement".utf8).write(to: cache.appendingPathComponent("ours.mobileprovision"))
        try backups.recover()
        try check(String(contentsOf: cache.appendingPathComponent("ours.mobileprovision")) == "replacement", "recovery never overwrites newly created profile")
        var lock: SigningLock? = try SigningLock(root: root)
        try rejects("cross-process lock prevents duplicate renewal") { _ = try SigningLock(root: root) }
        withExtendedLifetime(lock) {}; lock = nil
        let nextLock = try SigningLock(root: root)
        withExtendedLifetime(nextLock) {}; count += 1; print("PASS: lock releases")
        try check(Command.run("/usr/bin/printf", ["%s", "literal ; $(not-a-command)"]) == "literal ; $(not-a-command)", "process arguments never expand shell syntax")
        try rejects("process exit failure") { _ = try Command.run("/usr/bin/false", []) }
        try rejects("process timeout") { _ = try Command.run("/bin/sleep", ["3"], timeout: 0.1) }

        print("\(count) CHECKS PASSED")
    }
}
