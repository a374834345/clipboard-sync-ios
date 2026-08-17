import SwiftUI
import UIKit

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

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var network: NetworkService
    @State private var testResult: String = ""
    @State private var testing: Bool = false
    @State private var tccResult: String = ""
    @State private var showRestartAlert: Bool = false

    // MARK: - 自定义封面状态
    @State private var showImagePicker: Bool = false
    @State private var showCameraPicker: Bool = false
    @State private var pickerSource: PickerSource = .library
    @State private var coverPreview: UIImage? = nil
    @State private var coverSaveResult: String = ""

    enum PickerSource { case library, camera }

    var body: some View {
        Form {
            // MARK: 自定义 App 封面 Section
            Section("自定义 App 封面") {
                // 预览卡片
                HStack {
                    Spacer()
                    coverPreviewCard
                        .frame(maxWidth: .infinity)
                    Spacer()
                }
                .listRowBackground(Color.clear)

                if !coverSaveResult.isEmpty {
                    Text(coverSaveResult)
                        .font(.caption)
                        .foregroundStyle(coverSaveResult.hasPrefix("✅") ? .green : .red)
                }

                Button {
                    coverPreview = nil
                    pickerSource = .library
                    showImagePicker = true
                } label: {
                    Label("从相册选择图片", systemImage: "photo.on.rectangle.angled")
                }

                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button {
                        coverPreview = nil
                        pickerSource = .camera
                        showCameraPicker = true
                    } label: {
                        Label("拍一张作为封面", systemImage: "camera.viewfinder")
                    }
                }

                Button(role: .destructive) {
                    let (ok, msg) = settings.deleteCustomCover()
                    coverSaveResult = msg
                    if ok { coverPreview = nil }
                } label: {
                    Label("恢复默认封面", systemImage: "arrow.uturn.backward.square.fill")
                }
                .disabled(!settings.hasCustomCover)
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
        .onAppear { if coverPreview == nil { coverPreview = settings.loadCoverImage() } }
        .sheet(isPresented: $showImagePicker) {
            ImagePicker { img in
                guard let img = img else { return }
                coverPreview = img
                let (ok, msg) = settings.saveCoverImage(img)
                coverSaveResult = msg
                if !ok { coverPreview = settings.loadCoverImage() }
            }
        }
        .fullScreenCover(isPresented: $showCameraPicker) {
            CameraPicker { img in
                guard let img = img else { return }
                coverPreview = img
                let (ok, msg) = settings.saveCoverImage(img)
                coverSaveResult = msg
                if !ok { coverPreview = settings.loadCoverImage() }
            }
        }
    }

    // MARK: - 封面预览小卡片
    @ViewBuilder
    private var coverPreviewCard: some View {
        let (img, isDefault) = resolvePreview()
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: isDefault
                                ? [.blue.opacity(0.15), .indigo.opacity(0.25), .purple.opacity(0.2)]
                                : [.clear],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(height: 200)

                if let ui = img {
                    Image(uiImage: ui)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 54, weight: .semibold))
                            .foregroundStyle(.blue.opacity(0.75))
                        Text("默认封面")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(height: 200)
                }
            }
            .frame(height: 200)

            Text(isDefault ? "（去下方选一张你自己的图片作为封面）" : "当前封面")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func resolvePreview() -> (UIImage?, isDefault: Bool) {
        if let p = coverPreview { return (p, false) }
        if let disk = settings.loadCoverImage() { return (disk, false) }
        return (nil, true)
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
