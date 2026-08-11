import Foundation
import ASBApplication

/// `config.json` から設定を読む。
///
/// - 存在しなければデフォルト値で新規作成する（ユーザーが場所と項目を発見できるように）
/// - 更新時刻を見て変更を検知するため、**編集すると次の通知から反映される**
///   （アプリの再起動は不要）
/// - 壊れた JSON は直前の正常な設定を保持し、警告を一度だけ出す
public final class FileSettingsStore: SettingsStore, @unchecked Sendable {
    // @unchecked Sendable: 可変状態は lock で保護する

    public let path: String
    private let lock = NSLock()
    private var cached: AppSettings = .default
    private var cachedModified: Date?
    private var loggedFailure = false

    public static let defaultPath: String = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AgentStatusBar", isDirectory: true)
        return base.appendingPathComponent("config.json").path
    }()

    public init(path: String = FileSettingsStore.defaultPath) {
        self.path = path
        createDefaultFileIfMissing()
        _ = current()
    }

    public func current() -> AppSettings {
        lock.lock()
        defer { lock.unlock() }

        let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        // 変更されていなければキャッシュを返す
        if let modified, modified == cachedModified { return cached }

        guard let data = FileManager.default.contents(atPath: path) else { return cached }
        do {
            cached = try JSONDecoder().decode(AppSettings.self, from: data)
            cachedModified = modified
            loggedFailure = false
        } catch {
            if !loggedFailure {
                loggedFailure = true
                FileHandle.standardError.write(
                    Data("config.json を読めない（直前の設定を使う）: \(error.localizedDescription)\n".utf8)
                )
            }
            // 壊れたファイルを読み直し続けないように時刻は進めておく
            cachedModified = modified
        }
        return cached
    }

    public func save(_ settings: AppSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)

        lock.lock()
        cached = settings
        // 自分で書いた変更を「外部からの変更」として読み直さないよう時刻を更新する
        cachedModified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        lock.unlock()
    }

    private func createDefaultFileIfMissing() {
        guard !FileManager.default.fileExists(atPath: path) else { return }
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(AppSettings.default) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
