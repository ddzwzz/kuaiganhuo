import SwiftUI
import KuaiGanHuCore

/// 角色选择页：遍历 PersonaRegistry 中所有已注册角色（内置三个 + 后续注册的新角色自动出现）
struct RolePickerView: View {
    @Environment(AppState.self) private var appState
    /// 选中"伴侣"但用户未设置性别时的引导弹窗
    @State private var pendingPartnerID: String?

    private var personas: [PersonaDefinition] { PersonaRegistry.shared.all }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("情绪", selection: Bindable(appState).mood) {
                        ForEach(MoodKind.allCases) { mood in
                            Text(mood.displayName).tag(mood)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("监工情绪档位")
                } footer: {
                    Text("急躁：短句高压、当场戳穿。温柔：先共情，但狡辩一样不放行。")
                }

                Section {
                    ForEach(personas) { def in
                        RoleCard(
                            def: def,
                            isSelected: appState.roleID == def.id,
                            quote: sampleQuote(def),
                            genderNote: genderNote(def)
                        )
                        .onTapGesture { select(def) }
                    }
                } header: {
                    Text("选角色")
                } footer: {
                    Text("切换角色后，之前角色的对话内容不会带过来——每个监工只在自己的上下文里说话。")
                }
            }
            .navigationTitle("选监工")
            .alert("先告诉我你的性别", isPresented: Binding(
                get: { pendingPartnerID != nil },
                set: { if !$0 { pendingPartnerID = nil } }
            )) {
                Button("我是男生") { confirmGender(.male) }
                Button("我是女生") { confirmGender(.female) }
                Button("暂不设置", role: .cancel) { pendingPartnerID = nil }
            } message: {
                Text("伴侣模式的监工性别会自动设为跟你相反。只保存在手机本地，可在设置里改。")
            }
        }
    }

    // MARK: - 逻辑

    /// 选择角色：伴侣模式（性别强制与用户相异）需要用户先设置性别
    private func select(_ def: PersonaDefinition) {
        if def.genderPolicy == .oppositeOfUser && appState.userGender == .undisclosed {
            pendingPartnerID = def.id
            return
        }
        appState.roleID = def.id
    }

    private func confirmGender(_ gender: UserGender) {
        appState.userGender = gender
        if let id = pendingPartnerID {
            appState.roleID = id
            pendingPartnerID = nil
        }
    }

    private func sampleQuote(_ def: PersonaDefinition) -> String {
        let gender = appState.personaGender(for: def.id)
        let resolved = PersonaRegistry.shared.resolved(def.id, gender: gender)
        return resolved.catchphrases[appState.mood]?.first ?? "该干活了。"
    }

    /// 卡片副标题里的性别说明
    private func genderNote(_ def: PersonaDefinition) -> String? {
        switch def.genderPolicy {
        case .oppositeOfUser:
            switch appState.userGender {
            case .male: return "女友"
            case .female: return "男友"
            case .undisclosed: return "需先设置你的性别"
            }
        case .userChoice(let fallback):
            let g = appState.personaGender(for: def.id) ?? fallback
            return g == .undisclosed ? nil : (g == .male ? "男" : "女")
        case .irrelevant:
            return nil
        }
    }
}

struct RoleCard: View {
    let def: PersonaDefinition
    let isSelected: Bool
    let quote: String
    var genderNote: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: def.icon)
                .font(.title2)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(def.displayName)
                        .font(.body.weight(.medium))
                    if let note = genderNote {
                        Text(note)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
                Text("“\(quote)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
