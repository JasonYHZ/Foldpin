# Foldpin macOS · M1 单纸片原型

2026-09-07。以已创建的 macOS App 工程为基础，实现第一张原生纸片。当前是技术原型，不是 PRD 中全部 P0 已完成的 MVP。

## 运行

Git 仓库根目录是产品目录 `../`，统一管理本文、工程、PRD 与设计资料；本目录不再是独立嵌套仓库。下文构建和测试命令仍从本目录执行。

使用 Xcode 打开 [Foldpin.xcodeproj](Foldpin.xcodeproj)，Scheme 选择 **Foldpin**，运行目标选择 **My Mac**，按 **⌘R**。

- 实测工具链：Xcode **26.6 (17F113)**。
- 当前机器：macOS **26.6.2**，Apple Silicon。
- 保留用户创建的最低系统版本：**macOS 26.5**。尚未评估更早系统支持。
- 保留用户的 Team、自动签名和 Bundle ID：`dev.jasonyu.Foldpin`。
- 保留 App Sandbox 与 Hardened Runtime；没有新增网络、麦克风、辅助功能或输入监听权限。

第一次打开是空白纸片，可以直接写。顶部左侧为关闭按钮，右侧依次为置顶、折叠、收起，均为图标。折叠后纸片留在桌面，缩成 34 点高的一行；再点击展开恢复原大小，也可双击顶部空白区切换。收起后屏幕右侧出现 `1` 的入口，点开摘要，再选“贴回原处”。按 Esc 收起；左侧关闭同样收起，不删除内容。

折叠条中间显示正文第一行内容（跳过空白行），长标题自动省略，悬停可看完整标题；没有内容时显示「空白纸片」。标题区域仍可以拖动和双击展开。折叠条可以水平缩放和切换置顶，重启保留折叠状态和展开尺寸。从收纳「贴回原处」保留折叠状态；菜单「打开纸片」和全局快捷键会展开纸条，方便继续输入。

标题栏空白处用于移动纸片，靠近四边或四角时用缩放光标调整大小；折叠条仅左右两边可调整宽度。2026-09-08 补上纸感原生实色底层与无边框窗口的边缘缩放处理；本轮只做隔离检查，实际指针操作的已测 / 未测范围见 [M1 验证记录](../docs/engineering/m1-validation.md)。

默认全局快捷键为 **⌃⌥Space（Control + Option + 空格）**：隐藏时唤出纸片；正在编辑时再次按下收起。同一张纸片已经显示但没有输入焦点时，快捷键先让它进入编辑。也可以从菜单栏 Foldpin 图标进入，或在菜单中换成 **⌃⌥N**。如果注册失败，菜单会提示更换组合。

**⌘M（Command + M）**：纸片获得焦点时，在一行折叠条和展开正文之间切换。先点击纸片，再使用 Raycast 或系统窗口调整快捷键。纸片已按标准窗口参与识别；本轮实际检查了 Raycast 的 Left Half 和系统窗口菜单的左半屏 / 恢复尺寸操作。⌘M 不注册为全局热键，其他应用保持自己的快捷键行为。

**⌘W（Command + W）**：关闭当前获得焦点的窗口。纸片（包括折叠条）会先保存再收纳，内容保留；保存失败时保留窗口和重试入口。设置窗口沿用系统关闭行为。⌘W 不注册为全局热键。

这一版只维护一张纸片。“打开纸片”始终找回同一条记录，不清空内容，也不会悄悄新建第二张。

## 原生块编辑器（2026-09-08）

