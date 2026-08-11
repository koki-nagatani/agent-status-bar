// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentStatusBar",
    platforms: [.macOS(.v14)],
    targets: [
        // 純粋なドメイン。Foundation 以外に依存しない。
        .target(name: "ASBDomain"),

        // ユースケースと port の定義。
        .target(name: "ASBApplication", dependencies: ["ASBDomain"]),

        // port の具体実装。hook 受信・Decoder・OS 連携。
        .target(name: "ASBAdapters", dependencies: ["ASBDomain", "ASBApplication"]),

        // メニューバー UI。`.app` バンドルに包んで起動する（Scripts/make-app.sh）。
        .executableTarget(
            name: "AgentStatusBarApp",
            dependencies: ["ASBDomain", "ASBApplication", "ASBAdapters"]
        ),

        // GUI 抜きで hook 経路を確認する開発用デーモン。
        .executableTarget(name: "asb-hookd", dependencies: ["ASBDomain", "ASBApplication", "ASBAdapters"]),

        .testTarget(name: "ASBDomainTests", dependencies: ["ASBDomain"]),
        .testTarget(name: "ASBApplicationTests", dependencies: ["ASBApplication", "ASBDomain"]),
        .testTarget(name: "ASBAdaptersTests", dependencies: ["ASBAdapters", "ASBDomain", "ASBApplication"]),
    ]
)
