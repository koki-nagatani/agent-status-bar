import SwiftUI
import ASBDomain
import ASBApplication

/// メニューバーアイコンをクリックしたときに出る詳細パネル。
struct DetailPanel: View {
    let snapshot: StatusSnapshot
    let settings: SettingsModel
    let remoteHosts: RemoteHostsModel
    /// パネルを開いた時点で完了バッジをリセットするために呼ぶ。
    let onAppear: () -> Void

    /// リストの実測高さ。
    ///
    /// `ScrollView` は理想高さを持たないため、内容に合わせてウィンドウサイズを決める
    /// `MenuBarExtra(.window)` の中に素朴に置くと高さが確定せず、行が潰れて見えなくなる。
    /// 中身の高さを測って明示的に与えることで回避する。
    @State private var listHeight: CGFloat = 0

    /// これを超えたらスクロールさせる。
    private static let maxListHeight: CGFloat = 360

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SummaryRow(summary: snapshot.summary)
            Divider()

            if snapshot.sessions.isEmpty {
                EmptyState()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(snapshot.sessions, id: \.key) { session in
                            SessionRow(session: session)
                            Divider().opacity(0.4)
                        }
                    }
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: ListHeightKey.self, value: proxy.size.height)
                        }
                    )
                }
                .frame(height: min(max(listHeight, 1), Self.maxListHeight))
                .onPreferenceChange(ListHeightKey.self) { height in
                    listHeight = height
                }
            }

            Divider()
            RemoteSection(model: remoteHosts)
            Divider()
            SettingsSection(model: settings)
            Divider()
            FooterRow(settings: settings)
        }
        .frame(width: 340)
        // メニューバーの 🟢 は「前回開いてから完了した件数」なので、開いた時点で消す
        .onAppear(perform: onAppear)
    }
}

private struct ListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct SummaryRow: View {
    let summary: SessionRegistry.Summary

    var body: some View {
        HStack(spacing: 14) {
            // 緑＝成功、青＝進行中。CI ツール等の慣習に合わせる
            item("実行中", summary.running, .blue)
            item("判断待ち", summary.waiting, .orange)
            item("完了", summary.completed, .green)
            item("異常終了", summary.error, .red)
            if summary.abandoned > 0 {
                item("中断", summary.abandoned, .secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func item(_ label: String, _ count: Int, _ color: Color) -> some View {
        VStack(spacing: 1) {
            Text("\(count)")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(count > 0 ? color : Color.secondary.opacity(0.5))
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }
}

/// 1 セッションの行。
///
/// Working Directory を Agent 名より目立たせる。
/// 「Codex が完了しました」ではなく「どの作業が終わったのか」を伝えるため、
/// ディレクトリ名を主見出しに、provider を従属情報として配置する。
private struct SessionRow: View {
    let session: AgentSession

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Text(session.displaySymbol)
                .font(.system(size: 11))
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(timeLabel)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 5) {
                    if let host = session.host {
                        Label(host, systemImage: "network")
                            .font(.system(size: 9))
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.blue)
                            .help("リモート (SSH): \(host)")
                    }
                    Text("\(session.providerLabel) · \(session.displayStatus)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Text(abbreviatedPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)

                if let message = session.errorMessage, !message.isEmpty {
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        // 応答が途絶えたセッションは淡色にするが、消さない
        .opacity(session.liveness == .stale ? 0.55 : 1)
    }

    private var abbreviatedPath: String {
        let home = NSHomeDirectory()
        return session.cwd.hasPrefix(home)
            ? "~" + session.cwd.dropFirst(home.count)
            : session.cwd
    }

    /// 実行中・判断待ちは経過時間、終了済みは時刻を出す。
    private var timeLabel: String {
        switch session.status {
        case .running, .waiting:
            guard let started = session.startedAt else { return "" }
            let elapsed = Int(Date().timeIntervalSince(started))
            return String(format: "%d:%02d", elapsed / 60, elapsed % 60)
        case .completed, .error:
            let at = session.completedAt ?? session.updatedAt
            return at.formatted(date: .omitted, time: .shortened)
        }
    }
}

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 4) {
            Text("動いている Agent はありません")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("Codex / Claude Code を起動すると表示されます")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }
}

private struct FooterRow: View {
    let settings: SettingsModel

    var body: some View {
        HStack(spacing: 0) {
            MuteToggle(settings: settings)
            Spacer()
            Button("終了") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// 音の一括オンオフ。
///
/// 会議中などに即座に黙らせたい操作なので、折りたたみの中ではなく
/// パネルを開いた時点で見える位置に置く。個別の音設定は保持したまま切り替わる。
///
/// スイッチは「音を鳴らすか」の向きにする（オン＝鳴る）。
/// 「ミュート」を軸にすると、オンが無音を意味することになり分かりにくい。
private struct MuteToggle: View {
    let settings: SettingsModel

    var body: some View {
        Toggle(isOn: Binding(
            get: { settings.soundEnabled },
            set: { settings.setSoundEnabled($0) }
        )) {
            HStack(spacing: 4) {
                Image(systemName: settings.soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 9))
                    .frame(width: 12)
                Text("通知音")
                    .font(.system(size: 11))
            }
            .foregroundStyle(.secondary)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .help(settings.soundEnabled ? "通知音を止める" : "通知音を鳴らす")
    }
}
