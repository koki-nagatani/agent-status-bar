import Foundation

/// 正規化されたイベント。Adapter と Domain の境界。
///
/// provider 固有の `hook_event_name` はここに到達する前に解決される。
/// 会話内容（prompt / tool_input / last_assistant_message）は**この型に存在しない**。
/// これはデータ最小化を型で強制するための設計である。
public struct AgentEvent: Sendable, Equatable {
    public let key: SessionKey
    public let cwd: String
    public let kind: Kind
    public let pid: ProcessID?
    /// このイベントを発したホスト。ローカルは `nil`。
    /// リモート（SSH 越し）のセッションだけ値が入り、liveness 判定に使う。
    public let host: String?
    public let at: Date

    public init(key: SessionKey, cwd: String, kind: Kind, pid: ProcessID? = nil, host: String? = nil, at: Date) {
        self.key = key
        self.cwd = cwd
        self.kind = kind
        self.pid = pid
        self.host = host
        self.at = at
    }

    public enum Kind: Sendable, Equatable {
        /// SessionStart
        case sessionStarted

        /// UserPromptSubmit / PreToolUse / PostToolUse / **PostToolUseFailure**
        ///
        /// `PostToolUseFailure` がここに含まれるのは意図的である。
        /// 実測の結果これはツール1回分の失敗であり、Agent の通常動作だった。
        /// `error` にすると 🔴 が平常運転中に点灯し続ける。
        case activity

        /// PermissionRequest / Notification
        case awaitingApproval

        /// Stop —— **セッション終了ではなくターン終了**。
        /// この後 `activity` が来て `running` に戻るのが正常系。
        case turnCompleted

        /// StopFailure 等、ターン／セッション単位の失敗。
        case turnFailed(message: String?)

        /// SessionEnd
        case sessionEnded
    }
}

/// Registry が状態を更新した結果、外側で起こすべき副作用。
///
/// いずれも**状態が実際に遷移したときだけ**発生する。
/// 同じ状態を繰り返し通知しない（`PermissionRequest` は連続で飛びうる）。
public enum RegistryEffect: Sendable, Equatable {
    case notifyCompleted(SessionKey)
    case notifyFailed(SessionKey)
    case notifyWaiting(SessionKey)
}
