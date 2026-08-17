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

    /// 规范化服务器地址：去除末尾斜杠
    var normalizedServerURL: String {
        var url = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") {
            url.removeLast()
        }
        return url
    }
}
