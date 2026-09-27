import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// AI 客户端：OpenAI 兼容接口（DeepSeek / 豆包 / Kimi / GPT 均可），实现三大协议。
public struct AIClient: Sendable {

    public var config: AIConfig

    public init(config: AIConfig) {
        self.config = config
    }

    public enum AIError: LocalizedError {
        case noAPIKey
        case badResponse(String)
        case badJSON(String)
        /// HTTP 状态码错误：提示语按小白能看懂的方式翻译（401 说 Key 错，402 说没钱…）
        case httpStatus(Int)
        /// 连不上：网络问题或本地模型地址不通
        case transport(String)

        public var errorDescription: String? {
            switch self {
            case .noAPIKey: return "还没填 API Key，去设置页填一下"
            case .badResponse(let s): return "接口返回异常：\(s)"
            case .badJSON(let s): return "AI 输出解析失败：\(s)"
            case .httpStatus(let code):
                switch code {
                case 401, 403: return "API Key 不对或已失效，去设置页重新粘一次"
                case 402: return "账号余额不足，去 DeepSeek 后台充点值（10 块能用很久）"
                case 404: return "接口地址或模型名不对，检查设置里的 API 地址和模型名"
                case 429: return "请求太频繁被限流了，歇一分钟再试"
                case 500..<600: return "AI 服务端出错了，稍后再试"
                default: return "接口返回 HTTP \(code)，检查 API 地址和模型名"
                }
            case .transport(let s): return "连不上 AI（\(s)）：检查网络；用本地模型的话，看电脑开没开、地址填对没"
            }
        }
    }

    // MARK: - 底层调用

    public struct WireMessage: Codable {
        var role: String
        var content: String
    }

    public struct WireRequest: Codable {
        var model: String
        var messages: [WireMessage]
        var temperature: Double
        var maxTokens: Int

        enum CodingKeys: String, CodingKey {
            case model, messages, temperature
            case maxTokens = "max_tokens"
        }
    }

    public struct WireResponse: Codable {
        struct Choice: Codable {
            struct Msg: Codable { var content: String? }
            var message: Msg
        }
        var choices: [Choice]
    }

