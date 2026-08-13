import Foundation
import ASBApplication

/// ホストごとに `ssh -N -R` のリバーストンネルを張り、落ちたら再接続する。
///
/// リモートで発火した hook を、転送した Unix ソケット経由でローカルのアプリへ届けるための経路。
/// アプリ本体（`AgentStatusBarApp`）と同じプロセスで動き、UI から駆動されるため MainActor 隔離。
///
/// Phase 1 ではトンネルの確立のみを担う。リモートの shim 配置と hook 登録は利用者が手動で行う。
@MainActor
public final class RemoteTunnelSupervisor: TunnelSupervising {
    public var onChange: (@MainActor () -> Void)?
    public let remoteSocketPath: String
    private let localSocketPath: String

    private struct Entry {
        var state: TunnelState
        var process: Process?
        var task: Task<Void, Never>?
    }
    private var entries: [String: Entry] = [:]

    /// トンネル確立とみなすまでの猶予。この間プロセスが生きていれば connected にする。
    private static let graceNanos: UInt64 = 3_000_000_000
    /// 再接続バックオフの下限・上限。
    private static let minBackoffNanos: UInt64 = 2_000_000_000
    private static let maxBackoffNanos: UInt64 = 30_000_000_000

    public init(localSocketPath: String, remoteSocketPath: String) {
        self.localSocketPath = localSocketPath
        self.remoteSocketPath = remoteSocketPath
        // 前回のアプリ終了時に残った自分のトンネル（launchd に里親付けされた orphan）を掃除する。
        // これが同じリモートソケットパスを掴んでいると、新しいトンネルが
        // ExitOnForwardFailure で張れずに「失敗」になり続ける。
        killStrayTunnels()
    }

    /// 自分の remoteSocketPath を転送している ssh プロセスを終了させる。
    /// 起動直後（まだ自分のトンネルを張っていない時点）に呼ぶので、対象は orphan だけ。
    private func killStrayTunnels() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        // `-R <remoteSocketPath>:` を含む ssh だけに限定する（他の ssh を巻き込まない）。
        process.arguments = ["-f", "ssh .*-R \(remoteSocketPath):"]
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: - TunnelSupervising

    public func setEnabled(_ aliases: [String]) {
        let desired = Set(aliases)
        for alias in Array(entries.keys) where !desired.contains(alias) { stop(alias) }
        for alias in desired where entries[alias] == nil { start(alias) }
    }

    public func shutdown() {
        for alias in Array(entries.keys) { stop(alias) }
    }

    public func state(for alias: String) -> TunnelState {
        entries[alias]?.state ?? .idle
    }

    // MARK: - 内部

    private func start(_ alias: String) {
        entries[alias] = Entry(state: .connecting, process: nil, task: nil)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.superviseLoop(alias)
        }
        entries[alias]?.task = task
        onChange?()
    }

    private func stop(_ alias: String) {
        guard let entry = entries.removeValue(forKey: alias) else { return }
        entry.task?.cancel()
        if let process = entry.process, process.isRunning { process.terminate() }
        onChange?()
    }

    private func setState(_ state: TunnelState, for alias: String) {
        guard entries[alias] != nil else { return }
        entries[alias]?.state = state
        onChange?()
    }

    /// 生存中（entry がまだあり、プロセスが動いている）ときだけ connected にする。
    private func markConnectedIfRunning(_ alias: String) {
        guard let process = entries[alias]?.process, process.isRunning else { return }
        setState(.connected, for: alias)
    }

    private func superviseLoop(_ alias: String) async {
        var backoff = Self.minBackoffNanos
        while !Task.isCancelled {
            setState(.connecting, for: alias)
            // 前のトンネルが残したリモートのソケットファイルを消してから張る。
            // StreamLocalBindUnlink はこの相手では効かず、残骸があると -R の bind に失敗する。
            await cleanupRemoteSocket(alias)
            if Task.isCancelled { break }

            let reason = await runTunnel(alias)
            if Task.isCancelled { break }

            setState(.failed(reason), for: alias)
            // 落ちたら待ってから再接続する。連続失敗で徐々に間隔を空ける。
            try? await Task.sleep(nanoseconds: backoff)
            backoff = min(backoff * 2, Self.maxBackoffNanos)
        }
    }

    /// リモートに残った古い転送ソケットを削除する。失敗しても無視する（次の bind で分かる）。
    private func cleanupRemoteSocket(_ alias: String) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", alias, "rm -f \(remoteSocketPath)",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume()
            }
        }
    }

    /// ssh を 1 回起動し、終了まで待って失敗理由を返す。
    private func runTunnel(_ alias: String) async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-N", "-T",
            "-o", "BatchMode=yes",              // パスワード対話に落ちず即座に失敗させる（鍵前提）
            "-o", "ExitOnForwardFailure=yes",   // 転送が張れなければ接続自体を失敗にする
            "-o", "StreamLocalBindUnlink=yes",  // 残ったソケットファイルを消してから bind する
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-R", "\(remoteSocketPath):\(localSocketPath)",
            alias,
        ]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        entries[alias]?.process = process

        // 起動前に terminationHandler を仕込み、終了 or 起動失敗のどちらか一方だけで resume する
        // （二重 resume を避けるため、成功時はハンドラ経由、失敗時はここで resume）。
        enum Outcome { case launchFailed(String); case exited }
        var grace: Task<Void, Never>?
        let outcome: Outcome = await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume(returning: .exited) }
            do {
                try process.run()
                // 起動成功。猶予後もまだ生きていれば connected と見なす。
                grace = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: Self.graceNanos)
                    self?.markConnectedIfRunning(alias)
                }
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: .launchFailed("ssh を起動できません: \(error.localizedDescription)"))
            }
        }
        grace?.cancel()

        switch outcome {
        case .launchFailed(let message):
            return message
        case .exited:
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8) ?? ""
            return Self.classify(stderr: errText)
        }
    }

    /// ssh の stderr から人間に分かる失敗理由へ変換する。純粋関数。
    nonisolated static func classify(stderr: String) -> String {
        let lower = stderr.lowercased()
        if lower.contains("permission denied") || lower.contains("publickey") {
            return "鍵認証が必要です（ssh-agent に鍵を登録してください）"
        }
        if lower.contains("could not resolve") || lower.contains("name or service not known") {
            return "ホスト名を解決できません"
        }
        if lower.contains("connection refused") {
            return "接続を拒否されました"
        }
        if lower.contains("connection timed out") || lower.contains("operation timed out") {
            return "接続がタイムアウトしました"
        }
        if lower.contains("remote port forwarding failed") {
            return "リモート転送に失敗（既存のソケットが残っている可能性）"
        }
        let tail = stderr.split(whereSeparator: \.isNewline).last.map(String.init)
        return tail?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? "接続が切れました"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
