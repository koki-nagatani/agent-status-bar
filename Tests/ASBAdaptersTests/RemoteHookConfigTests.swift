import XCTest
@testable import ASBAdapters

final class RemoteHookConfigTests: XCTestCase {

    private let command = "env ASB_SOCKET=/tmp/asb.sock ASB_HOST=devbox ~/.agent-status-bar/asb-hook claude"

    private func register(_ json: String, events: [String] = ["Stop", "SessionStart"]) -> [String: Any] {
        let data = RemoteHookConfig.register(
            configJSON: Data(json.utf8), events: events, command: command,
            timeoutFor: { RemoteHookConfig.timeout(provider: "claude", event: $0) }
        )
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func groups(_ root: [String: Any], _ event: String) -> [[String: Any]] {
        (root["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
    }

    private func commands(_ root: [String: Any], _ event: String) -> [String] {
        groups(root, event).flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
    }

    func testRegisterIntoEmptyAddsEveryEvent() {
        let root = register("{}", events: ["Stop", "PreToolUse"])
        XCTAssertEqual(commands(root, "Stop"), [command])
        XCTAssertEqual(commands(root, "PreToolUse"), [command])
    }

    /// 二重登録しない。再実行で command / timeout を現在値へ揃えるだけ。
    func testRegisterIsIdempotent() {
        let once = RemoteHookConfig.register(
            configJSON: Data("{}".utf8), events: ["Stop"], command: command,
            timeoutFor: { _ in 5 }
        )
        let twice = RemoteHookConfig.register(
            configJSON: once, events: ["Stop"], command: command,
            timeoutFor: { _ in 5 }
        )
        let root = (try? JSONSerialization.jsonObject(with: twice)) as? [String: Any] ?? [:]
        XCTAssertEqual(commands(root, "Stop"), [command], "重複して増えてはならない")
    }

    /// ユーザーの既存 hook を壊さない。
    func testRegisterPreservesExistingHooks() {
        let existing = #"""
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo mine"}]}]}}
        """#
        let root = register(existing, events: ["Stop"])
        let cmds = commands(root, "Stop")
        XCTAssertTrue(cmds.contains("echo mine"), "既存 hook が消えた")
        XCTAssertTrue(cmds.contains(command), "自分の hook が入っていない")
    }

    func testCodexSessionEndTimeoutIsThree() {
        let data = RemoteHookConfig.register(
            configJSON: Data("{}".utf8), events: ["SessionEnd"], command: command,
            timeoutFor: { RemoteHookConfig.timeout(provider: "codex", event: $0) }
        )
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let hook = groups(root, "SessionEnd").first?["hooks"] as? [[String: Any]]
        XCTAssertEqual(hook?.first?["timeout"] as? Int, 3)
    }

    func testUnregisterRemovesOursButKeepsOthers() {
        let registered = RemoteHookConfig.register(
            configJSON: Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo mine"}]}]}}"#.utf8),
            events: ["Stop"], command: command, timeoutFor: { _ in 5 }
        )
        let cleaned = RemoteHookConfig.unregister(configJSON: registered)
        let root = (try? JSONSerialization.jsonObject(with: cleaned)) as? [String: Any] ?? [:]
        let cmds = commands(root, "Stop")
        XCTAssertEqual(cmds, ["echo mine"], "自分のだけ消し、他は残す")
    }

    func testUnregisterDropsEmptyEvents() {
        let registered = RemoteHookConfig.register(
            configJSON: Data("{}".utf8), events: ["Stop"], command: command, timeoutFor: { _ in 5 }
        )
        let cleaned = RemoteHookConfig.unregister(configJSON: registered)
        let root = (try? JSONSerialization.jsonObject(with: cleaned)) as? [String: Any] ?? [:]
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        XCTAssertNil(hooks["Stop"], "自分だけの event はキーごと消す")
    }

    func testCommandCarriesSocketAndHost() {
        let cmd = RemoteHookConfig.command(
            hookPath: "/home/u/.agent-status-bar/asb-hook",
            socket: "/tmp/s.sock", host: "box", provider: "codex"
        )
        XCTAssertEqual(cmd, "env ASB_SOCKET=/tmp/s.sock ASB_HOST=box /home/u/.agent-status-bar/asb-hook codex")
    }
}
