import SwiftUI
import AudioToolbox
import UIKit



// MARK: - 全局复制音效 & 触感反馈
enum PasteHaptic {
    private static let lightImpact  = UIImpactFeedbackGenerator(style: .light)
    private static let mediumImpact = UIImpactFeedbackGenerator(style: .medium)
    private static let rigidImpact  = UIImpactFeedbackGenerator(style: .rigid)

    /// 写入剪贴板：系统音 1104 + 轻震动
    static func copy() {
        AudioServicesPlaySystemSound(1104)
        lightImpact.prepare()
        lightImpact.impactOccurred()
    }

    /// 拉取成功
    static func pullSuccess() {
        AudioServicesPlaySystemSound(1104)
        mediumImpact.prepare()
        mediumImpact.impactOccurred(intensity: 0.8)
        let notif = UINotificationFeedbackGenerator()
        notif.notificationOccurred(.success)
    }

    /// 错误反馈
    static func error() {
        let notif = UINotificationFeedbackGenerator()
        notif.notificationOccurred(.error)
    }

    /// 按钮按下去的触感（硬按钮"咔哒"一声，按下瞬间调用）
    static func pressDown() {
        rigidImpact.prepare()
        rigidImpact.impactOccurred(intensity: 0.55)
    }

    /// 按钮抬起的触感（软一点）
    static func pressUp() {
        lightImpact.prepare()
        lightImpact.impactOccurred(intensity: 0.3)
    }
}

// MARK: - 「按下」视觉效果 modifier（不依赖 ButtonStyle，更稳）
/// 用 DragGesture(minimumDistance:0) 来判断手指是否按着。
/// 按下瞬间：scale 0.94 + 变暗 + rigid 咔哒；抬起：恢复 + light 软咔哒。
struct PressableEffect: ViewModifier {
    var scale: CGFloat = 0.94
    var opacity: Double = 0.82
    var dim: Double = 0.07
    @State private var pressed: Bool = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed ? scale : 1.0)
            .opacity(pressed ? opacity : 1.0)
            .brightness(pressed ? -dim : 0)
            .animation(.easeOut(duration: 0.07), value: pressed)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !pressed {
                            pressed = true
                            PasteHaptic.pressDown()
                        }
                    }
                    .onEnded { _ in
                        if pressed {
                            pressed = false
                            PasteHaptic.pressUp()
                        }
                    }
            )
    }
}
extension View {
    /// 按下视觉：scale 0.94 + 变暗 + rigid 咔哒；抬起恢复 + 软咔哒
    func pressable(scale: CGFloat = 0.94, opacity: Double = 0.82) -> some View {
        self.modifier(PressableEffect(scale: scale, opacity: opacity))
    }
}

