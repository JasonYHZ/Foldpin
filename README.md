# Foldpin

代码高亮已接入 highlight.js 11.11.1，通过本机 JavaScriptCore 后台解析，编辑器仍为原生 NSTextView。支持 29 个语言选择及自动识别，复用现有主题；实现、限制与来源见[语法引擎说明](docs/engineering/syntax-engine.md)。

**Floating Sticky Notes for Mac**\
**随手记，眼前贴，一键收。**

一款 macOS 桌面随手记工具：将想法、待办和参考资料随手变成小纸片，需要时留在眼前，用完后一键收拢，再按需整理。

## 当前状态

2026-09-10：当前纸片新增查找与替换，支持匹配高亮、表格 / 图片标题、一次撤销和后台合并查询；⌘F 查找、⌘⌥F 替换，可在设置改绑。见[纸片内搜索](docs/engineering/note-search.md)。

2026-09-09：设置新增「快捷键」，分窗口内 / 全局，可录入、清除与恢复默认；菜单和操作提示即时同步。全局支持新建、快速录音、显示／收起和收纳，默认分别为 ⌃⌥N / ⌃⌥R / ⌃⌥Space / ⌃⌥O，保留已有自定义。见[自定义快捷键](docs/engineering/custom-shortcuts.md)。

2026-09-09：新增本地视频区块，支持 MP4 / MOV / M4V 导入、封面、点击播放、原生进度 / 音量、原文件导出和撤销恢复。视频在点击播放前不启动解码器，收起纸片时暂停；详见[视频区块](docs/engineering/video-blocks.md)。

2026-09-09：图片与音频均可从「更多」或区块菜单导出原文件，保留原始格式；图片缩放与标题不影响导出。视频随后接入同一导出入口。见[媒体导出](docs/engineering/media-export.md)。

2026-09-09：图片新增悬停缩放手柄和下方标题。左右拖动保持比例与居中，松手后保存并支持撤销；悬浮工具条可编辑标题、恢复尺寸和打开块菜单。原图文件保留，标题和显示尺寸跟随图片复制、移动与恢复。见[图片缩放与标题](docs/engineering/image-size-captions.md)。

2026-09-09：纸片新增本地录音与音频导入，支持波形播放条、拖动进度、倍速、重命名、导出和撤销恢复。正文 `/` 媒体组进入，首次主动录音才申请麦克风权限；转写与上传尚未加入。实现与验证边界见[音频块说明](docs/engineering/audio-blocks.md)。

2026-09-09：菜单栏与纸片操作面板新增「排列桌面纸片」和单次撤销排列，保持尺寸 / 折叠状态并按显示器分别整理。通透模式的选色增加常驻淡色层，避免只依赖玻璃激活态染色。六项定向检查与 Debug 构建通过，真实桌面排列和失焦配色仍待实机验收。见[桌面排列说明](docs/engineering/desktop-arrangement.md)。

2026-09-09：纸片操作菜单 ⌘K、长按 Command 提示、颜色快捷键与侧边子菜单、图文复制、独立纸片副本、最近删除与恢复，以及按块类型区分的右键菜单已实现。文字右键支持常用行内格式，表格支持按位置增删行列。继续开发前阅读[开发交接](docs/engineering/development-handoff.md)，其中记录真实工作目录、代码入口和待验收项目。

2026-09-08 多窗口已接入：激活 Foldpin 后按 **⌘N**，或从菜单栏 / 收纳架「＋」创建纸片。每张独立保存内容、位置、置顶与折叠状态；⌘W 收纳当前纸片，收纳架可找回，重启恢复原状态。表格底部 / 右侧「＋」可增行列，六点块菜单可切换标题行 / 标题列。旧单纸片自动备份后迁移。见[多窗口说明](docs/engineering/multi-note-windows.md)。

2026-09-08 性能整理：代码词元属性缓存、变化属性更新、区块几何复用、表格局部刷新及界面状态去重已实现。125 项检查与 Debug 构建通过；独立临时进程完成 1 / 10 / 30 张合成纸片的纸感 / 通透对照，表格输入与滚动开销下降。该次测量基于多窗口接入前的组件；测量口径、内存和未验证范围见[性能报告](docs/engineering/editor-performance.md)。

