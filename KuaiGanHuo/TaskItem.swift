import Foundation
import SwiftData
import KuaiGanHuCore

/// 任务数据模型（SwiftData 本地持久化）
@Model
final class TaskItem {
    /// 稳定唯一 ID（通知取消跨启动依赖它，不能用 persistentModelID）
    var uid: String
    var title: String
    var deadline: Date?
    var createdAt: Date
    /// pending = 进行中 / grace = 宽限中 / done = 已完成
    var statusRaw: String
    /// 预生成的到点催促文案（本地通知弹出用）
    var nudgeAtDeadline: [String]
    /// 宽限结束查岗文案
    var nudgeGraceOver: String
    /// 对话历史（含监工与用户）
    var chatJSON: Data
    /// 历史借口记录（翻旧账用）
    var excuseHistory: [String]
    /// 待兑现的时间承诺原话（如"再给我10分钟"），无则 nil
    var promiseClaim: String?
    /// 承诺到期时间，过期未完成即失信
    var promiseDue: Date?
    /// 已失信的承诺（原话，最近 5 条），注入判定供 AI 点破"说到没做到"
    var brokenPromises: [String]
    /// 已通过系统通知发出去的文案（"角色ID\u{1F}文案"编码存储，隔离注入防串味）
    var sentNudges: [String]
    /// 宽限度（用户自定义分级，影响 AI 判定松紧）
    var strictnessRaw: String
    /// 跨角色共享的任务事实摘要（AI 每轮提炼，最近 8 条；切换监工角色时交接任务进展用）
    var factDigests: [String]

    // MARK: - 周期 / 固定时间段（每天几点做、每周哪几天、每 N 天）
    /// 重复规则原始值（RepeatRule）
    var repeatRuleRaw: String = RepeatRule.none.rawValue
    /// 每周规则下选中的星期（1=周日 … 7=周六），与 Calendar.component(.weekday) 一致
    var weekdays: [Int] = []
    /// 每 N 天规则下的间隔天数
    var intervalDays: Int = 3
    /// 固定做这件事的时刻 "HH:mm"（周期任务用；空=不限时刻）
    var timeOfDay: String = ""
    /// 完成日志（"yyyy-MM-dd"，周期任务按天记，一天只记一次）
    var completions: [String] = []

    // MARK: - 任务类型（决定监工给的具体建议）
    var taskTypeRaw: String = TaskKind.auto.rawValue
    /// 具体建议轮换游标（保证不连着重复同一句）
    var stepCursor: Int = 0

