import Foundation
import ASBDomain

/// inbound port。**イベントの入力元を差し替える箇所**。
/// composition root でこの実装を入れ替えるだけで、Domain / Application / UI は変更不要。
public protocol AgentEventSource: Sendable {
    /// 受け取ったイベントを引数のハンドラへ流し続ける。
    func start(_ onEvent: @escaping @Sendable (AgentEvent) -> Void) throws
    func stop()
}

/// 現在時刻。stale 判定をテスト可能にするために port にしている。
public protocol Clock: Sendable {
    var now: Date { get }
}

/// プロセスの生存確認。
public protocol ProcessProbe: Sendable {
    func isAlive(_ pid: ProcessID) -> Bool
}

/// 通知。`gone` への遷移（中断）では呼ばれない。
/// ターミナルを閉じるたびに通知が飛ぶのを避けるため。
public protocol Notifier: Sendable {
    func notifyCompleted(_ session: AgentSession) async
    func notifyFailed(_ session: AgentSession) async
    func notifyWaiting(_ session: AgentSession) async
}
