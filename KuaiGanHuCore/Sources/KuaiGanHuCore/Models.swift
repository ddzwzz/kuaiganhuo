import Foundation

// MARK: - 角色与情绪

public enum RoleKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case boss, parent, partner
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .boss: return "上司"
        case .parent: return "父母"
        case .partner: return "伴侣"
        }
    }
}

public enum MoodKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case impatient, gentle
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .impatient: return "急躁"
        case .gentle: return "温柔"
        }
    }
}

// MARK: - 性别

public enum UserGender: String, Codable, CaseIterable, Sendable, Identifiable {
    case male, female, undisclosed
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .male: return "男"
        case .female: return "女"
        case .undisclosed: return "不愿透露"
        }
    }
    /// 提示词里的完整表述
    public var promptWord: String {
        switch self {
        case .male: return "男性"
        case .female: return "女性"
        case .undisclosed: return "不愿透露性别"
        }
    }
    /// 相反性别（亲密向监工用）；未设置时保持未设置
    public var opposite: UserGender {
        switch self {
        case .male: return .female
        case .female: return .male
        case .undisclosed: return .undisclosed
        }
    }
}

/// 用户性别 + 监工人设性别的组合，随每次 AI 调用注入
public struct GenderContext: Sendable {
    public var userGender: UserGender?
    public var personaGender: UserGender?

    public init(userGender: UserGender? = nil, personaGender: UserGender? = nil) {
        self.userGender = userGender
        self.personaGender = personaGender
    }
}

// MARK: - 任务宽限度（用户自定义分级）

public enum TaskStrictness: String, Codable, CaseIterable, Sendable, Identifiable {
    /// 容易宽限：自我安排，晚点没啥后果
    case flexible
    /// 标准
    case normal
    /// 很难宽限：外部硬截止（报名、交作业、考试），错过有真实代价
    case strict

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .flexible: return "容易宽限"
        case .normal: return "一般"
        case .strict: return "很难宽限"
        }
    }

    /// 注入判定的宽限度说明
    public var promptLine: String {
        switch self {
        case .flexible: return "容易宽限（用户自定：自我安排类，晚点完成没有外部后果）——判定从宽，多点耐心，给台阶时可以大方些"
        case .normal: return "一般（用户自定：常规任务）——按常规划定规则"
        case .strict: return "很难宽限（用户自定：外部硬截止，错过有真实代价，如报名/交作业/考试）——判定从严：宽限极少且必须有事由，模糊借口直接 excuse 指数上调，哪怕放行也要逼今天至少启动一小步"
        }
    }
}

// MARK: - 数据模型

public struct ParsedTask: Codable, Sendable, Equatable {
    public var title: String
    public var deadline: Date?
    public var estimateMinutes: Int?
    /// AI 建议的宽限度（用户保存时可改）
    public var strictness: TaskStrictness?

    enum CodingKeys: String, CodingKey {
        case title
        case deadline
        case estimateMinutes = "estimate_minutes"
        case strictness
    }

    public init(title: String, deadline: Date? = nil, estimateMinutes: Int? = nil, strictness: TaskStrictness? = nil) {
        self.title = title
        self.deadline = deadline
        self.estimateMinutes = estimateMinutes
        self.strictness = strictness
    }
}

public struct TaskParseResult: Codable, Sendable {
    public var tasks: [ParsedTask]
    public var clarification: String?
}

public struct NudgeSet: Codable, Sendable {
    public var atDeadline: [String]
    public var graceOver: String

    enum CodingKeys: String, CodingKey {
        case atDeadline = "at_deadline"
        case graceOver = "grace_over"
    }

    /// 容错解码：模型偶尔把三条全写成 at_deadline（实测出现过），
    /// 此时把最后一条挪去当查岗文案，而不是整包丢弃浪费一次调用
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var list = ((try? c.decode([String].self, forKey: .atDeadline)) ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var grace = ((try? c.decode(String.self, forKey: .graceOver)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if grace.isEmpty, list.count >= 3 { grace = list.removeLast() }
        if grace.isEmpty { grace = list.last ?? "" }
        guard !list.isEmpty, !grace.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .atDeadline, in: c, debugDescription: "催促文案为空")
        }
        self.atDeadline = list
        self.graceOver = grace
    }

    public init(atDeadline: [String], graceOver: String) {
        self.atDeadline = atDeadline
        self.graceOver = graceOver
    }
}

/// 习惯每日提醒文案：锚点时刻一条 + 晚间未打卡追问一条
public struct HabitNudgeSet: Codable, Sendable {
    public var anchor: String
    public var evening: String

    enum CodingKeys: String, CodingKey {
        case anchor
        case evening
    }

    public init(anchor: String, evening: String) {
        self.anchor = anchor
        self.evening = evening
    }

    /// 容错解码：漏字段给空串，由调用方校验
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        anchor = (try? c.decode(String.self, forKey: .anchor)) ?? ""
        evening = (try? c.decode(String.self, forKey: .evening)) ?? ""
    }
}

public enum Verdict: String, Codable, Sendable {
    case reasonable, excuse
}

