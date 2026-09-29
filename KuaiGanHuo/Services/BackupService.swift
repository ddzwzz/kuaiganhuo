import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import KuaiGanHuCore

// MARK: - 快照数据结构

/// 备份文件容器：把整个 App 的数据打包成一个 JSON 文件
struct BackupFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct TaskSnapshot: Codable {
    var uid: String
    var title: String
    var deadline: Date?
    var createdAt: Date
    var statusRaw: String
    var nudgeAtDeadline: [String]
    var nudgeGraceOver: String
    var chatJSON: Data
    var excuseHistory: [String]
    var promiseClaim: String?
    var promiseDue: Date?
    var brokenPromises: [String]
    var sentNudges: [String]
    var strictnessRaw: String
    var factDigests: [String]

    init(_ item: TaskItem) {
        self.uid = item.uid
        self.title = item.title
        self.deadline = item.deadline
        self.createdAt = item.createdAt
        self.statusRaw = item.statusRaw
        self.nudgeAtDeadline = item.nudgeAtDeadline
        self.nudgeGraceOver = item.nudgeGraceOver
        self.chatJSON = item.chatJSON
        self.excuseHistory = item.excuseHistory
        self.promiseClaim = item.promiseClaim
        self.promiseDue = item.promiseDue
        self.brokenPromises = item.brokenPromises
        self.sentNudges = item.sentNudges
        self.strictnessRaw = item.strictnessRaw
        self.factDigests = item.factDigests
    }
}

struct HabitSnapshot: Codable {
    var uid: String
    var name: String
    var anchor: String
    var remindHour: Int
    var remindMinute: Int
    var startDate: Date
    var completions: [Date]
    var missedStreak: Int
    var lastMissedCheck: Date
    var brokenDate: Date?
    var active: Bool

    init(_ item: HabitItem) {
        self.uid = item.uid
        self.name = item.name
        self.anchor = item.anchor
        self.remindHour = item.remindHour
        self.remindMinute = item.remindMinute
        self.startDate = item.startDate
        self.completions = item.completions
        self.missedStreak = item.missedStreak
        self.lastMissedCheck = item.lastMissedCheck
        self.brokenDate = item.brokenDate
        self.active = item.active
    }
}

struct MajorEventSnapshot: Codable {
    var label: String
    var date: Date
}

/// 偏好设置快照。注意：**不含 API Key**——Key 存在钥匙串里，不跟着备份走（换设备后重新填一次，
/// 避免导出的文件被转发时把付费凭据带走）
struct SettingsSnapshot: Codable {
    var roleID: String
    var mood: String
    var userGenderRaw: String
    var roleGenders: [String: String]
    var roleAvatars: [String: String]
    var userAvatarID: String
    var userFacts: [String]
    var toneNotesByRole: [String: [String]]
    var delayCauses: [String: Int]
    var excuseStats: [String: Int]
    var periodStarts: [Date]
    var majorEvents: [MajorEventSnapshot]
    var baseURL: String
    var model: String
    var useLocalModel: Bool
    var localBaseURL: String
    var localModel: String
}

struct BackupSnapshot: Codable {
    var version: Int
    var exportedAt: Date
    var tasks: [TaskSnapshot]
    var habits: [HabitSnapshot]
    var settings: SettingsSnapshot
}

/// 恢复结果：给 UI 报个数
struct RestoreSummary {
    var newTasks = 0
    var updatedTasks = 0
    var newHabits = 0
    var updatedHabits = 0
}

// MARK: - 备份 / 恢复

enum BackupService {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// 导出：把 SwiftData 里的任务/习惯 + AppState 的偏好打包成 JSON
    static func makeSnapshot(context: ModelContext, appState: AppState) throws -> BackupSnapshot {
        let tasks = try context.fetch(FetchDescriptor<TaskItem>()).map(TaskSnapshot.init)
        let habits = try context.fetch(FetchDescriptor<HabitItem>()).map(HabitSnapshot.init)
        return BackupSnapshot(
            version: 1,
            exportedAt: Date(),
            tasks: tasks,
            habits: habits,
            settings: SettingsSnapshot(
                roleID: appState.roleID,
                mood: appState.mood.rawValue,
                userGenderRaw: appState.userGender.rawValue,
                roleGenders: appState.roleGenders,
                roleAvatars: appState.roleAvatars,
                userAvatarID: appState.userAvatarID,
                userFacts: appState.userFacts,
                toneNotesByRole: appState.toneNotesByRole,
                delayCauses: appState.delayCauses,
                excuseStats: appState.excuseStats,
                periodStarts: appState.periodStarts,
                majorEvents: appState.majorEvents.map { MajorEventSnapshot(label: $0.label, date: $0.date) },
                baseURL: appState.baseURL,
                model: appState.model,
                useLocalModel: appState.useLocalModel,
                localBaseURL: appState.localBaseURL,
                localModel: appState.localModel
            )
        )
    }

