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

    var status: TaskStatus {
        get { TaskStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    var strictness: TaskStrictness {
        get { TaskStrictness(rawValue: strictnessRaw) ?? .normal }
        set { strictnessRaw = newValue.rawValue }
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
