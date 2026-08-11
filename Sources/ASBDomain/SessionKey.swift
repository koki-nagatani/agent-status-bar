/// セッションの同一性。
///
/// `cwd` は識別子に**しない**。同一ディレクトリで複数セッションを並行させるのは
/// 通常の使い方であり、`cwd` をキーにすると互いを上書きしてしまう。
/// `cwd` はあくまで表示上の最重要属性である。
public struct SessionKey: Hashable, Sendable {
    public let provider: AgentProvider
    public let sessionId: String

    public init(provider: AgentProvider, sessionId: String) {
        self.provider = provider
        self.sessionId = sessionId
    }
}
