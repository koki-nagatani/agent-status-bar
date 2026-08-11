import XCTest
@testable import ASBApplication
import ASBDomain

/// メニューバーに何が出るかを決めるロジック。UI を目視しなくても壊れを検出できるようにする。
final class StatusSnapshotTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func session(
        _ id: String,
        _ status: AgentStatus,
        _ liveness: Liveness = .live,
        cwd: String = "/work/proj",
        provider: AgentProvider = .claude,
        updated: TimeInterval = 0
    ) -> AgentSession {
        AgentSession(
            key: SessionKey(provider: provider, sessionId: id),
            cwd: cwd,
            status: status,
            liveness: liveness,
            updatedAt: now.addingTimeInterval(updated)
        )
    }

    private func snapshot(_ sessions: [AgentSession]) -> StatusSnapshot {
        var registry = SessionRegistry()
        for s in sessions {
            let kind: AgentEvent.Kind = switch s.status {
            case .running: .activity
            case .waiting: .awaitingApproval
            case .completed: .turnCompleted
            case .error: .turnFailed(message: nil)
            }
            registry.apply(AgentEvent(key: s.key, cwd: s.cwd, kind: kind, pid: nil, at: s.updatedAt))
            if s.liveness == .gone {
                registry.apply(AgentEvent(key: s.key, cwd: s.cwd, kind: .sessionEnded, pid: nil, at: s.updatedAt))
            }
        }
        return StatusSnapshot(summary: registry.summary, sessions: displayOrder(registry.all))
    }

    // MARK: - メニューバーの文字列

    /// 実行中・判断待ち・完了・異常終了をこの順で並べる。
    /// 完了は未確認分のみ（このスナップショットはまだ開かれていない）。
    func testMenuBarTitleShowsAllFourStates() {
        let s = snapshot([
            session("r1", .running),
            session("r2", .running),
            session("w1", .waiting),
            session("c1", .completed),
            session("e1", .error),
        ])
        XCTAssertEqual(s.menuBarTitle, "🔵 2  🟡 1  🟢 1  🔴 1")
    }

    func testMenuBarTitleShowsCompletedAlone() {
        XCTAssertEqual(snapshot([session("c1", .completed)]).menuBarTitle, "🟢 1")
    }

    /// 0 件の状態は出さない。`🔵 0` のような表示は情報量がない。
    func testMenuBarTitleOmitsZeroCounts() {
        let s = snapshot([session("r1", .running)])
        XCTAssertEqual(s.menuBarTitle, "🔵 1")
        XCTAssertEqual(StatusSnapshot.empty.menuBarTitle, "")
    }

    func testMenuBarTitleShowsErrors() {
        let s = snapshot([session("e1", .error), session("r1", .running)])
        XCTAssertEqual(s.menuBarTitle, "🔵 1  🔴 1")
    }

    /// 死んだセッションを実行中として数えてはならない。中断もメニューバーには出さない。
    func testAbandonedSessionIsNotCountedInMenuBar() {
        let s = snapshot([session("gone", .running, .gone)])
        XCTAssertEqual(s.menuBarTitle, "", "中断は見ても行動につながらないため出さない")
        XCTAssertEqual(s.summary.abandoned, 1)
        XCTAssertEqual(s.summary.running, 0)
    }

    // MARK: - 表示順

    /// 判断待ちはユーザーの行動を要求する唯一の状態なので最上部に置く。
    func testWaitingComesFirst() {
        let s = snapshot([
            session("c1", .completed, updated: 30),
            session("r1", .running, updated: 20),
            session("w1", .waiting, updated: 10),
        ])
        XCTAssertEqual(s.sessions.first?.key.sessionId, "w1", "更新が古くても判断待ちを先頭に出す")
    }

    func testOrderIsWaitingRunningErrorCompletedAbandoned() {
        let s = snapshot([
            session("gone", .running, .gone, updated: 50),
            session("c1", .completed, updated: 40),
            session("e1", .error, updated: 30),
            session("r1", .running, updated: 20),
            session("w1", .waiting, updated: 10),
        ])
        XCTAssertEqual(s.sessions.map(\.key.sessionId), ["w1", "r1", "e1", "c1", "gone"])
    }

    func testSameRankIsOrderedByRecency() {
        let s = snapshot([
            session("old", .running, updated: 10),
            session("new", .running, updated: 99),
        ])
        XCTAssertEqual(s.sessions.map(\.key.sessionId), ["new", "old"])
    }

    // MARK: - 行の表示

    func testDisplayNameIsDirectoryBasename() {
        let s = session("s", .running, cwd: "/Users/u/projects/api-server")
        XCTAssertEqual(s.displayName, "api-server")
    }

    func testProviderLabels() {
        XCTAssertEqual(session("s", .running, provider: .claude).providerLabel, "Claude Code")
        XCTAssertEqual(session("s", .running, provider: .codex).providerLabel, "Codex")
    }

    /// stale は「実行中だが応答がない」ことを区別して見せる。
    func testStaleIsDistinguishedInStatusLabel() {
        XCTAssertEqual(session("s", .running, .live).displayStatus, "実行中")
        XCTAssertEqual(session("s", .running, .stale).displayStatus, "実行中 (応答なし)")
        XCTAssertEqual(session("s", .running, .gone).displayStatus, "中断")
    }

    func testSymbols() {
        XCTAssertEqual(session("s", .running).displaySymbol, "🔵")
        XCTAssertEqual(session("s", .waiting).displaySymbol, "🟡")
        XCTAssertEqual(session("s", .completed).displaySymbol, "🟢")
        XCTAssertEqual(session("s", .error).displaySymbol, "🔴")
        XCTAssertEqual(session("s", .running, .gone).displaySymbol, "⏹")
    }
}
