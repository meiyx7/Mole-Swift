import Foundation

/// 统一操作日志：让 GUI 自研删除路径（AnalyzeDeleter / PurgeDeleter）
/// 也写入 CLI 的 `~/Library/Logs/mole/deletions.log`，格式对齐 CLI 的
/// `mole_delete` helper（`lib/core/file_ops.sh`）。
///
/// CLI 的 deletions.log 格式（tab 分隔）：
/// ```
/// <iso_ts>\t<mode>\t<size_kb>\t<status>\t<path>
/// ```
/// 例如：
/// ```
/// 2026-06-22T10:30:00Z\ttrash\t1024\ttrashed\t/Users/foo/Code/bar/node_modules
/// ```
///
/// 这样 `mo history --json` 能看到所有删除记录，无论来自 CLI 还是 GUI，
/// 符合 AGENTS.md 的操作日志契约。
///
/// 同时保留 GUI 自己的 `~/Library/Logs/MoleApp/{analyze,purge}.log` 详细日志
/// （含 trashedURL / error 等额外字段），用于 GUI 内部审计。
enum UnifiedOperationLog {

    /// CLI deletions.log 路径。与 `lib/core/file_ops.sh` 的 `MOLE_DELETE_LOG`
    /// 默认值一致。若环境变量 `MOLE_DELETE_LOG` 已设置则使用它。
    static var cliDeletionsLogURL: URL {
        let home = NSHomeDirectory()
        let logDir = URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Logs/mole")
        // 读取 CLI 的 MOLE_DELETE_LOG 环境变量（若设置）
        if let raw = getenv("MOLE_DELETE_LOG"),
           let s = String(cString: raw, encoding: .utf8),
           !s.isEmpty {
            return URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
        }
        return logDir.appendingPathComponent("deletions.log")
    }

    /// 追加一行到 CLI 的 deletions.log。
    ///
    /// - Parameters:
    ///   - path: 被删除的路径
    ///   - sizeBytes: 路径大小（字节）。未知时传 0，会写 "unknown" 与 CLI 一致。
    ///   - mode: "trash" 或 "permanent"
    ///   - status: "trashed" / "failed" / "skipped" 等
    ///   - error: 失败时的错误描述（可选）
    static func appendToCLIDeletionLog(
        path: String,
        sizeBytes: Int64,
        mode: String,
        status: String,
        error: String? = nil
    ) {
        let logURL = cliDeletionsLogURL
        let fm = FileManager.default

        // 确保目录存在
        try? fm.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // CLI 的 size_kb 字段：未知时写 "unknown"（与 mole_delete 一致）
        let sizeKB: String
        if sizeBytes > 0 {
            sizeKB = "\((sizeBytes + 1023) / 1024)" // 向上取整到 KB
        } else {
            sizeKB = "unknown"
        }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        // CLI 格式：iso_ts\tmode\tsize_kb\tstatus\tpath
        // 失败时在 path 后追加 error（CLI 没有这个字段，但 tab 分隔便于解析）
        var line = "\(timestamp)\t\(mode)\t\(sizeKB)\t\(status)\t\(path)"
        if let error = error, !error.isEmpty {
            line += "\t\(error)"
        }
        line += "\n"

        guard let data = line.data(using: .utf8) else { return }

        // 追加写，失败静默（日志不应阻塞主流程）
        if fm.fileExists(atPath: logURL.path) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }
}
