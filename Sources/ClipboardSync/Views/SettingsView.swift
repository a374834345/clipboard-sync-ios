import SwiftUI
import UIKit
import AudioToolbox

/// TCC 剪贴板权限重置：动态加载 /usr/lib/libsqlite3.dylib，直接 C-API 调 sqlite3_exec。
/// 不使用 Process / NSTask / popen — 这些在 iOS Swift SDK 里都被标记 unavailable（虽然运行时符号存在）。
/// TrollStore platform-application 环境下 /var/mobile/Library/TCC/TCC.db 可写。
enum TCCReset {
    static let tccDBPath = "/private/var/mobile/Library/TCC/TCC.db"

    // libsqlite3 C function signatures
    private typealias sqlite3_open_t   = @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<OpaquePointer?>?) -> Int32
    private typealias sqlite3_close_t  = @convention(c) (OpaquePointer?) -> Void
    private typealias sqlite3_exec_t   = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, (@convention(c) (UnsafeMutableRawPointer?, Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32)?, UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
    private typealias sqlite3_changes_t = @convention(c) (OpaquePointer?) -> Int32
    private typealias sqlite3_errmsg_t  = @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?

    /// 返回 (成功: Bool, 结果文案)
    static func resetPasteboard(bundleID: String) -> (Bool, String) {
        // 1. 动态加载 libsqlite3（用 Darwin.dlopen 系列，避免与自定义 @_silgen_name 冲突）
        guard let libHandle = Darwin.dlopen("/usr/lib/libsqlite3.dylib", Darwin.RTLD_NOW) else {
            let cErr = Darwin.dlerror()
            let err: String = cErr != nil ? String(cString: cErr!) : "unknown dlerror"
            return (false, "❌ dlopen(libsqlite3.dylib) 失败: \(err)")
        }
        defer { _ = Darwin.dlclose(libHandle) }

        // 2. 拿函数指针（用 Darwin.dlsym 避免符号歧义）
        guard let p_open  = Darwin.dlsym(libHandle, "sqlite3_open")  .map({ unsafeBitCast($0, to: sqlite3_open_t.self)  }) else { return (false, "❌ 找不到 sqlite3_open") }
        guard let p_close = Darwin.dlsym(libHandle, "sqlite3_close") .map({ unsafeBitCast($0, to: sqlite3_close_t.self) }) else { return (false, "❌ 找不到 sqlite3_close") }
        guard let p_exec  = Darwin.dlsym(libHandle, "sqlite3_exec")  .map({ unsafeBitCast($0, to: sqlite3_exec_t.self)  }) else { return (false, "❌ 找不到 sqlite3_exec") }
        guard let p_changes = Darwin.dlsym(libHandle, "sqlite3_changes").map({ unsafeBitCast($0, to: sqlite3_changes_t.self) }) else { return (false, "❌ 找不到 sqlite3_changes") }
        guard let p_errmsg  = Darwin.dlsym(libHandle, "sqlite3_errmsg") .map({ unsafeBitCast($0, to: sqlite3_errmsg_t.self)  }) else { return (false, "❌ 找不到 sqlite3_errmsg") }

        // 3. 单引号转义（SQL 注入防护）
        let safeID = bundleID.replacingOccurrences(of: "'", with: "''")

        // 4. 打开数据库
        var db: OpaquePointer? = nil
        let openRC = tccDBPath.withCString { cs in p_open(cs, &db) }
        guard openRC == 0 /* SQLITE_OK */, let db = db else {
            let err = db.flatMap { p_errmsg($0) }.map { String(cString: $0) } ?? "rc=\(openRC)"
            return (false, "❌ 无法打开 TCC.db：\(err)")
        }
        defer { p_close(db) }

        // 5. 逐条执行 DELETE SQL（分开执行便于累计 deleted 行数）
        let statements: [String] = [
            "DELETE FROM access WHERE service='kTCCServicePasteboard' AND client='\(safeID)';",
            "DELETE FROM access WHERE service='kTCCServicePasteboard' AND client LIKE '%\(safeID)%';",
            "DELETE FROM access_overrides WHERE service='kTCCServicePasteboard' AND bundle_id='\(safeID)';",
            "DELETE FROM admin WHERE service='kTCCServicePasteboard' AND subject LIKE '%\(safeID)%';",
        ]
        var deleted: Int32 = 0
        var errMsgs: [String] = []
        for sql in statements {
            let rc = sql.withCString { cs in p_exec(db, cs, nil, nil, nil) }
            if rc == 0 {
                deleted += p_changes(db)
            } else {
                let msg = p_errmsg(db).map { String(cString: $0) } ?? "rc=\(rc)"
                errMsgs.append(msg)
            }
        }
        if errMsgs.isEmpty {
            if deleted > 0 {
                return (true, "✅ 已从 TCC.db 清除 \(deleted) 条剪贴板权限记录。请立刻杀进程重开 App，下次点「粘贴」会重新弹允许对话框。")
            } else {
                return (true, "✅ TCC.db 里已经没有本 App 的剪贴板权限记录（可能之前已经清过了）。请杀进程重开 App。")
            }
        } else {
            return (false, "❌ SQL 错误：\(errMsgs.joined(separator: "；"))")
        }
    }
}

