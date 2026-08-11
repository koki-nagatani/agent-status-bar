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

/// ログイン時の自動起動。
///
/// 状態は OS 側が保持するため、`config.json` には持たない。
/// 二重管理になると「設定では ON なのに実際は起動しない」という食い違いが起きる。
public protocol LoginItemController: Sendable {
    /// 登録済みで有効か。
    var isEnabled: Bool { get }
    /// 登録はされたが、ユーザーがシステム設定で許可する必要がある状態か。
    var needsApproval: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

/// 通知。`gone` への遷移（中断）では呼ばれない。
/// ターミナルを閉じるたびに通知が飛ぶのを避けるため。
public protocol Notifier: Sendable {
    func notifyCompleted(_ session: AgentSession) async
    func notifyFailed(_ session: AgentSession) async
    func notifyWaiting(_ session: AgentSession) async
}
