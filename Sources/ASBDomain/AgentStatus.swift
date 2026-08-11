/// Agent が何をしているか。README の4状態。
///
/// `liveness` とは直交する。「何をしているか」と「その情報をまだ信じてよいか」は
/// 別の問いであるため、単一の enum に混ぜない。
public enum AgentStatus: String, Sendable, CaseIterable {
    case running
    case waiting
    case completed
    case error
}

/// その情報をまだ信じてよいか。
public enum Liveness: String, Sendable, CaseIterable {
    /// 直近にイベントがあり、プロセスも生存している。
    case live
    /// プロセスは生存しているが一定時間イベントがない。
    case stale
    /// プロセスが存在しない。
    case gone
}

public enum AgentProvider: String, Sendable, CaseIterable {
    case claude
    case codex
}

/// Agent 本体のプロセス ID。Domain を Darwin 非依存に保つため独自に定義する。
public typealias ProcessID = Int32
