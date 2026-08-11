import Foundation
import ASBDomain

/// 表示用のラベル。UI と開発用デーモンで同じ表現を使うために Application 層に置く。
public extension AgentSession {
    /// 状態を表す記号。READMEの色分けに対応する。
    var displaySymbol: String {
        if isAbandoned { return "⏹" }
        switch status {
        case .running: return "🔵"
        case .waiting: return "🟡"
        case .completed: return "🟢"
        case .error: return "🔴"
        }
    }

    var displayStatus: String {
        if isAbandoned { return "中断" }
        switch status {
        case .running: return liveness == .stale ? "実行中 (応答なし)" : "実行中"
        case .waiting: return "判断待ち"
        case .completed: return "完了"
        case .error: return "異常終了"
        }
    }

    /// `cwd` の末尾要素。一覧では省略形を、詳細ではフルパスを見せる。
    var displayName: String {
        (cwd as NSString).lastPathComponent
    }

    var providerLabel: String {
        switch key.provider {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }
}
