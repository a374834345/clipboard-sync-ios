import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var network: NetworkService
    @State private var testResult: String = ""
    @State private var testing: Bool = false

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

            Section("TrollStore 后台保活") {
                Text("本应用已通过 TrollStore + ImmortalizerTS 保活。请确保已在 ImmortalizerTS 中将本应用添加到保活列表，并在系统设置中授予后台刷新权限。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let url = URL(string: "App-Prefs:root=General&path=BACKGROUND_APP_REFRESH") {
                    Button("打开系统后台刷新设置") {
                        UIApplication.shared.open(url)
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
