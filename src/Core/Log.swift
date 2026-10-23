import Foundation

private let logFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MM-dd HH:mm:ss.SSS"
    return f
}()

/// 单文件日志，超过 1MB 自动轮转（覆盖式，保留最近一段）
func log(_ msg: String) {
    let line = "[\(logFormatter.string(from: Date()))] \(msg)\n"
    guard let data = line.data(using: .utf8) else { return }

    let url = AppPaths.logFileURL
    if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
       let size = attrs[.size] as? Int, size > 1_000_000 {
        try? FileManager.default.removeItem(at: url)
    }

    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile()
        h.write(data)
        try? h.close()
    } else {
        try? data.write(to: url)
    }
}

/// 追加文本到文件（诊断输出用）
func appendText(_ text: String, to url: URL) {
    guard let data = text.data(using: .utf8) else { return }
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile()
        h.write(data)
        try? h.close()
    } else {
        try? data.write(to: url)
    }
}