在空段落输入 **/**，或点击编辑区域底部的内容块按钮，可选择正文、两级标题、项目列表、待办、引用、代码块或图片。右键也有内容块菜单。

底部按钮现在直接显示当前块类型，例如 **+ 正文** 或 **+ 代码块**，点击即可切换。代码内的 `/` 是普通代码字符；按 **⌘Return** 新开正文段落，再输入 `/` 可打开建议。要保留当前文字并去掉代码格式，点击 **+ 代码块 → 正文**。空代码块 / 空标题也可按 Backspace 回正文。

删除整张纸片全部字符后会回到空正文，再输入不继承代码底色。清空与格式切换可撤销 / 重做。新文件没有预填字符；重新打开已有纸片会恢复上次保存的文字与块类型。

- **/ 建议浮层**：Backspace 可直接删除；继续输入会关闭建议并保留文字。↑ / ↓ 选择、回车确认，Esc 只关闭建议。
- **⌘B / ⌘I**：粗体 / 斜体。
- **待办**：点击复选标记切换完成；回车继续，空待办回车回到正文。
- **⌘⌥↑ / ⌘⌥↓**：移动当前块；菜单中还可复制块。
- **代码块**：菜单选择语言、复制原始代码；普通回车在代码内换行，**⌘Return** 回到正文。超过 24,000 UTF-16 单位的代码保留等宽显示，跳过高亮。
- **图片**：选择文件、粘贴或拖入一张图片，限制 40 MB / 8000 万像素。原图先保存到本机，使用最长边 1400 像素的预览显示。
- 原生撤销 / 重做同时覆盖文字与块操作，窗口的 ⌘M / ⌘W 行为保持不变。

也可以直接在普通段落开头键入 Markdown 快捷方式：

| 输入 | 转换结果 |
| --- | --- |
| `#` + 空格 | H1 一级标题 |
| `##` + 空格 | H2 二级标题 |
| `-` / `*` / `+` + 空格 | 无序列表 |
| `[]` / `[ ]` + 空格 | 未完成待办；也支持连续键入 `- [ ] ` |
| `[x]` / `[X]` + 空格 | 已完成待办 |
| `>` + 空格 | 引用 |
| 三个反引号 + 回车或空格 | 代码块；反引号后可接 `swift`、`js`、`ts`、`python`、`json`、`sql`、`shell` 等现有语言 |

转换去掉输入前缀，保留后续文字和可用格式，光标继续留在当前块，可用 **⌘Z / ⇧⌘Z** 撤销 / 重做。正文仍存为结构化 JSON；这些是输入快捷方式，不会自动把粘贴内容或旧笔记当 Markdown 解析，也不在句中、代码块内、选区替换或输入法组合期间触发。当前支持两级标题，尚无有序列表、行内 Markdown 自动转换或完整 Markdown 导入 / 导出。

第一阶段使用 **NSTextView + TextKit 2**，没有 WebView 或第三方编辑器依赖。仍是单纸片原型；语音、可视块拖拽手柄、嵌套列表、图片图注 / 原图预览和多纸片休眠尚未实现。实际 UI 的已测 / 未测边界见 [原生编辑器验证](../docs/engineering/native-editor-validation.md)。

