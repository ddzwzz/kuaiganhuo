import Foundation
import SwiftData
import KuaiGanHuCore

/// 习惯养成数据模型 + 行为科学阶段引擎
///
/// 体系依据（浓缩进 prompt 与阶段规则）：
/// - Lally et al. (2009)：习惯自动化平均 66 天（个体 18-254 天）——阶段划分的基准
/// - 漏 1 天几乎不影响习惯形成——真正的杀手是"破罐破摔"（破堤效应），所以漏卡不清零、恢复优先
/// - 两分钟法则 / 微缩版：中断的重启成本远高于缩小，保住"今天做了一点"就是赢
/// - 损失厌恶：挣扎期点连续天数最有效
/// - 身份认同（巩固期）："你已经是个会X的人"比"你要坚持"更有效
@Model
final class HabitItem {
    var uid: String
    var name: String
    /// 锚点场景描述（如"睡前""早饭后"），提醒与习惯绑定
    var anchor: String
    var remindHour: Int
    var remindMinute: Int
    /// 开始日期（只看日历日）
    var startDate: Date
    /// 打卡记录（每次打卡一个时间戳）
    var completions: [Date]
    /// 连续漏卡天数（打卡后清零；≥3 时 streak 清零）
    var missedStreak: Int
    /// 最近一次漏卡检查到哪天了（防重复计数）
    var lastMissedCheck: Date
    /// 最近一次连续天数清零的日期
    var brokenDate: Date?
    var active: Bool

    init(name: String, anchor: String, remindHour: Int, remindMinute: Int) {
        self.uid = UUID().uuidString
        self.name = name
        self.anchor = anchor
        self.remindHour = remindHour
        self.remindMinute = remindMinute
        self.startDate = Calendar.current.startOfDay(for: Date())
        self.completions = []
        self.missedStreak = 0
        self.lastMissedCheck = Calendar.current.startOfDay(for: Date())
        self.brokenDate = nil
        self.active = true
    }

    var idString: String { uid }

    // MARK: - 日期工具

    private func isSameDay(_ a: Date, _ b: Date) -> Bool {
        Calendar.current.isDate(a, inSameDayAs: b)
    }

    private func completionDays() -> Set<Date> {
        Set(completions.map { Calendar.current.startOfDay(for: $0) })
    }

    private func dateByAddingDays(_ days: Int, to date: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: date) ?? date
    }

    // MARK: - 阶段引擎

    enum Phase: String {
        case launching      // 第 1-7 天：启动期
        case struggle       // 第 8-30 天：挣扎期（最容易放弃）
        case consolidating  // 第 31-66 天：巩固期
        case established    // 66 天+：成熟期

        var displayName: String {
            switch self {
            case .launching: return "启动期"
            case .struggle: return "挣扎期"
            case .consolidating: return "巩固期"
            case .established: return "成熟期"
            }
        }
    }

    /// 今天是习惯的第几天（从 1 开始）
    var dayNumber: Int {
        let days = Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: startDate),
            to: Calendar.current.startOfDay(for: Date())
        ).day ?? 0
        return days + 1
    }

    var phase: Phase {
        switch dayNumber {
        case ...7: return .launching
        case 8...30: return .struggle
        case 31...66: return .consolidating
        default: return .established
        }
    }

    // MARK: - 打卡与漏卡

    var checkedToday: Bool {
        completions.contains { isSameDay($0, Date()) }
    }

    /// 连续打卡天数（以今天或昨天为端点往回数）
    var streak: Int {
        let days = completionDays()
        let today = Calendar.current.startOfDay(for: Date())
        var cursor = days.contains(today) ? today : dateByAddingDays(-1, to: today)
        // 昨天也没打卡 → 已断（漏卡结算后的状态），从 0 起
        if !days.contains(cursor) { return 0 }
        var count = 0
        while days.contains(cursor) {
            count += 1
            cursor = dateByAddingDays(-1, to: cursor)
        }
        return count
    }

    /// 漏卡结算：检查从上次检查到昨天之间漏了几天（App 打开时调用），处理漏卡计数与清零
    func settleMissedDays() {
        let today = Calendar.current.startOfDay(for: Date())
        let yesterday = dateByAddingDays(-1, to: today)
        var checkDay = dateByAddingDays(1, to: lastMissedCheck)
        guard checkDay <= yesterday else { return }
        let days = completionDays()
        var broke = false
        while checkDay <= yesterday {
            if !days.contains(checkDay) {
                missedStreak += 1
                if missedStreak >= 3 { broke = true }
            }
            checkDay = dateByAddingDays(1, to: checkDay)
        }
        if broke { brokenDate = Date() }
        lastMissedCheck = yesterday
    }

    /// 打卡（当天多次调用只记一次）
    @discardableResult
    func checkIn() -> Bool {
        guard !checkedToday else { return false }
        completions.append(Date())
        missedStreak = 0
        return true
    }

    // MARK: - AI 注入

    /// 给 AI 的习惯状态行（判定 / 提醒 / 庆祝共用）
    var habitStateLine: String {
        var line = "习惯「\(name)」（锚点：\(anchor)），第\(dayNumber)天，阶段=\(phase.displayName)"
        let s = streak
        if s > 0 {
            line += "，已连续打卡\(s)天"
        } else if brokenDate != nil {
            line += "，连续记录此前中断、正在重新计数"
        }
        if missedStreak == 1 {
            line += "，昨天漏了1次（漏一天不算失败，恢复打卡即可）"
        } else if missedStreak >= 2 {
            line += "，已连续漏\(missedStreak)天"
        }
        return line
    }

    /// 今天的锚点提醒时刻
    var todayAnchorTime: Date {
        Calendar.current.date(bySettingHour: remindHour, minute: remindMinute, second: 0, of: Date()) ?? Date()
    }
}
