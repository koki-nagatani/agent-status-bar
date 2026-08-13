import XCTest
@testable import ASBAdapters
import ASBDomain

/// フィクスチャは実際に採取した payload の構造をそのまま再現している。
/// 会話内容にあたる値のみ置き換えてある（実データを repo に持ち込まないため）。
final class HookEventDecoderTests: XCTestCase {

    private let decoder = HookEventDecoder()
    private let now = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - フィクスチャ

    /// Claude Code の `Stop`。`last_assistant_message` に応答全文が入る。
    private let claudeStop = """
    {
      "session_id": "022b8541-b2ca-4fcd-9215-8b9ca1921d35",
      "transcript_path": "/Users/u/.claude/projects/-work-proj/022b8541.jsonl",
      "cwd": "/work/proj",
      "prompt_id": "f6378b27-2bd5-4947-9244-abf42e0083b1",
      "permission_mode": "auto",
      "effort": { "level": "high" },
      "hook_event_name": "Stop",
      "stop_hook_active": false,
      "last_assistant_message": "<<会話内容が入る位置>>",
      "background_tasks": [],
      "session_crons": []
    }
    """

    /// Codex の `SessionStart`。`permission_mode` はあるが `prompt_id` は無い。
    private let codexSessionStart = """
    {
      "session_id": "019ff0f9-9ecb-71b3-b89f-3bf27f7575f1",
      "transcript_path": "/Users/u/.codex/sessions/2026/08/11/rollout-019ff0f9.jsonl",
      "cwd": "/work/proj",
      "hook_event_name": "SessionStart",
      "model": "gpt-5.6-sol",
      "permission_mode": "default",
      "source": "startup"
    }
    """

    /// Claude Code の `PermissionRequest`。`tool_input` に実行コマンド全文が入る。
    private let claudePermissionRequest = """
    {
      "session_id": "9c6634b2-da85-447e-995a-f271eaf16d7c",
      "transcript_path": "/Users/u/.claude/projects/-work-proj/9c6634b2.jsonl",
      "cwd": "/work/proj",
      "prompt_id": "1d7530c9-e232-4f05-9143-7c96477e11a1",
      "permission_mode": "acceptEdits",
      "hook_event_name": "PermissionRequest",
      "tool_name": "Bash",
      "tool_input": { "command": "<<会話内容が入る位置>>" },
      "permission_suggestions": [{ "type": "addRules" }]
    }
    """

    /// Codex の `SessionEnd`。`permission_mode` も turn 識別子も無い最小構成。
    private let codexSessionEnd = """
    {
      "session_id": "019ff12a-a09a-7c53-8fab-ed72aab7ed8c",
      "transcript_path": "/Users/u/.codex/sessions/2026/08/11/rollout-019ff12a.jsonl",
      "cwd": "/work/proj",
      "hook_event_name": "SessionEnd",
      "reason": "other"
    }
    """

    private func decode(_ json: String, _ provider: AgentProvider, pid: ProcessID? = nil) throws -> AgentEvent {
        try decoder.decode(provider: provider, pid: pid, at: now, payload: Data(json.utf8))
    }

    // MARK: - 封筒の抽出

    func testDecodesClaudeStopAsTurnCompleted() throws {
        let event = try decode(claudeStop, .claude, pid: 25915)
        XCTAssertEqual(event.key, SessionKey(provider: .claude, sessionId: "022b8541-b2ca-4fcd-9215-8b9ca1921d35"))
        XCTAssertEqual(event.cwd, "/work/proj")
        XCTAssertEqual(event.kind, .turnCompleted)
        XCTAssertEqual(event.pid, 25915)
    }

    /// `SessionStart` には `permission_mode` があり、`SessionEnd` には無い。
    /// どちらも同じ Decoder で扱えることを確認する。
    func testDecodesCodexSessionLifecycle() throws {
        XCTAssertEqual(try decode(codexSessionStart, .codex).kind, .sessionStarted)
        XCTAssertEqual(try decode(codexSessionEnd, .codex).kind, .sessionEnded)
    }

