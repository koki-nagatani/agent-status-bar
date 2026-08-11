import XCTest
@testable import ASBAdapters
import ASBDomain
import ASBApplication

/// hook が実際に使う経路（`curl --unix-socket` → socket → Decoder → AgentEvent）を
/// そのまま通して検証する。この経路が壊れるとアプリは何も観測できなくなる。
final class UnixSocketHookServerTests: XCTestCase {

    private var server: UnixSocketHookServer!
    private var socketPath: String!

    private struct FixedClock: Clock {
        let now: Date
    }

    override func setUp() {
        super.setUp()
        socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("asb-test-\(UUID().uuidString.prefix(8)).sock").path
    }

    override func tearDown() {
        server?.stop()
        server = nil
        super.tearDown()
    }

    /// hook が送るのと同じ形でリクエストを投げる。
    private func post(_ json: String, provider: String, pid: String?) throws {
        var url = "http://localhost/event?provider=\(provider)"
        if let pid { url += "&pid=\(pid)" }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = [
            "-s", "--unix-socket", socketPath,
            "-X", "POST", "--data-binary", "@-", url,
        ]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()
        input.fileHandleForWriting.write(Data(json.utf8))
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "curl が失敗した")
    }

    func testReceivesEventFromCurlOverUnixSocket() throws {
        let received = XCTestExpectation(description: "イベントを受信")
        let box = EventBox()

        server = UnixSocketHookServer(socketPath: socketPath, clock: FixedClock(now: Date(timeIntervalSince1970: 42)))
        try server.start { event in
            box.store(event)
            received.fulfill()
        }

        try post("""
        {
          "session_id": "abc-123",
          "transcript_path": "/tmp/t.jsonl",
          "cwd": "/work/api-server",
          "hook_event_name": "Stop",
          "last_assistant_message": "<<会話内容>>"
        }
        """, provider: "claude", pid: "25915")

        wait(for: [received], timeout: 5)

        let event = try XCTUnwrap(box.value)
        XCTAssertEqual(event.key, SessionKey(provider: .claude, sessionId: "abc-123"))
        XCTAssertEqual(event.cwd, "/work/api-server")
        XCTAssertEqual(event.kind, .turnCompleted)
        XCTAssertEqual(event.pid, 25915)
        XCTAssertEqual(event.at, Date(timeIntervalSince1970: 42), "時刻は Clock port から取る")
    }

    /// Codex は PID を渡せないため、pid なしのリクエストも受け付けなければならない。
    func testAcceptsRequestWithoutPid() throws {
        let received = XCTestExpectation(description: "イベントを受信")
        let box = EventBox()

        server = UnixSocketHookServer(socketPath: socketPath, clock: FixedClock(now: Date()))
        try server.start { event in
            box.store(event)
            received.fulfill()
        }

        try post("""
        {"session_id":"s1","transcript_path":"/t","cwd":"/w","hook_event_name":"SessionEnd","reason":"other"}
        """, provider: "codex", pid: nil)

        wait(for: [received], timeout: 5)
        let event = try XCTUnwrap(box.value)
        XCTAssertNil(event.pid)
        XCTAssertEqual(event.kind, .sessionEnded)
        XCTAssertEqual(event.key.provider, .codex)
    }

    /// 複数セッションが同時に hook を投げても取りこぼさない。
    func testHandlesConcurrentRequests() throws {
        let count = 20
        let received = XCTestExpectation(description: "全イベントを受信")
        received.expectedFulfillmentCount = count
        let collector = EventCollector()

        server = UnixSocketHookServer(socketPath: socketPath, clock: FixedClock(now: Date()))
        try server.start { event in
            collector.append(event)
            received.fulfill()
        }

        for index in 0..<count {
            try post("""
            {"session_id":"s\(index)","transcript_path":"/t","cwd":"/w","hook_event_name":"PreToolUse"}
            """, provider: "claude", pid: "\(1000 + index)")
        }

        wait(for: [received], timeout: 15)
        XCTAssertEqual(Set(collector.values.map(\.key.sessionId)).count, count, "セッションを取りこぼした")
    }

    /// 不正な入力で hook をブロックしたりクラッシュしたりしてはならない。
    func testMalformedRequestIsIgnoredWithoutBreakingServer() throws {
        let failures = FailureCollector()
        let received = XCTestExpectation(description: "正常なイベントは届く")

        server = UnixSocketHookServer(
            socketPath: socketPath,
            clock: FixedClock(now: Date()),
            onDecodeFailure: { failures.append($0) }
        )
        try server.start { _ in received.fulfill() }

        try post("これは JSON ではない", provider: "claude", pid: "1")
        try post(#"{"session_id":"s","cwd":"/w","hook_event_name":"Stop"}"#, provider: "unknown-provider", pid: "1")

        // 壊れた入力の後でも受信を続けられる
        try post(#"{"session_id":"ok","transcript_path":"/t","cwd":"/w","hook_event_name":"Stop"}"#,
                 provider: "claude", pid: "1")

        wait(for: [received], timeout: 5)
        XCTAssertEqual(failures.count, 2, "不正な入力は 2 件とも記録されるべき")
    }

    func testSocketIsCreatedWithOwnerOnlyPermissions() throws {
        server = UnixSocketHookServer(socketPath: socketPath, clock: FixedClock(now: Date()))
        try server.start { _ in }

        let attributes = try FileManager.default.attributesOfItem(atPath: socketPath)
        let permissions = attributes[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.int16Value, 0o600, "socket は本人以外が書き込めてはならない")
    }

    func testStopRemovesSocketFile() throws {
        server = UnixSocketHookServer(socketPath: socketPath, clock: FixedClock(now: Date()))
        try server.start { _ in }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))

        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath), "残骸が残ると次回の bind が失敗する")
    }
}

// MARK: - テスト用の受け皿

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AgentEvent?
    func store(_ event: AgentEvent) { lock.withLock { stored = event } }
    var value: AgentEvent? { lock.withLock { stored } }
}

private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [AgentEvent] = []
    func append(_ event: AgentEvent) { lock.withLock { stored.append(event) } }
    var values: [AgentEvent] { lock.withLock { stored } }
}

private final class FailureCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Error] = []
    func append(_ error: Error) { lock.withLock { stored.append(error) } }
    var count: Int { lock.withLock { stored.count } }
}
