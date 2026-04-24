import Foundation

final class FileLogger {
    let path: String
    private let queue = DispatchQueue(label: "farlock.logger")
    private let formatter: DateFormatter

    init(path: String) {
        self.path = (path as NSString).expandingTildeInPath
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        self.formatter = fmt
        let parent = (self.path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: parent, withIntermediateDirectories: true
        )
    }

    func log(_ msg: String) {
        let line = "\(formatter.string(from: Date())) \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        queue.async {
            if !FileManager.default.fileExists(atPath: self.path) {
                FileManager.default.createFile(atPath: self.path, contents: nil)
            }
            if let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: self.path)) {
                defer { try? fh.close() }
                _ = try? fh.seekToEnd()
                try? fh.write(contentsOf: data)
            }
            // Also mirror to stderr so launchd captures it in StandardErrorPath.
            FileHandle.standardError.write(data)
        }
    }
}
