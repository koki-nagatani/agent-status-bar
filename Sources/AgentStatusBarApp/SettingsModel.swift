import Foundation
import Observation
import ASBApplication

/// 設定の編集。変更は即座に保存し、次の通知から反映される。
@MainActor
@Observable
final class SettingsModel {
    private(set) var settings: AppSettings
    let soundNames: [String]

    /// 保存直後に短時間だけ true になる。即時保存方式では
    /// 「変更が効いたのか」がユーザーに分からないため、目に見える合図を出す。
    private(set) var showSavedIndicator = false
    private var indicatorTask: Task<Void, Never>?

    /// すでに既定値なら「既定に戻す」は無効にする。
    var isDefault: Bool { settings == .default }

    private let store: SettingsStore
    private let catalog: SoundCatalog
    private let loginItem: LoginItemController

    /// 「なし」を表す選択肢。`config.json` 上は `"none"` になる。
    static let silentLabel = "なし"

    init(store: SettingsStore, catalog: SoundCatalog, loginItem: LoginItemController) {
        self.store = store
        self.catalog = catalog
        self.loginItem = loginItem
        self.settings = store.current()
        self.soundNames = catalog.names
        self.launchesAtLogin = loginItem.isEnabled
        self.loginItemNeedsApproval = loginItem.needsApproval
    }

    // MARK: - ログイン時に起動

    /// OS 側が持つ状態のミラー。`config.json` には保存しない。
    private(set) var launchesAtLogin: Bool = false
    /// システム設定での許可待ちか。
    private(set) var loginItemNeedsApproval: Bool = false
    private(set) var loginItemError: String?

    func setLaunchesAtLogin(_ enabled: Bool) {
        do {
            try loginItem.setEnabled(enabled)
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        // 成否にかかわらず OS の実際の状態を読み直す
        launchesAtLogin = loginItem.isEnabled
        loginItemNeedsApproval = loginItem.needsApproval
        flashSaved()
    }

    /// 選択された音を保存し、その場で鳴らして確認できるようにする。
    func select(_ name: String?, for slot: SoundSlot) {
        var updated = settings
        updated.setSound(name ?? "none", for: slot)
        persist(updated)

        // ミュート中は試聴しても鳴らない（実際の挙動と一致させる）
        if let name = updated.effectiveSound(for: slot) {
            Task { await catalog.preview(name) }
        }
    }

    var isMuted: Bool { settings.muted }

    /// UI では「ミュートかどうか」ではなく「音を鳴らすか」を扱う。
    /// スイッチがオン＝音が鳴る、という向きの方が直感的なため。
    var soundEnabled: Bool { !settings.muted }

    /// オンに戻したときは、いま鳴る音を確認できるよう完了音を鳴らす。
    func setSoundEnabled(_ enabled: Bool) {
        guard enabled != soundEnabled else { return }
        var updated = settings
        updated.muted = !enabled
        persist(updated)

        if enabled, let name = updated.effectiveSound(for: .completed) {
            Task { await catalog.preview(name) }
        }
    }

    func setBannerEnabled(_ enabled: Bool) {
        var updated = settings
        updated.bannerEnabled = enabled
        persist(updated)
    }

    /// 即時保存で戻せなくなるのを防ぐための退路。
    func resetToDefaults() {
        guard !isDefault else { return }
        persist(.default)
    }

    /// 表示用。`nil` や `"none"` は「なし」として見せる。
    func displayedSelection(for slot: SoundSlot) -> String {
        normalizedSoundName(settings.sound(for: slot)) ?? Self.silentLabel
    }

    private func persist(_ updated: AppSettings) {
        settings = updated
        do {
            try store.save(updated)
            flashSaved()
        } catch {
            FileHandle.standardError.write(
                Data("設定を保存できなかった: \(error.localizedDescription)\n".utf8)
            )
        }
    }

    private func flashSaved() {
        indicatorTask?.cancel()
        showSavedIndicator = true
        indicatorTask = Task {
            try? await Task.sleep(for: .milliseconds(1400))
            guard !Task.isCancelled else { return }
            showSavedIndicator = false
        }
    }
}
