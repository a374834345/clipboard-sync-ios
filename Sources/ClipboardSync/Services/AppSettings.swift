import Foundation
import Combine
import SwiftUI

/// 应用配置：持久化服务器地址、上传间隔、自动上传开关
final class AppSettings: ObservableObject {
    @AppStorage("serverURL") var serverURL: String = "http://124.222.192.226:55555"
    @AppStorage("autoUploadEnabled") var autoUploadEnabled: Bool = true
    @AppStorage("autoPullEnabled") var autoPullEnabled: Bool = false
    @AppStorage("checkInterval") var checkInterval: Double = 1.0
    @AppStorage("minLength") var minLength: Int = 1
    @AppStorage("lastUploadedContent") var lastUploadedContent: String = ""
    @AppStorage("lastPulledTimestamp") var lastPulledTimestamp: String = ""
    /// 底部快捷按钮顺序（rawValue 逗号分隔）：pull / wxwork / weixin / xianyu
    @AppStorage("quickActionOrder") var quickActionOrderRaw: String = "pull,wxwork,weixin,xianyu"
    /// 是否自动后台轮询剪贴板（默认 false：只有用户手动点「粘贴」按钮才读取并上传）
    @AppStorage("autoMonitor") var autoMonitor: Bool = false

    // MARK: - 自定义 App 封面

    /// 沙盒 Documents 目录下自定义封面的文件名
    static let coverFileName: String = "app-custom-cover.jpg"

    /// 自定义封面完整本地路径（FileManager.SearchPathForDirectoriesInDomains(.documentDirectory,...)）
    static var coverURL: URL {
        let fm = FileManager.default
        let docs = (try? fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return docs.appendingPathComponent(AppSettings.coverFileName, isDirectory: false)
    }

    /// 封面是否存在（给 SwiftUI UI 监听用 @Published，每次写/删同步切换）
    @Published var hasCustomCover: Bool = FileManager.default.fileExists(atPath: AppSettings.coverURL.path)

    /// 加载自定义封面（不存在返回 nil，UI 显示默认占位）
    func loadCoverImage() -> UIImage? {
        guard let data = try? Data(contentsOf: AppSettings.coverURL) else { return nil }
        return UIImage(data: data)
    }

    /// 保存 UIImage 为 JPEG 到 Documents，并刷新 hasCustomCover
    /// - Parameters:
    ///   - image: 原图
    ///   - maxEdge: 最长边像素上限（默认 2048，超过就按比例缩），防止超大图占空间
    ///   - quality: JPEG 质量 0~1
    /// - Returns: 成功/失败 + 消息
    @discardableResult
    func saveCoverImage(_ image: UIImage, maxEdge: CGFloat = 2048, quality: CGFloat = 0.85) -> (Bool, String) {
        let target = image.scaled(toFitMaxEdge: maxEdge)
        guard let data = target.jpegData(compressionQuality: quality) else {
            return (false, "❌ 图片转 JPEG 失败")
        }
        do {
            if FileManager.default.fileExists(atPath: AppSettings.coverURL.path) {
                try FileManager.default.removeItem(at: AppSettings.coverURL)
            }
            try data.write(to: AppSettings.coverURL, options: [.atomic])
            DispatchQueue.main.async { self.hasCustomCover = true }
            let kb = data.count / 1024
            return (true, "✅ 已保存自定义封面（\(kb) KB）")
        } catch {
            return (false, "❌ 保存失败：\(error.localizedDescription)")
        }
    }

    /// 删除自定义封面，恢复默认
    @discardableResult
    func deleteCustomCover() -> (Bool, String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: AppSettings.coverURL.path) else {
            return (false, "没有自定义封面，当前已是默认")
        }
        do {
            try fm.removeItem(at: AppSettings.coverURL)
            DispatchQueue.main.async { self.hasCustomCover = false }
            return (true, "✅ 已恢复默认封面")
        } catch {
            return (false, "❌ 删除失败：\(error.localizedDescription)")
        }
    }

    /// 规范化服务器地址：去除末尾斜杠
    var normalizedServerURL: String {
        var url = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") {
            url.removeLast()
        }
        return url
    }
}

// MARK: - UIImage 按最长边缩放（保持宽高比）
extension UIImage {
    func scaled(toFitMaxEdge maxEdge: CGFloat) -> UIImage {
        let w = size.width, h = size.height
        if max(w, h) <= maxEdge { return self }
        let scale = maxEdge / max(w, h)
        let newSize = CGSize(width: w * scale, height: h * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            self.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
