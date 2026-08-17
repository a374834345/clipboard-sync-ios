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
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func start(settings: AppSettings, network: NetworkService) {
        self.settings = settings
        self.network = network
        guard !monitoring else { return }
        monitoring = true
        // 初始记录当前剪贴板内容，避免启动时立即上传
        currentClipboard = UIPasteboard.general.string ?? ""
        settings.lastUploadedContent = currentClipboard
        startTimer()
    }

    func stop() {
        monitoring = false
        timer?.invalidate()
        timer = nil
    }

    private func startTimer() {
        timer?.invalidate()
        let interval = settings?.checkInterval ?? 1.0
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.checkOnce()
        }
        // 加入 common runloop 模式，滑动时不停止
        RunLoop.main.add(timer!, forMode: .common)
    }

    /// 主动检查一次剪贴板变化
    func checkOnce() {
        guard monitoring,
              let settings = settings,
              let network = network,
              settings.autoUploadEnabled else {
            lastCheckedAt = Date()
            return
        }

        let now = UIPasteboard.general.string ?? ""
        lastCheckedAt = Date()

        // 空内容或长度不足，跳过
        if now.isEmpty || now.count < settings.minLength { return }

        // 与上次上传内容相同，跳过
        if now == settings.lastUploadedContent || now == currentClipboard {
            return
        }

        // iOS 系统自身的剪贴板访问控制：第一次读取时若有 banner 提示，仍会返回内容
        currentClipboard = now

        Task { [weak self] in
            let ok = await network.uploadText(now, serverURL: settings.normalizedServerURL)
            await MainActor.run {
                if ok {
                    settings.lastUploadedContent = now
                    self?.currentClipboard = now
                }
            }
        }
    }

    // MARK: - 后台保活

    @objc private func appDidEnterBackground() {
        // 申请后台运行时间
        bgTaskIdentifier = UIApplication.shared.beginBackgroundTask(withName: "ClipboardSyncBG") { [weak self] in
            self?.endBackgroundTask()
        }
        // 后台使用更低频率的 timer
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.checkOnce()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    @objc private func appWillEnterForeground() {
        endBackgroundTask()
        startTimer()
        // 前台恢复时立即检查一次
        checkOnce()
    }

    /// BGTaskScheduler 唤醒时触发
    @objc private func handleBackgroundTick() {
        checkOnce()
    }

    private func endBackgroundTask() {
        if bgTaskIdentifier != .invalid {
            UIApplication.shared.endBackgroundTask(bgTaskIdentifier)
            bgTaskIdentifier = .invalid
        }
    }

    // MARK: - 从服务器拉取内容到手机剪贴板

    /// 从服务器拉取最新内容，写入手机剪贴板
    func pullFromServer() async {
        guard let settings = settings, let network = network else { return }
        await MainActor.run { isPulling = true; pullStatus = "拉取中…" }

        let payload = await network.fetchLatest(serverURL: settings.normalizedServerURL)
        await MainActor.run {
            isPulling = false
            guard let payload = payload, !payload.content.isEmpty else {
                pullStatus = "服务器无内容"
                return
            }
            // 如果服务器内容与手机剪贴板相同，不重复写入
            if payload.content == UIPasteboard.general.string {
                pullStatus = "已是最新"
                return
            }
            UIPasteboard.general.string = payload.content
            currentClipboard = payload.content
            // 标记为已上传，避免本地监听又把它传回去
            settings.lastUploadedContent = payload.content
            lastPulledFromServer = payload.content
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
