import Foundation
import Combine
import UIKit

/// 剪贴板监听：定时轮询 UIPasteboard.general，检测变化后上传
///
/// 后台保活策略：
/// 1. 前台时使用 Timer 每 `checkInterval` 秒检查一次
/// 2. 进入后台时启动 backgroundTask，继续运行直到系统挂起
/// 3. 通过 BGTaskScheduler 周期性唤醒（详见 AppDelegate）
/// 4. TrollStore + ImmortalizerTS 可延长后台运行时间
///
/// 弹窗优化（iOS 14+ 剪贴板访问提示横幅）：
/// 1. 默认检查间隔从 1s 提到 2s，减少读取频率
/// 2. 先用 changeCount 判断是否真的变化（不触发 banner），只有 changeCount 变了才读 .string
/// 3. 本地拉取写入剪贴板后记录 changeCount，下一 tick 直接跳过，避免自触发
@MainActor
final class ClipboardMonitor: ObservableObject {
    @Published var monitoring: Bool = false
    @Published var lastCheckedAt: Date?
    @Published var currentClipboard: String = ""
    @Published var pullStatus: String = "空闲"
    @Published var history: [HistoryEntry] = []
    @Published var isPulling: Bool = false
    @Published var lastPulledFromServer: String?

    private var timer: Timer?
    private var bgTaskIdentifier: UIBackgroundTaskIdentifier = .invalid
    private var observers: [NSObjectProtocol] = []

    /// 记录"本 App 写入剪贴板时的 changeCount"，检测到相同值直接跳过（避免自触发 + 避免 banner）
    private var suppressChangeCount: Int? = nil

    /// 记录上一次的 UIPasteboard changeCount（不读 string 也能发现变化）
    private var lastChangeCount: Int = UIPasteboard.general.changeCount

    /// 注入 settings/network 让 monitor 调用
    weak var settings: AppSettings?
    weak var network: NetworkService?