    func testDecodesPermissionRequestAsAwaitingApproval() throws {
        XCTAssertEqual(try decode(claudePermissionRequest, .claude).kind, .awaitingApproval)
    }

    /// PID は payload ではなく transport が渡す。取得できない provider もある。
    func testPidIsOptional() throws {
        XCTAssertNil(try decode(codexSessionStart, .codex, pid: nil).pid)
    }

    /// host は transport（リモートの shim）が渡す。ローカルは nil。
    func testHostIsCarriedWhenProvided() throws {
        let event = try decoder.decode(
            provider: .claude, pid: 1, host: "devbox", at: now, payload: Data(claudeStop.utf8)
        )
        XCTAssertEqual(event.host, "devbox")
    }

    func testHostIsNilForLocalEvents() throws {
        XCTAssertNil(try decode(claudeStop, .claude).host)
    }

    // MARK: - イベント名のマッピング

    func testActivityEventsIncludeToolFailure() {
        for name in ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure"] {
            XCTAssertEqual(
                HookEventDecoder.kind(for: name), .activity,
                "\(name) は activity。ツール1回分の失敗を error にすると 🔴 が常時点灯する"
            )
        }
    }

    func testWaitingEvents() {
        XCTAssertEqual(HookEventDecoder.kind(for: "PermissionRequest"), .awaitingApproval)
    }

    // Claude Code の Notification はターン終了後の「入力待ち」でも発火するため、
    // 判断待ちには写さない（完了直後に判断待ちへ戻るのを防ぐ）。
    func testNotificationIsNotTreatedAsWaiting() {
        XCTAssertNil(HookEventDecoder.kind(for: "Notification"))
    }

    func testStopFailureIsTurnFailed() {
        XCTAssertEqual(HookEventDecoder.kind(for: "StopFailure"), .turnFailed(message: nil))
    }

    func testUnknownEventIsRejectedRatherThanGuessed() throws {
        XCTAssertNil(HookEventDecoder.kind(for: "SomeFutureEvent"))

        let payload = """
        {"session_id":"s","cwd":"/w","hook_event_name":"SomeFutureEvent"}
        """
        XCTAssertThrowsError(try decode(payload, .claude)) { error in
            XCTAssertEqual(error as? HookEventDecoder.DecodeError, .unknownEvent("SomeFutureEvent"))
        }
    }

    func testMalformedPayloadIsRejected() {
        XCTAssertThrowsError(try decode("not json", .claude))
        // session_id 欠落
        XCTAssertThrowsError(try decode(#"{"cwd":"/w","hook_event_name":"Stop"}"#, .claude))
    }

    // MARK: - データ最小化

    /// `AgentEvent` は会話内容を保持するフィールドを持たない。
    /// 上の各フィクスチャは実際に会話内容を含んでいるが、
    /// デコード結果からそれを取り出す手段が構造上存在しない。
    func testConversationContentCannotSurviveDecoding() throws {
        let event = try decode(claudeStop, .claude)
        let dumped = String(describing: event)
        XCTAssertFalse(
            dumped.contains("会話内容"),
            "会話内容が AgentEvent に混入している。データ最小化の前提が壊れた"
        )

        let request = try decode(claudePermissionRequest, .claude)
        XCTAssertFalse(String(describing: request).contains("会話内容"))
    }

    // MARK: - クエリ解析

    func testQueryParsing() {
        let items = UnixSocketHookServer.queryItems(
            from: "POST /event?provider=claude&pid=25915 HTTP/1.1"
        )
        XCTAssertEqual(items["provider"], "claude")
        XCTAssertEqual(items["pid"], "25915")

        XCTAssertTrue(UnixSocketHookServer.queryItems(from: "POST /event HTTP/1.1").isEmpty)
    }
}
