import Foundation
import ASBDomain

/// 全 Agent セッションの状態を管理する中核。
///
/// MVP では状態を永続化しない。プロセス再起動でリセットしてよい。
public actor AgentStatusService {
    public struct Configuration: Sendable {
        /// プロセスは生きているがイベントが途絶えたと見なす閾値。
        public var staleAfter: TimeInterval = 900
        /// completed / error の保持件数。
        public var keepFinished: Int = 20
        /// completed / error の保持期間。
        public var finishedTTL: TimeInterval = 86_400
        /// 中断セッションの保持期間。
        public var abandonedTTL: TimeInterval = 600

        public init() {}
    }

    private var registry = SessionRegistry()
    private let clock: Clock
    private let probe: ProcessProbe
    private let notifier: Notifier
    private let configuration: Configuration

    private var subscribers: [UUID: AsyncStream<StatusSnapshot>.Continuation] = [:]

    public init(clock: Clock, probe: ProcessProbe, notifier: Notifier, configuration: Configuration = .init()) {
        self.clock = clock
        self.probe = probe
        self.notifier = notifier
        self.configuration = configuration
    }

    // MARK: - 購読

    public func snapshots() -> AsyncStream<StatusSnapshot> {
        AsyncStream { continuation in
            let id = UUID()
            subscribers[id] = continuation
            continuation.yield(currentSnapshot())
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id) }
            }
        }
    }

    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }

    public func currentSnapshot() -> StatusSnapshot {
        StatusSnapshot(summary: registry.summary, sessions: displayOrder(registry.all))
    }

    private func publish() {
        let snapshot = currentSnapshot()
        for continuation in subscribers.values { continuation.yield(snapshot) }
    }

    // MARK: - イベント取り込み

    public func ingest(_ event: AgentEvent) async {
        let effects = registry.apply(event)
        publish()

        for effect in effects {
            switch effect {
            case .notifyCompleted(let key):
                if let session = registry[key] { await notifier.notifyCompleted(session) }
            case .notifyFailed(let key):
                if let session = registry[key] { await notifier.notifyFailed(session) }
            case .notifyWaiting(let key):
                if let session = registry[key] { await notifier.notifyWaiting(session) }
            }
        }
    }

    /// 詳細パネルが開かれたときに呼ぶ。メニューバーの完了バッジをリセットする。
    public func acknowledgeCompleted() {
        registry.acknowledgeCompleted()
        publish()
    }

    // MARK: - 定期処理

    /// liveness の再評価と eviction。タイマーから呼ぶ。
    public func tick() {
        let now = clock.now
        registry.evaluateLiveness(now: now, staleAfter: configuration.staleAfter) { [probe] pid in
            probe.isAlive(pid)
        }
        registry.evict(
            now: now,
            keepCompleted: configuration.keepFinished,
            completedTTL: configuration.finishedTTL,
            abandonedTTL: configuration.abandonedTTL
        )
        publish()
    }
}
