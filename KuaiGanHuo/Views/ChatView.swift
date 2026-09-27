import SwiftUI
import SwiftData
import KuaiGanHuCore

/// 监工对话页：通知点进来直达这里。借口判定核心交互。
struct ChatView: View {
    @Bindable var task: TaskItem
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @State private var input = ""
    @State private var thinking = false
    @State private var errorText: String?
    /// AI 提出的档案候选（如"经常肠胃不适"），显示为可一键记入的横幅
    @State private var factCandidate: String?
    /// AI 检测到的重大生活事件（如"亲人离世"），一键记入体谅期
    @State private var eventCandidate: String?
    /// 逾期任务点完成时弹出的归因选择
    @State private var showCausePicker = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(task.messages.indices, id: \.self) { i in
                            Bubble(message: task.messages[i])
                                .id(i)
                        }
                    }
                    .padding()
                }
                .onChange(of: task.messages.count) { _, new in
                    if let last = task.messages.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
                .defaultScrollAnchor(.bottom)
            }
            Divider()
            if let candidate = factCandidate {
                factBanner(candidate)
                Divider()
            }
            if let event = eventCandidate {
                eventBanner(event)
                Divider()
            }
            inputBar
        }
        .navigationTitle(task.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("完成了") { markDone() }
                    .disabled(task.status == .done)
            }
        }
        .confirmationDialog(
            "这次为什么拖到逾期？",
            isPresented: $showCausePicker,
            titleVisibility: .visible
        ) {
            Button("刷视频忘了时间") { appState.recordDelayCause("刷视频") }
            Button("打游戏忘了时间") { appState.recordDelayCause("打游戏") }
            Button("和人聊天 / 回消息") { appState.recordDelayCause("聊天") }
            Button("发呆 / 提不起劲") { appState.recordDelayCause("发呆") }
            Button("其他原因") { appState.recordDelayCause("其他") }
            Button("不告诉你", role: .cancel) {}
        } message: {
            Text("只在本机统计，监工会据此提前拦截你的老毛病")
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "person.wave.2.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(appState.persona.displayName) · \(appState.mood.displayName)")
                    .font(.subheadline.weight(.medium))
                if task.status == .grace {
                    Text("宽限中，到点会再查岗")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            if let d = task.deadline {
                Text(d.formatted(.dateTime.hour().minute()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("说说你的理由…", text: $input, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .disabled(thinking)
            Button {
                send()
            } label: {
                if thinking {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
            }
            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || thinking)
        }
        .padding()
    }

    // MARK: - 逻辑

    private func append(_ message: ChatMessage) {
        var msgs = task.messages
        msgs.append(message)
        task.messages = msgs
        try? context.save()
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let deadline = task.deadline else { return }
        input = ""
        let roleID = appState.roleID
        // 对话消息带角色标签：模式隔离的基础（AI 只看同角色的历史）
        append(ChatMessage(sender: .user, text: text, roleKey: roleID))
        thinking = true
        errorText = nil

        // 到期未兑现的承诺先落账为失信，让 AI 这轮就能点破"说到没做到"
        task.settlePromise()

        // ── 防恶意系统：本地预检（第一道防线）──
        // 色情/自伤内容不出本机、不上送 API；辱骂/越狱/粗俗注入人设化应对指示
        let moderation = Moderator.precheck(
            text,
            persona: appState.persona,
            abuseStreak: appState.abuseStreak
        )
        appState.updateAbuseStreak(after: moderation.category)

        if moderation.action == .localReply {
            // 本地直接回复：不走 AI，立即响应
            append(ChatMessage(sender: .supervisor, text: moderation.localReply ?? "……", roleKey: roleID))
            thinking = false
            // 安全优先：用户流露自伤念头时，暂停这个任务后续的催促通知
            if moderation.category == .selfHarm {
                NotificationManager.shared.cancelTaskNotifications(taskID: task.idString)
            }
            return
        }

        let client = appState.makeClient()
        let mood = appState.mood
        let gender = appState.genderContext
        let history = task.messages
        let excuseHistory = task.excuseHistory
        let userFacts = appState.userFacts
        let periodLine = appState.periodPromptLine
        let delayLine = appState.delayPatternLine
        let eventLines = appState.majorEventLines
        // 语气策略按角色隔离：只读当前监工学到的
        let notes = appState.toneNotes(for: roleID)
        let excusePattern = appState.excusePatternLine
        let promiseLines = task.promiseLines()
        // 通知文案按角色隔离注入
        let sentNudges = task.sentNudges(for: roleID)
        let title = task.title
        let factDigests = task.factDigests

        Task {
            defer { thinking = false }
            do {
                let (result, _) = try await client.judgeExcuse(
                    roleID: roleID,
                    mood: mood,
                    taskTitle: title,
                    deadline: deadline,
                    userMessage: text,
                    history: history,
                    excuseHistory: excuseHistory,
                    userFacts: userFacts,
                    periodLine: periodLine,
                    delayPatternLine: delayLine,
                    majorEventLines: eventLines,
                    toneNotes: notes,
                    now: Date(),
                    promiseLines: promiseLines,
                    excusePatternLine: excusePattern,
                    sentNudges: sentNudges,
                    strictness: task.strictness,
                    gender: gender,
                    moderationLine: moderation.instruction,
                    factDigests: factDigests
                )
                // 输出侧自检：AI 自己跑偏时，用内置兜底替换（通知栏比聊天更公开，不能冒这个险）
                let persona = appState.persona
                let fallbackLine = persona.nudgeExamples[mood]?.first ?? "该干活了。"
                var replyText = result.reply.isEmpty ? "先照顾好自己，别的事我们以后再说。" : result.reply
                if OutputGuard.safe(replyText) == nil { replyText = fallbackLine }
                append(ChatMessage(
                    sender: .supervisor,
                    text: replyText,
                    verdict: result.verdict,
                    bullshitIndex: result.bullshitIndex,
                    roleKey: roleID
                ))
                if let question = result.profileQuestion, question != "null",
                   OutputGuard.safe(question) != nil {
                    append(ChatMessage(sender: .supervisor, text: question, roleKey: roleID))
                }
                // 任务事实摘要：跨角色共享的交接信息（切换监工时新角色知道进展、不知道私聊内容）
                // 入库前走专用安检（长度 + 安全 + 反注入），避免夹带内容通过这条通道扩散
                if let digest = OutputGuard.safeFact(result.factDigest ?? "") {
                    task.appendFactDigest(digest)
                }
                factCandidate = (result.factCandidate != nil && result.factCandidate != "null") ? result.factCandidate : nil
                // 重大生活事件：AI 检测到 → 弹横幅一键记录，进入体谅期
                if let event = result.majorEvent, event != "null", event.count < 20 {
                    eventCandidate = event
                }
                // 语气策略：AI 读出的满意度调整持续生效（按角色隔离存储）
                if let note = result.toneNote, note != "null", !note.isEmpty {
                    appState.recordToneNote(note, for: roleID)
                }
                // 借口分类统计：合理与狡辩都记，供"惯用理由"模式识别
                if let type = result.excuseType, type != "null", !type.isEmpty {
                    appState.recordExcuseType(type)
                }
                // 时间承诺：落账 + 按承诺时间点查岗
                var checkInMinutes = result.nextCheckMinutes
                if let claim = result.promiseClaim, claim != "null", !claim.isEmpty {
                    let dueMinutes = result.promiseDueMinutes ?? result.nextCheckMinutes
                    task.recordPromise(claim: claim, minutes: dueMinutes)
                    checkInMinutes = min(checkInMinutes, max(5, dueMinutes))
                }
                // 模型自带对齐兜底：它认为这轮越界并做了软拒 → 不把这句记进"历史借口"（避免脏数据污染翻旧账）
                if result.safetyRefuse != true {
                    task.excuseHistory.append(text)
                    if task.excuseHistory.count > 20 { task.excuseHistory.removeFirst(task.excuseHistory.count - 20) }
                }

                let graceText = task.nudgeGraceOver
                task.appendSentNudge(graceText, roleID: roleID)

                if result.verdict == .reasonable {
                    task.status = .grace
                    NotificationManager.shared.scheduleCheckIn(
                        taskID: task.idString,
                        taskTitle: task.title,
                        afterMinutes: result.graceMinutes + 1,
                        text: graceText
                    )
                } else {
                    NotificationManager.shared.scheduleCheckIn(
                        taskID: task.idString,
                        taskTitle: task.title,
                        afterMinutes: checkInMinutes,
                        text: graceText
                    )
                }
                try? context.save()
            } catch {
                errorText = error.localizedDescription
                append(ChatMessage(sender: .supervisor, text: "（网络开小差了：\(error.localizedDescription)）", roleKey: roleID))
            }
        }
    }

    /// 档案候选横幅：一键把 AI 提炼的情况写进"我的情况"
    private func factBanner(_ candidate: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.plus")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("把「\(candidate)」记入我的情况？")
                    .font(.footnote.weight(.medium))
                Text("以后监工会体谅，不再为难你")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("记入") {
                appState.userFacts.append(candidate)
                factCandidate = nil
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button("不了") { factCandidate = nil }
                .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    /// 重大事件横幅：记入后进入约 3 周体谅期（语气渐弱再渐回）
    private func eventBanner(_ event: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "heart.circle")
                .foregroundStyle(.pink)
            VStack(alignment: .leading, spacing: 2) {
                Text("把「\(event)」记入大事件？")
                    .font(.footnote.weight(.medium))
                Text("接下来几周监工会温柔些，慢慢恢复")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("记入") {
                appState.recordMajorEvent(label: event)
                eventCandidate = nil
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button("不了") { eventCandidate = nil }
                .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func markDone() {
        let now = Date()
        let wasLate = task.deadline.map { $0 < now } ?? false
        task.status = .done
        NotificationManager.shared.cancelTaskNotifications(taskID: task.idString)

        // 承诺结算：到点前完成=兑现，超时=失信
        var keptPromise: Bool? = nil
        if let claim = task.promiseClaim {
            keptPromise = (task.promiseDue ?? now) >= now
            if keptPromise != true {
                task.brokenPromises.append(claim)
                if task.brokenPromises.count > 5 { task.brokenPromises.removeFirst(task.brokenPromises.count - 5) }
            }
            task.promiseClaim = nil
            task.promiseDue = nil
        }
        try? context.save()

        // 人设化庆祝（真实 API 失败时降级为内置夸奖）
        let client = appState.makeClient()
        let roleID = appState.roleID, mood = appState.mood
        let gender = appState.genderContext
        let title = task.title
        let history = task.messages
        Task {
            let fallback = PersonaRegistry.shared.resolved(roleID, gender: gender.personaGender).praise[mood]
                ?? PersonaRegistry.shared.persona(roleID).praise[mood]
                ?? "干得不错。"
            let reply: String
            if let r = try? await client.generateCelebration(
                roleID: roleID, mood: mood, taskTitle: title,
                onTime: !wasLate, keptPromise: keptPromise, history: history,
                gender: gender
            ), OutputGuard.safe(r) != nil {
                reply = r
            } else {
                reply = fallback
            }
            append(ChatMessage(sender: .supervisor, text: reply, roleKey: roleID))
        }
        // 逾期完成的任务：问一句为什么拖延，积累"拖延模式"供 AI 预判
        if wasLate { showCausePicker = true }
    }
}

/// 聊天气泡：判定结果默认隐藏，点一下才揭示（保留"被戳穿"的戏剧感，不剧透）
struct Bubble: View {
    let message: ChatMessage
    @State private var revealed = false

    var body: some View {
        HStack {
            if message.sender == .user { Spacer(minLength: 40) }
            VStack(alignment: message.sender == .user ? .trailing : .leading, spacing: 4) {
                if message.sender == .supervisor, let verdict = message.verdict, revealed {
                    HStack(spacing: 4) {
                        Image(systemName: verdict == .reasonable ? "checkmark.seal.fill" : "exclamationmark.shield.fill")
                        Text(verdict == .reasonable ? "理由合理" : "狡辩指数 \(message.bullshitIndex ?? 0)%")
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(verdict == .reasonable ? Color.green : Color.red)
                    .transition(.opacity)
                }
                Text(message.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        message.sender == .user
                            ? Color.accentColor.opacity(0.18)
                            : Color(.systemGray6)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                if message.sender == .supervisor, message.verdict != nil, !revealed {
                    Text("点击查看判定")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { revealed.toggle() } }
            if message.sender == .supervisor { Spacer(minLength: 40) }
        }
    }
}