    public func chat(system: String, user: String) async throws -> String {
        guard !config.apiKey.isEmpty else { throw AIError.noAPIKey }
        let url = URL(string: config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions")!
        var req = URLRequest(url: url, timeoutInterval: 45)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer " + config.apiKey, forHTTPHeaderField: "Authorization")

        let body = WireRequest(
            model: config.model,
            messages: [.init(role: "system", content: system), .init(role: "user", content: user)],
            temperature: config.temperature,
            maxTokens: 800
        )
        req.httpBody = try JSONEncoder().encode(body)

        // 两次机会：网络抖动、空回复、5xx 都值得再试一次；4xx（Key 错、没钱、地址错）立刻失败不重试
        var lastError: AIError = .badResponse("未知错误")
        for attempt in 0..<2 {
            var data = Data()
            var resp: URLResponse = URLResponse()
            do {
                let pair = try await URLSession.shared.data(for: req)
                data = pair.0
                resp = pair.1
            } catch {
                lastError = .transport(error.localizedDescription)
                if attempt == 0 { continue }
                throw lastError
            }
            guard let http = resp as? HTTPURLResponse else {
                lastError = .transport("没有收到响应")
                if attempt == 0 { continue }
                throw lastError
            }
            guard (200..<300).contains(http.statusCode) else {
                lastError = .httpStatus(http.statusCode)
                if (400..<500).contains(http.statusCode) || attempt == 1 { throw lastError }
                continue
            }
            guard let decoded = try? JSONDecoder().decode(WireResponse.self, from: data),
                  let content = decoded.choices.first?.message.content, !content.isEmpty else {
                lastError = .badResponse("空回复或返回格式不对（模型名填错？）")
                if attempt == 0 { continue }
                throw lastError
            }
            return content
        }
        throw lastError
    }

    /// 从模型输出中抠出第一个括号配平的 JSON（容忍 ```json 包裹、前后废话、多对象输出）
    // 协议顶层键：模型偶发在前面吐一段废话 JSON（如 {"ok":true}）时，优先挑含这些键的对象
    private static let protocolKeys = ["tasks", "nudges", "verdict", "reply", "anchor", "evening",
                                       "profile_question", "safety_refuse", "promise_claim", "excuse_type",
                                       "major_event", "habit"]

    static func extractJSON(from text: String) throws -> Data {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.contains("```") {
            if let fenceStart = body.range(of: "```"),
               let afterOpen = body.range(of: "\n", range: fenceStart.upperBound..<body.endIndex) {
                let rest = body[afterOpen.upperBound...]
                if let fenceEnd = rest.range(of: "```") {
                    body = String(rest[..<fenceEnd.lowerBound])
                }
            }
        }
        // 收集所有配平的 {...} 对象（LLM 偶尔输出多个对象，或前面带废话 JSON）
        var candidates: [String] = []
        var i = body.startIndex
        while i < body.endIndex {
            if body[i] == "{" {
                var depth = 0
                var inString = false
                var previous: Character = " "
                var j = i
                while j < body.endIndex {
                    let ch = body[j]
                    if inString {
                        if ch == "\"" && previous != "\\" { inString = false }
                    } else {
                        if ch == "\"" { inString = true }
                        else if ch == "{" { depth += 1 }
                        else if ch == "}" {
                            depth -= 1
                            if depth == 0 {
                                candidates.append(String(body[i...j]))
                                break
                            }
                        }
                    }
                    previous = ch
                    j = body.index(after: j)
                }
                // 该 '{' 没有配平的右括号（畸形输出）→ 停止扫描，避免越界
                guard j < body.endIndex else { break }
                i = body.index(after: j)
            } else {
                i = body.index(after: i)
            }
        }
        guard !candidates.isEmpty else {
            throw AIError.badJSON("没找到 JSON：" + String(text.prefix(120)))
        }
        // 优先返回含协议键的对象（避免取到 AI 偶发的前导废话 JSON）
        for cand in candidates where protocolKeys.contains(where: { cand.contains("\"\($0)\":") }) {
            return cand.data(using: .utf8)!
        }
        return candidates[0].data(using: .utf8)!
    }

    // MARK: - 协议 1：任务解析

    public func parseTasks(userInput: String, now: Date = Date()) async throws -> TaskParseResult {
        let df = ISO8601DateFormatter()
        let user = "当前时间：\(df.string(from: now))\n用户安排：\(userInput)"
        let raw = try await chat(system: PromptEngine.systemPrompt(roleID: RoleKind.boss.rawValue, mood: .gentle, protocol: .parse), user: user)
        let data = try Self.extractJSON(from: raw)

        struct WireParse: Codable {
            struct WireTask: Codable {
                var title: String
                var deadline: String?
                var estimateMinutes: Int?

                enum CodingKeys: String, CodingKey {
                    case title, deadline
                    case estimateMinutes = "estimate_minutes"
                }
            }
            var tasks: [WireTask]?
            var clarification: String?
        }

        let decoded = try JSONDecoder().decode(WireParse.self, from: data)
        var result = TaskParseResult(tasks: [], clarification: decoded.clarification)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let s = try d.singleValueContainer().decode(String.self)
            let iso = ISO8601DateFormatter()
            if let date = iso.date(from: s) { return date }
            if let date = Self.lenientDateFormatter().date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath, debugDescription: "无法解析时间 \(s)"))
        }
        for t in decoded.tasks ?? [] {
            let deadlineData = try JSONEncoder().encode(t.deadline)
            let date = try decoder.decode(Date?.self, from: deadlineData)
            result.tasks.append(ParsedTask(title: t.title, deadline: date, estimateMinutes: t.estimateMinutes))
        }
        return result
    }

    static func lenientDateFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.timeZone = .current
        return f
    }

    // MARK: - 协议 2：催促文案预生成

    public func generateNudges(roleID: String, mood: MoodKind, taskTitle: String, deadline: Date?, delayPattern: String? = nil, strictness: TaskStrictness? = nil, gender: GenderContext? = nil) async throws -> NudgeSet {
        let df = ISO8601DateFormatter()
        var user = "任务：\(taskTitle)"
        if let d = deadline {
            user += "\n截止：\(df.string(from: d))"
            if let night = PromptEngine.timeOfDayLine(d) {
                user += "\n[当前时段：\(night)，通知会在深夜弹出]"
            }
        }
        if let s = strictness {
            user += "\n[任务宽限度：\(s.displayName)——\(s.promptLine.contains("——") ? String(s.promptLine.split(separator: "——")[1]) : s.promptLine)]"
        }
        if let pattern = delayPattern, !pattern.isEmpty {
            user += "\n[拖延模式：\(pattern)]"
        }
        let raw = try await chat(system: PromptEngine.systemPrompt(roleID: roleID, mood: mood, protocol: .nudge, userGender: gender?.userGender, personaGender: gender?.personaGender), user: user)
        let data = try Self.extractJSON(from: raw)

        struct WireNudges: Codable {
            struct Nudge: Codable {
                var atDeadline: String?
                var graceOver: String?

                enum CodingKeys: String, CodingKey {
                    case atDeadline = "at_deadline"
                    case graceOver = "grace_over"
                }
            }
            var nudges: [Nudge]
        }

        let decoded = try JSONDecoder().decode(WireNudges.self, from: data)
        var atDeadline = decoded.nudges.compactMap(\.atDeadline).filter { !$0.isEmpty }
        var graceOver = decoded.nudges.compactMap(\.graceOver).first ?? ""
        // 模型偶尔把三条全写成 at_deadline（实测出现过）：把最后一条挪去当查岗文案，
        // 别浪费已经生成好的文案
        if graceOver.isEmpty, atDeadline.count >= 3 { graceOver = atDeadline.removeLast() }
        if graceOver.isEmpty { graceOver = "宽限结束了。该干活了。" }
        guard !atDeadline.isEmpty else {
            throw AIError.badJSON("没有生成到点催促文案")
        }
        return NudgeSet(atDeadline: atDeadline, graceOver: graceOver)
    }

    // MARK: - 协议 3：借口判定（监工对话）

    public func judgeExcuse(
        roleID: String,
        mood: MoodKind,
        taskTitle: String,
        deadline: Date,
        userMessage: String,
        history: [ChatMessage],
        excuseHistory: [String],
        userFacts: [String] = [],
        periodLine: String? = nil,
        delayPatternLine: String? = nil,
        majorEventLines: [String] = [],
        toneNotes: [String] = [],
        now: Date = Date(),
        promiseLines: [String] = [],
        excusePatternLine: String? = nil,
        sentNudges: [String] = [],
        strictness: TaskStrictness? = nil,
        habitStateLine: String? = nil,
        gender: GenderContext? = nil,
        moderationLine: String? = nil,
        factDigests: [String] = []
    ) async throws -> (JudgeResult, [WireMessage]) {
        let df = ISO8601DateFormatter()
        let sys = PromptEngine.systemPrompt(roleID: roleID, mood: mood, protocol: .judge, userGender: gender?.userGender, personaGender: gender?.personaGender)
        // 模式隔离：只注入同角色的对话历史（ContextIsolation.filteredHistory），
        // 父母/伴侣模式的对话原文与语气不得串进上司模式等
        let isolated = ContextIsolation.filteredHistory(history, roleID: roleID)
        let context = isolated.suffix(10).map { m in
            (m.sender == .user ? "用户" : "监工") + "：" + m.text
        }.joined(separator: "\n")
        let eventBlock = majorEventLines.isEmpty ? "" :
            "[重大事件：\n" + majorEventLines.map { "- \($0)" }.joined(separator: "\n") + "]\n"
        let toneBlock = toneNotes.isEmpty ? "" :
            "[语气反馈（此前记录，持续生效）：\n" + toneNotes.map { "- \($0)" }.joined(separator: "\n") + "]\n"
        let promiseBlock = promiseLines.isEmpty ? "" :
            "[承诺记录：\n" + promiseLines.map { "- \($0)" }.joined(separator: "\n") + "]\n"
        let excusePatternBlock = (excusePatternLine?.isEmpty == false) ? "[借口模式：\(excusePatternLine!)]\n" : ""
        let sentNudgeBlock = sentNudges.isEmpty ? "" :
            "[已发通知：\n" + sentNudges.suffix(5).map { "- \($0)" }.joined(separator: "\n") + "]\n"
        let strictnessBlock = strictness.map { "[任务宽限度：\($0.displayName)——\($0.promptLine)]\n" } ?? ""
        let habitBlock = (habitStateLine?.isEmpty == false) ? "[习惯状态：\(habitStateLine!)]\n" : ""
        let moderationBlock = (moderationLine?.isEmpty == false) ? "\(moderationLine!)\n" : ""
        let factDigestBlock = factDigests.isEmpty ? "" :
            "[任务事实摘要（跨角色共享的任务进展）：\n" + factDigests.suffix(8).map { "- \($0)" }.joined(separator: "\n") + "]\n"
        let nightLine = PromptEngine.timeOfDayLine(now).map { "[当前时段：\($0)]\n" } ?? ""
        let overdue = PromptEngine.overdueLine(deadline: deadline, now: now)
        let user = """
        \(userFacts.isEmpty ? "" : "[用户已知情况：\(userFacts.joined(separator: "；"))]\n")\
        \(periodLine.map { "[生理期情况：\($0)]\n" } ?? "")\
        \(delayPatternLine.map { "[拖延模式：\($0)]\n" } ?? "")\
        \(excusePatternBlock)\(eventBlock)\(toneBlock)\(promiseBlock)\(sentNudgeBlock)\(strictnessBlock)\(habitBlock)\(moderationBlock)\(factDigestBlock)\
        [历史借口记录：\(excuseHistory.isEmpty ? "无" : excuseHistory.joined(separator: "、"))]
        [任务：\(taskTitle) \(overdue)，截止 \(df.string(from: deadline))]
        当前时间：\(df.string(from: now))
        \(nightLine)\(context.isEmpty ? "" : "[此前对话]\n" + context + "\n")
        用户说：\(userMessage)
        """
        var raw = try await chat(system: sys, user: user)
        var data = try Self.extractJSON(from: raw)
        var result = try JSONDecoder().decode(JudgeResult.self, from: data)
        // LLM 在沉重场景下偶发省略 reply（实测丧亲场景出现过）：重试一次
        if result.reply.isEmpty {
            raw = try await chat(system: sys, user: user)
            data = try Self.extractJSON(from: raw)
            result = try JSONDecoder().decode(JudgeResult.self, from: data)
        }
        return (result, [])
    }

    // MARK: - 协议 4：完成庆祝（人设化，不带数据）

    public func generateCelebration(
        roleID: String,
        mood: MoodKind,
        taskTitle: String,
        onTime: Bool,
        keptPromise: Bool? = nil,
        history: [ChatMessage] = [],
        habitStateLine: String? = nil,
        gender: GenderContext? = nil
    ) async throws -> String {
        let sys = PromptEngine.systemPrompt(roleID: roleID, mood: mood, protocol: .celebrate, userGender: gender?.userGender, personaGender: gender?.personaGender)
        let isolated = ContextIsolation.filteredHistory(history, roleID: roleID)
        let context = isolated.suffix(6).map { m in
            (m.sender == .user ? "用户" : "监工") + "：" + m.text
        }.joined(separator: "\n")
        var promise = onTime ? "按时完成" : "逾期完成"
        if let kept = keptPromise {
            promise += kept ? "，且兑现了之前的时间承诺" : "，之前的时间承诺没有兑现"
        }
        let habitBlock = (habitStateLine?.isEmpty == false) ? "[习惯状态：\(habitStateLine!)]\n" : ""
        let user = """
        \(habitBlock)[任务：\(taskTitle)，\(promise)]
        \(context.isEmpty ? "" : "[此前对话]\n" + context + "\n")
        用户刚刚完成了任务。
        """
        let raw = try await chat(system: sys, user: user)
        let data = try Self.extractJSON(from: raw)
        struct WireCelebrate: Codable { var reply: String? }
        let decoded = try JSONDecoder().decode(WireCelebrate.self, from: data)
        guard let reply = decoded.reply, !reply.isEmpty else {
            throw AIError.badJSON("庆祝回复缺失")
        }
        return reply
    }

    // MARK: - 协议 5：习惯每日提醒（阶段化强度）

    public func generateHabitNudges(
        roleID: String,
        mood: MoodKind,
        habitName: String,
        anchor: String,
        habitStateLine: String,
        gender: GenderContext? = nil
    ) async throws -> HabitNudgeSet {
        let sys = PromptEngine.systemPrompt(roleID: roleID, mood: mood, protocol: .habitNudge, userGender: gender?.userGender, personaGender: gender?.personaGender)
        let user = """
        [习惯状态：\(habitStateLine)]
        [锚点场景：\(anchor)]
        习惯：\(habitName)
        """
        let raw = try await chat(system: sys, user: user)
        let data = try Self.extractJSON(from: raw)
        let decoded = try JSONDecoder().decode(HabitNudgeSet.self, from: data)
        guard !decoded.anchor.isEmpty, !decoded.evening.isEmpty else {
            throw AIError.badJSON("习惯文案缺失")
        }
        return decoded
    }

    // MARK: - 工具：连通性测试

    public func ping() async throws -> String {
        try await chat(
            system: "你是连通性测试助手。只回复：OK",
            user: "ping"
        )
    }
}