    init() {
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground),
                                                 name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground),
                                                 name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleBackgroundTick),
                                                 name: .clipboardBackgroundTick, object: nil)
        // ContentView 用户点历史条目复制时，会把 changeCount 发过来
        NotificationCenter.default.addObserver(forName: .clipboardSuppressNextChange,
                                               object: nil, queue: .main) { [weak self] notif in
            guard let cc = notif.object as? Int else { return }
            Task { @MainActor [weak self] in
                self?.suppressChangeCount = cc
                self?.lastChangeCount = cc
            }
        }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func start(settings: AppSettings, network: NetworkService) {
        self.settings = settings
        self.network = network
        guard !monitoring else { return }
        monitoring = true
        // 启动时仅记录 changeCount（不读 .string，避免启动就弹"允许粘贴"横幅）
        lastChangeCount = UIPasteboard.general.changeCount
        // 根据设置决定是否启动自动轮询
        if settings.autoMonitor {
            startTimer()
        }
    }

    func stop() {
        monitoring = false
        timer?.invalidate()
        timer = nil
    }

    /// autoMonitor 开关变化外部调用：启停 Timer
    func applyAutoMonitorSetting(enabled: Bool) {
        if enabled {
            startTimer()
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    /// 手动粘贴的结果
    enum ManualResult: String {
        case ok             // 成功上传（或已相同）
        case uploadFailed   // 网络失败
        case contentTooShort// 内容为空 / 长度不足（正常情况，真的没复制东西）
        case permissionDenied // TCC 拒绝导致读不到
    }

    /// 用户手动点「粘贴」按钮：强制读取当前剪贴板 + 上传
    @discardableResult
    func manualPasteAndUpload() async -> ManualResult {
        guard let settings = settings,
              let network = network,
              settings.autoUploadEnabled else {
            lastCheckedAt = Date()
            return .ok
        }
        lastCheckedAt = Date()
        let pb = UIPasteboard.general
        let rawString = pb.string
        let now = rawString ?? ""
        // 记录本次 changeCount，避免 autoMonitor 如果启用后自触发上传
        lastChangeCount = pb.changeCount
        currentClipboard = now

        // TCC 拒绝启发式：hasStrings == true 但读到的是空/nil → 系统把内容截断了（权限拒绝）
        if pb.hasStrings && now.isEmpty {
            return .permissionDenied
        }
        if now.isEmpty || now.count < settings.minLength {
            return .contentTooShort
        }
        if now == settings.lastUploadedContent {
            // 和上次相同：不重复上传，但也响一声给用户反馈
            PasteHaptic.copy()
            return .ok
        }
        let ok = await network.uploadText(now, serverURL: settings.normalizedServerURL)
        if ok {
            settings.lastUploadedContent = now
            currentClipboard = now
            PasteHaptic.copy()
            return .ok
        } else {
            PasteHaptic.error()
            return .uploadFailed
        }
    }

    @Published var manualIsProcessing: Bool = false

    private func startTimer() {
        timer?.invalidate()
        let interval = settings?.checkInterval ?? 2.0
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkOnce()
            }
        }
        // 加入 common runloop 模式，滑动时不停止
        RunLoop.main.add(timer!, forMode: .common)
    }

    /// 主动检查一次剪贴板变化（核心：先看 changeCount，没变化就不读 string，从而不触发 banner）
    func checkOnce() {
        guard monitoring,
              let settings = settings,
              let network = network,
              settings.autoUploadEnabled else {
            lastCheckedAt = Date()
            return
        }

        lastCheckedAt = Date()
        let pb = UIPasteboard.general
        let nowCount = pb.changeCount

        // 1) changeCount 没变 → 剪贴板没动 → 直接返回，零 banner
        if nowCount == lastChangeCount { return }

        // 2) changeCount 变了，但是是我们自己写入产生的那个值 → 跳过（避免 banner + 避免自循环上传）
        if let sup = suppressChangeCount, nowCount == sup {
            lastChangeCount = nowCount
            return
        }

        // 3) 真正的外部变化，此时必须读 .string（会触发一次 iOS 剪贴板横幅，但这是用户真的复制了）
        lastChangeCount = nowCount
        let now = pb.string ?? ""

        // 空内容或长度不足，跳过
        if now.isEmpty || now.count < settings.minLength { return }

        // 与上次上传内容相同，跳过
        if now == settings.lastUploadedContent || now == currentClipboard {
            return
        }

        currentClipboard = now

        Task { @MainActor [weak self, weak settings, weak network] in
            guard let self = self, let settings = settings, let network = network else { return }
            let ok = await network.uploadText(now, serverURL: settings.normalizedServerURL)
            if ok {
                settings.lastUploadedContent = now
                self.currentClipboard = now
            }
        }
    }

    // MARK: - 后台保活

    @objc private func appDidEnterBackground() {
        // 如果用户关闭了自动监听（autoMonitor=false）→ 切后台什么都不做（避免读 string 触发 banner）
        guard let autoMon = settings?.autoMonitor, autoMon else { return }
        // 申请后台运行时间
        bgTaskIdentifier = UIApplication.shared.beginBackgroundTask(withName: "ClipboardSyncBG") { [weak self] in
            self?.endBackgroundTask()
        }
        // 后台使用更低频率的 timer
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkOnce()
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    @objc private func appWillEnterForeground() {
        endBackgroundTask()
        // 只有 autoMonitor=true 才重新启前台 Timer（用户关掉了就不启，完全不读剪贴板，零横幅）
        if let autoMon = settings?.autoMonitor, autoMon {
            startTimer()
            // autoMonitor 开着时才额外检查一次（用户已经明确选了自动监听，接受可能的横幅）
            checkOnce()
        }
        // autoMonitor=false → 绝对不读剪贴板（用户要手动点「粘贴」）
    }

    /// BGTaskScheduler 唤醒时触发（也只有开了自动监听才执行）
    @objc private func handleBackgroundTick() {
        guard let autoMon = settings?.autoMonitor, autoMon else { return }
        checkOnce()
    }

    private func endBackgroundTask() {
        if bgTaskIdentifier != .invalid {
            UIApplication.shared.endBackgroundTask(bgTaskIdentifier)
            bgTaskIdentifier = .invalid
        }
    }

    // MARK: - 从服务器拉取内容到手机剪贴板

    /// 从服务器拉取最新内容，写入手机剪贴板（走 /raw 纯文本）
    func pullFromServer() async {
        guard let settings = settings, let network = network else { return }
        await MainActor.run { isPulling = true; pullStatus = "拉取中…" }

        let text = await network.fetchLatestRaw(serverURL: settings.normalizedServerURL)
        await MainActor.run {
            isPulling = false
            guard let text = text, !text.isEmpty else {
                pullStatus = "服务器无内容"
                return
            }
            let existing = UIPasteboard.general.string ?? ""
            if text == existing {
                pullStatus = "已是最新"
                return
            }
            // 写入剪贴板，并记录 changeCount → 下一 tick 检测到就跳过，不会触发 banner 也不会再上传回去
            var cc: Int? = nil
            network.setLocalClipboard(text, suppressChangeCount: &cc)
            if let cc = cc { self.suppressChangeCount = cc }
            currentClipboard = text
            settings.lastUploadedContent = text
            lastPulledFromServer = text
            pullStatus = "已写入剪贴板"
        }
    }

    /// 拉取历史记录列表
    func refreshHistory() async {
        guard let settings = settings, let network = network else { return }
        let list = await network.fetchHistory(serverURL: settings.normalizedServerURL, limit: 30)
        await MainActor.run { self.history = list }
    }
}
