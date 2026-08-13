import XCTest
@testable import ASBDomain

/// これらのテストは、実際に Claude Code / Codex の hook payload を採取して
/// 判明した挙動を固定するものである。
/// provider 側の変更でこれらが壊れた場合、設計の前提が変わったことを意味する。
final class SessionRegistryTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }

    private func key(_ id: String, _ provider: AgentProvider = .claude) -> SessionKey {
        SessionKey(provider: provider, sessionId: id)
    }

    private func event(
        _ kind: AgentEvent.Kind,
        _ k: SessionKey,
        cwd: String = "/work/proj",
        pid: ProcessID? = 100,
        at offset: TimeInterval
    ) -> AgentEvent {
        AgentEvent(key: k, cwd: cwd, kind: kind, pid: pid, at: at(offset))
    }

    // MARK: - Stop はターン境界であってセッション終了ではない

    /// 実測列: UserPromptSubmit → PreToolUse → Stop → UserPromptSubmit → … → Stop
    /// `completed` は終端状態ではなく、`running` に戻るのが正常系。
    func testStopIsTurnBoundaryAndCompletedCanReturnToRunning() {
        var registry = SessionRegistry()
        let k = key("s1")

        registry.apply(event(.sessionStarted, k, at: 0))
        registry.apply(event(.activity, k, at: 1))
        let effects = registry.apply(event(.turnCompleted, k, at: 2))

        XCTAssertEqual(registry[k]?.status, .completed)
        XCTAssertEqual(effects, [.notifyCompleted(k)])
        // Stop の時点ではプロセスは生きている。gone にしてはならない。
        XCTAssertEqual(registry[k]?.liveness, .live)

        // 次のターンが始まる
        registry.apply(event(.activity, k, at: 3))
        XCTAssertEqual(registry[k]?.status, .running, "completed から running への復帰は正常系")
    }

    // MARK: - PostToolUseFailure は error ではない

    /// ツール1回分の失敗は Agent の通常動作。error にすると 🔴 が常時点灯する。
    /// Decoder はこれを `.activity` に写す契約になっている。
    func testToolFailureIsActivityNotError() {
        var registry = SessionRegistry()
        let k = key("s1")

        registry.apply(event(.activity, k, at: 0))
        let effects = registry.apply(event(.activity, k, at: 1)) // PostToolUseFailure 相当

        XCTAssertEqual(registry[k]?.status, .running)
        XCTAssertTrue(effects.isEmpty, "ツール失敗で通知を出してはならない")
    }

    // MARK: - 中断（running のまま終端）

    /// 実測列（Codex, Ctrl-C）: SessionStart → UserPromptSubmit → PreToolUse → SessionEnd
    /// Stop が無いまま終端に至る経路があるため、running のまま gone になる。
    func testSessionEndWhileRunningIsAbandonedAndSilent() {
        var registry = SessionRegistry()
        let k = key("s1", .codex)

        registry.apply(event(.sessionStarted, k, at: 0))
        registry.apply(event(.activity, k, at: 1))
        let effects = registry.apply(event(.sessionEnded, k, at: 2))

        XCTAssertEqual(registry[k]?.status, .running)
        XCTAssertEqual(registry[k]?.liveness, .gone)
        XCTAssertTrue(registry[k]!.isAbandoned)
        XCTAssertFalse(registry[k]!.isActive, "中断はサマリのカウントに含めない")
        XCTAssertTrue(effects.isEmpty, "中断で通知を出してはならない")
    }

    /// 実測（Codex, タブを閉じる）: 終了イベントが一切来ずにプロセスが消滅する。
    /// この設計で PID 監視を主軸に置いた理由そのもの。
    func testProcessDeathWithoutTerminalEventIsDetectedOnlyByPid() {
        var registry = SessionRegistry()
        let k = key("s1", .codex)

        registry.apply(event(.sessionStarted, k, pid: 15752, at: 0))
        registry.apply(event(.activity, k, pid: 15752, at: 1))
        XCTAssertEqual(registry[k]?.status, .running)

        // 終了イベントは来ない。プロセスだけが消えている。
        registry.evaluateLiveness(now: at(2), staleAfter: 900) { _ in false }

        XCTAssertEqual(registry[k]?.liveness, .gone)
        XCTAssertTrue(registry[k]!.isAbandoned)
        XCTAssertEqual(registry.summary.running, 0, "死んだセッションを実行中として数えてはならない")
        XCTAssertEqual(registry.summary.abandoned, 1)
    }

    // MARK: - completed + gone は正常系

    func testCompletedThenProcessExitIsNormalNotAbandoned() {
        var registry = SessionRegistry()
        let k = key("s1")

        registry.apply(event(.turnCompleted, k, at: 0))
        registry.apply(event(.sessionEnded, k, at: 1))

        XCTAssertEqual(registry[k]?.status, .completed)
        XCTAssertEqual(registry[k]?.liveness, .gone)
        XCTAssertFalse(registry[k]!.isAbandoned, "completed + gone は完全に正常")
        XCTAssertEqual(registry.summary.completed, 1)
    }

    // MARK: - stale

    func testStaleKeepsSessionWhenProcessIsAlive() {
        var registry = SessionRegistry()
        let k = key("s1")

        registry.apply(event(.activity, k, pid: 200, at: 0))
        // 長時間のビルド中: 無言だがプロセスは生きている
        registry.evaluateLiveness(now: at(3600), staleAfter: 900) { _ in true }

        XCTAssertEqual(registry[k]?.liveness, .stale)
        XCTAssertEqual(registry[k]?.status, .running, "stale でも status は running のまま")
        XCTAssertTrue(registry[k]!.isActive, "stale はカウントに含める（淡色表示するだけ）")
        XCTAssertNotNil(registry[k], "stale で削除してはならない")
    }

    func testPidlessSessionFallsBackToTtl() {
        var registry = SessionRegistry()
        let k = key("s1", .codex)

        registry.apply(event(.activity, k, pid: nil, at: 0))
        registry.evaluateLiveness(now: at(1000), staleAfter: 900) { _ in
            XCTFail("PID が無いのに生存確認を呼んではならない"); return true
        }
        XCTAssertEqual(registry[k]?.liveness, .stale)
    }

    // MARK: - リモート（SSH 越し）のセッション

    /// リモートの PID はローカルの kill(0) で検証できない。
    /// host が付いたセッションはプローブせず、TTL だけで liveness を決める。
    func testRemoteSessionSkipsLocalPidProbe() {
        var registry = SessionRegistry()
        let k = key("r1")
        // pid はリモート側のもの。ローカルには存在しない or 無関係なプロセスと衝突しうる。
        registry.apply(AgentEvent(key: k, cwd: "/w", kind: .activity, pid: 424242, host: "devbox", at: at(0)))
        XCTAssertEqual(registry[k]?.host, "devbox")

        registry.evaluateLiveness(now: at(10), staleAfter: 900) { _ in
            XCTFail("リモートセッションでローカル PID プローブを呼んではならない"); return false
        }
        XCTAssertEqual(registry[k]?.liveness, .live)
        XCTAssertTrue(registry[k]!.isActive)

        // TTL 超過は stale。gone にはしない（SessionEnd を待つ）。
        registry.evaluateLiveness(now: at(1000), staleAfter: 900) { _ in
            XCTFail("リモートは probe を呼ばない"); return true
        }
        XCTAssertEqual(registry[k]?.liveness, .stale)
    }

    /// リモートでも SessionEnd が届けば gone にする。
    func testRemoteSessionEndMarksGone() {
        var registry = SessionRegistry()
        let k = key("r1")
        registry.apply(AgentEvent(key: k, cwd: "/w", kind: .activity, pid: 1, host: "box", at: at(0)))
        registry.apply(AgentEvent(key: k, cwd: "/w", kind: .sessionEnded, pid: 1, host: "box", at: at(1)))
        XCTAssertEqual(registry[k]?.liveness, .gone)
    }

    // MARK: - 同一性

    /// cwd をキーにすると並行セッションが互いを上書きしてしまう。
    func testSameCwdDifferentSessionsCoexist() {
        var registry = SessionRegistry()
        let a = key("a"), b = key("b")

        registry.apply(event(.activity, a, cwd: "/same/dir", at: 0))
        registry.apply(event(.turnCompleted, b, cwd: "/same/dir", at: 1))

        XCTAssertEqual(registry.all.count, 2)
        XCTAssertEqual(registry[a]?.status, .running)
        XCTAssertEqual(registry[b]?.status, .completed)
    }

    func testSameSessionIdAcrossProvidersAreDistinct() {
        var registry = SessionRegistry()
        registry.apply(event(.activity, key("dup", .claude), at: 0))
        registry.apply(event(.activity, key("dup", .codex), at: 0))
        XCTAssertEqual(registry.all.count, 2)
    }

    // MARK: - 保持ポリシー

    func testEvictionKeepsRecentCompletedAndAllActive() {
        var registry = SessionRegistry()
        for i in 0..<30 {
            let k = key("done\(i)")
            registry.apply(event(.turnCompleted, k, at: TimeInterval(i)))
            registry.apply(event(.sessionEnded, k, at: TimeInterval(i)))
        }
        let live = key("live")
        registry.apply(event(.activity, live, at: 100))

        registry.evict(now: at(200), keepCompleted: 20, completedTTL: 86400, abandonedTTL: 600)

        XCTAssertEqual(registry.all.filter { $0.status == .completed }.count, 20)
        XCTAssertNotNil(registry[live], "アクティブなセッションは常に保持する")
    }

    func testAbandonedIsEvictedAfterShortTtl() {
        var registry = SessionRegistry()
        let k = key("s1")
        registry.apply(event(.activity, k, at: 0))
        registry.apply(event(.sessionEnded, k, at: 0))
        XCTAssertTrue(registry[k]!.isAbandoned)

        registry.evict(now: at(1200), keepCompleted: 20, completedTTL: 86400, abandonedTTL: 600)
        XCTAssertNil(registry[k])
    }

    // MARK: - サマリ

    func testSummaryCounts() {
        var registry = SessionRegistry()
        registry.apply(event(.activity, key("r1"), at: 0))
        registry.apply(event(.activity, key("r2"), at: 0))
        registry.apply(event(.awaitingApproval, key("w1"), at: 0))
        registry.apply(event(.turnCompleted, key("c1"), at: 0))
        registry.apply(event(.turnFailed(message: "API Error"), key("e1"), at: 0))

        let s = registry.summary
        XCTAssertEqual(s.running, 2)
        XCTAssertEqual(s.waiting, 1)
        XCTAssertEqual(s.completed, 1)
        XCTAssertEqual(s.error, 1)
        XCTAssertEqual(s.abandoned, 0)
    }

    func testTurnFailedCarriesMessageAndNotifies() {
        var registry = SessionRegistry()
        let k = key("s1")
        let effects = registry.apply(event(.turnFailed(message: "API Error"), k, at: 0))

        XCTAssertEqual(registry[k]?.status, .error)
        XCTAssertEqual(registry[k]?.errorMessage, "API Error")
        XCTAssertEqual(effects, [.notifyFailed(k)])
    }
}

