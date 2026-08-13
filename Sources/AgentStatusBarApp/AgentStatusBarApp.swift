import SwiftUI
import ASBDomain
import ASBApplication
import ASBAdapters

/// composition root。
///
/// ここが port と adapter を結線する唯一の場所である。
/// イベントの入力元を差し替える場合、変更するのは `eventSource` の生成だけで、
/// Domain / Application / UI は一切触らない。
@MainActor
final class Composition {
    let service: AgentStatusService
    let settingsStore: SettingsStore
    let soundCatalog: SoundCatalog
    let loginItem: LoginItemController
    let remoteEnumerator: RemoteHostEnumerator
    let tunnelSupervisor: RemoteTunnelSupervisor
    let remoteBootstrapper: RemoteBootstrapper
    private let eventSource: AgentEventSource
    private var tickTask: Task<Void, Never>?

    /// liveness の再評価間隔。stale 判定の粒度もこれに依存する。
    private static let tickInterval: Duration = .seconds(5)

    static let socketPath: String = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AgentStatusBar", isDirectory: true)
        return base.appendingPathComponent("asb.sock").path
    }()

    /// リモート側へ `ssh -R` で転送するソケットのパス。
    /// 同一リモート上での取り違えを避けるため、ローカルのユーザー名を混ぜる。
    static let remoteSocketPath: String = {
        let slug = NSUserName().unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
        return "/tmp/agent-status-bar-\(String(slug)).sock"
    }()

    /// リモートへ配布する shim の在り処。setup-hooks が配置したものを使う。
    static let shimPath: String = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AgentStatusBar", isDirectory: true)
        return base.appendingPathComponent("asb-hook").path
    }()

    init() {
        let clock = SystemClock()
        // 設定ファイルは編集すると次の通知から反映される（再起動不要）
        let settings = FileSettingsStore()
        settingsStore = settings
        soundCatalog = SystemSoundCatalog()
        loginItem = SMLoginItem()
        remoteEnumerator = SSHConfigReader()
        tunnelSupervisor = RemoteTunnelSupervisor(
            localSocketPath: Self.socketPath,
            remoteSocketPath: Self.remoteSocketPath
        )
        remoteBootstrapper = RemoteBootstrapper(
            localShimPath: Self.shimPath,
            remoteSocketPath: Self.remoteSocketPath
        )
        service = AgentStatusService(
            clock: clock,
            probe: SignalProcessProbe(),
            notifier: MacNotifier(settings: settings)
        )
        eventSource = UnixSocketHookServer(
            socketPath: Self.socketPath,
            clock: clock,
            onDecodeFailure: { error in
                FileHandle.standardError.write(Data("hook decode failure: \(error)\n".utf8))
            }
        )
    }

    func start() {
        let service = service
        do {
            try eventSource.start { event in
                Task { await service.ingest(event) }
            }
        } catch {
            FileHandle.standardError.write(
                Data("hook server failed to start: \(error)\n".utf8)
            )
        }

        // PID 生存確認と eviction
        tickTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                await service.tick()
            }
        }
    }

    func stop() {
        tickTask?.cancel()
        eventSource.stop()
        tunnelSupervisor.shutdown()
    }
}

@main
struct AgentStatusBarApp: App {
    @State private var model: StatusModel
    @State private var settings: SettingsModel
    @State private var remoteHosts: RemoteHostsModel
    private let composition: Composition

    init() {
        let composition = Composition()
        self.composition = composition
        _model = State(initialValue: StatusModel(service: composition.service))
        _settings = State(initialValue: SettingsModel(
            store: composition.settingsStore,
            catalog: composition.soundCatalog,
            loginItem: composition.loginItem
        ))
        _remoteHosts = State(initialValue: RemoteHostsModel(
            store: composition.settingsStore,
            enumerator: composition.remoteEnumerator,
            supervisor: composition.tunnelSupervisor,
            bootstrapper: composition.remoteBootstrapper
        ))
    }

    var body: some Scene {
        MenuBarExtra {
            DetailPanel(
                snapshot: model.snapshot,
                settings: settings,
                remoteHosts: remoteHosts,
                onAppear: { model.acknowledgeCompleted() }
            )
        } label: {
            MenuBarLabel(snapshot: model.snapshot)
                .task {
                    model.start()
                    composition.start()
                }
        }
        .menuBarExtraStyle(.window)
    }
}

/// メニューバーに常時見えている部分。
///
/// 「確認しなくても状況が目に入る」ことを優先し、表示は最小限にする。
/// 完了件数は通常時に出さない。
private struct MenuBarLabel: View {
    let snapshot: StatusSnapshot

    var body: some View {
        if snapshot.menuBarTitle.isEmpty {
            // 何も動いていないときも存在は示すが、目を引かないようにする
            Image(systemName: "circle.dotted")
        } else {
            Text(snapshot.menuBarTitle)
        }
    }
}