    var status: TaskStatus {
        get { TaskStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    var strictness: TaskStrictness {
        get { TaskStrictness(rawValue: strictnessRaw) ?? .normal }
        set { strictnessRaw = newValue.rawValue }
    }

    var repeatRule: RepeatRule {
        get { RepeatRule(rawValue: repeatRuleRaw) ?? .none }
        set { repeatRuleRaw = newValue.rawValue }
    }

    var kind: TaskKind {
        get { TaskKind(rawValue: taskTypeRaw) ?? .auto }
        set { taskTypeRaw = newValue.rawValue }
    }

    /// auto 时按标题关键词兜底识别
    var resolvedKind: TaskKind {
        kind == .auto ? TaskKind.detect(title: title) : kind
    }

    var isRecurring: Bool { repeatRule != .none }

    /// 规则简述，如 "每周一三"、"每 3 天"
    var repeatLabel: String {
        Recurrence.label(rule: repeatRule, weekdays: weekdays, intervalDays: intervalDays)
    }

    /// 今天是否该做（只针对周期任务）
    func isDueToday(now: Date = Date()) -> Bool {
        guard status != .done else { return false }
        return Recurrence.isDueToday(rule: repeatRule, weekdays: weekdays,
                                     intervalDays: intervalDays, completions: completions, now: now)
    }

    func doneToday(now: Date = Date()) -> Bool {
        Recurrence.doneToday(completions: completions, now: now)
    }

    /// 到了固定时刻但今天还没做
    func missedToday(now: Date = Date()) -> Bool {
        guard isRecurring, !timeOfDay.isEmpty, !doneToday(now: now),
              let at = Recurrence.today(at: timeOfDay, now: now) else { return false }
        return now > at
    }

    /// 周期任务：记今天完成（幂等，重复调用只记一次）
    @discardableResult
    func markDoneToday(now: Date = Date()) -> Bool {
        let key = Recurrence.dayKey(now)
        if completions.contains(key) { return false }
        completions.append(key)
        if completions.count > 400 { completions.removeFirst(completions.count - 400) }
        return true
    }

    /// 下一次该做的自然语言描述
    func nextDueText(now: Date = Date()) -> String {
        Recurrence.nextDueText(rule: repeatRule, weekdays: weekdays,
                               intervalDays: intervalDays, timeOfDay: timeOfDay, from: now)
    }

    /// 取一条"此刻能立刻开始"的具体动作（同一任务轮换，不重复）
    func nextConcreteStep() -> String {
        let s = resolvedKind.step(cursor: stepCursor)
        stepCursor += 1
        return s
    }

    init(title: String, deadline: Date?, nudges: NudgeSet, strictness: TaskStrictness = .normal) {
        self.uid = UUID().uuidString
        self.title = title
        self.deadline = deadline
        self.createdAt = Date()
        self.statusRaw = TaskStatus.pending.rawValue
        self.nudgeAtDeadline = nudges.atDeadline
        self.nudgeGraceOver = nudges.graceOver
        self.chatJSON = (try? JSONEncoder().encode([ChatMessage]())) ?? Data("[]".utf8)
        self.excuseHistory = []
        self.promiseClaim = nil
        self.promiseDue = nil
        self.brokenPromises = []
        self.sentNudges = []
        self.strictnessRaw = strictness.rawValue
        self.factDigests = []
    }

    var messages: [ChatMessage] {
        get { (try? JSONDecoder().decode([ChatMessage].self, from: chatJSON)) ?? [] }
        set { chatJSON = (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8) }
    }

    var idString: String { uid }

    // MARK: - 承诺追踪

    /// 判定输入用的承诺状态行（待兑现 + 近期失信）
    func promiseLines(now: Date = Date()) -> [String] {
        var lines: [String] = []
        if let claim = promiseClaim, let due = promiseDue {
            if now < due {
                lines.append("待兑现承诺：'\(claim)'，到期还有 \(max(1, Int(due.timeIntervalSince(now) / 60))) 分钟")
            } else {
                lines.append("承诺'\(claim)'已到期未兑现（刚刚超时）")
            }
        }
        for broken in brokenPromises.suffix(3).reversed() {
            lines.append("历史失信：曾承诺'\(broken)'，未兑现")
        }
        return lines
    }

    /// 把到期未兑现的承诺转为失信记录（判定/完成前调用）
    @discardableResult
    func settlePromise(now: Date = Date()) -> Bool {
        guard let claim = promiseClaim, let due = promiseDue, now > due else { return false }
        brokenPromises.append(claim)
        if brokenPromises.count > 5 { brokenPromises.removeFirst(brokenPromises.count - 5) }
        promiseClaim = nil
        promiseDue = nil
        return true
    }

    func recordPromise(claim: String, minutes: Int) {
        promiseClaim = claim
        promiseDue = Date().addingTimeInterval(TimeInterval(max(5, minutes)) * 60)
    }

    // MARK: - 模式隔离：通知文案按角色存取

    /// 记录一条已发通知（带角色标签：注入判定时只给同角色看，防串味）
    func appendSentNudge(_ text: String, roleID: String) {
        sentNudges.append(SentNudge.encode(roleID: roleID, text: text))
        if sentNudges.count > 10 { sentNudges.removeFirst(sentNudges.count - 10) }
    }

    /// 取当前角色已发的通知文案（其他角色的过滤掉）
    func sentNudges(for roleID: String) -> [String] {
        SentNudge.decode(sentNudges, roleID: roleID)
    }

    /// 记录一条 AI 提炼的任务事实（跨角色共享，封顶 8 条）
    func appendFactDigest(_ digest: String) {
        let d = digest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !d.isEmpty, d.lowercased() != "null" else { return }
        factDigests.append(d)
        if factDigests.count > 8 { factDigests.removeFirst(factDigests.count - 8) }
    }
}

enum TaskStatus: String, Codable {
    case pending, grace, done
}
