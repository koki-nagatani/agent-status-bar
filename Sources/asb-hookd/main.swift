import Foundation
import ASBDomain
import ASBApplication
import ASBAdapters

// パイプへ出力する際もブロックバッファされないようにする
setvbuf(stdout, nil, _IOLBF, 0)

/// GUI を介さずに hook 経路と状態遷移を確認するための開発用デーモン。
///
/// 実際の Agent から hook を受けて、状態がどう変化するかを標準出力に流す。
/// UI のバグと取り込み経路のバグを切り分けるために使う。

struct StdoutNotifier: Notifier {
    func notifyCompleted(_ session: AgentSession) async {
        print("🔔 completed  \(session.providerLabel)  \(session.cwd)")
    }
    func notifyFailed(_ session: AgentSession) async {
        print("⚠️  failed     \(session.providerLabel)  \(session.cwd)  \(session.errorMessage ?? "")")
    }
    func notifyWaiting(_ session: AgentSession) async {
        print("🔔 waiting    \(session.providerLabel)  \(session.cwd)")
    }
}

let socketPath = ProcessInfo.processInfo.environment["ASB_SOCKET"]
    ?? NSString(string: "~/Library/Application Support/AgentStatusBar/asb.sock").expandingTildeInPath

let service = AgentStatusService(clock: SystemClock(), probe: SignalProcessProbe(), notifier: StdoutNotifier())
let server = UnixSocketHookServer(
    socketPath: socketPath,
    clock: SystemClock(),
    onDecodeFailure: { FileHandle.standardError.write(Data("decode failure: \($0)\n".utf8)) }
)

Task {
    for await snapshot in await service.snapshots() {
        let title = snapshot.menuBarTitle.isEmpty ? "(何も動いていない)" : snapshot.menuBarTitle
        print("\n── \(title)")
        for session in snapshot.sessions {
            print("   \(session.displaySymbol) \(session.displayStatus)  \(session.providerLabel)  \(session.cwd)")
        }
    }
}

try server.start { event in
    Task { await service.ingest(event) }
}
print("listening: \(socketPath)")

// liveness の再評価
let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
    Task { await service.tick() }
}
RunLoop.main.add(timer, forMode: .common)
RunLoop.main.run()
