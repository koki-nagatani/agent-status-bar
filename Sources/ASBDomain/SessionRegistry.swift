import Foundation

/// 全セッションの状態を保持し、遷移を決定する純粋なロジック。
///
/// スロットの概念を持たない。セッションは登録されるものではなく観測されるものであり、
/// 上限もない。
public struct SessionRegistry: Sendable {
    private var sessions: [SessionKey: AgentSession] = [:]

    public init() {}

    // MARK: - 参照

    public var all: [AgentSession] {
        Array(sessions.values)
    }

    public subscript(key: SessionKey) -> AgentSession? {
        sessions[key]
    }

    public var summary: Summary {
        var s = Summary()
        for session in sessions.values {
            switch (session.status, session.liveness) {
            case (_, .gone) where session.isAbandoned:
                s.abandoned += 1
            case (.running, _):
                s.running += 1
            case (.waiting, _):
                s.waiting += 1
            case (.completed, _):
                s.completed += 1
                if !session.acknowledged { s.unacknowledgedCompleted += 1 }
            case (.error, _):
                s.error += 1
            }
        }
        return s
    }

    public struct Summary: Sendable, Equatable {
        public var running = 0
        public var waiting = 0
        public var completed = 0
        /// 前回パネルを開いてから完了した件数。メニューバーに出すのはこちら。
        public var unacknowledgedCompleted = 0
        public var error = 0
        /// 終了イベントを受け取れずに消えたセッション。カウント表示には含めない。
        public var abandoned = 0

        public init() {}
    }

    // MARK: - 遷移

    @discardableResult
    public mutating func apply(_ event: AgentEvent) -> [RegistryEffect] {
        switch event.kind {
        case .sessionStarted:
            // SessionStart は実行の開始ではないため、他のイベントと同じ経路に乗せない。
            applySessionOpened(event)
            return []
        default:
            return applyProgress(event)
        }
    }

    /// `SessionStart`。**セッションが「開かれた」だけで、まだ何も実行していない。**
    ///
    /// ターミナルで agent を起動した時点、VSCode のチャットタブが復元された時点
    /// （リモート再接続時の resume を含む）で発火するため、これを `running` に写すと
    /// **何も送っていないセッションが実行中として数えられる**。
    /// 実行中の実体は `UserPromptSubmit` 以降（`.activity`）にしかない。
    ///
    /// したがってここではセッションを作らない。さらに、同じ session_id が
    /// 既に `running` / `waiting` として残っている場合、それは経路断などで
    /// 終了イベントを取りこぼした残骸であり（セッションは今まさに開き直されたので
    /// 何も走っていない）、破棄する。
    /// `completed` / `error` は「終わった記録」なので残す。再接続でタブが復元されただけで
    /// 未確認の完了バッジを消してしまわないため。
    private mutating func applySessionOpened(_ event: AgentEvent) {
        guard var session = sessions[event.key],
              session.status == .completed || session.status == .error
        else {
            sessions[event.key] = nil
            return
        }
        session.cwd = event.cwd
        if let pid = event.pid { session.pid = pid }
        if let host = event.host { session.host = host }
        session.updatedAt = event.at
        session.liveness = .live
        sessions[event.key] = session
    }

    private mutating func applyProgress(_ event: AgentEvent) -> [RegistryEffect] {
        // 通知は状態が変化したときだけ出す。同じ状態の再通知を防ぐための基準値。
        let previousStatus = sessions[event.key]?.status

        var session = sessions[event.key] ?? AgentSession(
            key: event.key,
            cwd: event.cwd,
            status: .running,
            // SessionStart では作らないため、最初の実イベントが開始時刻になる。
            startedAt: event.at,
            updatedAt: event.at
        )

        // cwd と pid は毎イベントで最新に追従させる（pid は取得できた時のみ）。
        session.cwd = event.cwd
        if let pid = event.pid { session.pid = pid }
        // host はリモートセッションでのみ入る。一度付いたら維持する。
        if let host = event.host { session.host = host }
        session.updatedAt = event.at

        var effects: [RegistryEffect] = []

        switch event.kind {
        case .sessionStarted:
            // applySessionOpened で処理済み。ここには到達しない。
            break

        case .activity:
            // completed からの復帰を正常系として許可する。
            // `Stop` はターン終了にすぎず、次のターンで running に戻る。
            session.status = .running
            session.liveness = .live
            session.errorMessage = nil

        case .awaitingApproval:
            session.status = .waiting
            session.liveness = .live
            // PermissionRequest は連続で発火しうるため、遷移時のみ通知する。
            if previousStatus != .waiting { effects.append(.notifyWaiting(event.key)) }

        case .turnCompleted:
            session.status = .completed
            // プロセスはまだ生きている。gone にはしない。
            session.liveness = .live
            session.completedAt = event.at
            // 新しい完了なので、また目に入れてもらう必要がある
            session.acknowledged = false
            if previousStatus != .completed { effects.append(.notifyCompleted(event.key)) }

        case .turnFailed(let message):
            session.status = .error
            session.liveness = .live
            session.errorMessage = message
            if previousStatus != .error { effects.append(.notifyFailed(event.key)) }

        case .sessionEnded:
            // status は変えない。running のまま gone になれば「中断」を意味する。
            session.liveness = .gone
        }

        sessions[event.key] = session
        return effects
    }

