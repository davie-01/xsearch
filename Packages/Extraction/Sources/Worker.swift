import Darwin
import Foundation

/// Wire format between the supervisor and `xs-extract`: each message is a 4-byte little-endian
/// length followed by that many bytes of JSON.
public struct WorkerRequest: Codable, Sendable {
    public var id: UInt64
    public var path: String
    public var limits: ExtractionLimits
    /// Fault injection for tests ("hang", "crash"); honoured only when the worker runs with
    /// XS_EXTRACT_FAULTS=1.
    public var fault: String?

    public init(id: UInt64, path: String, limits: ExtractionLimits, fault: String? = nil) {
        self.id = id
        self.path = path
        self.limits = limits
        self.fault = fault
    }
}

public struct WorkerResponse: Codable, Sendable {
    public var id: UInt64
    public var result: ExtractionResult?
    public var error: String?

    public init(id: UInt64, result: ExtractionResult? = nil, error: String? = nil) {
        self.id = id
        self.result = result
        self.error = error
    }
}

public enum Framing {
    public static func write(_ data: Data, to fd: Int32) -> Bool {
        var len = UInt32(data.count).littleEndian
        let header = Data(bytes: &len, count: 4)
        return writeAll(header, fd) && writeAll(data, fd)
    }

    static func writeAll(_ data: Data, _ fd: Int32) -> Bool {
        data.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
                if n < 0 { if errno == EINTR { continue }; return false }
                off += n
            }
            return true
        }
    }

    /// Blocks until a whole message arrives; nil on EOF or error.
    public static func read(from fd: Int32) -> Data? {
        guard let header = readExactly(4, fd) else { return nil }
        let len = header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        return readExactly(Int(len), fd)
    }

    static func readExactly(_ n: Int, _ fd: Int32) -> Data? {
        var out = Data(count: n)
        var off = 0
        let ok = out.withUnsafeMutableBytes { buf -> Bool in
            while off < n {
                let r = Darwin.read(fd, buf.baseAddress! + off, n - off)
                if r < 0 { if errno == EINTR { continue }; return false }
                if r == 0 { return false }
                off += r
            }
            return true
        }
        return ok ? out : nil
    }
}

/// Supervises one `xs-extract` process (ARCHITECTURE §5: parsing runs in a separate process
/// that can be killed). A request that exceeds its timeout gets the worker SIGKILLed; a worker
/// that dies is restarted on the next request. Retry, backoff and quarantine are decided by
/// the task scheduler from the outcome.
public final class ExtractionWorker: @unchecked Sendable {
    public enum Outcome: Sendable, Equatable {
        case extracted(ExtractionResult)
        /// The extractor reported an error for this file (unsupported, encrypted, corrupt…).
        case failed(String)
        case timedOut
        /// The worker process died while handling the file.
        case crashed
        /// `cancel()` stopped it; says nothing about the file.
        case cancelled
    }

    private let executable: URL
    private let environment: [String: String]
    private let lock = NSLock()
    private var process: Process?
    private var toWorker: FileHandle?
    private var fromWorker: FileHandle?
    private var nextId: UInt64 = 1
    public private(set) var restarts = 0
    private var started = false
    /// Separate from `lock`, which `extract` holds for the whole request.
    private let cancelLock = NSLock()
    private var cancelled = false
    private var activePid: Int32?

    public init(executable: URL, environment: [String: String] = [:]) {
        self.executable = executable
        self.environment = environment
    }

    deinit { stop() }

    public var pid: Int32? { process?.processIdentifier }

    public func stop() {
        if let p = process, p.isRunning { kill(p.processIdentifier, SIGKILL); Self.awaitExit(p) }
        process = nil
        toWorker = nil
        fromWorker = nil
    }

    /// Kills the running request at once, from any thread; later requests return `.cancelled`
    /// until `resume()`.
    public func cancel() {
        cancelLock.withLock {
            cancelled = true
            if let activePid { kill(activePid, SIGKILL) }
        }
    }

    public func resume() {
        cancelLock.withLock { cancelled = false }
    }

    private func beginRequest(_ pid: Int32) -> Bool {
        cancelLock.withLock {
            guard !cancelled else { return false }
            activePid = pid
            return true
        }
    }

    /// Whether the request was cancelled. Called before the process is reaped, so `cancel` never
    /// signals a reused pid.
    private func endRequest() -> Bool {
        cancelLock.withLock {
            activePid = nil
            return cancelled
        }
    }

    /// After SIGKILL. Not `waitUntilExit`: it waits in the run loop for a wake-up that never comes
    /// if the process ended just before (seen when `cancel` had already killed it), and the
    /// indexer's stop, so the app's quit, would hang for ever. The process is certainly dying.
    private static func awaitExit(_ p: Process) {
        let deadline = Date().addingTimeInterval(1)
        while p.isRunning && Date() < deadline { usleep(1000) }
    }

    private func ensureRunning() throws {
        if let p = process, p.isRunning { return }
        if started { restarts += 1 }
        started = true
        let p = Process()
        p.executableURL = executable
        p.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        try p.run()
        process = p
        toWorker = input.fileHandleForWriting
        fromWorker = output.fileHandleForReading
    }

    /// One file at a time per worker; callers run several workers for parallelism.
    public func extract(path: String, limits: ExtractionLimits, timeout: TimeInterval, fault: String? = nil) -> Outcome {
        lock.lock()
        defer { lock.unlock() }
        if cancelLock.withLock({ cancelled }) { return .cancelled }
        do { try ensureRunning() } catch { return .failed("提取进程无法启动：\(error)") }
        guard let toWorker, let fromWorker, let p = process else { return .crashed }
        guard beginRequest(p.processIdentifier) else { return .cancelled }
        let id = nextId
        nextId += 1
        let request = WorkerRequest(id: id, path: path, limits: limits, fault: fault)
        guard let data = try? JSONEncoder().encode(request), Framing.write(data, to: toWorker.fileDescriptor) else {
            let wasCancelled = endRequest()
            stop()
            return wasCancelled ? .cancelled : .crashed
        }
        // Read on another thread so the timeout can fire while the worker is stuck.
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var reply: Data?
        let fd = fromWorker.fileDescriptor
        // A dedicated thread, not GCD: this read can block for the whole timeout.
        Thread.detachNewThread {
            reply = Framing.read(from: fd)
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            _ = endRequest()
            kill(p.processIdentifier, SIGKILL)
            Self.awaitExit(p)
            done.wait()  // the read returns once the pipe closes
            stop()
            return .timedOut
        }
        let wasCancelled = endRequest()
        guard let reply, let response = try? JSONDecoder().decode(WorkerResponse.self, from: reply), response.id == id else {
            stop()
            return wasCancelled ? .cancelled : .crashed
        }
        if let r = response.result { return .extracted(r) }
        return .failed(response.error ?? "未知错误")
    }
}