// MARK: - 应用图标切换模型（SpringBoard 主屏图标，官方 Alternate Icons API）
enum AlternateAppIcon: String, CaseIterable, Identifiable {
    case primary   = "PrimaryIcon"
    case blue      = "AppIcon-Blue"
    case green     = "AppIcon-Green"
    case orange    = "AppIcon-Orange"
    case purple    = "AppIcon-Purple"
    case pink      = "AppIcon-Pink"
    case black     = "AppIcon-Black"
    case white     = "AppIcon-White"

    var id: String { rawValue }

    /// 设置页按钮左上角颜色小方块的预览颜色（左→右渐变两个 RGB）
    var gradient: (from: (r: CGFloat, g: CGFloat, b: CGFloat), to: (r: CGFloat, g: CGFloat, b: CGFloat)) {
        switch self {
        case .primary: return ((0.23, 0.49, 0.95), (0.39, 0.28, 0.95))
        case .blue:    return ((0.00, 0.48, 1.00), (0.00, 0.25, 0.87))
        case .green:   return ((0.20, 0.78, 0.35), (0.00, 0.59, 0.53))
        case .orange:  return ((1.00, 0.58, 0.00), (1.00, 0.37, 0.23))
        case .purple:  return ((0.69, 0.32, 0.87), (0.35, 0.34, 0.84))
        case .pink:    return ((1.00, 0.18, 0.33), (1.00, 0.51, 0.67))
        case .black:   return ((0.12, 0.12, 0.13), (0.24, 0.24, 0.26))
        case .white:   return ((0.95, 0.95, 0.97), (0.88, 0.88, 0.92))
        }
    }

    var label: String {
        switch self {
        case .primary: return "默认"
        case .blue:    return "蓝"
        case .green:   return "绿"
        case .orange:  return "橙"
        case .purple:  return "紫"
        case .pink:    return "粉"
        case .black:   return "黑"
        case .white:   return "白"
        }
    }

    /// 传 nil 给 setAlternateIconName 就恢复 primary
    var setAlternateIconNameValue: String? {
        switch self {
        case .primary: return nil
        default:       return rawValue
        }
    }

    static func fromSpringBoardName(_ name: String?) -> AlternateAppIcon {
        guard let n = name, let c = AlternateAppIcon(rawValue: n) else { return .primary }
        return c
    }
}

// MARK: - 预览切换按钮的结果触感/音效包装（对应 ContentView.PasteHaptic，独立实现避免跨文件依赖）
enum PasteHapticWrapper {
    static func pullSuccess() {
        AudioServicesPlaySystemSound(1104)
        let medium = UIImpactFeedbackGenerator(style: .medium)
        medium.prepare()
        medium.impactOccurred(intensity: 0.8)
        let notif = UINotificationFeedbackGenerator()
        notif.notificationOccurred(.success)
    }
    static func error() {
        let notif = UINotificationFeedbackGenerator()
        notif.notificationOccurred(.error)
    }
}

// MARK: - 设置页里的图标预览（用 SwiftUI 画模拟 iOS 圆角图标 + 中心剪贴板图形，不读 Assets.xcassets）
struct AppIconPreview: View {
    let icon: AlternateAppIcon
    var side: CGFloat = 62

