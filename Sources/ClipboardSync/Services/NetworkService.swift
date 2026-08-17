import Foundation
import Combine
import UIKit

/// 网络服务：负责与电脑端服务器通信
/// 对应 server.py 中的：
///   - POST /api/set     上传文字
///   - GET  /raw         拉取纯文字（更快）
///   - GET  /api/get     拉取完整 JSON（含 type/timestamp，备用）
///   - GET  /api/history 拉取历史
final class NetworkService: ObservableObject {
    @Published var isUploading: Bool = false
    @Published var lastError: String?
    @Published var lastUploadedAt: Date?

    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init() {
        let config = URLSessionConfiguration.default
        // 更短的超时 + HTTP 连接复用（Keep-Alive 默认开启）
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 8
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldUsePipelining = true
        config.httpShouldSetCookies = false
        config.allowsCellularAccess = true
        // 提升 HTTP 优先级，减少首包延迟
        if #available(iOS 17.0, *) {
            config.multipathServiceType = .handover
        }
        session = URLSession(configuration: config)
    }

    /// 上传文字内容
    /// - Returns: true 表示上传成功
    @discardableResult
    func uploadText(_ text: String, serverURL: String) async -> Bool {
        guard !text.isEmpty else { return false }
        guard let url = URL(string: "\(serverURL)/api/set") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Keep-Alive", forHTTPHeaderField: "Connection")
        req.timeoutInterval = 4

        let ts = ISO8601DateFormatter().string(from: Date())
        let body = UploadRequest(type: "text", content: text, timestamp: ts)
        guard let data = try? encoder.encode(body) else {
            await MainActor.run { self.lastError = "编码失败" }
            return false
        }
        req.httpBody = data

        await MainActor.run {
            self.isUploading = true
            self.lastError = nil
        }

        do {
            let (responseData, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                await MainActor.run {
                    self.isUploading = false
                    self.lastError = "HTTP \(code)"
                }
                return false
            }
            let parsed = try? decoder.decode(UploadResponse.self, from: responseData)
            let ok = parsed?.success ?? false
            await MainActor.run {
                self.isUploading = false
                if ok {
                    self.lastUploadedAt = Date()
                } else {
                    self.lastError = parsed?.message ?? "上传失败"
                }
            }
            return ok
        } catch {
            await MainActor.run {
                self.isUploading = false
                self.lastError = error.localizedDescription
            }
            return false
        }
    }

    /// 拉取服务器最新剪贴板文字（用 /raw 纯文本接口，比 /api/get 少一次 JSON 解码，更快）
    /// - Returns: 服务器最新文字内容，空或失败返回 nil
    func fetchLatestRaw(serverURL: String) async -> String? {
        guard let url = URL(string: "\(serverURL)/raw") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Keep-Alive", forHTTPHeaderField: "Connection")
        req.timeoutInterval = 3

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            let text = String(data: data, encoding: .utf8) ?? ""
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }

    /// 兼容：保留 fetchLatest，但内部改为走 /raw 再合成 ClipboardPayload
    func fetchLatest(serverURL: String) async -> ClipboardPayload? {
        guard let text = await fetchLatestRaw(serverURL: serverURL) else { return nil }
        return ClipboardPayload(type: "text", content: text, timestamp: nil)
    }

    /// 拉取历史记录
    func fetchHistory(serverURL: String, limit: Int = 30) async -> [HistoryEntry] {
        guard let url = URL(string: "\(serverURL)/api/history?limit=\(limit)") else { return [] }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Keep-Alive", forHTTPHeaderField: "Connection")
        req.timeoutInterval = 4

        do {
            struct HistoryResponse: Codable {
                let success: Bool
                let history: [HistoryEntry]
                let total: Int
            }
            let (data, _) = try await session.data(for: req)
            let parsed = try? decoder.decode(HistoryResponse.self, from: data)
            return parsed?.history ?? []
        } catch {
            return []
        }
    }

    /// 写入手机剪贴板（同时设置 changeCount 避免被自己的监听器再上传回去）
    @MainActor
    func setLocalClipboard(_ text: String, suppressChangeCount: inout Int?) {
        UIPasteboard.general.string = text
        // UIPasteboard 的 changeCount 每写一次自增，下次检测到同值 + 同 changeCount 就跳过
        suppressChangeCount = UIPasteboard.general.changeCount
    }
}
