import Foundation
import Observation
import ASBDomain
import ASBApplication

/// actor が publish するスナップショットを SwiftUI が観測できる形に橋渡しする。
///
/// UI 側にドメインロジックは持たせない。ここは購読と保持だけを行う。
@MainActor
@Observable
final class StatusModel {
    private(set) var snapshot: StatusSnapshot = .empty

    private let service: AgentStatusService
    private var subscription: Task<Void, Never>?

    init(service: AgentStatusService) {
        self.service = service
    }

    func start() {
        guard subscription == nil else { return }
        subscription = Task { [service] in
            for await next in await service.snapshots() {
                self.snapshot = next
            }
        }
    }

    /// 詳細パネルが表示されたときに呼ぶ。
    func acknowledgeCompleted() {
        Task { [service] in await service.acknowledgeCompleted() }
    }

    func stop() {
        subscription?.cancel()
        subscription = nil
    }

    // deinit は置かない。このモデルはアプリのライフタイム全体を通じて生存し、
    // @MainActor 隔離された状態を deinit から触ることは Swift 6 では許されない。
}