    static func exportData(context: ModelContext, appState: AppState) throws -> Data {
        try encoder.encode(makeSnapshot(context: context, appState: appState))
    }

    /// 恢复：按 uid 合并（同 uid 覆盖，新的插入），不删任何现有数据，避免误操作丢东西
    @discardableResult
    static func apply(_ snapshot: BackupSnapshot, context: ModelContext, appState: AppState) throws -> RestoreSummary {
        var summary = RestoreSummary()

        var existingTasks: [String: TaskItem] = [:]
        for t in try context.fetch(FetchDescriptor<TaskItem>()) { existingTasks[t.uid] = t }

        for dto in snapshot.tasks {
            if let item = existingTasks[dto.uid] {
                item.title = dto.title
                item.deadline = dto.deadline
                item.statusRaw = dto.statusRaw
                item.nudgeAtDeadline = dto.nudgeAtDeadline
                item.nudgeGraceOver = dto.nudgeGraceOver
                item.chatJSON = dto.chatJSON
                item.excuseHistory = dto.excuseHistory
                item.promiseClaim = dto.promiseClaim
                item.promiseDue = dto.promiseDue
                item.brokenPromises = dto.brokenPromises
                item.sentNudges = dto.sentNudges
                item.strictnessRaw = dto.strictnessRaw
                item.factDigests = dto.factDigests
                summary.updatedTasks += 1
            } else {
                let created = TaskItem(
                    title: dto.title,
                    deadline: dto.deadline,
                    nudges: NudgeSet(atDeadline: dto.nudgeAtDeadline, graceOver: dto.nudgeGraceOver),
                    strictness: TaskStrictness(rawValue: dto.strictnessRaw) ?? .normal
                )
                created.uid = dto.uid
                created.createdAt = dto.createdAt
                created.statusRaw = dto.statusRaw
                created.chatJSON = dto.chatJSON
                created.excuseHistory = dto.excuseHistory
                created.promiseClaim = dto.promiseClaim
                created.promiseDue = dto.promiseDue
                created.brokenPromises = dto.brokenPromises
                created.sentNudges = dto.sentNudges
                created.strictnessRaw = dto.strictnessRaw
                created.factDigests = dto.factDigests
                context.insert(created)
                summary.newTasks += 1
            }
        }

        var existingHabits: [String: HabitItem] = [:]
        for h in try context.fetch(FetchDescriptor<HabitItem>()) { existingHabits[h.uid] = h }

        for dto in snapshot.habits {
            if let item = existingHabits[dto.uid] {
                item.name = dto.name
                item.anchor = dto.anchor
                item.remindHour = dto.remindHour
                item.remindMinute = dto.remindMinute
                item.startDate = dto.startDate
                item.completions = dto.completions
                item.missedStreak = dto.missedStreak
                item.lastMissedCheck = dto.lastMissedCheck
                item.brokenDate = dto.brokenDate
                item.active = dto.active
                summary.updatedHabits += 1
            } else {
                let created = HabitItem(
                    name: dto.name,
                    anchor: dto.anchor,
                    remindHour: dto.remindHour,
                    remindMinute: dto.remindMinute
                )
                created.uid = dto.uid
                created.startDate = dto.startDate
                created.completions = dto.completions
                created.missedStreak = dto.missedStreak
                created.lastMissedCheck = dto.lastMissedCheck
                created.brokenDate = dto.brokenDate
                created.active = dto.active
                context.insert(created)
                summary.newHabits += 1
            }
        }

        let s = snapshot.settings
        if PersonaRegistry.shared.exists(s.roleID) { appState.roleID = s.roleID }
        appState.mood = MoodKind(rawValue: s.mood) ?? .impatient
        appState.userGender = UserGender(rawValue: s.userGenderRaw) ?? .undisclosed
        appState.roleGenders = s.roleGenders
        appState.roleAvatars = s.roleAvatars
        appState.userAvatarID = s.userAvatarID
        appState.userFacts = s.userFacts
        appState.toneNotesByRole = s.toneNotesByRole
        appState.delayCauses = s.delayCauses
        appState.excuseStats = s.excuseStats
        appState.periodStarts = s.periodStarts
        appState.majorEvents = s.majorEvents.map { AppState.MajorEvent(label: $0.label, date: $0.date) }
        appState.baseURL = s.baseURL
        appState.model = s.model
        appState.useLocalModel = s.useLocalModel
        appState.localBaseURL = s.localBaseURL
        appState.localModel = s.localModel

        try context.save()
        return summary
    }

    static func decode(_ data: Data) throws -> BackupSnapshot {
        try decoder.decode(BackupSnapshot.self, from: data)
    }
}
