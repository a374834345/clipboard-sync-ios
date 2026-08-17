import Foundation

/// 服务器返回的最新剪贴板内容
struct ClipboardPayload: Codable, Equatable {
    let type: String
    let content: String
    let timestamp: String?
}

/// /api/get 接口返回结构
struct ClipboardResponse: Codable {
    let current: ClipboardPayload?
    let history: [HistoryEntry]?
}

/// 历史记录条目
struct HistoryEntry: Codable, Identifiable, Equatable {
    let id: String?
    let type: String
    let content: String
    let timestamp: String?

    enum CodingKeys: String, CodingKey {
        case id, type, content, timestamp
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try? c.decode(String.self, forKey: .id)
        type = (try? c.decode(String.self, forKey: .type)) ?? "text"
        content = (try? c.decode(String.self, forKey: .content)) ?? ""
        timestamp = try? c.decode(String.self, forKey: .timestamp)
    }
}

/// /api/set 上传请求体
struct UploadRequest: Codable {
    let type: String
    let content: String
    let timestamp: String
}

/// /api/set 上传响应
struct UploadResponse: Codable {
    let success: Bool
    let message: String?
    let id: String?
    let timestamp: String?
}
