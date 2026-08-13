import SwiftUI
import ASBApplication

/// 詳細パネル内のリモートホスト設定セクション。
///
/// `~/.ssh/config` の Host を並べ、選んだホストへ SSH リバーストンネルを張る。
/// Phase 1 ではトンネルの確立まで。リモートの shim 配置と hook 登録は手動で行う。
struct RemoteSection: View {
    @Bindable var model: RemoteHostsModel
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
                if expanded { model.reload() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                    Text("リモート")
                        .font(.system(size: 11))
                    if !model.enabled.isEmpty {
                        Text("\(model.enabled.count)")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(.blue)
                    }
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if model.isEmpty {
                        Text("~/.ssh/config に Host がありません")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.hosts, id: \.self) { host in
                            RemoteHostRow(model: model, alias: host)
                        }
                    }

                    HStack {
                        Button {
                            model.reload()
                        } label: {
                            Label("再読込", systemImage: "arrow.clockwise")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .controlSize(.small)
                        .help("~/.ssh/config を読み直す")
                        Spacer()
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
        }
    }
}

private struct RemoteHostRow: View {
    let model: RemoteHostsModel
    let alias: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                Toggle(isOn: Binding(
                    get: { model.isEnabled(alias) },
                    set: { model.setEnabled(alias, $0) }
                )) {
                    Text(alias)
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
                .toggleStyle(.checkbox)

                Spacer(minLength: 6)

                StateBadge(state: model.state(for: alias))
            }

            if let note = bootstrapNote {
                Text(note.text)
                    .font(.system(size: 9))
                    .foregroundStyle(note.color)
                    .lineLimit(2)
                    .padding(.leading, 18)
            }
        }
    }

    /// 初期設定（shim/hook 登録）の途中経過・失敗だけを補助行として出す。
    private var bootstrapNote: (text: String, color: Color)? {
        switch model.bootstrapState(for: alias) {
        case .idle, .done: return nil
        case .running: return ("リモートを設定中…", .secondary)
        case .failed(let reason): return ("設定に失敗: \(reason)", .red)
        }
    }
}

private struct StateBadge: View {
    let state: TunnelState

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .help(helpText)
    }

    private var color: Color {
        switch state {
        case .idle: return .secondary.opacity(0.4)
        case .connecting: return .orange
        case .connected: return .green
        case .failed: return .red
        }
    }

    private var label: String {
        switch state {
        case .idle: return ""
        case .connecting: return "接続中"
        case .connected: return "接続済"
        case .failed: return "失敗"
        }
    }

    private var helpText: String {
        switch state {
        case .idle: return "未接続"
        case .connecting: return "接続中"
        case .connected: return "トンネル確立"
        case .failed(let reason): return reason
        }
    }
}