struct ContentView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var monitor: ClipboardMonitor
    @EnvironmentObject var network: NetworkService

    @State private var pasteInFlight: Bool = false
    @State private var pullInFlight:  Bool = false
    @State private var showTCCDeniedAlert: Bool = false
    /// 自定义封面缓存（设置页换完后会刷新 settings.hasCustomCover，这里立刻更新显示）
    @State private var coverUIImage: UIImage? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: []) {
                    coverBanner
                    statusCard
                    quickActionBar
                    historyList
                }
            }
            .navigationTitle("剪贴板同步")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                            .environmentObject(settings)
                            .environmentObject(monitor)
                            .environmentObject(network)
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .onAppear {
                monitor.start(settings: settings, network: network)
                Task { await monitor.refreshHistory() }
                reloadCoverFromDisk()
            }
            .onChange(of: settings.hasCustomCover) { _, _ in
                // 设置页封面更新/删除后同步刷新显示
                reloadCoverFromDisk()
            }
            // 每次回到前台（从设置页切回来）也刷一次封面
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                reloadCoverFromDisk()
            }
            .alert("剪贴板权限被拒绝", isPresented: $showTCCDeniedAlert) {
                Button("去设置开启", role: .none) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url, options: [:], completionHandler: nil)
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("之前你两次拒绝了「从其他 App 粘贴」的权限，所以系统禁止本 App 读取剪贴板。请在打开的设置页里找到「从其他 App 粘贴」，选择「允许」或「询问」，然后回 App 再点粘贴。")
            }
        }
    }

    // MARK: - 顶部自定义封面（用户可以在设置页上传自己的图）
    @ViewBuilder
    private var coverBanner: some View {
        if let ui = coverUIImage {
            // 用户自定义封面
            Image(uiImage: ui)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: 190)
                .clipped()
                .overlay(
                    LinearGradient(
                        colors: [.black.opacity(0.0), .black.opacity(0.22)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("剪贴板同步")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 14)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                }
        } else {
            // 默认封面：渐变色 + 大图标
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    colors: [
                        Color(red: 0.24, green: 0.49, blue: 0.95),
                        Color(red: 0.39, green: 0.28, blue: 0.95),
                        Color(red: 0.65, green: 0.27, blue: 0.92),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                // 装饰圆
                Circle()
                    .fill(.white.opacity(0.12))
                    .frame(width: 280, height: 280)
                    .offset(x: 170, y: -120)
                Circle()
                    .fill(.white.opacity(0.09))
                    .frame(width: 170, height: 170)
                    .offset(x: -110, y: 110)

                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "doc.on.clipboard.fill")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.15), radius: 3, y: 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("剪贴板同步")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("电脑 ⇌ 手机 · 无缝同步")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.92))
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 190)
        }
    }

    private func reloadCoverFromDisk() {
        coverUIImage = settings.loadCoverImage()
    }

    // MARK: - 顶部状态卡（右上角不再放粘贴按钮，移到底部）
    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(monitor.monitoring ? Color.green : Color.gray)
                    .frame(width: 10, height: 10)
                Text(settings.autoMonitor ? "自动监听" : "手动模式")
                    .font(.headline)
                Spacer()
                if pasteInFlight || network.isUploading || pullInFlight {
                    ProgressView().scaleEffect(0.7)
                }
            }
            Text("当前剪贴板：")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(monitor.currentClipboard.isEmpty ? "（空）" : String(monitor.currentClipboard.prefix(120)))
                .font(.caption)
                .lineLimit(3)
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
        .padding(.top, 14)
    }

    // MARK: - 快捷按钮栏（左：拉取  右：粘贴）
    private var quickActionBar: some View {
        HStack(spacing: 12) {
            // === 左：拉取 ===
            Button {
                Task {
                    pullInFlight = true
                    defer { pullInFlight = false }
                    await monitor.pullFromServer()
                    if monitor.pullStatus == "已写入剪贴板" || monitor.pullStatus == "已是最新" {
                        PasteHaptic.pullSuccess()
                    }
                }
            } label: {
                VStack(spacing: 5) {
                    ZStack {
                        Circle()
                            .fill(Color.blue.opacity(0.12))
                            .frame(width: 60, height: 60)
                        Image(systemName: "arrow.down.to.line.circle.fill")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 34, height: 34)
                            .foregroundStyle(.blue)
                        if pullInFlight || monitor.isPulling {
                            Circle()
                                .stroke(Color.blue.opacity(0.5), lineWidth: 2)
                                .frame(width: 70, height: 70)
                                .overlay(ProgressView().scaleEffect(0.8))
                        }
                    }
                    Text("拉取")
                        .font(.caption2)
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .pressable(scale: 0.95, opacity: 0.85)
            .disabled(pullInFlight || monitor.isPulling)

            // === 右：粘贴 ===
            Button {
                Task {
                    pasteInFlight = true
                    defer { pasteInFlight = false }
                    let result = await monitor.manualPasteAndUpload()
                    if result == .permissionDenied {
                        showTCCDeniedAlert = true
                    }
                }
            } label: {
                VStack(spacing: 5) {
                    ZStack {
                        Circle()
                            .fill(Color.orange.opacity(0.14))
                            .frame(width: 60, height: 60)
                        Image(systemName: "doc.on.clipboard.fill")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 34, height: 34)
                            .foregroundStyle(.orange)
                        if pasteInFlight || network.isUploading {
                            Circle()
                                .stroke(Color.orange.opacity(0.5), lineWidth: 2)
                                .frame(width: 70, height: 70)
                                .overlay(ProgressView().scaleEffect(0.8))
                        }
                    }
                    Text("粘贴")
                        .font(.caption2)
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .pressable(scale: 0.95, opacity: 0.85)
            .disabled(pasteInFlight)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 历史列表
    private var historyList: some View {
        List {
            Section("最近上传") {
                if monitor.history.isEmpty {
                    Text("暂无记录（下拉可刷新）")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(monitor.history) { item in
                        HistoryRow(entry: item, onCopy: { [weak settings, weak monitor] in
                            guard let settings = settings, let monitor = monitor else { return }
                            // 写入剪贴板 + 跳过自触发（记 changeCount） + 响"叮"
                            var cc: Int? = nil
                            Task { @MainActor in
                                network.setLocalClipboard(item.content, suppressChangeCount: &cc)
                                if let cc = cc {
                                    // 告诉 monitor 跳过这一次自检测
                                    NotificationCenter.default.post(name: .clipboardSuppressNextChange, object: cc)
                                }
                                settings.lastUploadedContent = item.content
                                monitor.currentClipboard = item.content
                                PasteHaptic.copy()
                            }
                        })
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

// MARK: - 历史行（点整个条目即写入剪贴板 + 响"叮"）
struct HistoryRow: View {
    let entry: HistoryEntry
    var onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.content)
                .lineLimit(3)
                .font(.body)
            HStack {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                Text(formatTime(entry.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                // 右侧显式复制按钮，视觉上提示"点我复制"
                Image(systemName: "doc.on.clipboard")
                    .foregroundStyle(.blue)
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onCopy)
    }

    private func formatTime(_ ts: String?) -> String {
        guard let ts = ts, !ts.isEmpty else { return "" }
        return String(ts.prefix(19)).replacingOccurrences(of: "T", with: " ")
    }
}

// MARK: - 新增：通知名（告诉 ClipboardMonitor 下一次 changeCount 要跳过）
extension Notification.Name {
    static let clipboardSuppressNextChange = Notification.Name("clipboardSuppressNextChange")
}
