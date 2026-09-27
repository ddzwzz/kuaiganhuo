import SwiftUI
import SwiftData
import KuaiGanHuCore

@main
struct KuaiGanHuoApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: [TaskItem.self, HabitItem.self])
    }
}

struct RootView: View {
    @State private var appState = AppState()
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "kgh.onboarded")

    var body: some View {
        TabView {
            TaskListView()
                .tabItem { Label("任务", systemImage: "checklist") }
            HabitsView()
                .tabItem { Label("习惯", systemImage: "flame.fill") }
            RolePickerView()
                .tabItem { Label("监工", systemImage: "person.wave.2.fill") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .environment(appState)
        .sheet(isPresented: $showOnboarding) {
            OnboardingView()
        }
        .task {
            NotificationManager.shared.requestAuthorization()
        }
    }
}

/// 全局状态：当前角色/情绪 + AI 配置 + 性别机制 + 防恶意统计
@Observable
final class AppState {
    /// 当前监工角色 ID（PersonaRegistry 数据驱动，支持任意注册角色；UserDefaults 存的就是角色 ID，旧数据天然兼容）
    var roleID: String {
        didSet { UserDefaults.standard.set(roleID, forKey: "kgh.role") }
    }
    var mood: MoodKind {
        didSet { UserDefaults.standard.set(mood.rawValue, forKey: "kgh.mood") }
    }
    var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: "kgh.baseURL") }
    }
    var model: String {
        didSet { UserDefaults.standard.set(model, forKey: "kgh.model") }
    }
    var apiKeySet: Bool = false
    /// 用户性别（伴侣监工自动使用与用户相反的性别；其余角色监工性别独立可选）
    var userGender: UserGender {
        didSet { UserDefaults.standard.set(userGender.rawValue, forKey: "kgh.userGender") }
    }
    /// 各监工角色的性别配置（角色 ID → 性别 rawValue；伴侣模式不走这里，自动与用户相反）
    var roleGenders: [String: String] {
        didSet {
            if let data = try? JSONEncoder().encode(roleGenders) {
                UserDefaults.standard.set(data, forKey: "kgh.roleGenders")
            }
        }
    }
    /// AI 的语气策略备忘（按监工角色隔离存储，最近 3 条）：伴侣模式学到的"放轻"不串进上司模式
    var toneNotesByRole: [String: [String]] {
        didSet {
            if let data = try? JSONEncoder().encode(toneNotesByRole) {
                UserDefaults.standard.set(data, forKey: "kgh.toneNotesByRole")
            }
        }
    }
    /// 连续辱骂监工的轮数（防恶意系统：达到升级线时 AI 表达人设化失望）
    var abuseStreak: Int {
        didSet { UserDefaults.standard.set(abuseStreak, forKey: "kgh.abuseStreak") }
    }
    /// 用户登记的真实情况（如肠胃炎、考试周），监工判定时参考
    var userFacts: [String] {
        didSet {
            if let data = try? JSONEncoder().encode(userFacts) {
                UserDefaults.standard.set(data, forKey: "kgh.userFacts")
            }
        }
    }
    /// 生理期开始日期记录（时间戳，最多保留 6 次），用于预测窗口
    var periodStarts: [Date] {
        didSet {
            let stamps = periodStarts.suffix(6).map { $0.timeIntervalSince1970 }
            UserDefaults.standard.set(stamps, forKey: "kgh.periodStarts")
        }
    }
    /// 拖延原因统计（原因 → 次数）：逾期完成时快速归因积累，供 AI 预判
    var delayCauses: [String: Int] {
        didSet {
            if let data = try? JSONEncoder().encode(delayCauses) {
                UserDefaults.standard.set(data, forKey: "kgh.delayCauses")
            }
        }
    }
    /// 重大生活事件（亲人离世、结婚、比赛等），触发体谅期：包容度升高再逐渐回落
    var majorEvents: [MajorEvent] {
        didSet {
            if let data = try? JSONEncoder().encode(majorEvents) {
                UserDefaults.standard.set(data, forKey: "kgh.majorEvents")
            }
        }
    }
    /// 借口分类统计（AI 每轮判定输出的分类 → 次数），用于识别"惯用理由"模式
    var excuseStats: [String: Int] {
        didSet {
            if let data = try? JSONEncoder().encode(excuseStats) {
                UserDefaults.standard.set(data, forKey: "kgh.excuseStats")
            }
        }
    }

    init() {
        let d = UserDefaults.standard
        // 存储的就是角色 ID：新注册的角色与旧版本数据天然兼容
        let storedRoleID = d.string(forKey: "kgh.role") ?? RoleKind.boss.rawValue
        let effectiveRoleID = PersonaRegistry.shared.exists(storedRoleID) ? storedRoleID : RoleKind.boss.rawValue
        self.roleID = effectiveRoleID
        self.mood = MoodKind(rawValue: d.string(forKey: "kgh.mood") ?? "") ?? .impatient
        self.baseURL = d.string(forKey: "kgh.baseURL") ?? "https://api.deepseek.com"
        self.model = d.string(forKey: "kgh.model") ?? "deepseek-chat"
        self.apiKeySet = !Keychain.get(service: "kgh", account: "apiKey").isEmpty
        self.userGender = UserGender(rawValue: d.string(forKey: "kgh.userGender") ?? "") ?? .undisclosed
        if let data = d.data(forKey: "kgh.roleGenders"),
           let map = try? JSONDecoder().decode([String: String].self, from: data) {
            self.roleGenders = map
        } else {
            self.roleGenders = [:]
        }
        // 语气备忘 v2（按角色隔离存储，模式切换不串味）；首次升级时把旧版全局备忘导入当前角色
        if let data = d.data(forKey: "kgh.toneNotesByRole"),
           let map = try? JSONDecoder().decode([String: [String]].self, from: data) {
            self.toneNotesByRole = map
        } else if let legacy = d.stringArray(forKey: "kgh.toneNotes"), !legacy.isEmpty {
            self.toneNotesByRole = [effectiveRoleID: legacy]
        } else {
            self.toneNotesByRole = [:]
        }
        self.abuseStreak = d.integer(forKey: "kgh.abuseStreak")
        if let data = d.data(forKey: "kgh.userFacts"),
           let facts = try? JSONDecoder().decode([String].self, from: data) {
            self.userFacts = facts
        } else {
            self.userFacts = []
        }
        self.periodStarts = (d.array(forKey: "kgh.periodStarts") as? [Double] ?? [])
            .map { Date(timeIntervalSince1970: $0) }
            .sorted()
        if let data = d.data(forKey: "kgh.delayCauses"),
           let causes = try? JSONDecoder().decode([String: Int].self, from: data) {
            self.delayCauses = causes
        } else {
            self.delayCauses = [:]
        }
        if let data = d.data(forKey: "kgh.majorEvents"),
           let events = try? JSONDecoder().decode([MajorEvent].self, from: data) {
            self.majorEvents = events
        } else {
            self.majorEvents = []
        }
        if let data = d.data(forKey: "kgh.excuseStats"),
           let stats = try? JSONDecoder().decode([String: Int].self, from: data) {
            self.excuseStats = stats
        } else {
            self.excuseStats = [:]
        }
    }

    // MARK: - 重大事件体谅期

    struct MajorEvent: Codable, Identifiable, Equatable {
        var id = UUID()
        var label: String
        var date: Date
    }

    /// 体谅期阶段描述：包容度先高后低，3 周后过期
    func eventStage(_ event: MajorEvent) -> String? {
        let days = Calendar.current.dateComponents([.day], from: event.date, to: Date()).day ?? 0
        switch days {
        case ..<0: return nil
        case 0...7: return "体谅期（第1周）：语气明显放软，只温和提醒不施压，不主动提及事件"
        case 8...14: return "恢复期（第2周）：温和推进任务，逐步恢复要求，仍不主动提及事件"
        case 15...21: return "尾声（第3周）：基本恢复正常语气，若提及任务后果措辞收敛"
        default: return nil
        }
    }

    var activeMajorEvents: [MajorEvent] {
        majorEvents.filter { eventStage($0) != nil }
    }

    /// 注入判定的重大事件状态行
    var majorEventLines: [String] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return activeMajorEvents.map { e in
            let days = Calendar.current.dateComponents([.day], from: e.date, to: Date()).day ?? 0
            return "\(e.label)（\(f.string(from: e.date))，\(days)天前）——\(eventStage(e)!)"
        }
    }

    func recordMajorEvent(label: String, date: Date = Date()) {
        guard !majorEvents.contains(where: { $0.label == label }) else { return }
        majorEvents.append(MajorEvent(label: label, date: date))
    }

    // MARK: - 角色与性别机制

    /// 当前监工的完整定义
    var persona: PersonaDefinition { PersonaRegistry.shared.persona(roleID) }

    /// 某角色的监工性别：按角色的性别策略解析
    /// - 伴侣模式：强制与用户性别相异（用户未设置性别时返回 nil，该角色不可选）
    /// - 上司/父母：用户可选，默认值兜底
    func personaGender(for id: String) -> UserGender? {
        switch PersonaRegistry.shared.persona(id).genderPolicy {
        case .oppositeOfUser:
            // 亲密向角色：监工性别与用户相异；用户未设置性别时该角色不可选（返回 nil）
            let flipped = userGender.opposite
            return flipped == .undisclosed ? nil : flipped
        case .userChoice(let fallback):
            if let s = roleGenders[id], let g = UserGender(rawValue: s), g != .undisclosed { return g }
            return fallback == .undisclosed ? nil : fallback
        case .irrelevant:
            return nil
        }
    }

    func setRoleGender(_ gender: UserGender, for id: String) {
        roleGenders[id] = gender.rawValue
    }

    /// 当前监工的性别上下文（注入每次 AI 调用）
    var genderContext: GenderContext {
        GenderContext(
            userGender: userGender == .undisclosed ? nil : userGender,
            personaGender: personaGender(for: roleID)
        )
    }

    /// 当前角色的语气备忘（模式隔离：只读当前角色的）
    func toneNotes(for id: String) -> [String] {
        Array((toneNotesByRole[id] ?? []).suffix(3))
    }

    func recordToneNote(_ note: String, for id: String) {
        var arr = toneNotesByRole[id] ?? []
        arr.append(note)
        toneNotesByRole[id] = arr
    }

    /// 防恶意统计：本轮审核后更新辱骂连续计数，返回当前值
    @discardableResult
    func updateAbuseStreak(after category: ModerationCategory) -> Int {
        switch category {
        case .abusive: abuseStreak += 1
        case .clean: abuseStreak = 0
        default: break  // 其他类别不清零（如色情拦截后接一条正常消息不清账）
        }
        return abuseStreak
    }

    // MARK: - 生理期预测（动态）

    private var cycleIntervals: [Double] {
        guard periodStarts.count >= 2 else { return [] }
        return zip(periodStarts, periodStarts.dropFirst())
            .map { $1.timeIntervalSince($0) / 86400 }
    }

    /// 平均周期天数：最近 3 个间隔加权（越近权重越高），夹在 21~45 天
    var averageCycleDays: Int {
        guard !cycleIntervals.isEmpty else { return 28 }
        let recent = Array(cycleIntervals.suffix(3))
        let weights = recent.count == 3 ? [0.5, 0.75, 1.0]
                       : recent.count == 2 ? [0.7, 1.0] : [1.0]
        let weighted = zip(recent, weights).reduce(0.0) { $0 + $1.0 * $1.1 }
            / weights.reduce(0, +)
        return max(21, min(45, Int(weighted.rounded())))
    }

    /// 周期是否不规律（间隔标准差 > 5 天）——不规律时窗口放宽、AI 保持不确定
    var cycleIsIrregular: Bool {
        let iv = cycleIntervals
        guard iv.count >= 2 else { return false }
        let mean = iv.reduce(0, +) / Double(iv.count)
        let variance = iv.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(iv.count)
        return variance.squareRoot() > 5
    }

    /// 今天是否落在生理期预测窗口（不规律时窗口更宽）
    var inPeriodWindowNow: Bool {
        guard let last = periodStarts.last else { return false }
        let cal = Calendar.current
        let predicted = cal.date(byAdding: .day, value: averageCycleDays, to: last) ?? last
        let lead = cycleIsIrregular ? 4 : 2     // 提前量：不规律 → 提前 4 天开始可能
        let span = cycleIsIrregular ? 9 : 7     // 持续：不规律 → 多留 2 天
        let start = cal.date(byAdding: .day, value: -lead, to: predicted) ?? predicted
        let end = cal.date(byAdding: .day, value: span, to: predicted) ?? predicted
        return Date() >= start && Date() <= end
    }

    /// 给 AI 的生理期情况描述（未记录则 nil，不注入）
    var periodPromptLine: String? {
        guard let last = periodStarts.last else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        var line = "记录了\(periodStarts.count)次生理期，最近一次\(f.string(from: last))开始，预测周期\(averageCycleDays)天"
        line += cycleIsIrregular ? "；周期不太规律，预测仅供参考，日期偏差是正常的" : ""
        line += "；今天\(inPeriodWindowNow ? "落在预测窗口内" : "不在预测窗口内（但不规律时也可能只是偏差）")"
        return line
    }

    // MARK: - 拖延模式

    func recordDelayCause(_ cause: String) {
        delayCauses[cause, default: 0] += 1
    }

    /// 给 AI 的拖延模式描述（无记录则 nil）
    var delayPatternLine: String? {
        let sorted = delayCauses.sorted { $0.value > $1.value }.prefix(3)
        guard !sorted.isEmpty else { return nil }
        let text = sorted.map { "\($0.key)\($0.value)次" }.joined(separator: "、")
        return "用户逾期后自述原因统计：" + text
    }

    // MARK: - 借口模式（AI 分类统计）

    func recordExcuseType(_ type: String) {
        guard !type.isEmpty, type != "null" else { return }
        excuseStats[type, default: 0] += 1
    }

    /// 给 AI 的借口模式描述（无记录则 nil）
    var excusePatternLine: String? {
        let sorted = excuseStats.sorted { $0.value > $1.value }.prefix(3)
        guard !sorted.isEmpty else { return nil }
        let text = sorted.map { "\($0.key)\($0.value)次" }.joined(separator: "、")
        return "历史理由分类统计：" + text
    }

    func makeClient() -> AIClient {
        AIClient(config: AIConfig(
            baseURL: baseURL,
            apiKey: Keychain.get(service: "kgh", account: "apiKey"),
            model: model
        ))
    }
}
