import Foundation

// MARK: - 任务类型（决定监工给的"具体下一步"是什么）

/// 任务类型。auto = 交给关键词自动识别。
public enum TaskKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto, write, chore, study, social, health, other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto:   return "自动识别"
        case .write:  return "写作/脑力"
        case .chore:  return "家务/体力"
        case .study:  return "学习/阅读"
        case .social: return "社交/沟通"
        case .health: return "健康/作息"
        case .other:  return "其他"
        }
    }

    /// 关键词（用于自动识别）
    public var keywords: [String] {
        switch self {
        case .write:  return ["写","周报","论文","方案","报告","总结","稿","文档","邮件","代码","编程","改","ppt","设计","策划","文案","简历"]
        case .chore:  return ["洗碗","洗","扫","拖","收拾","整理","倒垃圾","垃圾","洗衣","晾","健身","跑步","运动","取快递","快递","买","做饭","打扫","擦","搬","换","丢"]
        case .study:  return ["看","读","学","背","复习","刷题","预习","课","单词","题","书","笔记","听力","练"]
        case .social: return ["打给","打电话","电话","回","消息","微信","约","联系","问候","道歉","沟通","问","回复","找"]
        case .health: return ["睡","起床","喝水","吃药","休息","早睡","熄灯","拉伸","冥想","吃饭","走"]
        default:      return []
        }
    }

    /// 这类任务此刻能立刻开始的具体动作（教练模式/兜底用，按顺序轮换）
    public var steps: [String] {
        switch self {
        case .write:
            return ["打开文档，先把标题和 3 个小标题列出来",
                    "写第一段，写得再烂也别删，先有字",
                    "把相关材料全拖进文档，先堆着别管顺序",
                    "设 25 分钟倒计时，这期间不许切屏",
                    "先憋 100 字，写完这 100 字再说"]
        case .chore:
            return ["放下手机，先站起来走到现场",
                    "只做 2 分钟，做满 2 分钟就算赢",
                    "先处理最碍眼的那一处",
                    "放首歌，边听边动手",
                    "数三下就起身：一、二、三，走"]
        case .study:
            return ["翻开书/打开 App，先做第 1 题",
                    "就读一页，读完这页随你干嘛",
                    "手机扣过去，设 20 分钟",
                    "先扫目录，挑最短的一节下手",
                    "背 5 个，就 5 个，背完算完成"]
        case .social:
            return ["打开对话框，先打一句草稿",
                    "想好开口第一句，就一句",
                    "把要说的三点写下来，照着念",
                    "先发「在吗，有个事」，发出去就完成一半",
                    "设 5 分钟后的闹钟，到点必须发"]
        case .health:
            return ["先喝一口水，就一口",
                    "手机放到客厅，现在躺下",
                    "把充电器挪到床头，别再刷了",
                    "站起来伸个懒腰，去倒杯水",
                    "设 30 分钟后的就寝提醒"]
        default:
            return ["先迈第一步：做两分钟再说",
                    "把这件事拆到最小的第一下，现在就做那一下",
                    "设 10 分钟倒计时，开始就够",
                    "找件做过的类似事，照着它的开头做"]
        }
    }

    /// 这类任务"为什么会卡住"（注入提示词让 AI 对症下药，不会原话讲给用户）
    public var stuckReason: String {
        switch self {
        case .write:  return "多半是想一次写对，先允许自己写烂"
        case .chore:  return "难点只在起身那一下，把启动成本压到最小"
        case .study:  return "总量吓人，缩到最小单位就不怕了"
        case .social: return "怕说不好，先把要说的话落到文字上"
        case .health: return "靠仪式感启动，不靠意志力"
        default:      return "怕的是想整件事，只做下一件事就不怕"
        }
    }

    /// 按顺序取一条具体动作（cursor 由调用方持久化，保证不连着重复同一句）
    public func step(cursor: Int) -> String {
        let s = steps
        guard !s.isEmpty else { return "先做最小的第一下" }
        let i = ((cursor % s.count) + s.count) % s.count
        return s[i]
    }

    /// 关键词自动识别；识别不出返回 other（永不返回 auto）
    public static func detect(title: String) -> TaskKind {
        let s = title.lowercased()
        for k in TaskKind.allCases where k != .auto && k != .other {
            if k.keywords.contains(where: { s.contains($0) }) { return k }
        }
        return .other
    }
}

