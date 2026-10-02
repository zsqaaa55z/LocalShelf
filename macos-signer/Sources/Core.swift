import Foundation
import Security

enum SignerError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

struct SigningProfile {
    let expiry: Date
    let team: String
    let applicationID: String
    let development: Bool
    let devices: [String]
    let uuid: String

    init(plist: [String: Any]) throws {
        guard let expiry = plist["ExpirationDate"] as? Date,
              let team = (plist["TeamIdentifier"] as? [String])?.first,
              let entitlements = plist["Entitlements"] as? [String: Any],
              let appID = entitlements["application-identifier"] as? String,
              let uuid = plist["UUID"] as? String else {
            throw SignerError.message("描述文件缺少必要字段，已停止。")
        }
        self.expiry = expiry; self.team = team; self.applicationID = appID
        self.uuid = uuid
        development = entitlements["get-task-allow"] as? Bool == true
        devices = plist["ProvisionedDevices"] as? [String] ?? []
    }

    static func read(_ url: URL) throws -> SigningProfile {
        let data = try Data(contentsOf: url)
        guard !data.isEmpty, data.count < 4_000_000 else { throw SignerError.message("描述文件为空或过大。") }
        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder else {
            throw SignerError.message("无法创建系统描述文件解码器。")
        }
        let status = data.withUnsafeBytes { CMSDecoderUpdateMessage(decoder, $0.baseAddress!, data.count) }
        guard status == errSecSuccess, CMSDecoderFinalizeMessage(decoder) == errSecSuccess else {
            throw SignerError.message("描述文件格式无效。")
        }
        var content: CFData?
        guard CMSDecoderCopyContent(decoder, &content) == errSecSuccess, let content,
              let plist = try PropertyListSerialization.propertyList(from: content as Data, format: nil) as? [String: Any] else {
            throw SignerError.message("无法读取描述文件。")
        }
        return try SigningProfile(plist: plist)
    }

    func matches(team: String, bundle: String) -> Bool {
        self.team == team && applicationID == "\(team).\(bundle)" && development
    }
}

enum SigningIdentity {
    static func validate(app: URL, team: String) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw SignerError.message("无法读取安装包的代码签名。")
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any],
              info[kSecCodeInfoIdentifier as String] as? String == Settings.bundle,
              info[kSecCodeInfoTeamIdentifier as String] as? String == team else {
            throw SignerError.message("实际代码签名与预期团队或应用标识不符，已停止安装。")
        }
        // Modern iOS binaries can use DER-only entitlements, for which this optional
        // dictionary is absent. The exact application-identifier is also checked in
        // the embedded profile; iOS verifies its entitlement allowance at installation.
        if let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] {
            guard entitlements["application-identifier"] as? String == "\(team).\(Settings.bundle)",
                  entitlements["com.apple.developer.team-identifier"] as? String == team,
                  entitlements["get-task-allow"] as? Bool == true else {
                throw SignerError.message("代码签名权限不匹配，已停止安装。")
            }
        }
    }
}

struct Phone: Identifiable, Equatable {
    let id: String
    let udid: String
    let name: String
    let connected: Bool
    let developerEnabled: Bool
    var label: String { "\(name) · \(connected ? "已连接" : "已配对，待连接")" }
}

enum DeviceJSON {
    static func result(_ data: Data) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = root["info"] as? [String: Any], info["outcome"] as? String == "success",
              let result = root["result"] as? [String: Any] else {
            throw SignerError.message("设备工具未返回成功结果。请解锁 iPhone，并在 Xcode 中确认设备连接。")
        }
        return result
    }
    static func phones(_ data: Data) throws -> [Phone] {
        guard let rows = try result(data)["devices"] as? [[String: Any]] else {
            throw SignerError.message("无法识别设备列表格式。")
        }
        return rows.compactMap { row in
            guard let hardware = row["hardwareProperties"] as? [String: Any],
                  hardware["platform"] as? String == "iOS",
                  hardware["deviceType"] as? String == "iPhone",
                  let id = row["identifier"] as? String, let udid = hardware["udid"] as? String,
                  let props = row["deviceProperties"] as? [String: Any],
                  let connection = row["connectionProperties"] as? [String: Any],
                  connection["pairingState"] as? String == "paired" else { return nil }
            return Phone(id: id, udid: udid, name: props["name"] as? String ?? "iPhone",
                         connected: connection["tunnelState"] as? String == "connected",
                         developerEnabled: props["developerModeStatus"] as? String == "enabled")
        }
    }
    static func installed(_ data: Data, bundle: String) throws -> [String: Any]? {
        guard let apps = try result(data)["apps"] as? [[String: Any]] else {
            throw SignerError.message("无法识别已安装应用列表，未确认安装结果。")
        }
        return apps.first { $0["bundleIdentifier"] as? String == bundle }
    }
}