    var body: some View {
        let c = icon.gradient
        RoundedRectangle(cornerRadius: side * 0.23, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: c.from.r, green: c.from.g, blue: c.from.b),
                        Color(red: c.to.r,   green: c.to.g,   blue: c.to.b),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .frame(width: side, height: side)
            .overlay(alignment: .center) {
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.system(size: side * 0.55, weight: .semibold))
                    .foregroundStyle(icon == .white ? Color(red: 0.31, green: 0.31, blue: 0.33) : .white)
                    .shadow(color: .black.opacity(icon == .white ? 0.0 : 0.12), radius: 2, y: 1)
            }
            .overlay(
                RoundedRectangle(cornerRadius: side * 0.23, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.09), radius: 3, y: 2)
    }
}

@MainActor
final class AppIconSwitcher: ObservableObject {
    static let shared = AppIconSwitcher()

    @Published var current: AlternateAppIcon = .primary
    @Published var lastError: String? = nil

    private init() { refresh() }

    func refresh() {
        let sbName = UIApplication.shared.alternateIconName
        current = AlternateAppIcon.fromSpringBoardName(sbName)
    }

    func apply(_ next: AlternateAppIcon) async -> (Bool, String) {
        guard UIApplication.shared.supportsAlternateIcons else {
            return (false, "❌ 当前 iOS 环境不支持 Alternate Icons（应检查 Info.plist 中 CFBundleAlternateIcons）")
        }
        guard current != next else {
            return (true, "当前已是 \(next.label) 图标")
        }
        do {
            try await UIApplication.shared.setAlternateIconName(next.setAlternateIconNameValue)
            current = next
            return (true, "✅ 已切换到「\(next.label)」图标（请返回桌面查看）")
        } catch {
            let msg = "❌ 切换失败：\(error.localizedDescription)"
            lastError = msg
            return (false, msg)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var network: NetworkService
    @StateObject private var iconSwitcher = AppIconSwitcher.shared
    @State private var testResult: String = ""
    @State private var testing: Bool = false
    @State private var tccResult: String = ""
    @State private var showRestartAlert: Bool = false
    @State private var iconSwitchResult: String = ""

    var body: some View {
        Form {
            // MARK: 切换应用图标（iPhone 桌面 SpringBoard 图标）
            Section("切换应用图标（桌面图标）") {
                Text("选择下方任一图标，点击立刻切换到该桌面图标（iPhone 主屏）。无需注销重启，官方 API 一秒生效。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                let cols = [GridItem(.adaptive(minimum: 78), spacing: 14)]
                LazyVGrid(columns: cols, alignment: .center, spacing: 14) {
                    ForEach(AlternateAppIcon.allCases) { icon in
                        let isSelected = iconSwitcher.current == icon
                        Button {
                            Task {
                                let (ok, msg) = await iconSwitcher.apply(icon)
                                iconSwitchResult = msg
                                if !ok { PasteHapticWrapper.error() }
                                else { PasteHapticWrapper.pullSuccess() }
                            }
                        } label: {
                            VStack(spacing: 6) {
                                AppIconPreview(icon: icon)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .stroke(isSelected ? Color.accentColor : Color.clear,
                                                    lineWidth: isSelected ? 2.5 : 0)
                                    )
                                    .overlay(alignment: .topTrailing) {
                                        if isSelected {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(Color.white, Color.accentColor)
                                                .font(.system(size: 20, weight: .bold))
                                                .offset(x: 5, y: -5)
                                                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                                        }
                                    }
                                Text(icon.label)
                                    .font(.caption2)
                                    .foregroundStyle(.primary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 6)

                if !iconSwitchResult.isEmpty {
                    Text(iconSwitchResult)
                        .font(.caption)
                        .foregroundStyle(iconSwitchResult.hasPrefix("✅") ? .green : .red)
                }
            }

            Section("服务器") {
                TextField("服务器地址", text: $settings.serverURL)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)

                Button {
                    Task { await testConnection() }
                } label: {
                    if testing {
                        HStack { ProgressView(); Text("测试中…") }
                    } else {
                        Label("测试连接", systemImage: "network")
                    }
                }
                if !testResult.isEmpty {
                    Text(testResult)
                        .font(.caption)
                        .foregroundStyle(testResult.hasPrefix("✅") ? .green : .red)
                }
            }

            Section("监听设置") {
                Toggle("自动读取剪贴板（后台轮询）", isOn: $settings.autoMonitor)
                if settings.autoMonitor {
                    Text("关闭此项只有点击主页的「粘贴」按钮才读取剪贴板，完全不弹「允许粘贴」横幅。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Toggle("自动上传剪贴板", isOn: $settings.autoUploadEnabled)
                Toggle("启动时自动拉取", isOn: $settings.autoPullEnabled)

                if settings.autoMonitor {
                    VStack(alignment: .leading) {
                        Text("检查间隔：\(String(format: "%.1f", settings.checkInterval)) 秒")
                        Slider(value: $settings.checkInterval, in: 0.5...5.0, step: 0.5)
                    }
                }

                Stepper("最小内容长度：\(settings.minLength)", value: $settings.minLength, in: 1...20)
            }

            Section("剪贴板权限修复（点粘贴没用 / 总弹询问）") {
                Text("系统 App 列表里找不到本 App？因为你之前拒绝了剪贴板权限，TCC 数据库只记录了拒绝态，所以系统设置不显示条目。点下面按钮就能把这条记录删掉，然后重启 App，再点粘贴时系统会重新弹「允许」对话框，这次点允许就会出现了。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                let bundleID = Bundle.main.bundleIdentifier ?? "com.clipboardsync.app"

                Button {
                    let (ok, msg) = TCCReset.resetPasteboard(bundleID: bundleID)
                    tccResult = msg
                    if ok {
                        showRestartAlert = true
                    }
                } label: {
                    Label("重置剪贴板权限（删 TCC 记录）", systemImage: "arrow.counterclockwise.circle.fill")
                        .foregroundStyle(Color.red)
                }

                Button {
                    // 跳到系统「隐私与安全性 → 剪贴板」（iOS 通用设置入口）
                    if let u = URL(string: "App-Prefs:root=Privacy&path=PASTEBOARD") {
                        UIApplication.shared.open(u, options: [:], completionHandler: nil)
                    } else if let u = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(u, options: [:], completionHandler: nil)
                    }
                } label: {
                    Label("打开系统剪贴板隐私设置", systemImage: "hand.raised.slash")
                }

                Button {
                    if let u = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(u, options: [:], completionHandler: nil)
                    }
                } label: {
                    Label("打开本 App 系统设置页（如无则用上一项）", systemImage: "gearshape.2")
                }

                if !tccResult.isEmpty {
                    Text(tccResult)
                        .font(.caption)
                        .foregroundStyle(tccResult.hasPrefix("✅") ? .green : .red)
                }
            }
            .alert("请立即重启 App", isPresented: $showRestartAlert) {
                Button("好，我去杀进程重开") { }
            } message: {
                Text("TCC 记录已经删除。iOS 进程运行时会缓存 TCC 权限结果，必须杀掉本 App 再打开，下次点「粘贴」时系统才会重新弹出「允许粘贴」对话框。\n\n之后如果再拒绝，随时可以回来点这个按钮再来一次。")
            }

            Section("TrollStore 后台保活") {
                Text("本应用已通过 TrollStore + ImmortalizerTS 保活。请确保已在 ImmortalizerTS 中将本应用添加到保活列表，并在系统设置中授予后台刷新权限。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let url = URL(string: "App-Prefs:root=General&path=BACKGROUND_APP_REFRESH") {
                    Button("打开系统后台刷新设置") {
                        UIApplication.shared.open(url, options: [:], completionHandler: nil)
                    }
                }
            }

            Section("关于") {
                LabeledContent("当前服务器", value: settings.normalizedServerURL)
                LabeledContent("最后上传时间") {
                    Text(network.lastUploadedAt.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .medium) } ?? "—")
                }
                if let err = network.lastError {
                    LabeledContent("最近错误", value: err)
                }
            }
        }
        .navigationTitle("设置")
    }

    private func testConnection() async {
        await MainActor.run { testing = true; testResult = "" }
        let payload = await network.fetchLatest(serverURL: settings.normalizedServerURL)
        await MainActor.run {
            testing = false
            if payload != nil {
                testResult = "✅ 连接成功"
            } else {
                testResult = "❌ 无法连接到服务器"
            }
        }
    }
}
