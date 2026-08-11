import Foundation
import ServiceManagement
import ASBApplication

/// `SMAppService` によるログイン項目の登録。
///
/// アプリ自身が登録するため、ユーザーがシステム設定を開いて追加する必要がない。
///
/// **登録されるのは実行中の `.app` の場所である。** `build/` の中から起動している場合、
/// 再ビルドで `.app` が作り直されるとログイン項目が壊れる。
/// `/Applications` などの固定の場所に置いてから有効にすること。
public struct SMLoginItem: LoginItemController {

    public init() {}

    public var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// macOS が「ログイン項目として登録されたが、ユーザーの許可待ち」と判断している状態。
    /// この場合はシステム設定 > 一般 > ログイン項目 で有効にしてもらう必要がある。
    public var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// 診断用。状態をそのまま文字列で返す。
    public var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "enabled"
        case .notRegistered: return "notRegistered"
        case .notFound: return "notFound"
        case .requiresApproval: return "requiresApproval"
        @unknown default: return "unknown"
        }
    }
}
