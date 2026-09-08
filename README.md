# Foldpin

**Floating Sticky Notes for Mac**\
**随手记，眼前贴，一键收。**

一款 macOS 桌面随手记工具：将想法、待办和参考资料随手变成小纸片，需要时留在眼前，用完后一键收拢，再按需整理。

## 当前状态

2026-09-07：已在用户创建的 Xcode 工程中实现原生单纸片技术原型：文字输入、置顶、单行折叠、收纳、恢复和本地保存；顶部操作使用图标，折叠时显示正文首行标题，菜单栏可打开「纸感 / 通透」外观设置。已有可运行 Debug 构建与数据测试；窗口交互的已测/未测范围单独记录。PRD 描述完整产品目标，当前原型不代表完整 MVP，也没有发布版本。

界面现支持简体中文和英文，设置内可选择「跟随系统 / 简体中文 / English」，选择后立即生效；笔记正文保持原样。已完成双语资源检查，实际双语排版的验证范围见 M1 记录。

外观设置现增加「跟随系统 / 明亮 / 暗色」主题，与纸感 / 通透材质独立，选择后立即应用并记住。代码块采用 GitHub 风格明暗配色与完整圆角背景，继续使用本地原生渲染。

2026-09-08：按用户选择升级为 TextKit 2 原生块编辑器，第一阶段接入标题、待办、图片、基础代码高亮及块转换，支持 `#` 加空格等 Markdown 输入快捷方式，正文仍按结构化 JSON 保存。旧笔记首次保存前自动备份。语音、完整块拖拽和多纸片性能验证仍在后续范围。

## 文档入口

| 文档 | 用途 |
| --- | --- |
| [原生工程说明](macOS/README.md) | Xcode 运行、快捷键、保存位置、构建与测试命令 |
| [M1 验证记录](docs/engineering/m1-validation.md) | 当前原型已通过的检查与仍需实机验证的场景 |
| [块编辑器实施方案](docs/engineering/block-editor-plan.md) | 原生块编辑第一阶段的实现、数据迁移、验证边界与后续语音路线 |
| [PRD.md](PRD.md) | 产品定位、MVP 范围、需求编号、状态流转、验收条件、待决问题 |
| [AGENTS.md](AGENTS.md) | 后续开发代理的项目上下文与工作约定 |
| [第一版界面草图](docs/design/ui-v0.1/README.md) | 展开纸片、多纸片桌面、收起与找回；含可点击的状态演示和设计规则 |
| [资料索引](docs/research/README.md) | 原始来源、证据等级、归档范围和已知局限 |
| [ChatGPT 会话要点](docs/research/chatgpt-summary.md) | 工作记忆、开发者场景、工作区与分期建议 |
| [Grok 会话要点](docs/research/grok-summary.md) | 创始人需求、概念图、技术讨论、商业与命名探索 |
| [产品与命名决策](docs/decisions/0001-product-and-name.md) | 已确定内容与暂定提案的边界 |
| [产品仓库与工程目录](docs/decisions/0002-product-repository.md) | 统一 Git 根目录、macOS 工程结构与迁移验证 |
| [概念图索引](docs/design/concepts/README.md) | 两批 8 张原图、逐图说明及使用边界 |
| [概念图画廊](docs/design/concepts/index.html) | 可离线打开的原图浏览页 |
| [图片溯源清单](docs/design/concepts/manifest.json) | 原图 URL、批次、文件名、SHA-256 与尺寸 |

## 开发起点

产品根目录 `Foldpin/` 是统一 Git 仓库，包含 PRD、AGENTS.md、研究 / 设计资料和 macOS 工程。在本目录或 `macOS/` 内都可执行 `git status`；原生构建和测试命令从 `macOS/` 运行。2026-09-08 将 Git 根目录提升到产品目录并去掉 macOS 工程外层的同名目录，保留此前提交历史。工程与源码的相对位置保持一致；构建缓存和 Xcode 个人界面状态不纳入版本管理。

```text
Foldpin/
├── .git/
├── AGENTS.md
├── PRD.md
├── docs/
└── macOS/
    ├── Foldpin.xcodeproj
    ├── Foldpin/           # 应用源码与资源
    ├── Tests/
    ├── Package.swift
    └── README.md
```

打开 [Foldpin.xcodeproj](macOS/Foldpin.xcodeproj)，在 Xcode 中选择 Foldpin / My Mac，按 ⌘R。先试用单张纸片，再按 M1 验证记录继续补齐窗口测试。

首个技术验证重点是窗口层级、编辑焦点、全屏/Spaces、多屏位置恢复与本地保存。语音、自动收集、AI 整理保留在路线图中；具体进入哪个版本见 PRD。

## 资料约定

- 研究文档记录历史讨论，不代表其中的市场、技术、收入或名称可用性说法都已验证。
- 8 张 Grok 生成图片用于内部设计探索；图中旧名称、示例代码、平台图标和装饰不是 Foldpin 的正式资产或功能承诺。
- 品牌正式发布前仍需完成域名、商标与相关资产使用范围核验。
- 原生工程由用户通过 Xcode 创建，现与产品文档、设计素材一起纳入产品根目录的 Git 仓库。当前保存为本地提交，尚未配置远程仓库；资料公开前应检查是否适合公开原始会话链接与图片来源信息。
