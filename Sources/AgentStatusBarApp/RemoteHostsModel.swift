import Foundation
import Observation
import ASBApplication

/// リモートホスト（SSH 越し）の監視設定を扱う。
///
/// `~/.ssh/config` から候補を列挙し、ユーザーが選んだホストへトンネルを張る。
/// 有効なホストは `config.json`（`AppSettings.remotes`）に保存し、次回起動時に張り直す。
@MainActor
@Observable
final class RemoteHostsModel {
    /// `~/.ssh/config` から見つかった Host 一覧。
    private(set) var hosts: [String] = []
    /// トンネルを張る対象。
    private(set) var enabled: Set<String> = []
    /// ホストごとの接続状態。supervisor の変化に追従する。
    private(set) var states: [String: TunnelState] = [:]
    /// ホストごとの初期設定（shim/hook）状態。bootstrapper の変化に追従する。
    private(set) var bootstrapStates: [String: BootstrapState] = [:]

    private let store: SettingsStore
    private let enumerator: RemoteHostEnumerator
    private let supervisor: any TunnelSupervising
    private let bootstrapper: any RemoteBootstrapping

    init(
        store: SettingsStore,
        enumerator: RemoteHostEnumerator,
        supervisor: any TunnelSupervising,
        bootstrapper: any RemoteBootstrapping
    ) {
        self.store = store
        self.enumerator = enumerator
        self.supervisor = supervisor
        self.bootstrapper = bootstrapper

        self.hosts = enumerator.availableHosts()
        self.enabled = Set(store.current().remotes.filter(\.enabled).map(\.alias))

        supervisor.onChange = { [weak self] in self?.refreshStates() }
        bootstrapper.onChange = { [weak self] in self?.refreshStates() }
        // 保存済みの有効ホストへトンネルを張る（起動時は再設定はしない＝トグル ON 時のみ）。
        supervisor.setEnabled(Array(enabled))
        refreshStates()
    }

    /// リモート側の設定手順に使うソケットパス。
    var remoteSocketPath: String { supervisor.remoteSocketPath }

    var isEmpty: Bool { hosts.isEmpty }

    func isEnabled(_ alias: String) -> Bool { enabled.contains(alias) }

    func state(for alias: String) -> TunnelState { states[alias] ?? .idle }

    func bootstrapState(for alias: String) -> BootstrapState { bootstrapStates[alias] ?? .idle }

    /// `~/.ssh/config` を読み直す。
    func reload() {
        hosts = enumerator.availableHosts()
        refreshStates()
    }

    func setEnabled(_ alias: String, _ on: Bool) {
        if on { enabled.insert(alias) } else { enabled.remove(alias) }

        // 他モデルの変更を潰さないよう、保存直前に最新を読み直して remotes だけ載せ替える。
        var settings = store.current()
        settings.remotes = enabled.sorted().map { AppSettings.RemoteHost(alias: $0, enabled: true) }
        try? store.save(settings)

        supervisor.setEnabled(Array(enabled))
        // ON: トンネルを張りつつ、リモートへ shim 配置 + hook 登録。OFF: hook を解除。
        if on {
            bootstrapper.bootstrap(alias)
        } else {
            bootstrapper.teardown(alias)
        }
        refreshStates()
    }

    private func refreshStates() {
        var next: [String: TunnelState] = [:]
        var boots: [String: BootstrapState] = [:]
        for host in hosts {
            next[host] = supervisor.state(for: host)
            boots[host] = bootstrapper.state(for: host)
        }
        // 一覧に無い（config から消えた）が有効なホストも状態は見せる。
        for alias in enabled where next[alias] == nil {
            next[alias] = supervisor.state(for: alias)
            boots[alias] = bootstrapper.state(for: alias)
        }
        states = next
        bootstrapStates = boots
    }
}
