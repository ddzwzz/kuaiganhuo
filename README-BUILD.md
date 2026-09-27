# 快干活 — 工程结构与上手指南

> 给未来的自己（和 AI 同事）：代码在 Windows 上写，在 Mac 上编译，中间靠 Git 和 CI 连接。

## 目录结构

```
kuaiganhuo/
├── project.yml              # Xcode 工程描述（XcodeGen 用，别手改 .xcodeproj）
├── KuaiGanHuCore/           # 核心逻辑包（SPM，任何平台可编译）
│   ├── Sources/KuaiGanHuCore/
│   │   ├── Models.swift     # 数据模型 + AI 配置
│   │   ├── PromptEngine.swift  # ★ 提示词引擎：角色人设 × 情绪 × 协议
│   │   └── AIClient.swift   # AI 接入：OpenAI 兼容接口 + 三大协议
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

- 推到 GitHub 后，`.github/workflows/ios-build.yml` 自动在云端 Mac 上：
  1. 跑核心包单元测试（提示词拼装、JSON 解析）
  2. 生成 Xcode 工程并完整编译 App
- 任何一行代码写错，Actions 页面会标红并给出报错位置——**在 Windows 上就能改完**

## 改提示词的唯一入口

**人设/语气/判定规则** → `KuaiGanHuCore/Sources/KuaiGanHuCore/PromptEngine.swift`
（`ai-engine/*.json` 是设计稿，Swift 文件是运行时真身；两边改动要同步）

## 技术要点备忘

- iOS 17+，SwiftUI + SwiftData + @Observable（不用老式 ObservableObject）
- 通知文案是任务保存时**预生成**的（本地通知弹出时不能调 AI）
- 借口判定在 ChatView 里实时调 AI，带对话历史 + 借口历史（翻旧账）
- AI 失败不阻塞保存任务：文案有内置兜底
- API Key 只存 Keychain，永不进 UserDefaults / 网络
