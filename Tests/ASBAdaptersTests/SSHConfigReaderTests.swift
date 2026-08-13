import XCTest
@testable import ASBAdapters

final class SSHConfigReaderTests: XCTestCase {

    func testExtractsHostAliasesInOrder() {
        let text = """
        Host alpha
            HostName 1.2.3.4
            User me
        Host beta gamma
            Port 22
        """
        XCTAssertEqual(SSHConfigReader.parse(text).hosts, ["alpha", "beta", "gamma"])
    }

    /// ワイルドカード・否定パターンは実接続先ではないので除く。
    func testSkipsWildcardAndNegatedPatterns() {
        let text = """
        Host *
            ForwardAgent yes
        Host prod-*
            User deploy
        Host real !bad
            User x
        """
        XCTAssertEqual(SSHConfigReader.parse(text).hosts, ["real"])
    }

    func testIgnoresCommentsAndIsCaseInsensitive() {
        let text = """
        # comment
        HOST one
          host two
        """
        XCTAssertEqual(SSHConfigReader.parse(text).hosts, ["one", "two"])
    }

    func testSupportsEqualsSyntax() {
        XCTAssertEqual(SSHConfigReader.parse("Host=box").hosts, ["box"])
    }

    func testCollectsIncludePatterns() {
        let text = """
        Include ~/.ssh/work/*.conf
        Host a
        Include extra1 extra2
        """
        let parsed = SSHConfigReader.parse(text)
        XCTAssertEqual(parsed.hosts, ["a"])
        XCTAssertEqual(parsed.includes, ["~/.ssh/work/*.conf", "extra1", "extra2"])
    }

    // MARK: - ssh の失敗理由の分類（トンネル supervisor）

    func testClassifyMapsKnownFailures() {
        XCTAssertTrue(RemoteTunnelSupervisor.classify(stderr: "x: Permission denied (publickey).").contains("鍵認証"))
        XCTAssertTrue(RemoteTunnelSupervisor.classify(stderr: "ssh: Could not resolve hostname devbox").contains("解決"))
        XCTAssertTrue(RemoteTunnelSupervisor.classify(stderr: "connect: Connection refused").contains("拒否"))
        XCTAssertTrue(RemoteTunnelSupervisor.classify(stderr: "Warning: remote port forwarding failed for listen path").contains("リモート転送"))
    }

    func testClassifyFallsBackToLastLine() {
        XCTAssertEqual(RemoteTunnelSupervisor.classify(stderr: "some other trouble\n"), "some other trouble")
        XCTAssertEqual(RemoteTunnelSupervisor.classify(stderr: ""), "接続が切れました")
    }
}
