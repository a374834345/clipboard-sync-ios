import UIKit
import BackgroundTasks

/// AppDelegate：负责注册后台任务、保活
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
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
