import SwiftUI
import KuaiGanHuCore

/// 首次启动引导：性别（决定监工人设性别）+ 可选填写"我的情况"，让监工从第一天就体谅真实的你
struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var draft: [String] = []
    @State private var input = ""
    @State private var gender: UserGender = .undisclosed
    @State private var avatar: AvatarKind = .builtin(1)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    AvatarView(kind: avatar, size: 64)
                    Text("让监工认识真实的你")
                        .font(.title3.weight(.semibold))
                    Text("填写后，监工判定借口时会记得这些情况——\n比如真有肠胃炎，就不会被当成装病")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 32)
                .padding(.bottom, 20)

                List {
                    Section {
                        Picker("我是", selection: $gender) {
                            ForEach(UserGender.allCases) { g in
                                Text(g.displayName).tag(g)
                            }
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        Text("你的性别")
                    } footer: {
                        Text("监工人设会据此贴合：父母/上司的性别可单独选，伴侣模式会自动使用与你相反的性别。只存在手机本地，随时可改。")
                    }

                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(builtInAvatars) { ava in
                                    let kind = AvatarKind.builtin(ava.id)
                                    Button { avatar = kind } label: {
                                        AvatarView(kind: kind, size: 56)
                                            .overlay(
                                                Circle()
                                                    .stroke(avatar == kind ? Color.accentColor : Color.clear, lineWidth: 3)
                                                    .padding(-3)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("头像 \(ava.id)")
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    } header: {
                        Text("给监工挑个头像")
                    } footer: {
                        Text("内置头像都是 App 自己画的几何图形，不涉及任何第三方素材。以后可以在设置里换成自己的照片。")
                    }

                    Section {
                        ForEach(draft.indices, id: \.self) { i in
                            Label(draft[i], systemImage: "checkmark.circle")
                                .foregroundStyle(.green)
                        }
                        .onDelete { draft.remove(atOffsets: $0) }
                        HStack {
                            TextField("如：我有慢性肠胃炎 / 这两周是考试周", text: $input)
                            Button("添加") {
                                let fact = input.trimmingCharacters(in: .whitespaces)
                                guard !fact.isEmpty else { return }
                                draft.append(fact)
                                input = ""
                            }
                            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    } header: {
                        Text("有没有需要监工体谅的情况？")
                    } footer: {
                        Text("完全可选，可以以后在设置里补填。只存在手机本地。")
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("跳过") {
                        UserDefaults.standard.set(true, forKey: "kgh.onboarded")
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("开始") {
                        appState.userFacts = draft
                        appState.userGender = gender
                        appState.setAvatar(avatar, for: appState.roleID)
                        UserDefaults.standard.set(true, forKey: "kgh.onboarded")
                        dismiss()
                    }
                    .font(.body.weight(.semibold))
                }
            }
        }
        .interactiveDismissDisabled()
        .task {
            // 首次进入时把选择器对齐到当前角色的默认头像
            avatar = appState.avatar(for: appState.roleID)
        }
    }
}