    /// リモートへの経路（SSH トンネル）が切れたときに呼ぶ。
    ///
    /// 以降そのホストの hook は届かない。`running` / `waiting` は
    /// **裏が取れないまま固まる**（リモートは PID プローブができず、
    /// TTL では `stale` になるだけで実行中カウントに残り続ける）ため破棄する。
    /// 実際にはまだ生きているセッションなら、再接続後の最初のイベントで戻ってくる。
    ///
    /// `completed` / `error` は既に終わった記録なので残し、liveness だけ落とす。
    public mutating func markHostDisconnected(_ host: String) {
        for (key, var session) in sessions where session.host == host {
            switch session.status {
            case .running, .waiting:
                sessions[key] = nil
            case .completed, .error:
                session.liveness = .gone
                sessions[key] = session
            }
        }
    }

    /// 完了をすべて「確認済み」にする。詳細パネルを開いたときに呼ぶ。
    ///
    /// `error` は対象にしない。異常終了は見ただけでは解決しないため、
    /// セッションが破棄されるまでメニューバーに出し続ける。
    public mutating func acknowledgeCompleted() {
        for (key, var session) in sessions where session.status == .completed && !session.acknowledged {
            session.acknowledged = true
            sessions[key] = session
        }
    }

    /// PID 生存確認と TTL による liveness の再評価。
    ///
    /// `gone` への遷移では通知しない。ターミナルを閉じるたびに通知が飛ぶのを避けるため。
    public mutating func evaluateLiveness(
        now: Date,
        staleAfter: TimeInterval,
        isAlive: (ProcessID) -> Bool
    ) {
        for (key, var session) in sessions {
            guard session.liveness != .gone else { continue }

            if session.host != nil {
                // リモート: PID はローカルの `kill(0)` で検証できない（不在なら消え、
                // 無関係なローカル PID と衝突すれば誤って生存判定になる）。
                // SessionEnd が来れば gone、来なければ TTL で stale に落とす。
                session.liveness = now.timeIntervalSince(session.updatedAt) > staleAfter ? .stale : .live
            } else if let pid = session.pid {
                // 第2層: プロセスの生存が最も確実な判定。
                if !isAlive(pid) {
                    session.liveness = .gone
                    sessions[key] = session
                    continue
                }
                // プロセスは生きている。無言が続いていれば stale だが削除はしない。
                session.liveness = now.timeIntervalSince(session.updatedAt) > staleAfter ? .stale : .live
            } else {
                // 第3層: PID が取れない provider は TTL のみに頼る。
                session.liveness = now.timeIntervalSince(session.updatedAt) > staleAfter ? .stale : .live
            }
            sessions[key] = session
        }
    }

    /// 保持ポリシー。
    ///
    /// `completed` は終端状態ではないため早期に破棄しない。
    public mutating func evict(now: Date, keepCompleted: Int, completedTTL: TimeInterval, abandonedTTL: TimeInterval) {
        // 中断セッションは短期間だけ保持する。
        for (key, session) in sessions where session.isAbandoned {
            if now.timeIntervalSince(session.updatedAt) > abandonedTTL { sessions[key] = nil }
        }

        let finished = sessions.values
            .filter { !$0.isActive && !$0.isAbandoned }
            .sorted { $0.updatedAt > $1.updatedAt }

        for (index, session) in finished.enumerated() {
            let tooOld = now.timeIntervalSince(session.updatedAt) > completedTTL
            if index >= keepCompleted || tooOld { sessions[session.key] = nil }
        }
    }
}
