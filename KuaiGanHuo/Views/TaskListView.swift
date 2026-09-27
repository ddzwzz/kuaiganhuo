import SwiftUI
import SwiftData

/// 首页：任务列表
struct TaskListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \TaskItem.deadline, order: .forward) private var tasks: [TaskItem]
    @Environment(AppState.self) private var appState
    @State private var showAdd = false

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
                        ForEach(tasks) { task in
                            NavigationLink(value: task) {
                                TaskRow(task: task)
                            }
                        }
                        .onDelete(perform: delete)
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

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let task = tasks[index]
            NotificationManager.shared.cancelTaskNotifications(taskID: task.idString)
            context.delete(task)
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
                if let d = task.deadline {
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
        .font(.caption)
    }
}
