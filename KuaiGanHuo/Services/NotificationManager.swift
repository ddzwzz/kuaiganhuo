import Foundation
import UserNotifications
import KuaiGanHuCore

/// 本地通知调度：到点催促 + 宽限查岗（内容为预生成文案，无需联网）
/// 催促类通知使用 timeSensitive（时间敏感）等级：用户开启对应权限后可穿透勿扰/专注模式
final class NotificationManager {

    static let shared = NotificationManager()
    private let center = UNUserNotificationCenter.current()

    func requestAuthorization() {
        Task {
            // timeSensitive：iOS 15+，允许通知在勿扰/专注模式下仍然弹出（用户可在系统设置里关掉）
            try? await center.requestAuthorization(options: [.alert, .sound, .badge, .timeSensitive])
        }
    }

    /// 到截止时间弹催促通知（每次用下一条预生成文案）
    func scheduleDeadlineNudge(taskID: String, taskTitle: String, deadline: Date, texts: [String], escalate: Bool) {
        guard let deadline = deadline as Date?, deadline > Date() else { return }
        guard let fireDate = Calendar.current.date(byAdding: .minute, value: -1, to: deadline) else { return }

        let index = escalate ? (texts.count - 1) : 0
        let body = texts[min(index, texts.count - 1)]
        schedule(
            id: "deadline-\(taskID)",
            title: taskTitle,
            body: body,
            at: fireDate,
            thread: "快干活",
            timeSensitive: true
        )
    }

    /// 宽限结束 / 施压后的查岗通知
    /// 深夜（00:00-06:59）触发的查岗间隔强制拉到至少 30 分钟——收敛版不靠 AI 自觉，代码兜底
    func scheduleCheckIn(taskID: String, taskTitle: String, afterMinutes minutes: Int, text: String) {
        var minutes = max(1, minutes)
        if let fireDate = Calendar.current.date(byAdding: .minute, value: minutes, to: Date()),
           PromptEngine.isDeepNight(fireDate) {
            minutes = max(minutes, 30)
        }
        guard let fireDate = Calendar.current.date(byAdding: .minute, value: minutes, to: Date()) else { return }
        cancel(id: "grace-\(taskID)")
        schedule(
            id: "grace-\(taskID)",
            title: taskTitle,
            body: text,
            at: fireDate,
            thread: "快干活",
            timeSensitive: true
        )
    }

    func cancelTaskNotifications(taskID: String) {
        center.removePendingNotificationRequests(withIdentifiers: ["deadline-\(taskID)", "grace-\(taskID)"])
    }

    // MARK: - 习惯提醒（锚点时刻 + 晚间未打卡追问）

    /// 排定今天的习惯提醒：锚点时刻一条；启动期/挣扎期在锚点 2 小时后加一条未打卡追问
    func scheduleHabitReminders(habitID: String, habitName: String, anchorTime: Date, anchorText: String, eveningText: String?, intensive: Bool) {
        cancelHabitNotifications(habitID: habitID)
        if anchorTime > Date() {
            schedule(
                id: "habit-anchor-\(habitID)",
                title: habitName,
                body: anchorText,
                at: anchorTime,
                thread: "快干活",
                timeSensitive: true
            )
        }
        // 晚间追问：只在高力度阶段（启动期/挣扎期）排；深夜锚点的追问顺延到次日
        if intensive, let evening = eveningText {
            let fire = Calendar.current.date(byAdding: .minute, value: 120, to: max(anchorTime, Date())) ?? Date()
            if fire > Date() {
                schedule(
                    id: "habit-evening-\(habitID)",
                    title: habitName,
                    body: evening,
                    at: fire,
                    thread: "快干活",
                    timeSensitive: false
                )
            }
        }
    }

    /// 打卡后取消当晚追问
    func cancelHabitEvening(habitID: String) {
        center.removePendingNotificationRequests(withIdentifiers: ["habit-evening-\(habitID)"])
    }

    func cancelHabitNotifications(habitID: String) {
        center.removePendingNotificationRequests(withIdentifiers: ["habit-anchor-\(habitID)", "habit-evening-\(habitID)"])
    }

    private func cancel(id: String) {
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    private func schedule(id: String, title: String, body: String, at date: Date, thread: String, timeSensitive: Bool = false) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // 声音开关（默认开）
        if UserDefaults.standard.object(forKey: "kgh.soundOn") as? Bool ?? true {
            content.sound = .default
        }
        content.threadIdentifier = thread
        if timeSensitive {
            content.interruptionLevel = .timeSensitive
        }

        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}
