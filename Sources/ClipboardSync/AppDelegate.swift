import UIKit
import BackgroundTasks
import MobileCoreServices

/// AppDelegate：负责注册后台任务、保活，以及剪贴板授权预热
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        // ========== 剪贴板访问"预热"：降低后续读取触发 iOS banner 的概率 ==========
        // 原理：App 启动时主动对 UIPasteboard 执行一次写+读，让 SpringBoard 记住
        // 本 App 的剪贴板访问"善意意图"，配合 TrollStore 安装 +
        // com.apple.pasteboard.read-automatic entitlement，基本可以做到不再弹顶部横幅。
        DispatchQueue.main.async {
            let pb = UIPasteboard.general
            let existing = pb.string ?? ""
            // 写自己一次（内容不变），触发 changeCount 自增但内容不变，
            // 下次 ClipboardMonitor 会判断内容相同而跳过上传。
            pb.string = existing

            // 尝试请求剪贴板持久授权（iOS 16+ 私有 API，TrollStore 环境会放行）
            if pb.responds(to: Selector(("_grantAccessIfNeeded"))) {
                _ = pb.perform(Selector(("_grantAccessIfNeeded")))
            }
            // iOS 14+ 另一个常见私有钩子：设置 presentingVC 来避免权限弹窗
            if pb.responds(to: Selector(("_setPermissionBlock:forUserInterface:item:atIndex:forAccess:withCompletionBlock:"))) {
                // 不调用，仅保留判断用于调试
            }
        }

        // 注册后台任务标识（在 Info.plist 中同样声明）
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.clipboardsync.refresh", using: nil) { task in
            self.handleAppRefresh(task: task as! BGAppRefreshTask)
        }
        return true
    }

    /// 应用进入后台时调度保活任务
    func applicationDidEnterBackground(_ application: UIApplication) {
        scheduleAppRefresh()
    }

    /// 调度下次后台刷新（iOS 给的窗口约 30 秒）
    func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: "com.clipboardsync.refresh")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("调度后台刷新失败：\(error)")
        }
    }

    /// 后台刷新回调：拉一次剪贴板，若变化则上传，再继续调度
    private func handleAppRefresh(task: BGAppRefreshTask) {
        scheduleAppRefresh()
        let taskIdentifier = UIApplication.shared.beginBackgroundTask(withName: "clipboard-bg")

        NotificationCenter.default.post(name: .clipboardBackgroundTick, object: nil)

        task.expirationHandler = {
            UIApplication.shared.endBackgroundTask(taskIdentifier)
        }

        // 30 秒后结束本次后台任务
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
            task.setTaskCompleted(success: true)
            UIApplication.shared.endBackgroundTask(taskIdentifier)
        }
    }
}

extension Notification.Name {
    static let clipboardBackgroundTick = Notification.Name("clipboardBackgroundTick")
}
