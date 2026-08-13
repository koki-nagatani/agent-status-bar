import Foundation
import ASBApplication

/// リモートホストへ shim を配り、hook を登録／解除する。
///
/// リモートに node を要求しないため、`settings.json` の編集はローカル（`RemoteHookConfig`）で行い、
/// ssh は `cat` による取得・書き戻しにだけ使う。UI から駆動されるため MainActor 隔離。
@MainActor
public final class RemoteBootstrapper: RemoteBootstrapping {
    public var onChange: (@MainActor () -> Void)?

    private let localShimPath: String
    private let remoteSocketPath: String
    private var states: [String: BootstrapState] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    /// リモート上の shim の置き場所（`~` 相対）。
    private static let remoteShimDir = "~/.agent-status-bar"

    public init(localShimPath: String, remoteSocketPath: String) {
        // stdin を読み切る前に相手が閉じても、書き込みでプロセスを殺さない。
        signal(SIGPIPE, SIG_IGN)
        self.localShimPath = localShimPath
        self.remoteSocketPath = remoteSocketPath
    }

    // MARK: - RemoteBootstrapping

    public func state(for alias: String) -> BootstrapState { states[alias] ?? .idle }

    public func bootstrap(_ alias: String) {
        tasks[alias]?.cancel()
        setState(.running, for: alias)
        tasks[alias] = Task { [weak self] in
            guard let self else { return }
            await self.runBootstrap(alias)
        }
    }

    public func teardown(_ alias: String) {
        tasks[alias]?.cancel()
        tasks[alias] = Task { [weak self] in
            guard let self else { return }
            await self.runTeardown(alias)
        }
    }

    // MARK: - 実処理

    private func setState(_ state: BootstrapState, for alias: String) {
        states[alias] = state
        onChange?()
    }

    /// bootstrap を試み、失敗したら一度だけリトライする。
    ///
    /// ssh は ControlMaster で 1 本に多重化しているが、トグル直後は
    /// トンネル確立と同時に走り、リンクのコールドスタートで最初の接続が
    /// タイムアウトしうる。冪等なので、落ちても間を置いてもう一度試す。
    private func runBootstrap(_ alias: String) async {
        for attempt in 0..<2 {
            if let error = await attemptBootstrap(alias) {
                if attempt == 0 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                setState(.failed(error), for: alias)
                return
            }
            setState(.done, for: alias)
            return
        }
    }

    /// 成功なら nil、失敗ならエラーメッセージを返す（状態は呼び出し側で設定）。
    private func attemptBootstrap(_ alias: String) async -> String? {
        // 1. リモートの $HOME を解決して shim の絶対パスを決める（hook 実行時の展開に頼らない）。
        let home = await sshCapture(alias, "printf %s \"$HOME\"")
        guard case .success(let homeOut) = home,
              let remoteHome = String(data: homeOut, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !remoteHome.isEmpty
        else {
            return reason(home)
        }
        let hookPath = "\(remoteHome)/.agent-status-bar/asb-hook"

        // 2. shim を配置する。
        guard let shim = try? Data(contentsOf: URL(fileURLWithPath: localShimPath)) else {
            return "ローカルの shim を読めません（先に setup-hooks を実行してください）"
        }
        let placed = await ssh(
            alias,
            "mkdir -p \(Self.remoteShimDir) && cat > \(Self.remoteShimDir)/asb-hook && chmod +x \(Self.remoteShimDir)/asb-hook",
            stdin: shim
        )
        guard case .success = placed else {
            return reason(placed)
        }

        // 3. Claude / Codex の hook を登録する。
        let targets: [(provider: String, path: String, events: [String])] = [
            ("claude", "~/.claude/settings.json", RemoteHookConfig.claudeEvents),
            ("codex", "~/.codex/hooks.json", RemoteHookConfig.codexEvents),
        ]
        for target in targets {
            let command = RemoteHookConfig.command(
                hookPath: hookPath, socket: remoteSocketPath, host: alias, provider: target.provider
            )
            if let message = await registerRemote(
                alias, remotePath: target.path, events: target.events, command: command,
                timeoutFor: { RemoteHookConfig.timeout(provider: target.provider, event: $0) }
            ) {
                return "\(target.provider): \(message)"
            }
        }

        return nil
    }

    /// 成功なら nil、失敗ならエラーメッセージを返す。
    private func registerRemote(
        _ alias: String,
        remotePath: String,
        events: [String],
        command: String,
        timeoutFor: (String) -> Int
    ) async -> String? {
        let dir = (remotePath as NSString).deletingLastPathComponent
        let fetched = await sshCapture(alias, "cat \(remotePath) 2>/dev/null || true")
        guard case .success(let existing) = fetched else { return reason(fetched) }

        let updated = RemoteHookConfig.register(
            configJSON: existing, events: events, command: command, timeoutFor: timeoutFor
        )
        let written = await ssh(alias, "mkdir -p \(dir) && cat > \(remotePath)", stdin: updated)
        if case .failure(let message) = written { return message }
        return nil
    }

    private func runTeardown(_ alias: String) async {
        for path in ["~/.claude/settings.json", "~/.codex/hooks.json"] {
            let fetched = await sshCapture(alias, "cat \(path) 2>/dev/null || true")
            guard case .success(let existing) = fetched, !existing.isEmpty else { continue }
            let updated = RemoteHookConfig.unregister(configJSON: existing)
            _ = await ssh(alias, "cat > \(path)", stdin: updated)
        }
        setState(.idle, for: alias)
    }

    // MARK: - ssh 実行

    fileprivate enum RunResult {
        case success(Data)
        case failure(String)
    }

    /// 成否だけ見る ssh（stdout は使わない）。
    private func ssh(_ alias: String, _ remoteCommand: String, stdin: Data?) async -> RunResult {
        await run(alias, remoteCommand, stdin: stdin)
    }

    /// stdout を取り込む ssh。
    private func sshCapture(_ alias: String, _ remoteCommand: String) async -> RunResult {
        await run(alias, remoteCommand, stdin: nil)
    }

    private func run(_ alias: String, _ remoteCommand: String, stdin: Data?) async -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        // ControlMaster で bootstrap 中の複数接続を 1 本に多重化する。
        // 6 回のハンドシェイクが 1 回になり、接続レート制限やコールドスタートの
        // 取りこぼしを避けられる。%C は接続毎のハッシュ（sun_path が短く収まる）。
        process.arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=15",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=/tmp/asb-cm-%C",
            "-o", "ControlPersist=15",
            alias, remoteCommand,
        ]

        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe

        return await withCheckedContinuation { (continuation: CheckedContinuation<RunResult, Never>) in
            process.terminationHandler = { proc in
                let out = outPipe.fileHandleForReading.readDataToEndOfFile()
                let err = errPipe.fileHandleForReading.readDataToEndOfFile()
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: .success(out))
                } else {
                    let errText = String(data: err, encoding: .utf8) ?? ""
                    continuation.resume(returning: .failure(RemoteTunnelSupervisor.classify(stderr: errText)))
                }
            }
            do {
                try process.run()
                if let stdin { try? inPipe.fileHandleForWriting.write(contentsOf: stdin) }
                try? inPipe.fileHandleForWriting.close()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: .failure("ssh を起動できません: \(error.localizedDescription)"))
            }
        }
    }

    private func reason(_ result: RunResult) -> String {
        if case .failure(let message) = result { return message }
        return "不明なエラー"
    }
}