struct Settings: Codable {
    var project: String
    var referenceApp: String
    var team: String
    var device: String
    var automatic = false
    var installedExpiry: Date?
    var installedAt: Date?
    var nextAttempt: Date?
    static let bundle = "local.shelf.reader"
    var configured: Bool {
        project.hasSuffix(".xcodeproj") && team.range(of:"^[A-Z0-9]{10}$",options:.regularExpression) != nil && !device.isEmpty
    }
}

enum RenewalPolicy {
    static let threshold: TimeInterval = 48 * 3600
    static func due(expiry: Date?, now: Date = Date()) -> Bool {
        guard let expiry else { return false }
        return expiry.timeIntervalSince(now) <= threshold
    }
    static func mayRun(settings: Settings, referenceExpiry: Date?, now: Date = Date()) -> Bool {
        settings.automatic && settings.configured
        && due(expiry: settings.installedExpiry ?? referenceExpiry, now: now)
        && (settings.nextAttempt == nil || settings.nextAttempt! <= now)
    }
    static func validate(_ profile: SigningProfile, team: String, udid: String,
                         previousExpiry: Date?, now: Date = Date()) throws {
        guard profile.matches(team: team, bundle: Settings.bundle), profile.devices.contains(udid) else {
            throw SignerError.message("新安装包的签名团队、应用标识或目标设备不匹配。不会安装，也不会卸载旧 App。")
        }
        guard profile.expiry.timeIntervalSince(now) > threshold else {
            throw SignerError.message("新描述文件剩余不足 48 小时，未取得可用的新签名。请检查 Xcode 账号。")
        }
        if let previousExpiry, profile.expiry <= previousExpiry {
            throw SignerError.message("Apple / Xcode 仍返回旧期限，没有实际延长签名。已停止安装，将在 6 小时后重试；也可稍后手动重试。")
        }
    }
    static func buildArguments(project: String, team: String, derived: String) -> [String] {
        ["xcodebuild", "-project", project, "-scheme", "LocalShelf", "-configuration", "Release",
         "-destination", "generic/platform=iOS", "-derivedDataPath", derived,
         // Replacing embedded.mobileprovision alone can leave Xcode's incremental
         // CodeSign task up-to-date and reuse a stale CodeResources seal. Always
         // clean this helper's dedicated products before rebuilding the signed app.
         "-allowProvisioningUpdates", "-quiet", "clean", "build", "DEVELOPMENT_TEAM=\(team)",
         "CODE_SIGN_STYLE=Automatic", "CODE_SIGN_IDENTITY=Apple Development",
         "PROVISIONING_PROFILE_SPECIFIER=", "PROVISIONING_PROFILE="]
    }
}