/// 通知は状態が実際に遷移したときだけ出す。
/// 実測で `PermissionRequest` が同一セッション内で複数回発火することを確認しているため、
/// 素朴に「イベントが来たら通知」にすると音が鳴り続ける。
final class NotificationTransitionTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func key(_ id: String) -> SessionKey { SessionKey(provider: .claude, sessionId: id) }
    private func event(_ kind: AgentEvent.Kind, _ k: SessionKey, _ o: TimeInterval) -> AgentEvent {
        AgentEvent(key: k, cwd: "/w", kind: kind, pid: 1, at: t0.addingTimeInterval(o))
    }

    func testWaitingNotifiesOnceOnEntry() {
        var registry = SessionRegistry()
        let k = key("s1")

        XCTAssertEqual(registry.apply(event(.awaitingApproval, k, 0)), [.notifyWaiting(k)])
        // 連続した PermissionRequest では鳴らさない
        XCTAssertTrue(registry.apply(event(.awaitingApproval, k, 1)).isEmpty)
    }

    /// 承認 → 実行 → また承認 は 2 回鳴るべき（実測で観測された列）。
    func testWaitingNotifiesAgainAfterReturningToRunning() {
        var registry = SessionRegistry()
        let k = key("s1")

        XCTAssertEqual(registry.apply(event(.awaitingApproval, k, 0)), [.notifyWaiting(k)])
        registry.apply(event(.activity, k, 1))
        XCTAssertEqual(registry.apply(event(.awaitingApproval, k, 2)), [.notifyWaiting(k)])
    }

    func testCompletedDoesNotNotifyTwiceInARow() {
        var registry = SessionRegistry()
        let k = key("s1")

        XCTAssertEqual(registry.apply(event(.turnCompleted, k, 0)), [.notifyCompleted(k)])
        XCTAssertTrue(registry.apply(event(.turnCompleted, k, 1)).isEmpty)
    }

    /// ターンごとに完了通知が出るのは正しい（`Stop` はターン境界）。
    func testCompletedNotifiesEveryTurn() {
        var registry = SessionRegistry()
        let k = key("s1")

        XCTAssertEqual(registry.apply(event(.turnCompleted, k, 0)), [.notifyCompleted(k)])
        registry.apply(event(.activity, k, 1))
        XCTAssertEqual(registry.apply(event(.turnCompleted, k, 2)), [.notifyCompleted(k)])
    }

    func testFailedNotifiesOnceOnEntry() {
        var registry = SessionRegistry()
        let k = key("s1")

        XCTAssertEqual(
            registry.apply(event(.turnFailed(message: "API Error"), k, 0)), [.notifyFailed(k)]
        )
        XCTAssertTrue(registry.apply(event(.turnFailed(message: "API Error"), k, 1)).isEmpty)
    }

    /// 中断は通知しない。ターミナルを閉じるたびに音が鳴るのを避けるため。
    func testAbandonedNeverNotifies() {
        var registry = SessionRegistry()
        let k = key("s1")
        registry.apply(event(.activity, k, 0))
        XCTAssertTrue(registry.apply(event(.sessionEnded, k, 1)).isEmpty)
    }
}


