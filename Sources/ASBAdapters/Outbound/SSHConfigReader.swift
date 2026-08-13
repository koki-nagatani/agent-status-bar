import Foundation
import ASBApplication

/// `~/.ssh/config` から Host エイリアスを列挙する。
///
/// 解決（HostName / User / ProxyJump 等）はここでは行わない。**alias だけ**を集める。
/// データ最小化の方針に合わせ、鍵や接続先を溜め込まない。
///
/// パースは純粋関数（`parse`）に切り出してテスト可能にし、Include 展開と
/// ファイル読み込みだけを IO 側に置く。
public struct SSHConfigReader: RemoteHostEnumerator {
    private let configPath: String
    private let sshDir: String

    public init(
        configPath: String = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/config"),
        sshDir: String = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh")
    ) {
        self.configPath = configPath
        self.sshDir = sshDir
    }

    public func availableHosts() -> [String] {
        var seenFiles = Set<String>()
        var ordered: [String] = []
        var seenHosts = Set<String>()
        collect(configPath, depth: 0, seenFiles: &seenFiles, into: &ordered, seenHosts: &seenHosts)
        return ordered
    }

    /// Include を辿りながらホストを集める。循環と暴走を深さと訪問済み集合で止める。
    private func collect(
        _ path: String,
        depth: Int,
        seenFiles: inout Set<String>,
        into ordered: inout [String],
        seenHosts: inout Set<String>
    ) {
        guard depth < 16 else { return }
        let resolved = (path as NSString).standardizingPath
        guard seenFiles.insert(resolved).inserted else { return }
        guard let text = try? String(contentsOfFile: resolved, encoding: .utf8) else { return }

        let parsed = Self.parse(text)
        for host in parsed.hosts where seenHosts.insert(host).inserted {
            ordered.append(host)
        }
        for pattern in parsed.includes {
            for file in expandInclude(pattern) {
                collect(file, depth: depth + 1, seenFiles: &seenFiles, into: &ordered, seenHosts: &seenHosts)
            }
        }
    }

    /// Include のパターンを実ファイル一覧へ展開する。
    /// 相対パスは `~/.ssh` 基準、`~` はホーム展開、glob（`*` 等）に対応する。
    private func expandInclude(_ pattern: String) -> [String] {
        var p = pattern
        if p.hasPrefix("~/") {
            p = (NSHomeDirectory() as NSString).appendingPathComponent(String(p.dropFirst(2)))
        } else if !p.hasPrefix("/") {
            p = (sshDir as NSString).appendingPathComponent(p)
        }
        return Self.globMatches(p)
    }

    /// `glob(3)` で展開。マッチが無ければ空。
    static func globMatches(_ pattern: String) -> [String] {
        var g = glob_t()
        defer { globfree(&g) }
        guard Darwin.glob(pattern, 0, nil, &g) == 0 else { return [] }
        var result: [String] = []
        for i in 0..<Int(g.gl_matchc) {
            if let c = g.gl_pathv[i] { result.append(String(cString: c)) }
        }
        return result
    }

    /// 1 ファイル分のテキストから Host エイリアスと Include パターンを取り出す純粋関数。
    ///
    /// - `Host a b c` の各パターンを列挙。ワイルドカード（`*` `?`）・否定（`!`）は除く。
    /// - `Include path...` を集める。
    /// - キーワードは大文字小文字を無視。`#` 始まりの行はコメント。
    static func parse(_ text: String) -> (hosts: [String], includes: [String]) {
        var hosts: [String] = []
        var includes: [String] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            // `Key=Value` と `Key Value` の両方を許す。最初の区切りでキーワードを切る。
            let normalized = line.replacingOccurrences(of: "=", with: " ")
            let tokens = normalized.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let keyword = tokens.first else { continue }
            let args = Array(tokens.dropFirst())

            switch keyword.lowercased() {
            case "host":
                for pattern in args where !pattern.contains("*") && !pattern.contains("?") && !pattern.hasPrefix("!") {
                    hosts.append(pattern)
                }
            case "include":
                includes.append(contentsOf: args)
            default:
                continue
            }
        }
        return (hosts, includes)
    }
}
