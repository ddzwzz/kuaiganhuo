import SwiftUI
import SwiftData
import KuaiGanHuCore

/// 首页：任务列表
struct TaskListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \TaskItem.deadline, order: .forward) private var tasks: [TaskItem]
    @Environment(AppState.self) private var appState
    @State private var showAdd = false

    /// 周期任务里今天该做的（按固定时刻排序）
    private var todayTasks: [TaskItem] {
        tasks.filter { $0.isDueToday() }
            .sorted { ($0.timeOfDay.isEmpty ? "99:99" : $0.timeOfDay) < ($1.timeOfDay.isEmpty ? "99:99" : $1.timeOfDay) }
    }

    /// 其余任务（一次性 + 今天不用做的周期任务）
    private var restTasks: [TaskItem] { tasks.filter { !$0.isDueToday() } }

    var body: some View {
        NavigationStack {
            Group {
                if tasks.isEmpty {
                    ContentUnavailableView(
                        "还没有任务",
                        systemImage: "figure.walk.motion",
                        description: Text("点右下角 + 把今天的安排讲给监工听")
                    )
                } else {
                    List {
                        if !todayTasks.isEmpty {
                            Section("今天该做") {
                                ForEach(todayTasks) { task in
                                    HStack(spacing: 8) {
                                        Button {
                                            withAnimation { _ = task.markDoneToday() }
                                        } label: {
                                            Image(systemName: task.doneToday() ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(task.doneToday() ? Color.green : Color.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        NavigationLink(value: task) { TaskRow(task: task) }
                                    }
                                }
                            }
                        }
                        ForEach(restTasks) { task in
                            NavigationLink(value: task) {
                                TaskRow(task: task)
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                let task = restTasks[index]
                                NotificationManager.shared.cancelTaskNotifications(taskID: task.idString)
                                context.delete(task)
                            }
                        }
                    }
                }
            }
            .navigationTitle("快干活")
            .navigationDestination(for: TaskItem.self) { task in
                ChatView(task: task)
            }
            .toolbar {
                Button {
                    showAdd = true
                } label: {
                    Image(systemName: "plus")
                }
            }
            .sheet(isPresented: $showAdd) {
                AddTaskView()
            }
        }
    }

}

struct TaskRow: View {
    let task: TaskItem
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(task.title)
                    .font(.body.weight(.medium))
                Spacer()
                statusBadge
            }
            HStack(spacing: 8) {
                if task.isRecurring {
                    Text(task.repeatLabel + (task.timeOfDay.isEmpty ? "" : " \(task.timeOfDay)"))
                    Text("下次 \(task.nextDueText())")
                } else if let d = task.deadline {
                    Text(d.formatted(.dateTime.month().day().hour().minute()))
                }
                if task.strictness != .normal {
                    Text(task.strictness == .strict ? "很难宽限" : "容易宽限")
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.quaternary))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var statusBadge: some View {
        Group {
            if task.isRecurring {
                if task.doneToday() {
                    Label("今天已做", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if task.missedToday() {
                    Label("还没做", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                } else {
                    Label("待办", systemImage: "circle.dashed")
                        .foregroundStyle(.secondary)
                }
            } else {
            switch task.status {
            case .done:
                Label("完成", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .grace:
                Label("宽限中", systemImage: "clock.badge.exclamationmark")
                    .foregroundStyle(.orange)
            case .pending:
                if let d = task.deadline, d < Date() {
                    Label("逾期", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                } else {
                    Label("进行中", systemImage: "circle.dashed")
                        .foregroundStyle(.secondary)
                }
            }
            }
        }
        .font(.caption)
    }
}
