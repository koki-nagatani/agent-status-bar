import Foundation

public struct AgentSession: Sendable, Equatable {
    public let key: SessionKey

    /// 表示上の最重要情報。「何が終わったのか」を判別する唯一の手がかり。
    public var cwd: String

    public var status: AgentStatus
    public var liveness: Liveness

    /// liveness 判定に使う。provider によっては取得できない。
    public var pid: ProcessID?

    /// SSH 越しのリモートセッションのホスト名。ローカルは `nil`。
    /// リモートの PID はローカルで検証できないため、`nil` でないセッションは
    /// PID プローブを行わず TTL のみで liveness を判定する。
    public var host: String?

    public var startedAt: Date?
    public var updatedAt: Date
    public var completedAt: Date?
    public var errorMessage: String?

    /// ユーザーがこの完了を目にしたか。
    ///
    /// メニューバーの 🟢 は「前回パネルを開いてから完了した件数」を表す。
    /// 完了セッションは最大 24 時間保持されるため、総数を出すと
    /// 一日中大きな数字が居座り、glanceable でなくなる。
    public var acknowledged: Bool

    public init(
        key: SessionKey,
        cwd: String,
        status: AgentStatus,
        liveness: Liveness = .live,
        pid: ProcessID? = nil,
        host: String? = nil,
        startedAt: Date? = nil,
        updatedAt: Date,
        completedAt: Date? = nil,
        errorMessage: String? = nil,
        acknowledged: Bool = false
    ) {
        self.key = key
        self.cwd = cwd
        self.status = status
        self.liveness = liveness
        self.pid = pid
        self.host = host
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.errorMessage = errorMessage
        self.acknowledged = acknowledged
    }

    /// サマリのカウント対象か。`gone` は実行中でも数えない。
    public var isActive: Bool {
        guard liveness != .gone else { return false }
        return status == .running || status == .waiting
    }

    /// 終了イベントを受け取れずにプロセスが消えたセッション。「中断」として扱う。
    public var isAbandoned: Bool {
        liveness == .gone && (status == .running || status == .waiting)
    }
}