2026-09-07：已在用户创建的 Xcode 工程中实现原生单纸片技术原型：文字输入、置顶、单行折叠、收纳、恢复和本地保存；顶部操作使用图标，折叠时显示正文首行标题，菜单栏可打开「纸感 / 通透」外观设置。已有可运行 Debug 构建与数据测试；窗口交互的已测/未测范围单独记录。PRD 描述完整产品目标，当前原型不代表完整 MVP，也没有发布版本。

界面现支持简体中文和英文，设置内可选择「跟随系统 / 简体中文 / English」，选择后立即生效；笔记正文保持原样。已完成双语资源检查，实际双语排版的验证范围见 M1 记录。

外观设置现增加「跟随系统 / 明亮 / 暗色」主题，与纸感 / 通透材质独立，选择后立即应用并记住。代码块采用 GitHub 风格明暗配色与完整圆角背景，继续使用本地原生渲染。

设置现支持独立代码样式：GitHub、VS Code Light+ / Dark+、Monokai、Solarized Light / Dark，并可导入 VS Code JSON/JSONC 或 TextMate tmTheme。带即时预览、0–100% 背景不透明度滑杆与导入主题移除，正文仍保持原生结构化编辑；兼容范围见 [代码主题说明](docs/engineering/code-theme-formats.md)。

2026-09-08：按用户选择升级为 TextKit 2 原生块编辑器，第一阶段接入标题、待办、图片、基础代码高亮及块转换，支持 `#` 加空格等 Markdown 输入快捷方式，正文仍按结构化 JSON 保存。代码块支持 HTML（含 script 中的基础 JavaScript / JSON），悬浮工具条可选择语言与复制原文；新代码块默认自动识别，也可手动指定语言，保持原生编辑。旧笔记首次保存前自动备份。块拖拽和合成多纸片性能验证已随后补齐，多纸片管理随后已接入，语音仍在后续范围。

代码语言已补齐 Java。悬浮工具条改为位于滚动区域上层，滚动时保持显示并更新位置，修复反复隐藏、显示导致的闪烁；验证范围见 [代码工具条记录](docs/engineering/code-block-toolbar.md)。

新增有序列表、`---` 分隔线与可直接编辑的原生表格，支持续号、Tab 切换、增行 / 增列及撤销保存。详见[使用与实现说明](docs/engineering/lists-dividers-tables.md)。

正文中输入「空格 + /」也能打开区块菜单，选择后保留前后文字，支持退格、Esc 和原生撤销。详见[区块菜单说明](docs/design/native-block-menu/README.md)。

⌘V 现可自动把 Markdown 转为原生区块及常用行内格式，⌘⇧⌥V 可保留纯文本。代码块内粘贴保持原文，转换支持选区替换、撤销和结构化保存。详见 [Markdown 粘贴](docs/engineering/markdown-paste.md)。

## 文档入口

标题现支持 H1–H4，可用 `#` 至 `####` 加空格输入，也可从区块菜单选择；保存、撤销、空标题提示与换行规则同步支持四级标题。

现已支持六点手柄、单块选中与操作菜单，可转换、复制、创建副本、上下移动和删除区块，结构操作继续使用原生撤销。现可直接拖动六点手柄排序，显示落点并支持边缘自动滚动；行为与原生预览见[单块操作说明](docs/engineering/block-actions.md)。

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

打开 [Foldpin.xcodeproj](macOS/Foldpin.xcodeproj)，在 Xcode 中选择 Foldpin / My Mac，按 ⌘R。按 ⌘N 创建多张纸片，按多窗口说明验证独立保存和收纳恢复。

首个技术验证重点是窗口层级、编辑焦点、全屏/Spaces、多屏位置恢复与本地保存。语音、自动收集、AI 整理保留在路线图中；具体进入哪个版本见 PRD。

## 资料约定

- 研究文档记录历史讨论，不代表其中的市场、技术、收入或名称可用性说法都已验证。
- 8 张 Grok 生成图片用于内部设计探索；图中旧名称、示例代码、平台图标和装饰不是 Foldpin 的正式资产或功能承诺。
- 品牌正式发布前仍需完成域名、商标与相关资产使用范围核验。
- 原生工程由用户通过 Xcode 创建，现与产品文档、设计素材一起纳入产品根目录的 Git 仓库。远程仓库为 `git@github.com:JasonYHZ/Foldpin.git`，主分支为 `main`。
