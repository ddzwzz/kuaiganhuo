import SwiftUI
import SwiftData
import KuaiGanHuCore

/// 习惯养成页：列表 + 打卡 + 新建 + "今天不想做"对话（复用判定协议）
struct HabitsView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var appState
    @Query(filter: #Predicate<HabitItem> { $0.active == true }, sort: \HabitItem.startDate)
    private var habits: [HabitItem]

    @State private var showNewHabit = false
    @State private var excuseHabit: HabitItem?
    @State private var celebrateText: String?
    @State private var showCelebrate = false

    var body: some View {
        NavigationStack {
            Group {
                if habits.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "flame")
                            .font(.system(size: 40))
                            .foregroundStyle(.tertiary)
                        Text("还没有习惯。想坚持什么？背单词、跑步、早睡……")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(habits) { habit in
                            HabitRow(
                                habit: habit,
                                onCheckIn: { checkIn(habit) },
                                onExcuse: { excuseHabit = habit }
                            )
                        }
                        .onDelete { indexSet in
                            for i in indexSet {
                                NotificationManager.shared.cancelHabitNotifications(habitID: habits[i].idString)
                                habits[i].active = false
                            }
                            try? context.save()
                        }
                    }
                }
            }
            .navigationTitle("习惯")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showNewHabit = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showNewHabit) {
                NewHabitView()
            }
            .sheet(item: $excuseHabit) { habit in
                HabitExcuseSheet(habit: habit)
            }
            .alert("打卡成功", isPresented: $showCelebrate) {
                Button("好", role: .cancel) {}
            } message: {
                Text(celebrateText ?? "")
            }
            .onAppear {
                refreshAll()
            }
        }
    }

    /// 打卡：记一笔 + 取消今晚追问 + AI 按阶段庆祝
    private func checkIn(_ habit: HabitItem) {
        guard habit.checkIn() else { return }
        NotificationManager.shared.cancelHabitEvening(habitID: habit.idString)
        try? context.save()

        let client = appState.makeClient()
        let roleID = appState.roleID, mood = appState.mood
        let gender = appState.genderContext
        let stateLine = habit.habitStateLine
        let name = habit.name
        Task {
            let fallback = PersonaRegistry.shared.persona(roleID).praise[mood] ?? "干得不错。"
            let reply: String
            if let r = try? await client.generateCelebration(
                roleID: roleID, mood: mood, taskTitle: name,
                onTime: true, habitStateLine: stateLine, gender: gender
            ), OutputGuard.safe(r) != nil {
                reply = r
            } else {
                reply = fallback
            }
            await MainActor.run {
                celebrateText = reply
                showCelebrate = true
            }
        }
    }

    /// 打开页面时：漏卡结算 + 重排提醒（文案随阶段更新）
    private func refreshAll() {
        let client = appState.makeClient()
        let roleID = appState.roleID, mood = appState.mood
        let gender = appState.genderContext
        for habit in habits where habit.active {
            habit.settleMissedDays()
        }
        try? context.save()
        for habit in habits where habit.active {
            let intensive = habit.phase == .launching || habit.phase == .struggle
            let stateLine = habit.habitStateLine
            let name = habit.name
            let anchor = habit.anchor
            let anchorTime = habit.todayAnchorTime
            let hid = habit.idString
            Task {
                if let set = try? await client.generateHabitNudges(
                    roleID: roleID, mood: mood, habitName: name,
                    anchor: anchor, habitStateLine: stateLine, gender: gender
                ) {
                    await MainActor.run {
                        NotificationManager.shared.scheduleHabitReminders(
                            habitID: hid, habitName: name,
                            anchorTime: anchorTime,
                            anchorText: OutputGuard.safe(set.anchor) ?? "\(name)时间到了，做一点点。",
                            eveningText: intensive ? (OutputGuard.safe(set.evening) ?? "今天的\(name)还没做，两分钟也算数。") : nil,
                            intensive: intensive
                        )
                    }
                }
            }
        }
    }
}

// MARK: - 习惯行

