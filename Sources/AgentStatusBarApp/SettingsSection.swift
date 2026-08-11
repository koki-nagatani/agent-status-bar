import SwiftUI
import ASBApplication

/// 詳細パネル内の設定セクション。
///
/// macOS のシステム設定（通知）からは音を変更できないため、ここで変更手段を提供する。
/// 音は `NSSound` で鳴らしており、OS の通知音設定の管轄外だからである。
struct SettingsSection: View {
    @Bindable var model: SettingsModel
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                    Text("通知音")
                        .font(.system(size: 11))
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
                    ForEach(SoundSlot.allCases, id: \.self) { slot in
                        SoundRow(model: model, slot: slot)
                    }

                    Toggle(isOn: Binding(
                        get: { model.settings.bannerEnabled },
                        set: { model.setBannerEnabled($0) }
                    )) {
                        Text("バナー通知も出す")
                            .font(.system(size: 10))
                    }
                    .toggleStyle(.checkbox)
                    .padding(.top, 2)

                    if model.isMuted {
                        // 音を選んでも鳴らない状態を、ここでも分かるようにする
                        Label("いま音はオフです（下の通知音スイッチで戻せます）", systemImage: "speaker.slash.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                            .padding(.top, 1)
                    } else {
                        Text("選ぶとその場で鳴ります。変更は自動で保存されます。")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 1)
                    }

                    HStack(spacing: 6) {
                        // 音が鳴らない変更（バナーのトグル等）でも保存を確認できるようにする
                        Label("保存しました", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.green)
                            .opacity(model.showSavedIndicator ? 1 : 0)
                            .animation(.easeInOut(duration: 0.15), value: model.showSavedIndicator)

                        Spacer()

                        Button("既定に戻す") { model.resetToDefaults() }
                            .buttonStyle(.plain)
                            .font(.system(size: 9))
                            .foregroundStyle(model.isDefault ? .tertiary : .secondary)
                            .disabled(model.isDefault)
                    }
                    .padding(.top, 2)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
        }
    }
}

private struct SoundRow: View {
    let model: SettingsModel
    let slot: SoundSlot

    var body: some View {
        HStack(spacing: 8) {
            Text(slot.label)
                .font(.system(size: 10))
                .frame(width: 56, alignment: .leading)

            Picker("", selection: Binding(
                get: { model.displayedSelection(for: slot) },
                set: { selected in
                    model.select(selected == SettingsModel.silentLabel ? nil : selected, for: slot)
                }
            )) {
                Text(SettingsModel.silentLabel).tag(SettingsModel.silentLabel)
                Divider()
                ForEach(model.soundNames, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .font(.system(size: 10))
        }
    }
}
