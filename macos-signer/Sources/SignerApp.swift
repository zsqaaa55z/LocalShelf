import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications

@MainActor
final class SignerModel: ObservableObject {
    @Published var settings: Settings
    @Published var phones: [Phone] = []
    @Published var busy = false
    @Published var status = "准备检查签名"
    @Published var referenceExpiry: Date?
    @Published var logs = ""
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var showConfirm = false
    let root: URL
    private var timer: Timer?
    private var started: Date?
    private var wakeObserver: NSObjectProtocol?

    init() {
        root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LocalShelfSigner-Public")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let defaults = Settings(project:"",referenceApp:"",team:"",device:"")
        settings = (try? JSONDecoder().decode(Settings.self, from: Data(contentsOf: root.appendingPathComponent("settings.json")))) ?? defaults
        refreshReference()
        logs = (try? String(contentsOf: root.appendingPathComponent("activity.log"), encoding: .utf8)) ?? ""
        if logs.count > 30_000 { logs = String(logs.suffix(30_000)) }
        do {
            let lock = try SigningLock(root: root)
            try ProfileBackup(root: root).recover()
            withExtendedLifetime(lock) {}
        }
        catch { settings.automatic = false; status = error.localizedDescription }
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = 60
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        Task { await inspect(); tick() }
    }
    var expiry: Date? { settings.installedExpiry ?? referenceExpiry }
    var remaining: String {
        guard let expiry else { return "尚未读取" }
        let hours = Int(expiry.timeIntervalSinceNow / 3600)
        if expiry <= Date() { return "签名已到期" }
        return hours >= 24 ? "剩余 \(hours / 24) 天 \(hours % 24) 小时" : "剩余不足 \(max(1, hours + 1)) 小时"
    }
    var menuIcon: String { busy ? "arrow.triangle.2.circlepath" : (RenewalPolicy.due(expiry: expiry) ? "exclamationmark.shield" : "checkmark.shield") }
    var elapsed: String {
        guard let started else { return "" }
        return "已用时 \(Int(Date().timeIntervalSince(started))) 秒"
    }
    func save() {
        do { try JSONEncoder().encode(settings).write(to: root.appendingPathComponent("settings.json"), options: .atomic) }
        catch { status = "设置保存失败：\(error.localizedDescription)" }
    }
    func log(_ text: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        logs = String((logs + "\n[\(stamp)] \(text)").suffix(30_000))
        try? logs.write(to: root.appendingPathComponent("activity.log"), atomically: true, encoding: .utf8)
    }
    func refreshReference() {
        referenceExpiry = (try? SigningProfile.read(URL(fileURLWithPath: settings.referenceApp).appendingPathComponent("embedded.mobileprovision")))?.expiry
    }
    func inspect() async {
        guard !busy else { return }
        busy = true
        status = "正在检查 Xcode 与已配对的 iPhone…"
        defer { busy = false }
        do {
            let result = try await Task.detached {
                _ = try Command.run("/usr/bin/xcrun", ["xcodebuild", "-version"])
                return try DeviceJSON.phones(Command.device(["list", "devices"]))
            }.value
            phones = result
            refreshReference()
            status = result.contains(where: { $0.id == settings.device }) ? "检查完成；续签前会实际验证设备是否可访问。" : "未找到选定 iPhone，请连接 USB 并信任此 Mac。"
            log(status)
        } catch { status = error.localizedDescription; log(status) }
    }
    func tick() {
        guard !busy else { return }
        refreshReference()
        if RenewalPolicy.mayRun(settings: settings, referenceExpiry: referenceExpiry) { renew() }
    }
    func renew() {
        guard !busy else { return }
        guard settings.configured else { status = "请先选择工程、填写开发团队 ID 并选择已配对的 iPhone。"; return }
        busy = true; started = Date()
        // Persist backoff before spawning so a crash/relaunch cannot create a retry loop.
        settings.nextAttempt = Date().addingTimeInterval(6 * 3600); save()
        let config = settings, directory = root, previous = expiry
        status = "正在启动续签…"; log(status)
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "完成 LocalShelf 签名和安装")
        Task {
            defer { busy = false; started = nil; ProcessInfo.processInfo.endActivity(activity) }
            do {
                let result = try await Task.detached {
                    try RenewalEngine.renew(settings: config, root: directory, previousExpiry: previous) { message in
                        Task { @MainActor in self.status = message; self.log(message) }
                    }
                }.value
                settings.installedExpiry = result.expiry; settings.installedAt = Date(); settings.nextAttempt = nil; save()
                status = "续签并覆盖安装成功 · \(result.version)"; log(status)
                notify(title: "LocalShelf 续签成功", body: "新到期时间：\(result.expiry.formatted(date: .abbreviated, time: .shortened))")
            } catch {
                status = "续签未完成：\(error.localizedDescription)"; log(status)
                notify(title: "LocalShelf 续签需要处理", body: "请打开 Mac 菜单栏的续签助手查看原因。没有卸载或清除手机 App。")
            }
        }
    }
    func setAutomatic(_ enabled: Bool) {
        guard !enabled || settings.configured else { status = "请先完成工程、开发团队和设备配置。"; return }
        settings.automatic = enabled; save()
        if enabled {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            log("已开启自动续签：到期前 48 小时尝试；失败后至少间隔 6 小时。")
            tick()
        }
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval {
                status = "请在系统设置 → 通用 → 登录项中允许续签助手。"
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch { status = "登录启动设置失败：\(error.localizedDescription)" }
    }
    func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowedContentTypes = [.init(filenameExtension: "xcodeproj")!]
        panel.message = "选择原来的 LocalShelf.xcodeproj。不会更改团队或 Bundle ID。"
        if panel.runModal() == .OK, let url = panel.url { settings.project = url.path; save() }
    }
    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent(); content.title = title; content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "signer-result", content: content, trigger: nil))
    }
}