代码采用 [GitHub 主题](https://github.com/primer/github-vscode-theme)风格配色：关键字、字符串、注释、数字与函数名分别着色，整个块使用圆角底色、细边线和留白，颜色跟随当前主题。语言为纯文本时保留等宽和块背景；在代码块菜单选择 Swift、JavaScript / TypeScript、Python、JSON、SQL 或 Shell 后显示相应高亮。所有渲染在本机完成，留白不改变原始代码；并非 GitHub 语法引擎的完整移植。许可随应用打包，见 [ThirdPartyNotices.txt](Foldpin/ThirdPartyNotices.txt)。

离屏原生编辑器样例：[明亮](../docs/engineering/screenshots/github-code-light.png) · [暗色](../docs/engineering/screenshots/github-code-dark.png)。仅使用示例文字，不是用户当前窗口截图。

## 界面语言

点击菜单栏 Foldpin 图标 →「设置…」，在底部 **语言 / Language** 选择 **跟随系统 / 简体中文 / English**。**选择后立即生效，无需重启**，现有纸片、收纳、设置、Foldpin 菜单、状态和应用错误提示一起更新，并自动记住选择。开发时需先在 Xcode 按 ⌘R 运行本次更新后的版本。

`LanguageSettings` 选择应用内对应的语言资源 Bundle，SwiftUI 观察配置并更新 locale，AppKit 原位更新窗口标题和基本菜单标签；正文和窗口对象保持不变。选择仍存入 Foldpin 自身偏好域的 `AppleLanguages`，以便下次启动沿用；「跟随系统」只移除本应用覆盖，并直接读取系统语言列表，无匹配语言时回退英文。

macOS 自带的服务、拼写、窗口排列等子菜单，以及系统生成的底层错误详情仍由系统管理；本次不替换这些系统功能。

菜单、设置、收纳、操作提示、保存 / 读取错误与辅助功能标签均已翻译，英文外观名称为 **Paper / Glass**。笔记正文、折叠条内容标题与摘要始终显示用户原文。外观偏好和快捷键保持稳定；2026-09-08 编辑器升级的 v2 文件迁移见下方保存说明。

所有应用文案集中在 [Localizable.xcstrings](Foldpin/Localizable.xcstrings)，英文为源语言；新增界面文字应使用本地化 API 并同步补齐中文。编辑器新增菜单与导入提示同步维护中英翻译；此前完成过无窗口的连续语言切换检查，实际双语排版仍需体验确认。

## 外观设置

点击屏幕顶部菜单栏的 Foldpin 纸片图标 →「设置…」，或在 Foldpin 中按 **⌘,**，进入同一个原生设置窗口。纸片上不再放置设置齿轮。

- **纸感（默认材质）**：明亮主题为温暖浅黄，暗色主题为暖深灰与浅色正文。
- **通透**：整张纸片使用原生 Liquid Glass，包含玻璃边缘、背景透光和桌面色彩变化；工具区与正文共用同一表面。
- 点击预览卡立即应用，无需保存；退出重开仍记住选择。外观用 `UserDefaults` 的 `noteAppearance` 保存，不修改笔记 JSON。
- **主题**：跟随系统 / 明亮 / 暗色，默认跟随系统。选择后纸片、设置、收纳与代码配色立即更新，无需重启；材质选择独立保留。
- 主题使用 Foldpin 自身的 `appTheme` 偏好，启动时应用。跟随系统移除应用覆盖，后续系统明暗变化自动继承；不改全局系统偏好或笔记 JSON。
- 两种材质都支持明暗主题；减少透明度或增强对比度开启时通透使用实色背景。切换只更新外观，正文编辑器不重建，光标、选区、组合输入和撤销记录保留。

[整张玻璃设置窗口截图](../docs/engineering/screenshots/whole-glass-settings.png)。

## 命令行构建

下面从本目录运行。显式指定 Xcode，不需要修改机器全局的 `xcode-select` 设置。

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project Foldpin.xcodeproj -scheme Foldpin \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/Foldpin-DerivedData \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
```

这是已验证的本机 ad-hoc 签名构建命令；仅覆盖当前这次命令的签名方式，未修改工程中的个人签名设置。用于本地验证，不作为发布签名。

## 自动测试

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/Foldpin-ModuleCache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/Foldpin-ModuleCache \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --disable-sandbox --package-path . --scratch-path /private/tmp/Foldpin-CoreTests
```

`Package.swift` 是同一份源码的测试入口，覆盖 Core、原生编辑适配与图片导入；不构建第二个 App。测试使用独立临时目录及无可见窗口的 NSTextView，不操作真实笔记或正在使用的纸条。该测试入口使用与 App 相同的 macOS 26.5 基线。显式缓存目录适配受限环境；`--disable-sandbox` 仅关闭 SwiftPM 自身的子进程沙盒，不修改 Foldpin 的 App Sandbox 设置。

## 文件与职责

| 文件 | 职责 |
| --- | --- |
| [FoldpinApp.swift](Foldpin/FoldpinApp.swift) | SwiftUI 应用入口、设置与菜单命令 |
| [Localizable.xcstrings](Foldpin/Localizable.xcstrings) | 简体中文与英文界面文案，包括动态状态、错误和辅助功能标签 |
| [LanguageSettings.swift](Foldpin/LanguageSettings.swift) | 即时语言配置、资源 Bundle、跟随系统与偏好保存 |
| [ApplicationMenuLocalization.swift](Foldpin/ApplicationMenuLocalization.swift) | 原位翻译 AppKit 基本菜单标签，保留动作、快捷键和系统窗口功能 |
| [AppDelegate.swift](Foldpin/AppDelegate.swift) | AppKit 窗口、置顶、边缘入口、收纳预览、显示器变化、退出保存 |
| [ContentView.swift](Foldpin/ContentView.swift) | 纸片排版、常用操作、保存反馈 |
| [AppearanceSettingsView.swift](Foldpin/AppearanceSettingsView.swift) | 两种外观的原生预览选择与即时反馈 |
| [ThemeSettings.swift](Foldpin/ThemeSettings.swift) | 三种主题偏好、启动应用与即时 AppKit 外观覆盖 |
| [NotePalette.swift](Foldpin/Editor/NotePalette.swift) | 动态纸面、正文和 GitHub 风格代码配色 |
| [NoteAppearance.swift](Foldpin/NoteAppearance.swift) | 外观定义、整张 Liquid Glass 纸片、边缘入口和辅助功能回退 |
| [NoteWindowSurface.swift](Foldpin/NoteWindowSurface.swift) | 窗口级 NSGlassEffectView、同一编辑器在两种材质间切换、透明宿主与辅助功能响应 |
| [NoteWindowDecoration.swift](Foldpin/NoteWindowDecoration.swift) | 圆角细边缘、外侧柔和投影与不接收鼠标的阴影子窗口 |
| [NoteEditor.swift](Foldpin/NoteEditor.swift) | SwiftUI / AppKit 编辑器宿主、内容块入口、拖动区 |
| [NativeBlockEditor.swift](Foldpin/Editor/NativeBlockEditor.swift) | 原生块交互、撤销、菜单、图片插入 |
| [BlockTextCodec.swift](Foldpin/Editor/BlockTextCodec.swift) | 结构化内容与 NSTextStorage 互转、样式和代码高亮 |
| [NoteContent.swift](Foldpin/Core/NoteContent.swift) | 块文档、行内格式、附件引用与 schema 校验 |
| [MarkdownBlockShortcut.swift](Foldpin/Core/MarkdownBlockShortcut.swift) | 常用 Markdown 前缀与现有结构化块的输入规则 |
| [ShelfView.swift](Foldpin/ShelfView.swift) | 收纳入口与单纸片摘要 |
| [GlobalShortcut.swift](Foldpin/GlobalShortcut.swift) | 系统注册快捷键与释放，不做全量键盘监听 |
| [Core](Foldpin/Core) | 可测试的数据模型、保存流程和窗口几何算法 |
| [Tests](Tests) | 自动测试 |

正文采用 NSTextView，窗口由 NSPanel 控制，SwiftUI 负责周边界面。置顶使用普通 floating 层级，不尝试覆盖系统安全界面。窗口加入 Spaces / 其他应用全屏的具体表现仍需要测试矩阵验证。

整张玻璃使用 `NSGlassEffectView.Style.regular`，正文宿主放进 `contentView`；设置预览和收纳入口使用对应的 regular glass。材质提供背景模糊和自适应对比度，浅色/深色分别叠加 12% 白色 / 16% 黑色阅读底色。切换时保留同一个宿主和 NSTextView，通过重新挂接视图切换材质，不重建编辑器或清空撤销栈。

纸片使用无标题外框的 NSPanel，保留 resizable / closable / nonactivatingPanel 和 `canBecomeKey`。玻璃与纸感表面铺满窗口 bounds，最外层按 16 点圆角裁剪；关闭产生矩形外轮廓的系统阴影。表面有 0.75 点的淡描边，按系统深浅色调整颜色，增强对比度时加深。

纸片同时允许 `canBecomeMain`，辅助功能子角色设为 standardWindow。显式点击和主动唤出时激活应用并更新 key / main window，供外部窗口管理工具找到正确目标；不会因被动展示而激活应用。⌘M 在纸片窗口内处理，与点击折叠按钮共用保存和恢复流程，忽略长按重复事件。

外侧投影由 `NoteShadowWindow` 绘制：两个柔和阴影共用纸片圆角路径，中心镂空，避免把玻璃压暗。它作为纸片后方的子窗口，由系统随父窗口移动，缩放时更新形状。阴影窗口不能获得焦点、不接收鼠标、不参与窗口菜单；其 36 点透明绘制余量不计入纸片尺寸或保存坐标，也不扩大缩放命中区。收起时一起隐藏，恢复或切换置顶时重新确认前后层级。不要直接在已裁剪的正文层上加外阴影，或为了修复直角线而把所有投影与轮廓都移除。

上沿拖动区将原始 mouse-down 事件交给 `NSWindow.performDrag(with:)`，由 WindowServer 移动窗口。不要同时逐事件手算坐标并调用 `setFrameOrigin`。关闭背景任意位置拖动，正文和按钮保留各自交互；窗口位置通知合并后再更新 SwiftUI 观察的数据，避免拖动时每像素刷新整个纸片。

## 保存与失败处理

数据在应用沙盒的 Application Support 中，当前 Bundle ID 对应：

```text
~/Library/Containers/dev.jasonyu.Foldpin/Data/Library/Application Support/Foldpin/note.json
```

当前文件为 v2，保存稳定 ID、结构化 content、修改时间及原有窗口状态；正文纯文本、标题和摘要均从 content 派生。读取旧 v1 时在内存转为普通段落，首次写入 v2 前把原始字节备份到同目录 `backups/note-v1-<UUID>.json`，备份失败不会覆盖旧文件。旧文件缺少 `isCollapsed` 时仍按 false 读取。

图片放在同目录 `assets/<UUID>.original` 和 `assets/<UUID>.png`，分别为原始文件与预览。文档保存前确认附件文件存在。删除图片块不立即清理附件，以保留撤销 / 重做和备份的恢复能力。

折叠条的实际顶边和宽度用于更新展开坐标，34 点的显示高度不会覆盖记住的展开高度。正文编辑后约 450 ms 合并保存；窗口移动/缩放通知先合并 150 ms，再进入保存队列。折叠、收起和退出前立即记录实际窗口位置并写入，唤出时也先采纳尚未记录的位置，避免短时间内操作导致位置回跳。原子替换减少写入中断造成半个 JSON 的风险，但不等于完整备份系统。

- 保存失败：保持内存内容，纸片显示错误与重试入口；不会折叠或收起到看不到错误的地方，已折叠时展开显示错误。
- 退出前保存失败：取消退出，让用户重试，避免静默丢失内容。
- 读取失败：保留原文件，阻止编辑与覆盖，提供重试读取。
- 重启时保持之前的收纳状态；收起的纸片不会自动全部弹出。
- 本轮不提供删除、归档或自动过期操作。

## 当前范围与后续验证

已具备单纸片编辑、手动置顶、单行折叠、边缘收纳/恢复、菜单栏设置、全局快捷键注册与切换、自动保存和错误反馈。已增加原生块编辑第一阶段与清单、图片、基础代码高亮和 Markdown 输入快捷方式；完整的多纸片、搜索、Markdown 导入 / 导出、归档/废纸篓、语音和 AI 尚未实现。

验证证据与未测项见 [M1 验证记录](../docs/engineering/m1-validation.md)。真实中文输入法的候选词组合、全屏/Spaces、Stage Manager、不同显示器缩放与拔插仍应以实际设备测试为准；数据层测试不能代替这些场景。

## 官方参考

- [Preparing your app’s text for translation](https://developer.apple.com/documentation/xcode/preparing-your-apps-text-for-translation)：使用原生本地化 API，按系统语言偏好查找翻译；AppKit 与 SwiftUI 共用 String Catalog。
- [NSPanel](https://developer.apple.com/documentation/appkit/nspanel)：辅助窗口与焦点行为。
- [performDrag(with:)](https://developer.apple.com/documentation/appkit/nswindow/performdrag(with:))：将原始鼠标按下事件交给系统执行窗口拖动；方法立即返回，不依赖 mouse-up 回调保存位置。
- [nonactivatingPanel](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel)：在不激活所属应用的情况下显示面板。
- [canJoinAllApplications](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallapplications)：浮动窗口参与全屏和 Stage Manager 的系统规则。
- [Data 原子写入](https://developer.apple.com/documentation/foundation/nsdata/writingoptions/atomic)：先写辅助文件，再替换目标文件。
- [Apple 材质指南](https://developer.apple.com/design/human-interface-guidelines/materials)、[SwiftUI Liquid Glass](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)：正文材质与交互控件分层。
- 快捷键同时核对了 Xcode 26.6 本地 macOS SDK 的 `CarbonEvents.h` 中 `RegisterEventHotKey` / `UnregisterEventHotKey` 声明。
