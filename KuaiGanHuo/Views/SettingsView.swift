import SwiftUI
import SwiftData
import UIKit
import KuaiGanHuCore

/// 设置页：API 配置 + 通知权限 + 档案（情况/生理期/拖延模式）
struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @AppStorage("kgh.soundOn") private var soundOn = true
    @State private var keyInput = ""
    @State private var factInput = ""
    @State private var eventInput = ""
    @State private var eventDate = Date()
    @State private var periodDate = Date()
    @State private var testing = false
    @State private var testResult: String?
    // 备份 / 恢复
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var backupFile: BackupFile?
    @State private var backupMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        AvatarPickerView(
                            title: "\(appState.persona.displayName)的头像",
                            selection: roleAvatarBinding()
                        )
                    } label: {
                        avatarRow(title: "\(appState.persona.displayName)的头像", kind: appState.avatar(for: appState.roleID))
                    }
                    NavigationLink {
                        AvatarPickerView(
                            title: "我的头像",
                            selection: Binding(
                                get: { appState.myAvatar },
                                set: { appState.myAvatar = $0 }
                            )
                        )
                    } label: {
                        avatarRow(title: "我的头像", kind: appState.myAvatar)
                    }
                } header: {
                    Text("头像")
                } footer: {
                    Text("内置头像是 App 自己画的几何图形，不涉及任何第三方素材，不会有版权问题；也可以从相册选自己的照片，图片只存在手机本地。")
                }

                Section {
                    LabeledContent("当前 Key", value: appState.apiKeySet ? "已保存" : "未设置")
                    SecureField("API Key（sk- 开头）", text: $keyInput)
                    Button("保存 Key") {
                        Keychain.set(keyInput.trimmingCharacters(in: .whitespaces), service: "kgh", account: "apiKey")
                        appState.apiKeySet = !keyInput.isEmpty
                        keyInput = ""
                        testResult = "已保存到钥匙串"
                    }
                    .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("AI 接入（自带 Key）")
                } footer: {
                    Text("推荐 DeepSeek：platform.deepseek.com 注册 → 充值 10 元 → 创建 API Key。Key 只存在手机钥匙串里，不上传任何服务器。")
                }

                Section {
                    TextField("Base URL", text: Bindable(appState).baseURL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    TextField("模型名", text: Bindable(appState).model)
                        .autocorrectionDisabled()
                } header: {
                    Text("接口")
                } footer: {
                    Text("任何 OpenAI 兼容接口都能填（DeepSeek / 豆包 / Kimi / 通义）。已调用 \(appState.aiCalls) 次，失败 \(appState.aiFailures) 次。")
                }

                Section {
                    Toggle("用本地模型（电脑跑，不花钱）", isOn: Bindable(appState).useLocalModel)
                    if appState.useLocalModel {
                        TextField("本机地址", text: Bindable(appState).localBaseURL)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                        TextField("本地模型名", text: Bindable(appState).localModel)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("本地部署（实验性）")
                } footer: {
                    Text("电脑上装 Ollama，手机和电脑连同一个 WiFi，地址填 http://电脑IP:11434/v1。对话完全不出你的设备，不花一分钱；代价是小模型没那么聪明，催得没那么狠。")
                }

                Section {
                    Button {
                        testConnection()
                    } label: {
                        if testing {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("测试连通性").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(testing)
                    if let testResult {
                        Text(testResult)
                            .font(.footnote)
                            .foregroundStyle(testResult.hasPrefix("✅") ? Color.green : Color.red)
                    }
                }

                Section {
                    Toggle("通知声音", isOn: $soundOn)
                    Button("打开系统通知设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                } header: {
                    Text("通知与勿扰")
                } footer: {
                    Text("催促通知已申请\"时间敏感\"权限：开启后即使手机在勿扰/专注模式，监工也能弹出提醒。若感觉通知被拦，到系统设置里确认\"时间敏感通知\"已允许。（闹铃级强制响铃需要苹果特批权限，个人开发者一般拿不到，V1 用时间敏感方案替代。）")
                }

                Section {
                    Picker("我是", selection: Bindable(appState).userGender) {
                        ForEach(UserGender.allCases) { g in
                            Text(g.displayName).tag(g)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("你的性别")
                } footer: {
                    Text("监工人设据此贴合：伴侣模式会自动使用与你相反的性别。只存在手机本地。")
                }

                Section {
                    ForEach(PersonaRegistry.shared.all) { def in
                        roleGenderRow(def)
                    }
                } header: {
                    Text("监工性别")
                } footer: {
                    Text("每个监工都有自己的性别设定。伴侣模式固定与你的性别相反（男用户→女友，女用户→男友），其余模式可自选。")
                }

                Section {
                    ForEach(appState.userFacts.indices, id: \.self) { i in
                        Text(appState.userFacts[i])
                    }
                    .onDelete { offsets in
                        appState.userFacts.remove(atOffsets: offsets)
                    }
                    HStack {
                        TextField("如：我有慢性肠胃炎", text: $factInput)
                        Button("添加") {
                            let fact = factInput.trimmingCharacters(in: .whitespaces)
                            guard !fact.isEmpty else { return }
                            appState.userFacts.append(fact)
                            factInput = ""
                        }
                        .disabled(factInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("我的情况（监工会体谅）")
                } footer: {
                    Text("登记确诊疾病、考试周等真实情况，监工判定时会记得并适当宽限。只在手机本地保存。")
                }

                Section {
                    if appState.periodStarts.isEmpty {
                        Text("还没有记录")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.periodStarts.indices, id: \.self) { i in
                            let d = appState.periodStarts[appState.periodStarts.count - 1 - i]
                            Text(d.formatted(.dateTime.year().month().day()))
                        }
                        .onDelete { offsets in
                            let reversed = offsets.map { appState.periodStarts.count - 1 - $0 }
                            appState.periodStarts.remove(atOffsets: IndexSet(reversed))
                        }
                        if let next = Calendar.current.date(
                            byAdding: .day, value: appState.averageCycleDays,
                            to: appState.periodStarts.last ?? Date()
                        ) {
                            LabeledContent("预测下次", value: next.formatted(.dateTime.month().day()))
                        }
                    }
                    DatePicker("记录一次开始日期", selection: $periodDate, displayedComponents: .date)
                    Button("记入") {
                        appState.periodStarts.append(periodDate)
                    }
                } header: {
                    Text("生理期记录（可选）")
                } footer: {
                    Text("记录开始日期后，App 会按周期自动预测窗口。痛经发生在预测期内时，监工会直接体谅不再追问；日期对不上才会存疑。数据只在手机本地保存。")
                }

                Section {
                    if appState.majorEvents.isEmpty {
                        Text("暂无记录")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.majorEvents) { event in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(event.label)
                                    Spacer()
                                    if appState.eventStage(event) == nil {
                                        Text("体谅期已过")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                if let stage = appState.eventStage(event) {
                                    Text("\(event.date.formatted(.dateTime.month().day())) · \(stage)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { offsets in
                            appState.majorEvents.remove(atOffsets: offsets)
                        }
                    }
                    HStack {
                        TextField("如：亲人离世、结婚、重要比赛", text: $eventInput)
                        Button("记入") {
                            let label = eventInput.trimmingCharacters(in: .whitespaces)
                            guard !label.isEmpty else { return }
                            appState.recordMajorEvent(label: label, date: eventDate)
                            eventInput = ""
                        }
                        .disabled(eventInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    DatePicker("发生日期", selection: $eventDate, displayedComponents: .date)
                } header: {
                    Text("大事件（体谅期）")
                } footer: {
                    Text("重要的人生大事。记入后监工语气会在约 3 周内放软、再慢慢恢复——不需要告诉它持续多久。对话中说起时它也会主动识别询问是否记录。")
                }

                if !appState.delayCauses.isEmpty {
                    Section {
                        ForEach(appState.delayCauses.sorted { $0.value > $1.value }, id: \.key) { cause, count in
                            LabeledContent(cause, value: "\(count) 次")
                        }
                        Button("清空拖延记录") { appState.delayCauses = [:] }
                            .foregroundStyle(.red)
                    } header: {
                        Text("拖延原因档案")
                    } footer: {
                        Text("逾期完成的任务会问一句为什么。积累几次后，监工会预判你的老毛病——比如到点提醒你先把短视频关了。")
                    }
                }

                Section {
                    Button {
                        prepareExport()
                    } label: {
                        Label("导出备份文件", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        showImporter = true
                    } label: {
                        Label("从备份恢复", systemImage: "square.and.arrow.down")
                    }
                } header: {
                    Text("数据备份")
                } footer: {
                    Text("导出一个 JSON 文件（任务、对话、习惯、偏好），存到「文件」App 或转发给自己的另一台设备，在那台设备上用「从备份恢复」导入，就能把记录搬过去。恢复是按任务 ID 合并，不会删掉现有内容。API Key 不在备份里，新设备需要重新填一次。" + (backupMessage.map { "\n\n\($0)" } ?? ""))
                }

                Section {
                    LabeledContent("版本", value: "0.1.0")
                } footer: {
                    Text("快干活 · AI 监工 · 所有数据仅存本机")
                }
            }
            .navigationTitle("设置")
            .fileExporter(
                isPresented: $showExporter,
                document: backupFile,
                contentType: .json,
                defaultFilename: Self.defaultBackupName
            ) { result in
                switch result {
                case .success: backupMessage = "备份已导出"
                case .failure(let error): backupMessage = "导出失败：\(error.localizedDescription)"
                }
                backupFile = nil
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url):
                    do {
                        let accessed = url.startAccessingSecurityScopedResource()
                        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                        let data = try Data(contentsOf: url)
                        let snapshot = try BackupService.decode(data)
                        let summary = try BackupService.apply(snapshot, context: modelContext, appState: appState)
                        backupMessage = "已恢复：新增 \(summary.newTasks) 个任务、\(summary.newHabits) 个习惯；" +
                            "覆盖 \(summary.updatedTasks) 个任务、\(summary.updatedHabits) 个习惯"
                    } catch {
                        backupMessage = "这个文件读不懂：\(error.localizedDescription)"
                    }
                case .failure(let error):
                    backupMessage = "选择文件失败：\(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - 备份

    private static var defaultBackupName: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return "快干活备份-\(f.string(from: Date()))"
    }

    private func prepareExport() {
        do {
            let data = try BackupService.exportData(context: modelContext, appState: appState)
            backupFile = BackupFile(data: data)
            showExporter = true
        } catch {
            backupMessage = "生成备份失败：\(error.localizedDescription)"
        }
    }

    /// 头像设置行：左侧头像图 + 名称，右侧显示来源
    private func avatarRow(title: String, kind: AvatarKind) -> some View {
        HStack(spacing: 12) {
            AvatarView(kind: kind, size: 44)
            Text(title)
            Spacer(minLength: 8)
            Text(kind.isCustom ? "照片" : "内置")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 当前监工头像的双向绑定
    private func roleAvatarBinding() -> Binding<AvatarKind> {
        Binding(
            get: { appState.avatar(for: appState.roleID) },
            set: { appState.setAvatar($0, for: appState.roleID) }
        )
    }

    /// 单角色的性别配置行：伴侣模式只读（与用户相反），其余模式可选
    @ViewBuilder
    private func roleGenderRow(_ def: PersonaDefinition) -> some View {
        switch def.genderPolicy {
        case .oppositeOfUser:
            LabeledContent(def.displayName) {
                switch appState.userGender {
                case .male: Text("女友（与你相反）").foregroundStyle(.secondary)
                case .female: Text("男友（与你相反）").foregroundStyle(.secondary)
                case .undisclosed: Text("需先设置你的性别").foregroundStyle(.orange)
                }
            }
        case .userChoice(let fallback):
            Picker(def.displayName, selection: Binding(
                get: { appState.personaGender(for: def.id) ?? (fallback == .undisclosed ? .male : fallback) },
                set: { appState.setRoleGender($0, for: def.id) }
            )) {
                Text("男").tag(UserGender.male)
                Text("女").tag(UserGender.female)
            }
        case .irrelevant:
            LabeledContent(def.displayName, value: "不区分")
        }
    }

    private func testConnection() {
        testing = true
        testResult = nil
        let client = appState.makeClient()
        Task {
            defer { testing = false }
            do {
                let reply = try await client.ping()
                testResult = reply.isEmpty ? "❌ 空回复" : "✅ 连通正常"
            } catch {
                testResult = "❌ " + error.localizedDescription
            }
        }
    }
}
