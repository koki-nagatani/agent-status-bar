import AppKit
import Foundation
import UserNotifications
import ASBDomain
import ASBApplication

/// macOS の通知音とバナー。
///
/// **音とバナーで信頼性が違うため、意図的に分けて扱う。**
///
/// - 音（`NSSound`）は許可を一切必要とせず、常に鳴る。本アプリが重視している
///   「完了に気づく」という価値の中心はこちらにある
/// - バナー（`UNUserNotificationCenter`）はユーザーの許可を必要とし、
///   ad-hoc 署名のアプリでは通知システムへの登録自体に失敗することがある。best-effort とする
///
/// したがって音を先に鳴らし、バナーの成否に依存させない。
public actor MacNotifier: Notifier {

    private let settings: SettingsProvider
    private var bannerState: BannerState = .unknown

    private enum BannerState {
        case unknown
        case authorized
        case unavailable(String)

        var isAuthorized: Bool {
            if case .authorized = self { return true }
            return false
        }
    }

    public init(settings: SettingsProvider) {
        self.settings = settings
    }

    public func notifyCompleted(_ session: AgentSession) async {
        await play(.completed)
        await postBanner(
            title: "\(session.providerLabel) completed",
            body: session.cwd,
            identifier: "completed-\(session.key.sessionId)"
        )
    }

    public func notifyFailed(_ session: AgentSession) async {
        await play(.failed)
        var body = session.cwd
        if let message = session.errorMessage, !message.isEmpty {
            body += "\n\(message)"
        }
        await postBanner(
            title: "\(session.providerLabel) failed",
            body: body,
            identifier: "failed-\(session.key.sessionId)"
        )
    }

    public func notifyWaiting(_ session: AgentSession) async {
        await play(.waiting)
        await postBanner(
            title: "\(session.providerLabel) needs approval",
            body: session.cwd,
            identifier: "waiting-\(session.key.sessionId)"
        )
    }

    /// ミュート中、または `null` / `"none"` が指定されていれば鳴らさない。
    private func play(_ slot: SoundSlot) async {
        guard let name = settings.current().effectiveSound(for: slot) else { return }
        await SoundPlayer.play(name)
    }

    // MARK: - バナー（best-effort）

    private func postBanner(title: String, body: String, identifier: String) async {
        guard settings.current().bannerEnabled else { return }
        guard await ensureBannerAuthorization() else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // 音は NSSound 側で鳴らしているので、ここでは鳴らさない（二重再生を避ける）
        content.sound = nil

        do {
            try await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            )
        } catch {
            bannerState = .unavailable("add failed: \(error.localizedDescription)")
            logBannerState()
        }
    }

    private func ensureBannerAuthorization() async -> Bool {
        switch bannerState {
        case .authorized: return true
        case .unavailable: return false
        case .unknown: break
        }

        guard Bundle.main.bundleIdentifier != nil else {
            // `.app` バンドル外（swift run など）では利用できない
            bannerState = .unavailable("bundle identifier がない")
            logBannerState()
            return false
        }

        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert])
            bannerState = granted ? .authorized : .unavailable("ユーザーが許可しなかった")
        } catch {
            // 署名や通知システムへの登録の問題でここに来る。
            // 音は鳴っているので致命的ではない。
            bannerState = .unavailable(error.localizedDescription)
        }
        logBannerState()
        return bannerState.isAuthorized
    }

    private func logBannerState() {
        guard case .unavailable(let reason) = bannerState else { return }
        FileHandle.standardError.write(
            Data("banner 通知は利用できない（音のみ動作）: \(reason)\n".utf8)
        )
    }
}
