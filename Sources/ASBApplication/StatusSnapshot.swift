import Foundation
import ASBDomain

/// UI へ渡す不変のスナップショット。
public struct StatusSnapshot: Sendable, Equatable {
    public let summary: SessionRegistry.Summary
    /// 表示順にソート済み。判断待ちが最上部に来る。
    public let sessions: [AgentSession]

    public init(summary: SessionRegistry.Summary, sessions: [AgentSession]) {
        self.summary = summary
        self.sessions = sessions
    }

    public static let empty = StatusSnapshot(summary: .init(), sessions: [])

    /// メニューバーに常時表示する文字列。
    ///
    /// 0 件の状態は出さない。`🔵 0` のような表示は情報量がなく、
    /// 「確認しなくても状況が目に入る」ことを妨げるため。
    /// 中断はカウントしない（見ても行動につながらないため詳細パネルのみで示す）。
    /// 完了は「前回パネルを開いてから完了した件数」を出す。
    public var menuBarTitle: String {
        var parts: [String] = []
        if summary.running > 0 { parts.append("🔵 \(summary.running)") }
        if summary.waiting > 0 { parts.append("🟡 \(summary.waiting)") }
        // 総数ではなく未確認分。パネルを開くとリセットされる。
        if summary.unacknowledgedCompleted > 0 { parts.append("🟢 \(summary.unacknowledgedCompleted)") }
        if summary.error > 0 { parts.append("🔴 \(summary.error)") }
        return parts.joined(separator: "  ")
    }
}

/// 表示順の決定。判断待ち → 実行中 → 完了/異常 → 中断。
/// 同順位内は更新時刻の新しい順。
///
/// 判断待ちを最上部に置くのは、それがユーザーの行動を要求する唯一の状態だからである。
public func displayOrder(_ sessions: [AgentSession]) -> [AgentSession] {
    func rank(_ s: AgentSession) -> Int {
        if s.isAbandoned { return 4 }
        switch s.status {
        case .waiting: return 0
        case .running: return 1
        case .error: return 2
        case .completed: return 3
        }
    }
    return sessions.sorted {
        rank($0) != rank($1) ? rank($0) < rank($1) : $0.updatedAt > $1.updatedAt
    }
}
