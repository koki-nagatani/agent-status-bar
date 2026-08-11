import XCTest
@testable import ASBApplication

final class AppSettingsTests: XCTestCase {

    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    func testDefaultsDifferentiateEachState() {
        let sounds = AppSettings.default.sounds
        XCTAssertEqual(sounds.completed, "Glass")
        XCTAssertEqual(sounds.waiting, "Blow")
        XCTAssertEqual(sounds.failed, "Basso")
        XCTAssertEqual(
            Set([sounds.completed, sounds.waiting, sounds.failed]).count, 3,
            "3 つの状態は聞き分けられる必要がある"
        )
    }

    /// 一部だけ書いた設定ファイルを許す。書いていない項目はデフォルトを使う。
    func testPartialConfigKeepsDefaults() throws {
        let settings = try decode(#"{"sounds":{"waiting":"Ping"}}"#)
        XCTAssertEqual(settings.sounds.waiting, "Ping")
        XCTAssertEqual(settings.sounds.completed, "Glass")
        XCTAssertEqual(settings.sounds.failed, "Basso")
        XCTAssertTrue(settings.bannerEnabled)
    }

    func testEmptyObjectIsAllValidDefaults() throws {
        XCTAssertEqual(try decode("{}"), .default)
    }

    func testBannerCanBeDisabledIndependentlyOfSound() throws {
        let settings = try decode(#"{"bannerEnabled":false}"#)
        XCTAssertFalse(settings.bannerEnabled)
        XCTAssertEqual(settings.sounds.completed, "Glass", "バナーを切っても音は残る")
    }

    // MARK: - 無音の指定

    func testSoundCanBeSilenced() throws {
        XCTAssertNil(normalizedSoundName(nil))
        XCTAssertNil(normalizedSoundName("none"))
        XCTAssertNil(normalizedSoundName("None"))
        XCTAssertNil(normalizedSoundName(""))
        XCTAssertNil(normalizedSoundName("   "))
        XCTAssertEqual(normalizedSoundName(" Glass "), "Glass")
    }

    /// READMEは判断待ちを既定で無音としていた。設定で戻せることを保証する。
    func testWaitingCanBeMadeSilent() throws {
        let settings = try decode(#"{"sounds":{"waiting":"none"}}"#)
        XCTAssertNil(normalizedSoundName(settings.sounds.waiting))
        XCTAssertNotNil(normalizedSoundName(settings.sounds.completed))
    }

    func testInvalidJsonThrowsSoCallerCanFallBack() {
        XCTAssertThrowsError(try decode("これは JSON ではない"))
    }
}

/// 即時保存方式の退路（「既定に戻す」）が成立するための性質。
final class AppSettingsResetTests: XCTestCase {

    func testDefaultIsDetectableSoResetCanBeDisabled() {
        XCTAssertEqual(AppSettings.default, AppSettings())

        var modified = AppSettings.default
        modified.setSound("Hero", for: .completed)
        XCTAssertNotEqual(modified, .default, "変更を検出できないと「既定に戻す」の有効判定ができない")
    }

    func testResetRestoresEveryField() {
        var modified = AppSettings.default
        for slot in SoundSlot.allCases { modified.setSound("none", for: slot) }
        modified.bannerEnabled = false
        XCTAssertNotEqual(modified, .default)

        // 「既定に戻す」は AppSettings.default をそのまま保存する操作である
        XCTAssertEqual(AppSettings.default.sounds.completed, "Glass")
        XCTAssertEqual(AppSettings.default.sounds.waiting, "Blow")
        XCTAssertEqual(AppSettings.default.sounds.failed, "Basso")
        XCTAssertTrue(AppSettings.default.bannerEnabled)
    }

    func testSoundSlotAccessorsRoundTrip() {
        var settings = AppSettings.default
        for slot in SoundSlot.allCases {
            settings.setSound("Hero", for: slot)
            XCTAssertEqual(settings.sound(for: slot), "Hero", "\(slot.rawValue) の読み書きが一致しない")
        }
    }

    func testSlotLabels() {
        XCTAssertEqual(SoundSlot.completed.label, "完了")
        XCTAssertEqual(SoundSlot.waiting.label, "判断待ち")
        XCTAssertEqual(SoundSlot.failed.label, "異常終了")
    }
}


/// 音の一括オフ。個別の音設定を壊さずに黙らせる必要がある。
final class MuteTests: XCTestCase {

    func testMutedSilencesEverySlotWithoutLosingConfiguration() {
        var settings = AppSettings.default
        settings.muted = true

        for slot in SoundSlot.allCases {
            XCTAssertNil(settings.effectiveSound(for: slot), "\(slot.rawValue) が鳴ってしまう")
        }
        // 個別の設定は保持されている
        XCTAssertEqual(settings.sounds.completed, "Glass")
        XCTAssertEqual(settings.sounds.waiting, "Blow")
        XCTAssertEqual(settings.sounds.failed, "Basso")
    }

    func testUnmutingRestoresPreviousSounds() {
        var settings = AppSettings.default
        settings.setSound("Hero", for: .completed)
        settings.muted = true
        XCTAssertNil(settings.effectiveSound(for: .completed))

        settings.muted = false
        XCTAssertEqual(settings.effectiveSound(for: .completed), "Hero", "ミュート解除で元の音に戻る")
    }

    /// ミュートと個別の「なし」は独立して効く。
    func testPerSlotSilenceIsIndependentOfMute() {
        var settings = AppSettings.default
        settings.setSound("none", for: .waiting)

        XCTAssertNil(settings.effectiveSound(for: .waiting))
        XCTAssertEqual(settings.effectiveSound(for: .completed), "Glass")
    }

    func testMuteDefaultsToOffAndPersists() throws {
        XCTAssertFalse(AppSettings.default.muted)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"muted":true}"#.utf8))
        XCTAssertTrue(decoded.muted)
        XCTAssertEqual(decoded.sounds.completed, "Glass", "muted だけ書いても他はデフォルト")
    }

    /// ミュートはバナー通知を止めない（音だけの機能である）。
    func testMuteDoesNotAffectBanner() throws {
        var settings = AppSettings.default
        settings.muted = true
        XCTAssertTrue(settings.bannerEnabled)
    }
}
