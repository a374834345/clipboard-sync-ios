import SwiftUI
import AudioToolbox
import UIKit

// MARK: - 快捷按钮类型
enum QuickAction: String, CaseIterable, Identifiable, Codable {
    case pull      // 拉取
    case wxwork    // 企业微信
    case weixin    // 微信
    case xianyu    // 闲鱼

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .pull:   return "arrow.down.to.line.circle.fill"
        case .wxwork: return "briefcase.circle.fill"
        case .weixin: return "message.circle.fill"
        case .xianyu: return "fish.circle.fill"
        }
    }

    var title: String {
        switch self {
        case .pull:   return "拉取"
        case .wxwork: return "企微"
        case .weixin: return "微信"
        case .xianyu: return "闲鱼"
        }
    }

    var tint: Color {
        switch self {
        case .pull:   return .blue
        case .wxwork: return .orange
        case .weixin: return .green
        case .xianyu: return .yellow
        }
    }

    /// App Store 搜索兜底文案
    var appStoreSearch: String {
        switch self {
        case .wxwork: return "企业微信"
        case .weixin: return "微信"
        case .xianyu: return "闲鱼"
        case .pull:   return ""
        }
    }

    /// 按顺序尝试多个 URL scheme（用户手机可能装的是不同版本，比如老版企微用 wxwork，新版用 wework）
    var openURLCandidates: [URL] {
        var arr: [URL] = []
        switch self {
        case .pull:   break
        case .wxwork:
            ["wxwork://dl/", "wxwork://", "wework://", "safepm://wxwork"].forEach { if let u = URL(string: $0) { arr.append(u) } }
        case .weixin:
            ["weixin://dl/", "weixin://", "wechat://"].forEach { if let u = URL(string: $0) { arr.append(u) } }
        case .xianyu:
            ["xianyu://", "idlefish://", "fleamarket://", "alipays://platformapi/startapp?appId=20000067"].forEach {
                if let u = URL(string: $0) { arr.append(u) }
            }
        }
        return arr
    }
}

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
    func pressable(scale: CGFloat = 0.94, opacity: Double = 0.82) -> some View {
        self.modifier(PressableEffect(scale: scale, opacity: opacity))
    }

    /// SwiftUI 没内建的 if：条件为 true 才套用 transform，否则原样返回
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var monitor: ClipboardMonitor
    @EnvironmentObject var network: NetworkService

    /// 当前快捷按钮顺序（本地状态，拖拽中改它，松手回写 AppStorage）
    @State private var actionOrder: [QuickAction] = [.pull, .wxwork, .weixin, .xianyu]

    /// 拖拽重排：当前正被长按拖的按钮
    @State private var dragging: QuickAction? = nil
    /// 拖拽中的平移偏移
    @State private var dragOffset: CGSize = .zero
    /// 编辑模式（进入编辑模式才能拖）
    @State private var editing: Bool = false
    /// TCC 权限被拒绝 Alert
    @State private var showTCCDeniedAlert: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusCard
                quickActionBar
                historyList
            }
            .navigationTitle("剪贴板同步")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        Menu {
                            Button(action: {
                                withAnimation { editing.toggle() }
                            }) {
                                Label(editing ? "完成排序" : "调整按钮顺序",
                                      systemImage: editing ? "checkmark" : "slider.horizontal.3")
                            }
                            Button(action: { resetButtonOrder() }) {
                                Label("恢复默认顺序", systemImage: "arrow.counterclockwise")
                            }
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                        }
                        NavigationLink {
                            SettingsView()
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
        }
        .onAppear {
            monitor.start(settings: settings, network: network)
            loadButtonOrder()
            Task { await monitor.refreshHistory() }
        }
        .onChange(of: editing) { _, isEditing in
            // 退出编辑模式：写回持久化
            if !isEditing { persistButtonOrder() }
        }
        .onChange(of: settings.autoMonitor) { _, enabled in
            // 用户在设置里切了自动监听开关 → 启停 Timer
            monitor.applyAutoMonitorSetting(enabled: enabled)
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

    @State private var pasteInFlight: Bool = false

    // MARK: - 顶部状态卡
    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(monitor.monitoring ? Color.green : Color.gray)
                    .frame(width: 10, height: 10)
                Text(settings.autoMonitor ? "自动监听" : "手动模式")
                    .font(.headline)
                Spacer()
                if pasteInFlight || network.isUploading {
                    ProgressView().scaleEffect(0.7)
                }
                // 「粘贴」按钮：点击才读取剪贴板并上传
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
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.clipboard.fill")
                        Text("粘贴")
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.blue.opacity(0.15))
                    .foregroundStyle(Color.blue)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .pressable(scale: 0.95, opacity: 0.85)
                .disabled(pasteInFlight)
            }
            Text("当前剪贴板：")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(monitor.currentClipboard.isEmpty ? "（空）" : String(monitor.currentClipboard.prefix(80)))
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

    // MARK: - 快捷按钮栏（一行 4 个图标 + 可长按拖拽重排）
    private var quickActionBar: some View {
        HStack(spacing: 12) {
            ForEach(actionOrder) { act in
                quickActionButton(act)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func quickActionButton(_ act: QuickAction) -> some View {
        let isDragging = dragging == act

        Button {
            // 编辑模式下点按钮不执行操作（此时专门用来拖位置）
            guard !editing else { return }
            Task { await handleAction(act) }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: act.icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 34, height: 34)
                    .foregroundStyle(act.tint)
                    .background(
                        Circle()
                            .fill(act.tint.opacity(0.12))
                            .frame(width: 56, height: 56)
                    )
                Text(act.title)
                    .font(.caption2)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(editing ? Color.orange.opacity(0.8) : Color.clear, lineWidth: 1.5)
            )
            .overlay(alignment: .topTrailing) {
                if editing {
                    Image(systemName: "line.3.horizontal")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 14, height: 14)
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(Circle().fill(.orange))
                        .padding(4)
                        .transition(.scale)
                }
            }
            .scaleEffect(isDragging ? 1.15 : 1.0)
            .shadow(color: isDragging ? .black.opacity(0.18) : .clear, radius: 8, y: 4)
            .offset(isDragging ? dragOffset : .zero)
            .zIndex(isDragging ? 1 : 0)
            .contentShape(Rectangle())
            .pressable()  // ← 按下缩放 + 咔哒触感（DragGesture minDistance 0，不抢 Button action）
            // ⭐️ 只在编辑模式才挂 拖 + 长按 手势，避免和普通按钮点击冲突
            .if(editing) { view in
                view
                    .gesture(dragGesture(for: act))
                    .simultaneousGesture(longPressGesture(for: act))
            }
        }
        .buttonStyle(.plain)  // ← 用 plain 系统 ButtonStyle，别叠加任何效果（都在 pressable() 里处理）
        .disabled(act == .pull && monitor.isPulling)
        .overlay {
            if act == .pull && monitor.isPulling {
                ProgressView().scaleEffect(0.9)
            }
        }
    }

    /// 按钮点击行为：企微/微信/闲鱼 — 按顺序试多个 scheme，能打开就立刻跳（零延迟）
    private func handleAction(_ act: QuickAction) async {
        switch act {
        case .pull:
            await monitor.pullFromServer()
            if monitor.pullStatus == "已写入剪贴板" || monitor.pullStatus == "已是最新" {
                PasteHaptic.pullSuccess()
            }
        case .wxwork, .weixin, .xianyu:
            // 先把"按下时响起的触感"叠一层成功音（让用户知道识别了）
            PasteHaptic.copy()
            // 按优先级试多个 URL scheme，第一个能开的就立刻开（completionHandler 版本不用 await，零延迟）
            for url in act.openURLCandidates {
                if UIApplication.shared.canOpenURL(url) {
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                    return
                }
            }
            // 所有 scheme 都打不开 → 兜底跳 App Store 搜索页
            PasteHaptic.error()
            let escaped = act.appStoreSearch.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let store = URL(string: "https://apps.apple.com/cn/search?term=\(escaped)") {
                UIApplication.shared.open(store, options: [:], completionHandler: nil)
            }
        }
    }

    // MARK: - 拖拽 + 长按
    private func longPressGesture(for act: QuickAction) -> some Gesture {
        LongPressGesture(minimumDuration: 0.4)
            .onEnded { success in
                guard success else { return }
                // 只要长按就自动进编辑模式
                withAnimation(.easeInOut(duration: 0.15)) {
                    editing = true
                    dragging = act
                }
            }
    }

    private func dragGesture(for act: QuickAction) -> some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { val in
                guard dragging == act else { return }
                dragOffset = val.translation
                // 根据当前 translation 推断与哪个按钮位置重叠，然后交换顺序
                if let targetIndex = actionOrder.firstIndex(of: act),
                   let draggedIndex = actionOrder.firstIndex(of: act) {
                    // 通过手指位置推断目标：粗略按 X 方向平移距离计算
                    let step: CGFloat = 90 // 每格大约 90pt
                    let offsetIdx = Int(round(val.translation.width / step))
                    var newIdx = draggedIndex + offsetIdx
                    newIdx = max(0, min(actionOrder.count - 1, newIdx))
                    if newIdx != targetIndex {
                        withAnimation(.interactiveSpring()) {
                            actionOrder.move(
                                fromOffsets: IndexSet(integer: draggedIndex),
                                toOffset: newIdx > draggedIndex ? newIdx + 1 : newIdx
                            )
                        }
                    }
                }
            }
            .onEnded { _ in
                withAnimation(.spring()) {
                    dragOffset = .zero
                    dragging = nil
                }
                // 松手后保持编辑模式，让用户可以继续拖；下次退出时才保存
            }
    }

    // MARK: - 按钮顺序持久化
    private func loadButtonOrder() {
        let raw = settings.quickActionOrderRaw
        let parts = raw.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var loaded: [QuickAction] = []
        for p in parts {
            if let a = QuickAction(rawValue: p) { loaded.append(a) }
        }
        // 防止缺项：保证 4 个按钮都存在且不重复
        for a in QuickAction.allCases where !loaded.contains(a) { loaded.append(a) }
        if loaded.count > QuickAction.allCases.count {
            loaded = Array(loaded.prefix(QuickAction.allCases.count))
        }
        actionOrder = loaded
    }

    private func persistButtonOrder() {
        let raw = actionOrder.map(\.rawValue).joined(separator: ",")
        settings.quickActionOrderRaw = raw
    }

    private func resetButtonOrder() {
        withAnimation {
            actionOrder = [.pull, .wxwork, .weixin, .xianyu]
        }
        persistButtonOrder()
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