public struct JudgeResult: Codable, Sendable {
    public var verdict: Verdict
    public var bullshitIndex: Int
    public var reply: String
    public var graceMinutes: Int
    public var escalate: Bool
    public var nextCheckMinutes: Int
    /// 需要向用户问清的问题（如身体不适真伪不明时），无则 null
    public var profileQuestion: String?
    /// 值得记入用户档案的候选情况（如"经常肠胃不适"），无则 null
    public var factCandidate: String?
    /// 从用户话语中读出的情绪（如：被激励/烦躁/被冒犯/低落/平常）
    public var userMood: String?
    /// 一句话语气策略调整建议（如"用户嫌凶，接下来放轻"），会进入后续判定持续生效，无则 null
    public var toneNote: String?
    /// 检测到的重大生活事件名（如"亲人离世"），App 记录后自动进入体谅期，无则 null
    public var majorEvent: String?
    /// 用户本轮给出的时间承诺原话（如"再给我10分钟"），无承诺则 null
    public var promiseClaim: String?
    /// 时间承诺的到期分钟数（如 10），无承诺则 null
    public var promiseDueMinutes: Int?
    /// 本轮理由的简短分类（如"身体不适-头疼""外部事件""纯拖延-游戏"），合理理由也分类，无则 null
    public var excuseType: String?
    /// 从用户本轮话语提炼的任务相关客观事实（如"晚上8点有课"），切换监工角色时跨角色交接用，无则 null
    public var factDigest: String?
    /// 模型自身判定：这轮用户的诉求越界、它无法配合（本地词表漏网的变体由它兜底），
    /// true 时 reply 是角色口吻的软拒，协议仍完整——这样模型的拒答不会破坏 JSON
    public var safetyRefuse: Bool?

    enum CodingKeys: String, CodingKey {
        case verdict
        case bullshitIndex = "bullshit_index"
        case reply
        case graceMinutes = "grace_minutes"
        case escalate
        case nextCheckMinutes = "next_check_minutes"
        case profileQuestion = "profile_question"
        case factCandidate = "fact_candidate"
        case userMood = "user_mood"
        case toneNote = "tone_note"
        case majorEvent = "major_event"
        case promiseClaim = "promise_claim"
        case promiseDueMinutes = "promise_due_minutes"
        case excuseType = "excuse_type"
        case factDigest = "fact_digest"
        case safetyRefuse = "safety_refuse"
    }

    /// 容错解码：LLM 偶尔会漏字段（实测在"亲人离世"场景下省略过 reply），关键字段给默认值不崩
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        verdict = (try? c.decode(Verdict.self, forKey: .verdict)) ?? .excuse
        bullshitIndex = (try? c.decode(Int.self, forKey: .bullshitIndex)) ?? 50
        reply = (try? c.decode(String.self, forKey: .reply)) ?? ""
        graceMinutes = (try? c.decode(Int.self, forKey: .graceMinutes)) ?? 0
        escalate = (try? c.decode(Bool.self, forKey: .escalate)) ?? false
        nextCheckMinutes = (try? c.decode(Int.self, forKey: .nextCheckMinutes)) ?? 15
        profileQuestion = try? c.decode(String.self, forKey: .profileQuestion)
        factCandidate = try? c.decode(String.self, forKey: .factCandidate)
        userMood = try? c.decode(String.self, forKey: .userMood)
        toneNote = try? c.decode(String.self, forKey: .toneNote)
        majorEvent = try? c.decode(String.self, forKey: .majorEvent)
        promiseClaim = try? c.decode(String.self, forKey: .promiseClaim)
        promiseDueMinutes = try? c.decode(Int.self, forKey: .promiseDueMinutes)
        excuseType = try? c.decode(String.self, forKey: .excuseType)
        factDigest = try? c.decode(String.self, forKey: .factDigest)
        safetyRefuse = try? c.decode(Bool.self, forKey: .safetyRefuse)
    }

    public init(
        verdict: Verdict, bullshitIndex: Int, reply: String, graceMinutes: Int,
        escalate: Bool, nextCheckMinutes: Int, profileQuestion: String? = nil,
        factCandidate: String? = nil, userMood: String? = nil,
        toneNote: String? = nil, majorEvent: String? = nil,
        promiseClaim: String? = nil, promiseDueMinutes: Int? = nil,
        excuseType: String? = nil, factDigest: String? = nil, safetyRefuse: Bool? = nil
    ) {
        self.verdict = verdict
        self.bullshitIndex = bullshitIndex
        self.reply = reply
        self.graceMinutes = graceMinutes
        self.escalate = escalate
        self.nextCheckMinutes = nextCheckMinutes
        self.profileQuestion = profileQuestion
        self.factCandidate = factCandidate
        self.userMood = userMood
        self.toneNote = toneNote
        self.majorEvent = majorEvent
        self.promiseClaim = promiseClaim
        self.promiseDueMinutes = promiseDueMinutes
        self.excuseType = excuseType
        self.factDigest = factDigest
        self.safetyRefuse = safetyRefuse
    }
}

public struct ChatMessage: Codable, Sendable, Equatable {
    public enum Sender: String, Codable {
        case user, supervisor
    }
    public var sender: Sender
    public var text: String
    public var verdict: Verdict?
    public var bullshitIndex: Int?
    /// 这条对话发生时的监工角色 ID。模式隔离：注入 AI 上下文时只带同角色的对话，
    /// 防止父母/伴侣模式的敏感内容串进上司模式。nil = 旧版本消息（兼容放行，避免老用户历史丢失）
    public var roleKey: String?

    public init(sender: Sender, text: String, verdict: Verdict? = nil, bullshitIndex: Int? = nil, roleKey: String? = nil) {
        self.sender = sender
        self.text = text
        self.verdict = verdict
        self.bullshitIndex = bullshitIndex
        self.roleKey = roleKey
    }
}

// MARK: - AI 配置

public struct AIConfig: Sendable {
    public var baseURL: String
    public var apiKey: String
    public var model: String
    public var temperature: Double

    public init(baseURL: String = "https://api.deepseek.com",
                apiKey: String = "",
                model: String = "deepseek-chat",
                temperature: Double = 0.9) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.temperature = temperature
    }
}
