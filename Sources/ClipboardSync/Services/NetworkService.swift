import Foundation
import Combine
import UIKit

/// 网络服务：负责与电脑端服务器通信
/// 对应 server.py 中的：
///   - POST /api/set     上传文字
///   - GET  /api/get     拉取最新内容
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
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        // 允许 HTTP 明文（服务器非 HTTPS）
        config.allowsCellularAccess = true
        session = URLSession(configuration: config)
    }

    /// 上传文字内容
    /// - Returns: true 表示上传成功
    @discardableResult
    func uploadText(_ text: String, serverURL: String) async -> Bool {
        guard !text.isEmpty else { return false }
        let url = URL(string: "\(serverURL)/api/set")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 8

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

    /// 拉取服务器最新剪贴板内容
    func fetchLatest(serverURL: String) async -> ClipboardPayload? {
        let url = URL(string: "\(serverURL)/api/get")!
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 8

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            let parsed = try? decoder.decode(ClipboardResponse.self, from: data)
            return parsed?.current
        } catch {
            return nil
        }
    }

    /// 拉取历史记录
    func fetchHistory(serverURL: String, limit: Int = 30) async -> [HistoryEntry] {
        let url = URL(string: "\(serverURL)/api/history?limit=\(limit)")!
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 8

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

    /// 写入手机剪贴板
    @MainActor
    func setLocalClipboard(_ text: String) {
        UIPasteboard.general.string = text
    }
}