/// Arguments are passed directly to Process. No shell expansion or Apple ID password storage.
enum Command {
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 60) throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LocalShelfSigner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("output.log")
        FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = handle; process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        env["LC_ALL"] = "en_US.UTF-8"
        process.environment = env
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            if Date() >= deadline {
                timedOut = true
                process.terminate()
                for _ in 0..<30 where process.isRunning { Thread.sleep(forTimeInterval: 0.1) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        process.waitUntilExit()
        let reader = try FileHandle(forReadingFrom: output)
        defer { try? reader.close() }
        let count = try reader.seekToEnd()
        try reader.seek(toOffset: count > 96_000 ? count - 96_000 : 0)
        let text = String(decoding: try reader.readToEnd() ?? Data(), as: UTF8.self)
        guard !timedOut else { throw SignerError.message("命令超时。请检查 Xcode、账号与设备连接。\n" + String(text.suffix(5000))) }
        guard process.terminationStatus == 0 else {
            throw SignerError.message("\(URL(fileURLWithPath: executable).lastPathComponent) 执行失败（\(process.terminationStatus)）。\n" + String(text.suffix(7000)))
        }
        return text
    }
    static func device(_ args: [String], timeout: Int = 30) throws -> Data {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("LocalShelfSigner-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try run("/usr/bin/xcrun", ["devicectl"] + args + ["--json-output", file.path, "--timeout", "\(timeout)"], timeout: Double(timeout + 10))
        return try Data(contentsOf: file)
    }
}

struct ProfileMove: Codable {
    let original: String
    let backup: String
}

/// A recoverable transaction, limited to exact LocalShelf development profiles.
final class ProfileBackup {
    let root: URL
    let cacheRoots: [URL]
    let journal: URL
    let readProfile: (URL) throws -> SigningProfile
    init(root: URL, cacheRoots: [URL]? = nil, readProfile: @escaping (URL) throws -> SigningProfile = SigningProfile.read) {
        self.root = root
        self.readProfile = readProfile
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.cacheRoots = cacheRoots ?? [
            home.appendingPathComponent("Library/MobileDevice/Provisioning Profiles"),
            home.appendingPathComponent("Library/Developer/Xcode/UserData/Provisioning Profiles")
        ]
        journal = root.appendingPathComponent("profile-transaction.json")
    }
    func recover() throws {
        guard FileManager.default.fileExists(atPath: journal.path) else { return }
        let moves = try JSONDecoder().decode([ProfileMove].self, from: Data(contentsOf: journal))
        for move in moves {
            let original = URL(fileURLWithPath: move.original).standardizedFileURL
            let backup = URL(fileURLWithPath: move.backup).standardizedFileURL
            guard cacheRoots.contains(where: { $0.resolvingSymlinksInPath().standardizedFileURL.path == original.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path }),
                  original.pathExtension == "mobileprovision",
                  backup.deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path == root.appendingPathComponent("ProfileBackups").resolvingSymlinksInPath().standardizedFileURL.path else {
                throw SignerError.message("签名缓存恢复记录异常，已停止。请检查 profile-transaction.json。原位置：\(original.path)；备份：\(backup.path)；允许缓存：\(cacheRoots.map { $0.standardizedFileURL.path })；备份根：\(root.appendingPathComponent("ProfileBackups").standardizedFileURL.path)")
            }
            if FileManager.default.fileExists(atPath: backup.path) && !FileManager.default.fileExists(atPath: original.path) {
                try FileManager.default.copyItem(at: backup, to: original)
            }
        }
        try FileManager.default.removeItem(at: journal)
    }
    func prepare(team: String) throws -> Int {
        try recover()
        let backupRoot = root.appendingPathComponent("ProfileBackups/\(UUID().uuidString)")
        var moves: [ProfileMove] = []
        for directory in cacheRoots where FileManager.default.fileExists(atPath: directory.path) {
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
                guard file.pathExtension == "mobileprovision",
                      try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                      let profile = try? readProfile(file), profile.matches(team: team, bundle: Settings.bundle) else { continue }
                let target = backupRoot.appendingPathComponent("\(moves.count)-\(file.lastPathComponent)")
                moves.append(ProfileMove(original: file.path, backup: target.path))
            }
        }
        guard !moves.isEmpty else { return 0 }
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Journal precedes mutation. Startup/failure recovery never overwrites a new profile.
        try JSONEncoder().encode(moves).write(to: journal, options: .atomic)
        do {
            for move in moves { try FileManager.default.moveItem(atPath: move.original, toPath: move.backup) }
        } catch { try? recover(); throw error }
        return moves.count
    }
    func commit() throws {
        if FileManager.default.fileExists(atPath: journal.path) { try FileManager.default.removeItem(at: journal) }
    }
}

/// Prevent two app copies or an integration check from mutating Xcode's cache together.
final class SigningLock {
    private var descriptor: Int32 = -1
    init(root: URL) throws {
        descriptor = open(root.appendingPathComponent("signing.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw SignerError.message("无法创建续签锁。") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor); descriptor = -1
            throw SignerError.message("已有另一个续签助手正在运行操作，请等待它完成。")
        }
    }
    deinit { if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor) } }
}

