import Foundation
import Darwin

/// 伪终端任务：在 PTY 中运行一个子进程，让交互式 TUI 程序（如 `mo purge`
/// 的选择菜单）认为自己运行在真实终端里。
///
/// 参照 Burrow 的 PTYTask 实现：使用 `openpty` 创建主/从设备对，子进程
/// 的 stdin/stdout/stderr 都接到从设备，主设备用于读取输出和写入按键。
/// 输出和退出回调都派发到主线程，保证宿主 reducer 单线程访问。
///
/// 设计要点：
/// - `readabilityHandler` 保留原始转义序列（reducer 依赖完整重绘帧）
/// - 写入走专用串行队列，避免阻塞主线程；SIGPIPE 全局忽略防止写已退出
///   子进程时崩溃
/// - `reportedExit` 保证退出只上报一次（terminationHandler 和 EOF 都可能触发）
final class PTYTask {
    private var proc = Process()
    private var master: FileHandle?

    /// 输出回调（主线程）。原始字节，未剥离 ANSI。
    var onOutput: ((String) -> Void)?
    /// 退出回调（主线程）。
    var onExit: ((Int32) -> Void)?

    private var reportedExit = false
    private let cols: UInt16
    private let rows: UInt16

    /// `rows` 控制 Mole TUI 单帧渲染行数（上限约 50）；60 覆盖常见场景。
    init(cols: UInt16 = 120, rows: UInt16 = 60) {
        self.cols = cols
        self.rows = rows
        // 写已退出的子进程会触发 SIGPIPE，全局忽略后 write 返回 EPIPE 被
        // 吞掉。必须在进程启动前设置。
        signal(SIGPIPE, SIG_IGN)
    }

    private func reportExitOnce(_ code: Int32) {
        guard !reportedExit else { return }
        reportedExit = true
        onExit?(code)
    }

    /// 启动子进程。一个 Process 只能运行一次，重复调用会重建实例。
    func launch(_ executable: String, _ args: [String]) throws {
        proc = Process()
        reportedExit = false

        var amaster: Int32 = 0
        var aslave: Int32 = 0
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&amaster, &aslave, nil, nil, &ws) == 0 else {
            throw NSError(domain: "mole.pty", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "openpty failed"])
        }
        let slave = FileHandle(fileDescriptor: aslave, closeOnDealloc: false)
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        proc.standardInput = slave
        proc.standardOutput = slave
        proc.standardError = slave
        var env = Foundation.ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        proc.environment = env

        proc.terminationHandler = { [weak self] p in
            let code = p.terminationStatus
            DispatchQueue.main.async { self?.reportExitOnce(code) }
        }

        let m = FileHandle(fileDescriptor: amaster, closeOnDealloc: true)
        m.readabilityHandler = { [weak self] h in
            guard let self else { return }
            let d = h.availableData
            if d.isEmpty {
                // EOF：子进程关闭了 PTY（已退出）。停止读取，否则空数据
                // 处理器会死循环饿死 terminationHandler。
                h.readabilityHandler = nil
                if !self.proc.isRunning {
                    let code = self.proc.terminationStatus
                    DispatchQueue.main.async { self.reportExitOnce(code) }
                }
                return
            }
            guard let s = String(data: d, encoding: .utf8) else { return }
            DispatchQueue.main.async { self.onOutput?(s) }
        }
        master = m

        // 无论启动成功与否都要关闭父进程持有的从设备 fd。
        do { try proc.run() }
        catch { close(aslave); throw error }
        close(aslave)
    }

    /// 写入按键序列。走专用串行队列避免阻塞主线程。
    private let writeQueue = DispatchQueue(label: "app.mole.pty-write")
    func send(_ bytes: [UInt8]) {
        guard let master else { return }
        let data = Data(bytes)
        writeQueue.async { try? master.write(contentsOf: data) }
    }

    /// 终止子进程并清理。
    func terminate() {
        master?.readabilityHandler = nil
        if proc.isRunning { proc.terminate() }
    }
}
