import Foundation

/// 极简 HTTP/1.1 请求/响应数据结构与解析器，专门服务 `HTTPServer` 的本地通信场景。
///
/// 不依赖任何第三方解析库——hey-clawd 的 hook 协议固定为本机短连接、单请求-单响应、
/// 没有 chunked / keep-alive / multipart。把范围控制小，代码可读性优于通用性。

struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]  // key 已统一小写，查找时无需关心大小写
    let body: Data
}

struct HTTPResponse: Sendable {
    let statusCode: Int
    var headers: [String: String]
    let body: Data?

    /// 序列化为原始 HTTP/1.1 响应报文：状态行 + 头部 + \r\n\r\n + body
    func serialize() -> Data {
        let bodyData = body ?? Data()
        var responseHeaders = headers

        if responseHeaders["Content-Length"] == nil {
            responseHeaders["Content-Length"] = String(bodyData.count)
        }

        // 每个连接只处理一个请求，响应后即关闭
        if responseHeaders["Connection"] == nil {
            responseHeaders["Connection"] = "close"
        }

        var lines = ["HTTP/1.1 \(statusCode) \(reasonPhrase(for: statusCode))"]
        // 排序仅为输出稳定，方便回归对比；HTTP 协议本身不强制头部顺序。
        for (key, value) in responseHeaders.sorted(by: { $0.key < $1.key }) {
            lines.append("\(key): \(value)")
        }
        // 空行分隔头部和 body（HTTP 协议要求）
        lines.append("")
        lines.append("")

        var data = Data(lines.joined(separator: "\r\n").utf8)
        data.append(bodyData)
        return data
    }

    /// 仅覆盖本项目实际会返回的状态码；其他状态码统一回 "Unknown" 不阻塞响应。
    private func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200:
            return "OK"
        case 400:
            return "Bad Request"
        case 404:
            return "Not Found"
        case 413:
            return "Payload Too Large"
        case 500:
            return "Internal Server Error"
        case 503:
            return "Service Unavailable"
        default:
            return "Unknown"
        }
    }
}

/// 轻量级 HTTP/1.1 请求解析器，支持增量解析。
/// buffer 数据不足时返回 nil，调用方可继续追加数据后重试。
enum HTTPParser {
    private static let headerSeparator = Data("\r\n\r\n".utf8)

    static func parseRequest(_ data: Data) -> HTTPRequest? {
        // 头部尚未接收完整（缺少 \r\n\r\n 分隔符），等待更多数据
        guard let headerRange = data.range(of: headerSeparator) else {
            return nil
        }

        let headerData = data.subdata(in: data.startIndex..<headerRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        // 解析请求行：METHOD PATH HTTP/1.1
        var lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return nil
        }
        lines.removeFirst()

        let requestLineParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        // 强制 HTTP/1.1：本地 hook 固定走 1.1，1.0/2.0/SSE 一律拒绝避免误用。
        guard requestLineParts.count == 3, requestLineParts[2] == "HTTP/1.1" else {
            return nil
        }

        // 解析头部，key 统一小写以便后续查找
        var headers = [String: String]()
        for line in lines where !line.isEmpty {
            guard let separatorIndex = line.firstIndex(of: ":") else {
                return nil
            }

            let key = line[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separatorIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        // 根据 Content-Length 确定 body 边界；body 数据不足时返回 nil 等待更多数据
        let bodyStartIndex = headerRange.upperBound
        let contentLength = Int(headers["content-length"] ?? "0") ?? -1
        // 负数 / 非法值视为协议错误，直接放弃；防止对端构造异常长度。
        guard contentLength >= 0 else {
            return nil
        }

        let bodyEndIndex = bodyStartIndex + contentLength
        guard data.count >= bodyEndIndex else {
            return nil
        }

        let body = data.subdata(in: bodyStartIndex..<bodyEndIndex)
        return HTTPRequest(
            method: String(requestLineParts[0]),
            path: String(requestLineParts[1]),
            headers: headers,
            body: body
        )
    }
}
