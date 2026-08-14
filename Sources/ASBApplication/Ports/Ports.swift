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

/// 監視候補のリモートホストを列挙する。`~/.ssh/config` を読む adapter が実装する。
public protocol RemoteHostEnumerator: Sendable {
    /// `~/.ssh/config` の Host エイリアス（ワイルドカードは除く）。呼ぶたびに読み直す。
    func availableHosts() -> [String]
}

/// SSH リバーストンネルの状態。
public enum TunnelState: Sendable, Equatable {
    /// 無効（張っていない）。
    case idle
    /// 接続試行中。
    case connecting
    /// 確立済み。
    case connected
    /// 失敗（理由つき）。再接続を続ける。
    case failed(String)
}

/// リモートの初期設定（shim 配置・hook 登録）の状態。
public enum BootstrapState: Sendable, Equatable {
    /// 未実施。
    case idle
    /// 実施中（ssh で shim 転送・hook 登録中）。
    case running
    /// 完了。
    case done
    /// 失敗（理由つき）。
    case failed(String)
}

/// リモートの初期設定を行う。トグル ON で shim を配り hook を登録、OFF で解除する。
///
/// リモートに node を要求しないよう、`settings.json` の編集はローカルで行い、
/// ssh は取得と書き戻し（`cat`）にだけ使う。UI から駆動されるため MainActor 隔離。
@MainActor
public protocol RemoteBootstrapping: AnyObject {
    /// shim を配置し hook を登録する。
    func bootstrap(_ alias: String)
    /// hook 登録を解除する（shim は残す）。
    func teardown(_ alias: String)
    func state(for alias: String) -> BootstrapState
    var onChange: (@MainActor () -> Void)? { get set }
}

/// ホストごとの SSH リバーストンネルの監督。
///
/// enable されたホストへトンネルを張り続け（落ちたら再接続）、disable されたら畳む。
/// UI から駆動されるため MainActor に隔離する。
@MainActor
public protocol TunnelSupervising: AnyObject {
    /// この集合のホストだけトンネルを維持する（差分適用）。
    func setEnabled(_ aliases: [String])
    /// 全トンネルを停止する（アプリ終了時）。
    func shutdown()
    func state(for alias: String) -> TunnelState
    /// リモート側に転送されるソケットのパス（リモートの設定手順に使う、表示用）。
    var remoteSocketPath: String { get }
    /// 状態が変わったときに呼ばれる。UI の再描画に使う。
    var onChange: (@MainActor () -> Void)? { get set }
    /// トンネルが落ちた／畳まれたときに、そのホストのエイリアスで呼ばれる。
    /// 経路が切れた間のリモートセッションは状態が更新されないため、片付けに使う。
    var onDisconnected: (@MainActor (String) -> Void)? { get set }
}