// MARK: - 周期重复规则

public enum RepeatRule: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, daily, weekdays, weekly, interval

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none:     return "不重复"
        case .daily:    return "每天"
        case .weekdays: return "工作日"
        case .weekly:   return "每周指定几天"
        case .interval: return "每 N 天"
        }
    }

    public var shortLabel: String {
        switch self {
        case .none:     return ""
        case .daily:    return "每天"
        case .weekdays: return "工作日"
        case .weekly:   return "每周"
        case .interval: return "每N天"
        }
    }
}

// MARK: - 周期计算（纯函数，便于单测）

public struct Recurrence: Sendable {

    /// "yyyy-MM-dd" 日键（按天记完成情况）
    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }

    /// 日键 → Date（当天零点）；解析失败返回 nil
    public static func date(fromDayKey key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var comps = DateComponents()
        comps.year = parts[0]; comps.month = parts[1]; comps.day = parts[2]
        return calendar.date(from: comps)
    }

    /// 今天是否该做（status == done 由调用方过滤）
    public static func isDueToday(rule: RepeatRule,
                                  weekdays: [Int] = [],
                                  intervalDays: Int = 3,
                                  completions: [String] = [],
                                  now: Date = Date(),
                                  calendar: Calendar = .current) -> Bool {
        switch rule {
        case .none:
            return false
        case .daily:
            return true
        case .weekdays:
            let w = calendar.component(.weekday, from: now)   // 1 = 周日 … 7 = 周六
            return (2...6).contains(w)
        case .weekly:
            let w = calendar.component(.weekday, from: now)
            return weekdays.contains(w)
        case .interval:
            guard let last = completions.sorted().last,
                  let lastDate = date(fromDayKey: last, calendar: calendar) else { return true }
            let gap = calendar.dateComponents([.day], from: lastDate, to: now).day ?? 0
            return gap >= max(1, intervalDays)
        }
    }

    /// 今天是否已经打卡
    public static func doneToday(completions: [String], now: Date = Date(), calendar: Calendar = .current) -> Bool {
        completions.contains(dayKey(now, calendar: calendar))
    }

    /// 规则简述，如 "每周一三"、"每 3 天"
    public static func label(rule: RepeatRule, weekdays: [Int] = [], intervalDays: Int = 3) -> String {
        switch rule {
        case .none:     return ""
        case .daily:    return "每天"
        case .weekdays: return "工作日"
        case .weekly:
            let names = ["日", "一", "二", "三", "四", "五", "六"]
            let s = weekdays.sorted().compactMap { w -> String? in
                let i = w - 1
                return (0..<names.count).contains(i) ? names[i] : nil
            }
            return s.isEmpty ? "每周" : "每周" + s.joined()
        case .interval: return "每 \(max(1, intervalDays)) 天"
        }
    }

    /// 下一次该做的自然语言描述（最多往后找 14 天）
    public static func nextDueText(rule: RepeatRule,
                                   weekdays: [Int] = [],
                                   intervalDays: Int = 3,
                                   timeOfDay: String = "",
                                   from now: Date = Date(),
                                   calendar: Calendar = .current) -> String {
        guard rule != .none else { return "（一次性）" }
        let suffix = timeOfDay.isEmpty ? "" : " " + timeOfDay
        for i in 1...14 {
            guard let d = calendar.date(byAdding: .day, value: i, to: now) else { break }
            let w = calendar.component(.weekday, from: d)
            let ok: Bool
            switch rule {
            case .none:     ok = false
            case .daily:    ok = true
            case .weekdays: ok = (2...6).contains(w)
            case .weekly:   ok = weekdays.contains(w)
            case .interval: ok = i >= max(1, intervalDays)
            }
            if ok { return (i == 1 ? "明天" : "\(i) 天后") + suffix }
        }
        return "待定"
    }

    /// "HH:mm" → 今天的 Date；格式非法返回 nil
    public static func today(at hhmm: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = parts[0]
        comps.minute = parts[1]
        comps.second = 0
        return calendar.date(from: comps)
    }
}
