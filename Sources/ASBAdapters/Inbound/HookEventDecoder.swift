import Foundation
import ASBDomain

/// provider 固有の hook payload を正規化イベントへ変換する。
///
/// **データ最小化の強制点**。
/// 実測の結果、hook payload には会話内容が含まれる。
/// - `UserPromptSubmit` → `prompt`（ユーザー入力の全文）
/// - `PreToolUse` → `tool_input`（実行コマンドの全文）
/// - `Stop` → `last_assistant_message`（アシスタント応答の全文）
///
/// `Envelope` はこれらのキーを**持たない**ため、`JSONDecoder` は自動的に読み捨てる。
/// 「気をつけて扱う」のではなく、構造上到達できないようにしている。
public struct HookEventDecoder: Sendable {

    /// 全イベントで存在が保証されているフィールドのみを宣言する。
    /// `permission_mode` や turn 識別子はイベントによって欠落するため含めない。
    private struct Envelope: Decodable {
        let sessionId: String
        let cwd: String
        let hookEventName: String

        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case cwd
            case hookEventName = "hook_event_name"
        }
    }

    public enum DecodeError: Error, Equatable {
        case malformedPayload
        case unknownEvent(String)
    }

    public init() {}

    public func decode(
        provider: AgentProvider,
        pid: ProcessID?,
        host: String? = nil,
        at: Date,
        payload: Data
    ) throws -> AgentEvent {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: payload) else {
            throw DecodeError.malformedPayload
        }
        guard let kind = Self.kind(for: envelope.hookEventName) else {
            throw DecodeError.unknownEvent(envelope.hookEventName)
        }
        return AgentEvent(
            key: SessionKey(provider: provider, sessionId: envelope.sessionId),
            cwd: envelope.cwd,
            kind: kind,
            pid: pid,
            host: host,
            at: at
        )
    }

    /// hook イベント名 → 正規化 Kind。両 provider で同名のため共通表で足りる
    static func kind(for eventName: String) -> AgentEvent.Kind? {
        switch eventName {
        case "SessionStart":
            return .sessionStarted

        // ツール1回分の失敗は Agent の通常動作であり error ではない。
        // これを error に写すと 🔴 が平常運転中に点灯し続ける。
        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure":
            return .activity

        // 判断待ちは PermissionRequest だけに写す。
        // Claude Code の Notification はターン終了後の「入力待ち」でも発火するため、
        // これを awaitingApproval にすると完了直後に判断待ちへ戻ってしまう。
        case "PermissionRequest":
            return .awaitingApproval

        // ターン終了であってセッション終了ではない。
        case "Stop":
            return .turnCompleted

        case "StopFailure":
            return .turnFailed(message: nil)

        case "SessionEnd":
            return .sessionEnded

        default:
            return nil
        }
    }
}
