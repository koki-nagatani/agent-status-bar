import AppKit
import Foundation
import ASBApplication

/// `NSSound` で鳴らせるシステムサウンドの一覧と再生。
///
/// 許可を一切必要としないため、バナー通知が使えない環境でも音は必ず鳴る。
public struct SystemSoundCatalog: SoundCatalog {

    /// 音が置かれている場所。ユーザーが自作の aiff を置ける場所も含める。
    private static let directories = [
        "/System/Library/Sounds",
        NSString(string: "~/Library/Sounds").expandingTildeInPath,
    ]

    public init() {}

    public var names: [String] {
        var found: Set<String> = []
        for directory in Self.directories {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            for entry in entries where entry.hasSuffix(".aiff") || entry.hasSuffix(".aif") {
                found.insert((entry as NSString).deletingPathExtension)
            }
        }
        return found.sorted()
    }

    public func preview(_ name: String) async {
        await SoundPlayer.play(name)
    }
}

/// システムサウンドの再生。
///
/// `NSSound` は再生中に解放されると途中で止まるため、終了まで参照を保持する。
@MainActor
enum SoundPlayer {
    private static var playing: [NSSound] = []
    private static let finishHandler = FinishHandler()

    static func play(_ name: String) {
        guard let sound = NSSound(named: NSSound.Name(name)) else {
            FileHandle.standardError.write(Data("システムサウンドが見つからない: \(name)\n".utf8))
            return
        }
        sound.delegate = finishHandler
        playing.append(sound)
        sound.play()
    }

    fileprivate static func finished(_ sound: NSSound) {
        playing.removeAll { $0 === sound }
    }

    private final class FinishHandler: NSObject, NSSoundDelegate {
        func sound(_ sound: NSSound, didFinishPlaying finished: Bool) {
            Task { @MainActor in SoundPlayer.finished(sound) }
        }
    }
}
