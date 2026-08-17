import SwiftUI

struct ContentView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var monitor: ClipboardMonitor
    @EnvironmentObject var network: NetworkService

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusCard
                actionButtons
                historyList
            }
            .navigationTitle("剪贴板同步")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
        }
        .onAppear {
            monitor.start(settings: settings, network: network)
            Task { await monitor.refreshHistory() }
        }
    }

    // MARK: - 状态卡片
    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(monitor.monitoring ? Color.green : Color.gray)
                    .frame(width: 10, height: 10)
                Text(monitor.monitoring ? "监听中" : "已停止")
                    .font(.headline)
                Spacer()
                if network.isUploading {
                    ProgressView().scaleEffect(0.7)
                }
            }
            Text("当前剪贴板：")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(monitor.currentClipboard.isEmpty ? "（空）" : String(monitor.currentClipboard.prefix(60)))
                .font(.caption)
                .lineLimit(2)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Label("拉取：\(monitor.pullStatus)", systemImage: "arrow.down.circle")
                if let err = network.lastError {
                    Label("错误：\(err)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.top, 8)
    }

    // MARK: - 操作按钮
    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                monitor.checkOnce()
            } label: {
                Label("立即检查", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                Task { await monitor.pullFromServer() }
            } label: {
                Label("从电脑拉取", systemImage: "arrow.down.to.line")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(monitor.isPulling)

            Button {
                monitor.monitoring ? monitor.stop() : monitor.start(settings: settings, network: network)
            } label: {
                Label(monitor.monitoring ? "暂停" : "启动", systemImage: monitor.monitoring ? "pause.circle" : "play.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(monitor.monitoring ? .red : .green)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - 历史列表
    private var historyList: some View {
        List {
            Section("最近上传") {
                if monitor.history.isEmpty {
                    Text("暂无记录")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(monitor.history) { item in
                        HistoryRow(entry: item)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                UIPasteboard.general.string = item.content
                                settings.lastUploadedContent = item.content
                                monitor.currentClipboard = item.content
                            }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await monitor.refreshHistory()
        }
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.content)
                .lineLimit(2)
                .font(.body)
            HStack {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                Text(formatTime(entry.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func formatTime(_ ts: String?) -> String {
        guard let ts = ts, !ts.isEmpty else { return "" }
        // 简单显示原字符串前 19 位
        return String(ts.prefix(19)).replacingOccurrences(of: "T", with: " ")
    }
}
