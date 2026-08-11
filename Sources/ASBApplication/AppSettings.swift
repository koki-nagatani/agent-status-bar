import Foundation

/// ユーザーが設定ファイルで変更できる項目。
///
/// 音は状態ごとに変えられる。`null` または `"none"` を指定すると鳴らさない。
public struct AppSettings: Sendable, Equatable, Codable {

    public struct Sounds: Sendable, Equatable, Codable {
        /// ターン完了（`Stop`）。最も頻繁に鳴る。
        public var completed: String?
        /// 承認待ちに入ったとき。
        public var waiting: String?
        /// 異常終了。完了と聞き分けられる音にする。
        public var failed: String?

        public init(completed: String? = "Glass", waiting: String? = "Blow", failed: String? = "Basso") {
            self.completed = completed
            self.waiting = waiting
            self.failed = failed
        }
    }

    public var sounds: Sounds
    /// バナー通知を出すか。音とは独立に切れる。
    public var bannerEnabled: Bool
    /// すべての音を止める。個別の音設定を保持したまま一括で黙らせるためのもの。
    ///
    /// 会議中など一時的に静かにしたい状況が想定用途なので、
    /// 折りたたみの中ではなくパネルを開いた時点で操作できる位置に置く。
    public var muted: Bool

    public init(sounds: Sounds = .init(), bannerEnabled: Bool = true, muted: Bool = false) {
        self.sounds = sounds
        self.bannerEnabled = bannerEnabled
        self.muted = muted
    }

    public static let `default` = AppSettings()

    /// 欠けているキーはデフォルトを使う（部分的な設定ファイルを許す）。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sounds = try container.decodeIfPresent(Sounds.self, forKey: .sounds) ?? Sounds()
        bannerEnabled = try container.decodeIfPresent(Bool.self, forKey: .bannerEnabled) ?? true
        muted = try container.decodeIfPresent(Bool.self, forKey: .muted) ?? false
    }
}

public extension AppSettings.Sounds {
    /// 欠けているキーはデフォルト音を使う。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AppSettings.Sounds()
        completed = try container.decodeIfPresent(String.self, forKey: .completed) ?? fallback.completed
        waiting = try container.decodeIfPresent(String.self, forKey: .waiting) ?? fallback.waiting
        failed = try container.decodeIfPresent(String.self, forKey: .failed) ?? fallback.failed
    }
}

/// 設定の読み出し。ファイルを編集したら次の通知から反映されることを期待する。
public protocol SettingsProvider: Sendable {
    func current() -> AppSettings
}

/// 設定の書き込み。UI から変更するために必要。
public protocol SettingsStore: SettingsProvider {
    func save(_ settings: AppSettings) throws
}

/// 選べる音の一覧と試聴。
///
/// どんな音が使えるかは OS 側の知識なので port として切る。
/// 試聴が port にあるのは、UI から `NSSound` を直接触らせないため。
public protocol SoundCatalog: Sendable {
    /// 選択肢として提示する音の名前。
    var names: [String] { get }
    /// その場で鳴らす。設定を選んだ瞬間に音を確認できるようにする。
    func preview(_ name: String) async
}

/// 音を設定できる契機。
public enum SoundSlot: String, Sendable, CaseIterable {
    case completed
    case waiting
    case failed

    public var label: String {
        switch self {
        case .completed: return "完了"
        case .waiting: return "判断待ち"
        case .failed: return "異常終了"
        }
    }
}

public extension AppSettings {
    /// 実際に鳴らす音。ミュート中は常に無音。
    func effectiveSound(for slot: SoundSlot) -> String? {
        muted ? nil : normalizedSoundName(sound(for: slot))
    }

    func sound(for slot: SoundSlot) -> String? {
        switch slot {
        case .completed: return sounds.completed
        case .waiting: return sounds.waiting
        case .failed: return sounds.failed
        }
    }

    mutating func setSound(_ name: String?, for slot: SoundSlot) {
        switch slot {
        case .completed: sounds.completed = name
        case .waiting: sounds.waiting = name
        case .failed: sounds.failed = name
        }
    }
}

/// `"none"` `""` `null` はいずれも「鳴らさない」を意味する。
public func normalizedSoundName(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty || trimmed.lowercased() == "none" { return nil }
    return trimmed
}
