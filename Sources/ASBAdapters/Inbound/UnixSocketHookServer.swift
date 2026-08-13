import Foundation
import ASBDomain
import ASBApplication

/// Unix domain socket で hook からのイベントを受け取る inbound adapter。
///
/// hook は起動ごとに生成される短命プロセスであるため、常駐アプリへ値を渡す経路が必要になる。
/// TCP ポートではなく Unix socket を選んだ理由:
/// - 追加バイナリが不要（`curl --unix-socket` で送れる）
/// - ポート衝突が起きない
/// - ファイル権限でアクセス範囲が閉じる（0600 で作成する）
///
/// 期待するリクエスト:
/// ```
/// POST /event?provider=claude&pid=25915
/// <hook payload (JSON) をそのまま body に>
/// ```
public final class UnixSocketHookServer: AgentEventSource, @unchecked Sendable {
    // @unchecked Sendable: 可変状態は全て `queue` 上でのみ触る。

    public let socketPath: String
    private let decoder = HookEventDecoder()
    private let clock: Clock
    private let onDecodeFailure: (@Sendable (Error) -> Void)?

    private let queue = DispatchQueue(label: "dev.asb.hook-server")
    private let connections = DispatchQueue(label: "dev.asb.hook-conn", attributes: .concurrent)
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var handler: (@Sendable (AgentEvent) -> Void)?

    /// 1 リクエストあたりの上限。hook payload は数 KB 程度だが、
    /// 会話全文を含むため余裕を持たせる。これを超える入力は破棄する。
    private static let maxBodyBytes = 4 * 1024 * 1024

    public init(socketPath: String, clock: Clock, onDecodeFailure: (@Sendable (Error) -> Void)? = nil) {
        self.socketPath = socketPath
        self.clock = clock
        self.onDecodeFailure = onDecodeFailure
    }

    public enum ServerError: Error {
        case socketCreationFailed(errno: Int32)
        case bindFailed(errno: Int32)
        case listenFailed(errno: Int32)
        case pathTooLong
    }

    // MARK: - AgentEventSource

    public func start(_ onEvent: @escaping @Sendable (AgentEvent) -> Void) throws {
        try queue.sync {
            guard listenFD < 0 else { return }
            handler = onEvent

            let directory = (socketPath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // 前回の残骸を掃除する。残っていると bind が EADDRINUSE で失敗する。
            unlink(socketPath)

            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw ServerError.socketCreationFailed(errno: errno) }

            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
            let pathBytes = Array(socketPath.utf8)
            guard pathBytes.count < pathCapacity else {
                close(fd); throw ServerError.pathTooLong
            }
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                raw.copyBytes(from: pathBytes)
            }

            let size = socklen_t(MemoryLayout<sockaddr_un>.size)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
            }
            guard bound == 0 else { close(fd); throw ServerError.bindFailed(errno: errno) }

            // 本人以外が書き込めないようにする。
            chmod(socketPath, 0o600)

            guard listen(fd, 32) == 0 else { close(fd); throw ServerError.listenFailed(errno: errno) }

            listenFD = fd
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptOne() }
            source.resume()
            acceptSource = source
        }
    }

    public func stop() {
        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil
            if listenFD >= 0 { close(listenFD); listenFD = -1 }
            unlink(socketPath)
            handler = nil
        }
    }

    // MARK: - 受信

    private func acceptOne() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        let handler = self.handler
        connections.async { [weak self] in
            self?.serve(client, handler: handler)
            close(client)
        }
    }

    private func serve(_ fd: Int32, handler: (@Sendable (AgentEvent) -> Void)?) {
        // hook を待たせないよう、常に応答を返してから閉じる。
        defer { _ = Self.writeAll(fd, "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n") }

        guard let request = Self.readRequest(fd) else { return }
        guard let event = decodeRequest(request) else { return }
        handler?(event)
    }

    private func decodeRequest(_ request: (line: String, body: Data)) -> AgentEvent? {
        let query = Self.queryItems(from: request.line)
        guard let providerRaw = query["provider"], let provider = AgentProvider(rawValue: providerRaw) else {
            onDecodeFailure?(HookEventDecoder.DecodeError.malformedPayload)
            return nil
        }
        // pid は payload ではなく transport が渡す。
        // Claude Code は CLAUDE_PID 環境変数、Codex は $PPID から取る。
        let pid = query["pid"].flatMap { ProcessID($0) }.flatMap { $0 > 0 ? $0 : nil }
        // host はリモート（SSH 越し）の shim だけが付ける。ローカルは付かない＝nil。
        let host = query["host"].flatMap { $0.isEmpty ? nil : $0 }

        do {
            return try decoder.decode(provider: provider, pid: pid, host: host, at: clock.now, payload: request.body)
        } catch {
            onDecodeFailure?(error)
            return nil
        }
    }

    // MARK: - 最小限の HTTP 解析

    static func queryItems(from requestLine: String) -> [String: String] {
        guard let target = requestLine.split(separator: " ").dropFirst().first,
              let queryString = target.split(separator: "?", maxSplits: 1).dropFirst().first
        else { return [:] }

        var items: [String: String] = [:]
        for pair in queryString.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            items[String(parts[0])] = String(parts[1]).removingPercentEncoding ?? String(parts[1])
        }
        return items
    }

    private static func readRequest(_ fd: Int32) -> (line: String, body: Data)? {
        var buffer = Data()
        let separator = Data("\r\n\r\n".utf8)

        // ヘッダ終端まで読む
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            guard let chunk = readChunk(fd), !chunk.isEmpty else { return nil }
            buffer.append(chunk)
            if buffer.count > maxBodyBytes { return nil }
            headerEnd = buffer.range(of: separator)
        }
        guard let range = headerEnd,
              let header = String(data: buffer[buffer.startIndex..<range.lowerBound], encoding: .utf8)
        else { return nil }

        let lines = header.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first.map(String.init) else { return nil }

        let contentLength = lines.dropFirst()
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) }

        var body = Data(buffer[range.upperBound...])
        if let expected = contentLength {
            while body.count < expected {
                guard let chunk = readChunk(fd), !chunk.isEmpty else { break }
                body.append(chunk)
                if body.count > maxBodyBytes { return nil }
            }
        }
        return (requestLine, body)
    }

    private static func readChunk(_ fd: Int32) -> Data? {
        var bytes = [UInt8](repeating: 0, count: 16 * 1024)
        let count = read(fd, &bytes, bytes.count)
        guard count > 0 else { return count == 0 ? Data() : nil }
        return Data(bytes[0..<count])
    }

    private static func writeAll(_ fd: Int32, _ text: String) -> Bool {
        // `&bytes[offset]` は配列要素 1 個への一時ポインタであり、
        // そこから複数バイト書くのは未定義動作になる（壊れたレスポンスを送ってしまう）。
        // バッファ全体を借りてオフセットを進める。
        Array(text.utf8).withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            while offset < raw.count {
                let written = write(fd, base.advanced(by: offset), raw.count - offset)
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }
}