struct Dashboard: View {
    @ObservedObject var model: SignerModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 16) {
                    Image(systemName: "signature").font(.system(size: 32)).foregroundStyle(.mint)
                        .frame(width: 68, height: 68).background(.mint.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("LocalShelf 续签助手").font(.largeTitle.bold())
                        Text("你的书库，保持可用。Mac 原生 · 只续签自己的 App")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(model.remaining).font(.system(size: 29, weight: .semibold, design: .rounded))
                        Spacer()
                        Label(model.settings.automatic ? "自动守护已开启" : "自动守护未开启", systemImage: model.settings.automatic ? "checkmark.circle.fill" : "pause.circle")
                            .foregroundStyle(model.settings.automatic ? Color.mint : Color.secondary)
                    }
                    if let expiry = model.expiry {
                        Text("到期时间：\(expiry.formatted(date: .complete, time: .shortened))").textSelection(.enabled)
                    }
                    Text(model.settings.installedAt == nil ? "依据上次构建安装包估算；首次由助手成功安装后，会记录该次安装期限。其他工具的后续安装不会自动同步到这里。" : "依据助手最后一次确认安装的记录；如果用其他工具更新过 App，这个期限可能已变化。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.mint.opacity(0.07), in: RoundedRectangle(cornerRadius: 20))
                GroupBox("连接与工程") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Picker("目标 iPhone", selection: Binding(get: { model.settings.device }, set: { model.settings.device = $0; model.settings.installedAt = nil; model.settings.installedExpiry = nil; model.save() })) {
                                if !model.phones.contains(where: { $0.id == model.settings.device }) {
                                    Text("请选择 iPhone").tag(model.settings.device)
                                }
                                ForEach(model.phones) { phone in Text(phone.label).tag(phone.id) }
                            }
                            Button("检查连接") { Task { await model.inspect() } }
                        }
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("LocalShelf.xcodeproj").fontWeight(.medium)
                                Text(model.settings.project).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Spacer()
                            Button("选择工程…", action: model.chooseProject)
                        }
                        Text("保留签名团队与应用标识 · 不卸载旧 App · 不保存 Apple ID 密码")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("你的 Apple 开发团队 ID（10 位）", text: Binding(get:{model.settings.team},set:{model.settings.team=$0.trimmingCharacters(in:.whitespacesAndNewlines).uppercased();model.settings.automatic=false;model.save()}))
                        TextField("可选：现有 LocalShelf.app 路径（用于估算期限）", text: Binding(get:{model.settings.referenceApp},set:{model.settings.referenceApp=$0;model.save();model.refreshReference()}))
                    }.padding(10)
                }.disabled(model.busy)
                GroupBox("自动化") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("到期前 48 小时自动续签", isOn: Binding(get: { model.settings.automatic }, set: model.setAutomatic))
                        Toggle("登录 Mac 时启动", isOn: Binding(get: { model.loginEnabled }, set: model.setLogin))
                        Text("运行中每 15 分钟检查一次，唤醒 Mac 时也会检查。续签需联网；iPhone 需可访问、已信任且开启开发者模式。USB 最稳定；无线连接需事先在 Xcode 配置。Mac 关机或 App 退出后不会工作。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text("续签会备份并移走 Xcode 缓存中仅属于 LocalShelf 的开发描述文件，促使 Xcode 请求新期限；失败自动恢复。不撤销证书，不处理其他 App。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(10)
                }.disabled(model.busy)
                HStack {
                    if model.busy { ProgressView().controlSize(.small) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.status).lineLimit(4).textSelection(.enabled)
                        if model.busy { TimelineView(.periodic(from: .now, by: 1)) { _ in Text(model.elapsed).font(.caption).foregroundStyle(.secondary) } }
                    }
                    Spacer()
                    Button("立即续签并覆盖安装") { model.showConfirm = true }
                        .buttonStyle(.borderedProminent).tint(.mint).foregroundStyle(.black)
                        .disabled(model.busy || model.settings.device.isEmpty)
                }
                DisclosureGroup("运行日志（仅保存在这台 Mac）") {
                    ScrollView { Text(model.logs.isEmpty ? "暂无日志" : model.logs).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 170)
                    HStack {
                        Button("打开日志与备份目录") { NSWorkspace.shared.open(model.root) }
                        Button("打开 Xcode") { NSWorkspace.shared.open(URL(fileURLWithPath: model.settings.project)) }
                        Spacer()
                    }
                }
                Text("免费账号仍受 Apple 的 7 天期限限制。本工具自动处理续签流程，不提供永久签名，也不保证无人值守时 Apple 授权始终有效。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }.frame(minWidth: 740, idealWidth: 800, minHeight: 780)
            .background(Color(nsColor: .windowBackgroundColor))
            .confirmationDialog("续签并覆盖安装 LocalShelf？", isPresented: $model.showConfirm, titleVisibility: .visible) {
                Button("开始续签") { model.renew() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将使用 Xcode 中已登录的账号，备份并刷新本 App 的描述文件，再构建安装。不会卸载或清除手机数据。请保持 iPhone 可连接；如 Xcode 要求登录或钥匙串授权，需要你确认。")
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: SignerModel?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model?.busy == true {
            let alert = NSAlert(); alert.messageText = "正在检查或续签，请等待当前操作完成。"
            alert.informativeText = "完成后可退出。强制退出可能中断构建或安装；下次启动会尝试恢复未完成的缓存备份。"
            alert.runModal(); return .terminateCancel
        }
        return .terminateNow
    }
}

@main
struct LocalShelfSignerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = SignerModel()
    @Environment(\.openWindow) var openWindow
    var body: some Scene {
        Window("LocalShelf 续签助手", id: "dashboard") {
            Dashboard(model: model).preferredColorScheme(.dark).onAppear { delegate.model = model }
        }.defaultSize(width: 800, height: 880)
        MenuBarExtra("LocalShelf 续签助手", systemImage: model.menuIcon) {
            Text(model.remaining)
            Text(model.busy ? "正在处理…" : (model.settings.automatic ? "自动续签已开启" : "自动续签未开启"))
            Divider()
            Button("打开续签助手") { openWindow(id: "dashboard"); NSApp.activate(ignoringOtherApps: true) }
            Button("检查连接") { Task { await model.inspect() } }.disabled(model.busy)
            Divider()
            Button("退出") { NSApp.terminate(nil) }.disabled(model.busy)
        }
    }
}