/// メニューバーの 🟢 は「前回パネルを開いてから完了した件数」。
///
/// 完了セッションは最大 24 時間保持されるため、総数を出すと一日中大きな数字が居座り、
/// 一目で状況が分かるという価値が失われる。
final class AcknowledgementTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func key(_ id: String) -> SessionKey { SessionKey(provider: .claude, sessionId: id) }
    private func event(_ kind: AgentEvent.Kind, _ k: SessionKey, _ o: TimeInterval) -> AgentEvent {
        AgentEvent(key: k, cwd: "/w", kind: kind, pid: 1, at: t0.addingTimeInterval(o))
    }

    func testCompletionStartsUnacknowledged() {
        var registry = SessionRegistry()
        registry.apply(event(.turnCompleted, key("s1"), 0))

        XCTAssertEqual(registry.summary.completed, 1)
        XCTAssertEqual(registry.summary.unacknowledgedCompleted, 1)
    }

    /// パネルを開くとバッジは消えるが、一覧の件数は残る。
    func testAcknowledgeClearsBadgeButKeepsTotal() {
        var registry = SessionRegistry()
        for i in 0..<3 { registry.apply(event(.turnCompleted, key("s\(i)"), TimeInterval(i))) }
        XCTAssertEqual(registry.summary.unacknowledgedCompleted, 3)

        registry.acknowledgeCompleted()

        XCTAssertEqual(registry.summary.unacknowledgedCompleted, 0, "開いたらバッジは消える")
        XCTAssertEqual(registry.summary.completed, 3, "一覧の件数は記録として残る")
    }

    /// 確認後に新しく完了したものは再びバッジに出る。
    func testNewCompletionAfterAcknowledgeShowsAgain() {
        var registry = SessionRegistry()
        let k = key("s1")
        registry.apply(event(.turnCompleted, k, 0))
        registry.acknowledgeCompleted()
        XCTAssertEqual(registry.summary.unacknowledgedCompleted, 0)

        // 次のターンが走って再び完了する
        registry.apply(event(.activity, k, 1))
        registry.apply(event(.turnCompleted, k, 2))
        XCTAssertEqual(registry.summary.unacknowledgedCompleted, 1, "新しい完了は再び知らせる")
    }

    func testAcknowledgeIsIdempotent() {
        var registry = SessionRegistry()
        registry.apply(event(.turnCompleted, key("s1"), 0))
        registry.acknowledgeCompleted()
        registry.acknowledgeCompleted()
        XCTAssertEqual(registry.summary.unacknowledgedCompleted, 0)
    }

    /// 異常終了は確認では消さない。見ただけでは解決しないため。
    func testErrorIsNotClearedByAcknowledge() {
        var registry = SessionRegistry()
        registry.apply(event(.turnFailed(message: "API Error"), key("e1"), 0))
        registry.acknowledgeCompleted()
        XCTAssertEqual(registry.summary.error, 1, "異常終了は出し続ける")
    }

    /// 実行中のセッションは確認の対象外（状態が変わっていないので消えては困る）。
    func testRunningIsUnaffectedByAcknowledge() {
        var registry = SessionRegistry()
        registry.apply(event(.activity, key("r1"), 0))
        registry.acknowledgeCompleted()
        XCTAssertEqual(registry.summary.running, 1)
    }
}
