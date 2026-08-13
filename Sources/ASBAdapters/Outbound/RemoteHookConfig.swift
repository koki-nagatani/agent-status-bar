import Foundation

/// リモートの `settings.json` / `hooks.json` へ AgentStatusBar の hook を登録・解除する純粋ロジック。
///
/// `Scripts/setup-hooks.js` と同じ規則をローカルの Swift で再現する。こうすることで
/// **リモートに node を要求しない**（ssh は取得と書き戻しの `cat` にだけ使う）。
///
/// 既存のユーザー hook は一切壊さず、各イベントに独立したグループとして足す（冪等）。
enum RemoteHookConfig {
    /// 登録するイベント。ローカルの setup-hooks.js と揃える（Notification は含めない）。
    static let claudeEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PostToolUseFailure", "PermissionRequest", "Stop", "StopFailure", "SessionEnd",
    ]
    static let codexEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PermissionRequest", "Stop", "SessionEnd",
    ]

    /// hook のコマンド。リモートでは shim に ASB_SOCKET / ASB_HOST を渡す。
    static func command(hookPath: String, socket: String, host: String, provider: String) -> String {
        "env ASB_SOCKET=\(socket) ASB_HOST=\(host) \(hookPath) \(provider)"
    }

    /// Codex の SessionEnd は 3 秒を超える timeout を受け付けない。
    static func timeout(provider: String, event: String) -> Int {
        (provider == "codex" && event == "SessionEnd") ? 3 : 5
    }

    static func isOurs(_ command: String) -> Bool { command.contains("asb-hook") }

    /// 既存 config（空でも可）へ登録した結果を返す。
    static func register(
        configJSON: Data,
        events: [String],
        command: String,
        timeoutFor: (String) -> Int
    ) -> Data {
        var root = object(from: configJSON)
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            var updated = false

            for i in groups.indices {
                guard var groupHooks = groups[i]["hooks"] as? [[String: Any]] else { continue }
                for j in groupHooks.indices {
                    if let cmd = groupHooks[j]["command"] as? String, isOurs(cmd) {
                        // 既にあれば command / timeout を現在値へ揃える（冪等）。
                        groupHooks[j]["type"] = "command"
                        groupHooks[j]["command"] = command
                        groupHooks[j]["timeout"] = timeoutFor(event)
                        updated = true
                    }
                }
                groups[i]["hooks"] = groupHooks
            }

            if !updated {
                groups.append(["hooks": [[
                    "type": "command",
                    "command": command,
                    "timeout": timeoutFor(event),
                ]]])
            }
            hooks[event] = groups
        }

        root["hooks"] = hooks
        return serialize(root)
    }

    /// AgentStatusBar の hook をすべて取り除いた結果を返す。他の hook は残す。
    static func unregister(configJSON: Data) -> Data {
        var root = object(from: configJSON)
        guard var hooks = root["hooks"] as? [String: Any] else { return serialize(root) }

        for event in Array(hooks.keys) {
            guard let groups = hooks[event] as? [[String: Any]] else { continue }
            let cleaned: [[String: Any]] = groups.compactMap { group in
                var g = group
                let groupHooks = (g["hooks"] as? [[String: Any]]) ?? []
                let kept = groupHooks.filter { !isOurs(($0["command"] as? String) ?? "") }
                if kept.isEmpty { return nil }
                g["hooks"] = kept
                return g
            }
            if cleaned.isEmpty { hooks[event] = nil } else { hooks[event] = cleaned }
        }

        root["hooks"] = hooks
        return serialize(root)
    }

    // MARK: - JSON ヘルパ

    private static func object(from data: Data) -> [String: Any] {
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    private static func serialize(_ root: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]))
            ?? Data("{}".utf8)
    }
}
