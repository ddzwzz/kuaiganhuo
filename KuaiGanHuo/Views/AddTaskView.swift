import SwiftUI
import SwiftData
import KuaiGanHuCore

/// 布置任务页：自然语言 → AI 解析 → 确认保存（保存时预生成催促文案）
struct AddTaskView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var appState

    @State private var input = ""
    @State private var parsing = false
    @State private var generating = false
    @State private var errorMessage: String?
    @State private var parsed: TaskParseResult?
    @State private var editingTasks: [ParsedTask] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $input)
                        .frame(minHeight: 100)
                        .disabled(parsing || generating)
                    Button {
                        parse()
                    } label: {
                        if parsing {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("解析安排").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || parsing || generating)
                } header: {
                    Text("跟监工说你的安排")
                } footer: {
                    EmptyView()
                }

                if let clarification = parsed?.clarification, editingTasks.isEmpty {
                    Section {
                        Label(clarification, systemImage: "questionmark.bubble")
                            .foregroundStyle(.orange)
                    } header: {
                        Text("监工有话说")
                    } footer: {
                        EmptyView()
                    }
                }

                if !editingTasks.isEmpty {
                    Section {
                        ForEach(editingTasks.indices, id: \.self) { i in
                            EditableTaskRow(task: $editingTasks[i])
                        }
                    } header: {
                        Text("解析结果（可改）")
                    } footer: {
                        EmptyView()
                    }
                    Section {
                        Button {
                            save()
                        } label: {
                            if generating {
                                ProgressView().frame(maxWidth: .infinity)
                            } else {
                                Text("交给监工盯梢").frame(maxWidth: .infinity)
                            }
                        }
                        .disabled(generating)
                    } footer: {
                        Text("保存时会按当前监工（\(appState.persona.displayName) · \(appState.mood.displayName)）预生成催促文案。宽限度决定监工对你的容忍度：很难宽限=硬截止从严，容易宽限=自我安排从宽")
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("布置任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func parse() {
        parsing = true
        errorMessage = nil
        Task {
            defer { parsing = false }
            do {
                let result = try await appState.makeClient().parseTasks(userInput: input)
                parsed = result
                editingTasks = result.tasks
                if result.tasks.isEmpty && result.clarification == nil {
                    errorMessage = "没解析出任务，换个说法试试"
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// 通知文案过滤后为空时用内置兜底，保证通知一定有内容
    private static func secured(_ texts: [String], fallback: [String]) -> [String] {
        texts.isEmpty ? fallback : texts
    }

    private func save() {
        // 任务标题预检：低俗标题既不送 API 也不推通知（锁屏可见，社交风险太大）
        for parsed in editingTasks {
            let check = Moderator.precheck(parsed.title, persona: appState.persona)
            if check.action == .localReply || check.category == .sexual || check.category == .selfHarm {
                errorMessage = "任务名「\(parsed.title)」没法生成提醒文案，换个说法吧"
                return
            }
        }
        generating = true
        errorMessage = nil
        let client = appState.makeClient()
        let roleID = appState.roleID, mood = appState.mood
        let gender = appState.genderContext
        let tasksToSave = editingTasks
        let delayPattern = appState.delayPatternLine
        Task {
            defer { generating = false }
            do {
                for parsed in tasksToSave {
                    let nudges: NudgeSet
                    if let n = try? await client.generateNudges(roleID: roleID, mood: mood, taskTitle: parsed.title, deadline: parsed.deadline, delayPattern: delayPattern, strictness: parsed.strictness, gender: gender) {
                        // 输出侧自检：通知文案要上锁屏，比聊天更公开，越界的一律换成兜底
                        nudges = NudgeSet(
                            atDeadline: Self.secured(OutputGuard.safeList(n.atDeadline), fallback: ["到点了。该干活了。", "\(parsed.title)，现在。"]),
                            graceOver: OutputGuard.safe(n.graceOver) ?? "宽限结束了。别让我说第三遍。"
                        )
                    } else {
                        // 降级：AI 失败也不挡保存，用内置兜底文案
                        nudges = NudgeSet(
                            atDeadline: ["到点了。该干活了。", "\(parsed.title)，现在。"],
                            graceOver: "宽限结束了。别让我说第三遍。"
                        )
                    }
                    let item = TaskItem(title: parsed.title, deadline: parsed.deadline, nudges: nudges, strictness: parsed.strictness ?? .normal)
                    // 预生成文案将随通知发出，先记账，聊天时 AI 不许重复这些话（带角色标签，切换监工时不串味）
                    for text in nudges.atDeadline + [nudges.graceOver] {
                        item.appendSentNudge(text, roleID: roleID)
                    }
                    context.insert(item)
                    NotificationManager.shared.scheduleDeadlineNudge(
                        taskID: item.idString,
                        taskTitle: item.title,
                        deadline: item.deadline ?? Date(),
                        texts: nudges.atDeadline,
                        escalate: false
                    )
                }
                dismiss()
            }
        }
    }
}

struct EditableTaskRow: View {
    @Binding var task: ParsedTask

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("任务名", text: $task.title)
            DatePicker("截止", selection: Binding(
                get: { task.deadline ?? Date().addingTimeInterval(3600) },
                set: { task.deadline = $0 }
            ))
            Picker("宽限度", selection: Binding(
                get: { task.strictness ?? .normal },
                set: { task.strictness = $0 }
            )) {
                ForEach(TaskStrictness.allCases) { s in
                    Text(s.displayName).tag(s)
                }
            }
            .pickerStyle(.segmented)
        }
    }
}