private struct HabitRow: View {
    let habit: HabitItem
    let onCheckIn: () -> Void
    let onExcuse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(habit.name).font(.headline)
                    Text("\(habit.anchor) · 第\(habit.dayNumber)天 · \(habit.phase.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if habit.streak > 0 {
                    Text("\(habit.streak)天")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.orange.opacity(0.15)))
                        .foregroundStyle(.orange)
                }
            }
            HStack {
                if habit.checkedToday {
                    Label("今天已打卡", systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                } else {
                    Button("打卡", action: onCheckIn)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("今天不想做…", action: onExcuse)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Spacer()
                if habit.missedStreak >= 1 {
                    Text("漏\(habit.missedStreak)天")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 新建习惯

private struct NewHabitView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    @State private var name = ""
    @State private var anchor = "睡前"
    @State private var time = Calendar.current.date(bySettingHour: 22, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var generating = false

    private let anchorOptions = ["睡前", "早饭后", "午休时", "晚饭后", "到宿舍时", "起床后"]

    var body: some View {
        NavigationStack {
            Form {
                Section("习惯") {
                    TextField("想坚持什么（如：背50个单词）", text: $name)
                }
                Section("锚点——把它绑在一个固定时刻上（习惯科学：绑定现有节律比靠意志力靠谱）") {
                    Picker("场景", selection: $anchor) {
                        ForEach(anchorOptions, id: \.self) { Text($0) }
                    }
                    DatePicker("提醒时间", selection: $time, displayedComponents: .hourAndMinute)
                }
                Section {
                    Text("前 7 天是启动期（多哄多夸），第 8-30 天是最容易放弃的挣扎期（提醒最狠），66 天后习惯基本成形。漏一天不算失败，恢复打卡才是重点。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("新习惯")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || generating)
                }
            }
        }
    }

    private func save() {
        generating = true
        let habit = HabitItem(
            name: name.trimmingCharacters(in: .whitespaces),
            anchor: anchor,
            remindHour: Calendar.current.component(.hour, from: time),
            remindMinute: Calendar.current.component(.minute, from: time)
        )
        context.insert(habit)
        try? context.save()

        // 首日提醒文案（AI 失败降级为内置）
        let client = appState.makeClient()
        let roleID = appState.roleID, mood = appState.mood
        let gender = appState.genderContext
        let stateLine = habit.habitStateLine
        let hname = habit.name, hanchor = habit.anchor, hid = habit.idString
        let anchorTime = habit.todayAnchorTime
        Task {
            let set = (try? await client.generateHabitNudges(
                roleID: roleID, mood: mood, habitName: hname,
                anchor: hanchor, habitStateLine: stateLine, gender: gender
            )) ?? HabitNudgeSet(
                anchor: "\(hanchor)到了，\(hname)，先做一点点。",
                evening: "今天还没做\(hname)。两分钟也算数。"
            )
            await MainActor.run {
                NotificationManager.shared.scheduleHabitReminders(
                    habitID: hid, habitName: hname,
                    anchorTime: anchorTime,
                    anchorText: OutputGuard.safe(set.anchor) ?? "\(hanchor)到了，\(hname)，先做一点点。",
                    eveningText: OutputGuard.safe(set.evening) ?? "今天还没做\(hname)。两分钟也算数。",
                    intensive: true
                )
                dismiss()
            }
        }
    }
}

// MARK: - "今天不想做"对话（复用判定协议）

private struct HabitExcuseSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    let habit: HabitItem

    @State private var excuse = ""
    @State private var reply: String?
    @State private var index: Int?
    @State private var verdict: Verdict?
    @State private var thinking = false

    var body: some View {
        NavigationStack {
            Form {
                Section("和监工说说为什么") {
                    TextField("今天怎么啦？", text: $excuse, axis: .vertical)
                        .lineLimit(3...6)
                }
                if thinking {
                    Section { HStack { ProgressView(); Text("监工在想…") } }
                }
                if let reply {
                    Section("监工") {
                        Text(reply)
                        if let v = verdict, let i = index {
                            Text(v == .reasonable ? "判定：合理（狡辩指数 \(i)）" : "判定：狡辩（指数 \(i)）")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("「\(habit.name)」")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发送") { send() }
                        .disabled(excuse.trimmingCharacters(in: .whitespaces).isEmpty || thinking)
                }
            }
        }
    }

    private func send() {
        let text = excuse.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        thinking = true
        let client = appState.makeClient()
        let roleID = appState.roleID, mood = appState.mood
        let gender = appState.genderContext
        let stateLine = habit.habitStateLine
        let name = habit.name
        let anchorTime = habit.todayAnchorTime
        let facts = appState.userFacts
        // 防恶意：习惯对话同样走本地预检（自伤/色情本地回复，辱骂人设化应对）
        let moderation = Moderator.precheck(
            text, persona: appState.persona, abuseStreak: appState.abuseStreak
        )
        appState.updateAbuseStreak(after: moderation.category)
        let notes = appState.toneNotes(for: roleID)
        let excusePattern = appState.excusePatternLine

        Task {
            defer { thinking = false }
            if moderation.action == .localReply {
                await MainActor.run {
                    reply = moderation.localReply
                    verdict = nil
                    index = nil
                }
                return
            }
            do {
                // 习惯没有截止时间，用今天的锚点时刻充当"应做时刻"
                let (result, _) = try await client.judgeExcuse(
                    roleID: roleID, mood: mood,
                    taskTitle: name, deadline: anchorTime,
                    userMessage: text, history: [],
                    excuseHistory: [], userFacts: facts,
                    toneNotes: notes,
                    excusePatternLine: excusePattern,
                    habitStateLine: stateLine,
                    gender: gender,
                    moderationLine: moderation.instruction
                )
                await MainActor.run {
                    reply = result.reply
                    verdict = result.verdict
                    index = result.bullshitIndex
                    if let note = result.toneNote, note != "null", !note.isEmpty {
                        appState.recordToneNote(note, for: roleID)
                    }
                    if let type = result.excuseType, type != "null", !type.isEmpty {
                        appState.recordExcuseType(type)
                    }
                }
            } catch {
                await MainActor.run { reply = "（网络开小差了：\(error.localizedDescription)）" }
            }
        }
    }
}
