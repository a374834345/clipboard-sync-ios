import SwiftUI
import UIKit

/// 重置 TCC 剪贴板权限：用 sqlite3 直接删 /private/var/mobile/Library/TCC/TCC.db 里本 App 的 kTCCServicePasteboard 记录。
/// TrollStore 安装的 App 是 platform-application + mobile 用户，有权读写自己的 TCC.db。
enum TCCReset {
    static let tccDBPath = "/private/var/mobile/Library/TCC/TCC.db"

    /// 返回 (成功: Bool, 结果文案)
    static func resetPasteboard(bundleID: String) -> (Bool, String) {
        // 安全起见不用动态库链接 sqlite3，用 subProcess 跑 sqlite3 CLI（iOS 自带，/usr/bin/sqlite3）
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        // 删除两张可能表（access 和 access_overrides）里关于 bundleID + kTCCServicePasteboard 的记录
        let sql = """
        DELETE FROM access WHERE service='kTCCServicePasteboard' AND client='\(bundleID)';
        DELETE FROM access WHERE service='kTCCServicePasteboard' AND client LIKE '%\(bundleID)%';
        DELETE FROM access_overrides WHERE service='kTCCServicePasteboard' AND bundle_id='\(bundleID)';
        DELETE FROM admin WHERE service='kTCCServicePasteboard' AND subject LIKE '%\(bundleID)%';
        """
        p.arguments = [tccDBPath, sql]
        p.standardOutput = pipe
        p.standardError  = pipe
        do {
            try p.run()
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if p.terminationStatus == 0 {
                return (true, output.isEmpty ? "✅ 已从 TCC.db 删除本 App 的剪贴板权限记录。" : "✅ 结果: \(output)")
            } else {
                return (false, "❌ sqlite3 退出码 \(p.terminationStatus): \(output)")
            }
        } catch {
            return (false, "❌ 无法执行 sqlite3：\(error.localizedDescription)")
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

    var body: some View {
        Form {
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