struct RenewalResult {
    let expiry: Date
    let version: String
}

enum RenewalEngine {
    static func renew(settings: Settings, root: URL, previousExpiry: Date?,
                      progress: @escaping (String) -> Void) throws -> RenewalResult {
        let lock = try SigningLock(root: root)
        defer { withExtendedLifetime(lock) {} }
        let project = URL(fileURLWithPath: settings.project)
        guard project.pathExtension == "xcodeproj", FileManager.default.fileExists(atPath: project.appendingPathComponent("project.pbxproj").path),
              settings.team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else {
            throw SignerError.message("工程路径或签名团队无效。请重新选择原来的 LocalShelf 工程。")
        }
        progress("正在检查 iPhone 和旧 App…")
        let phones = try DeviceJSON.phones(Command.device(["list", "devices"]))
        guard let phone = phones.first(where: { $0.id == settings.device }), phone.developerEnabled else {
            throw SignerError.message("没有找到选定且已开启开发者模式的 iPhone。请连接并信任此 Mac。")
        }
        // Paired is not the same as reachable: the live apps query must succeed first.
        let existingData = try Command.device(["device", "info", "apps", "--device", phone.id, "--bundle-id", Settings.bundle])
        guard let existing = try DeviceJSON.installed(existingData, bundle: Settings.bundle) else {
            throw SignerError.message("iPhone 上没有 LocalShelf。本工具只做覆盖续签，请先通过 Xcode 安装原 App。")
        }
        let transaction = ProfileBackup(root: root)
        try transaction.recover()
        progress("正在备份 LocalShelf 描述文件并请求新签名…")
        let backedUp = try transaction.prepare(team: settings.team)
        progress("已备份 \(backedUp) 个匹配描述文件；正在清理助手构建产物并完整构建签名…")
        var committed = false
        defer { if !committed { try? transaction.recover() } }
        let derived = root.appendingPathComponent("DerivedData")
        _ = try Command.run("/usr/bin/xcrun", RenewalPolicy.buildArguments(project: settings.project, team: settings.team, derived: derived.path), timeout: 1200)
        let app = derived.appendingPathComponent("Build/Products/Release-iphoneos/LocalShelf.app")
        guard let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Info.plist")), format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == Settings.bundle else {
            throw SignerError.message("构建结果不是原来的 LocalShelf，已停止安装。")
        }
        let build = info["CFBundleVersion"] as? String ?? ""
        let oldBuild = existing["bundleVersion"] as? String ?? ""
        if !oldBuild.isEmpty && build.compare(oldBuild, options: .numeric) == .orderedAscending {
            throw SignerError.message("工程版本低于手机已安装版本，已阻止降级。请使用最新源码。")
        }
        progress("正在验证签名、设备与新到期时间…")
        _ = try Command.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--verbose=4", app.path])
        try SigningIdentity.validate(app: app, team: settings.team)
        let profile = try SigningProfile.read(app.appendingPathComponent("embedded.mobileprovision"))
        try RenewalPolicy.validate(profile, team: settings.team, udid: phone.udid, previousExpiry: previousExpiry)
        // A valid renewed profile should remain cached even if the phone disconnects at install.
        try transaction.commit(); committed = true
        progress("新签名已确认；正在覆盖安装，请保持 iPhone 解锁…")
        _ = try DeviceJSON.result(Command.device(["device", "install", "app", "--device", phone.id, app.path], timeout: 180))
        progress("正在核对 iPhone 上的安装版本…")
        let verification = try Command.device(["device", "info", "apps", "--device", phone.id, "--bundle-id", Settings.bundle])
        guard let installed = try DeviceJSON.installed(verification, bundle: Settings.bundle),
              installed["bundleVersion"] as? String == build else {
            throw SignerError.message("安装指令已执行，但未能核对手机版本。未记录续签成功，请连接后重试。")
        }
        return RenewalResult(expiry: profile.expiry, version: "\(info["CFBundleShortVersionString"] as? String ?? "") (\(build))")
    }
}
