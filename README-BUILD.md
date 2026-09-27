# 快干活 — 工程结构与上手指南

> 给未来的自己（和 AI 同事）：代码在 Windows 上写，在 Mac 上编译，中间靠 Git 和 CI 连接。

## 目录结构

```
kuaiganhuo/
├── project.yml              # Xcode 工程描述（XcodeGen 用，别手改 .xcodeproj）
├── KuaiGanHuCore/           # 核心逻辑包（SPM，任何平台可编译）
│   ├── Sources/KuaiGanHuCore/
│   │   ├── Models.swift     # 数据模型 + 性别 + AI 配置
│   │   ├── PersonaRegistry.swift  # 角色注册表：数据驱动，加新角色只注册一份定义
│   │   ├── PromptEngine.swift  # ★ 提示词引擎：人设（含性别变体）× 情绪 × 协议 + 安全边界
│   │   ├── Moderation.swift  # ★ 防恶意：本地预检 + 可热更新词表 + 上下文隔离 + 输出侧安检
│   │   └── AIClient.swift   # AI 接入：OpenAI 兼容接口 + 五大协议
│   └── Tests/               # 单元测试（CI 会自动跑）
├── KuaiGanHuo/              # iOS App（SwiftUI）
│   ├── App.swift            # 入口 + 全局状态（角色/情绪/配置）
│   ├── TaskItem.swift       # 任务数据模型（SwiftData）
│   ├── Services/
│   │   ├── Keychain.swift   # API Key 安全存储
│   │   └── NotificationManager.swift  # 本地通知调度
│   └── Views/
│       ├── TaskListView.swift   # ① 首页任务列表
│       ├── AddTaskView.swift    # ② 布置任务（AI 解析）
│       ├── ChatView.swift       # ③ 监工对话（借口判定）
│       ├── RolePickerView.swift # ④ 角色情绪选择
│       └── SettingsView.swift   # ⑤ API Key 设置
├── ai-engine/               # 提示词原始定义（JSON + 协议文档，与 Swift 同源）
└── testbench/               # Python 测试台（mock / DeepSeek 真实模式）
```

## 在 Mac 上第一次编译（10 分钟）

1. 装 Xcode（App Store，免费）
2. 终端执行：`brew install xcodegen`（没有 brew 就去 brew.sh 装）
3. `cd kuaiganhuo && xcodegen generate` → 生成 `KuaiGanHuo.xcodeproj`
4. 双击打开工程，选 iPhone 模拟器，按 ⌘R 运行

## 不开 Mac 也能验证代码

`.github/workflows/ios-build.yml` 在每次 push / PR 时自动在云端 Mac 上跑两件事：
1. `swift test --package-path KuaiGanHuCore`：核心包单元测试（提示词拼装、JSON 解析、审核与隔离逻辑）
2. `xcodegen generate` + `xcodebuild build`：生成工程并完整编译 App（iOS 模拟器目标，不做签名）

任何一行代码写错，Actions 页面会标红并给出报错位置——**在 Windows 上就能改完**。

首次使用（本项目已 `git init` 并生成第一次提交，只需连上远端）：

```bash
# 1. 在 github.com 新建空仓库（不要勾 README / .gitignore）
# 2. 复制页面上的 "push an existing repository" 三行命令执行，例如：
git remote add origin https://github.com/<你的账号>/kuaiganhuo.git
git branch -M main
git push -u origin main
```

之后每次改动：`git add -A && git commit -m "更新" && git push`，然后去 Actions 页面看结果。

## 本地部署联调（不需要 Mac / 真 Ollama / API）

「本地部署」开关：设置页打开后，App 把 AI 请求指向你电脑上跑的 Ollama（或 LM Studio），
数据不出局域网、不花钱。这条链路的线协议（请求路径、字段、响应结构）和 Ollama 的
OpenAI 兼容接口完全同构——可以用下面的 Windows 脚本验证，不需要 Mac 或真实模型：

```bash
cd kuaiganhuo/testbench
python mock_ollama.py            # 终端 A：起一个本地模型 mock 服务（http://127.0.0.1:11434/v1）
python verify_local_deploy.py    # 终端 B：发一条与 Swift AIClient 完全一致的请求做端到端验证
```

`verify_local_deploy.py` 会按 Swift 的 `WireRequest`（model / messages / temperature / max_tokens）
构造请求打到 `/v1/chat/completions`，再用和 `AIClient.extractJSON` 同款的括号配平算法解析响应，
五个协议（解析 / 催促 / 判定 / 庆祝 / 习惯提醒）+ 连通性 ping 全过即代表线协议正确。

真机上：电脑装好 Ollama 并 `ollama pull qwen2.5:3b-instruct`，手机和电脑连同一 WiFi，
设置页把「本机地址」填 `http://<电脑IP>:11434/v1`、「本地模型名」填 `qwen2.5:3b-instruct` 即可。

## 改提示词的唯一入口

**人设/语气/判定规则** → `KuaiGanHuCore/Sources/KuaiGanHuCore/PromptEngine.swift`
（`ai-engine/*.json` 是设计稿，Swift 文件是运行时真身；两边改动要同步）

## 技术要点备忘

- iOS 17+，SwiftUI + SwiftData + @Observable（不用老式 ObservableObject）
- 通知文案是任务保存时**预生成**的（本地通知弹出时不能调 AI）
- 借口判定在 ChatView 里实时调 AI，带对话历史 + 借口历史（翻旧账）
- AI 失败不阻塞保存任务：文案有内置兜底
- API Key 只存 Keychain，永不进 UserDefaults / 网络
- 角色 ID 字符串化（`appState.roleID`）：新角色注册后自动可用，UserDefaults 无需迁移
- 模式切换隔离：对话 / 语气备忘 / 已发通知都带角色标签；只有任务事实摘要 `fact_digest` 跨角色共享
- 防恶意三层：本地预检（色情、自伤不上送 API）→ 模型 `safety_refuse`（软拒也写在 JSON 里）→ 提示词安全边界；输出侧另有一道安检（通知文案会上锁屏）
