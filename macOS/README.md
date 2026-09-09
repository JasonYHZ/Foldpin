# Foldpin macOS · 原生多纸片原型

**菜单操作：** ⌘K 和 `/` 现在使用同一配色。「纸片颜色」按 → 或点击展开侧边子菜单，↑↓ / Enter 选色，← / Esc 返回主菜单；⌘1–⌘6 仍可直接选色。⌘K 内新增「创建纸片副本」，图文、颜色、表情和置顶状态复制到独立纸片。

正文选中文字后右键可加粗、斜体、删除线、行内代码、清除格式或转换块类型。图片 / 表格 / 分隔线直接右键打开对应块菜单；表格单元格右键新增当前位置上下行 / 左右列、删除当前行列，至少保留一行一列；代码菜单提供语言和复制代码，待办菜单可切换完成。均保留原生数据与撤销路径。

**设置纸片图标：鼠标移入窗口，点击标题栏正中的笑脸。** 表情面板从 40 个常用 Emoji 开始，各分类连续排列，可向下滚动浏览全部 1,906 个基础表情；底部分类按钮可快速跳到对应位置，并随滚动更新当前分类。输入中英文搜索或直接粘贴一个表情；支持随机选择和移除。展开时图标居中，折叠时显示「图标 + 首行标题」，收纳架同步显示，每张纸片独立记住。全部本地运行，仅提供 Emoji。详见[纸片图标](../docs/engineering/note-icons.md)。

Emoji 连续滚动现使用单一懒加载列表与固定行高，分类指示统一从实际滚动位置计算；底栏变化不再刷新整个表情区域。一次构建和 3 项布局 / 分类定位检查通过，本轮未启动窗口或进行屏幕帧率测量。

2026-09-09 纸感夜间配色改为暖米色 / 牛皮纸色与深色墨迹；标题栏、占位、引用、链接、表格编辑及状态文字一并匹配纸面。细边框和阴影保留，代码块 / 设置 / 系统菜单继续使用各自主题；切换仍即时生效，不重建编辑器。

**更换颜色：右键点击纸片标题栏的空白处**，选择原色 / 黄 / 绿 / 蓝 / 粉 / 紫；也可从屏幕顶部 Foldpin 图标 →「纸片颜色」更改当前纸片。每张独立记住颜色，纸感显示彩色纸张，通透使用淡染色玻璃；夜间保留色相。详见[纸片颜色说明](../docs/engineering/note-colors.md)。

标题栏现随鼠标进入整张纸片显示、离开淡出：左侧圆形关闭，右侧置顶 / 折叠 / 收起位于胶囊工具条。折叠标题和拖动区不随显隐移动；按钮焦点 / VoiceOver 保持可达，减少动态效果时取消动画。Debug 构建与隔离窗口检查通过，没有操作真实笔记。

标题栏视觉调整：保留 92 × 36 点胶囊，分别校正图标大小与亮度、减淡置顶底色，关闭圆心对齐正文起点。展开 / 折叠标题栏均为 52 点高，按钮尺寸、留白和位置保持一致。窗口圆角统一为展开 28 点 / 折叠 26 点，玻璃、原生裁剪、描边和阴影共同适配。图标与圆角调整此前已完成一次暗色隔离窗口检查，查看展开 / 置顶 / 折叠截图，并通过原有编辑器、撤销与窗口快捷键检查。随后统一标题栏高度的改动通过构建和 5 项折叠几何 / 保存恢复检查；本次没有启动窗口或操作用户笔记。

激活 Foldpin 后按 **⌘N** 新建纸片；菜单栏「新建纸片」与收纳架「＋」也可创建。⌘W 保存并收纳当前纸片，⌘M 独立折叠；菜单栏「打开收纳架」找回任意纸片。「收起所有纸片」只操作当前可见集合。表格底部与右侧加号分别增行 / 列，六点菜单增加标题行 / 标题列。架构、迁移与验证见[多窗口说明](../docs/engineering/multi-note-windows.md)。

2026-09-08 性能整理已完成代码属性缓存、差异更新、事件内几何复用、表格局部刷新与界面状态去重。125 项检查和 Debug 构建通过；1 / 10 / 30 张合成原生窗口的内存与主线程操作已做前后对照。见[优化与性能报告](../docs/engineering/editor-performance.md)。下文“多纸片未测”是此前阶段记录；该报告为多窗口接入前的组件负载记录，GPU 完整帧率仍未验证。

普通 ⌘V 支持 Markdown 自动转换；⌘⇧⌥V 或「编辑 → 粘贴为纯文本」保留源字符。代码块和表格单元格内按字面文本粘贴。范围、原生插入和保存行为见 [Markdown 粘贴](../docs/engineering/markdown-paste.md)。

区块书写现支持类型占位提示、空标题回车返回正文与 Shift+Enter 块内换行；占位文字不会保存。菜单提示去掉「+ 空格」，代码围栏也接受 `···` / `｀｀｀` 加空格或回车。换行规则、原生存储方式及块手柄 / 排序建议见[区块书写说明](../docs/engineering/block-writing-behavior.md)。

`/` 建议菜单已按 Notion 参考优化分组、图标、输入提示与选中样式，支持中英文、明暗和短视口滚动。保持原生非激活浮层及 Backspace / 回车 / Esc 行为，只展示已支持区块；引用新增 `"` + 空格并兼容 `>`。截图和范围见[原生菜单记录](../docs/design/native-block-menu/README.md)。

代码高亮已升级为 highlight.js 11.11.1 + 系统 JavaScriptCore，本机后台处理；编辑器仍为 NSTextView / TextKit 2。29 个语言选择、自动识别和现有主题共用同一引擎。资源随 Xcode / SwiftPM 打包，构建不需下载新依赖。见[语法引擎说明](../docs/engineering/syntax-engine.md)，下方旧词法扫描器描述为历史状态。

自动识别现独立缓存有限样本，取消的排队任务进入引擎前跳过，当前块优先处理。工具条区分「识别中」「自动 · 未识别」和语言结果，识别出的语言无需等高亮完成；长代码暂停高亮时仍可识别语言。修正 Go / C# / PHP 等与共享关键字冲突的误判，手动指定仍优先。

本次引擎升级：Debug 构建与 24 项相关检查通过，四个引擎资源打包内容已核对。未启动用户应用做反复 UI 测试，多纸片性能未做基准测试。

随后已做单代码块离屏长度评估，保留 24,000 UTF-16 高亮保护上限，不降低为一万字符；正文不会截断。结果与复现方式见[高亮性能记录](../docs/engineering/syntax-performance.md)，多纸片与真实滚动性能仍未测量。

光标退出代码块：纸片末尾代码的末端按 ↓ / →，或点击代码下方空白可进入正文；纸片开头代码的起点按 ↑ / ← 可在上方继续写。⌘Return / ⌘小键盘 Enter 可直接进入后方正文。原代码与撤销保留，打开笔记不会自动补空行。见[代码块导航说明](../docs/engineering/code-block-navigation.md)。

2026-09-07。以已创建的 macOS App 工程为基础，实现第一张原生纸片。当前是技术原型，不是 PRD 中全部 P0 已完成的 MVP。

## 运行

Git 仓库根目录是产品目录 `../`，统一管理本文、工程、PRD 与设计资料；本目录不再是独立嵌套仓库。下文构建和测试命令仍从本目录执行。

使用 Xcode 打开 [Foldpin.xcodeproj](Foldpin.xcodeproj)，Scheme 选择 **Foldpin**，运行目标选择 **My Mac**，按 **⌘R**。

- 实测工具链：Xcode **26.6 (17F113)**。
- 当前机器：macOS **26.6.2**，Apple Silicon。
- 保留用户创建的最低系统版本：**macOS 26.5**。尚未评估更早系统支持。
- 保留用户的 Team、自动签名和 Bundle ID：`dev.jasonyu.Foldpin`。
- 保留 App Sandbox 与 Hardened Runtime；没有新增网络、麦克风、辅助功能或输入监听权限。

第一次打开是空白纸片，可以直接写。顶部左侧为关闭按钮，右侧依次为置顶、折叠、收起，均为图标。折叠后纸片留在桌面，缩成与标题栏等高的 52 点单行纸条；再点击展开恢复原大小，也可双击顶部空白区切换。收起后屏幕右侧出现 `1` 的入口，点开摘要，再选“贴回原处”。按 Esc 收起；左侧关闭同样收起，不删除内容。

折叠条中间显示正文第一行内容（跳过空白行），长标题自动省略，悬停可看完整标题；没有内容时显示「空白纸片」。标题区域仍可以拖动和双击展开。折叠条可以水平缩放和切换置顶，重启保留折叠状态和展开尺寸。从收纳「贴回原处」保留折叠状态；菜单「打开纸片」和全局快捷键会展开纸条，方便继续输入。

标题栏空白处用于移动纸片，靠近四边或四角时用缩放光标调整大小；折叠条仅左右两边可调整宽度。2026-09-08 补上纸感原生实色底层与无边框窗口的边缘缩放处理；本轮只做隔离检查，实际指针操作的已测 / 未测范围见 [M1 验证记录](../docs/engineering/m1-validation.md)。

默认全局快捷键为 **⌃⌥Space（Control + Option + 空格）**：隐藏时唤出纸片；正在编辑时再次按下收起。同一张纸片已经显示但没有输入焦点时，快捷键先让它进入编辑。也可以从菜单栏 Foldpin 图标进入，或在菜单中换成 **⌃⌥N**。如果注册失败，菜单会提示更换组合。

2026-09-09：底栏左侧显示保存状态，右侧为「操作 ⌘K」。点击或按 **⌘K** 打开纸片 / 应用操作面板（折叠条也支持），底部搜索，**↑ / ↓** 选择、**回车** 执行、**Esc / ⌘K** 关闭。可找到新建、置顶、折叠、收纳、表情、颜色、收纳架、全部收纳、设置、唤出快捷键配置、复制全部与删除当前纸片。它独立于正文 `/` 菜单。

激活纸片后**单独长按 ⌘ 约半秒**，标题栏按钮原位显示配合键，松开或开始组合键即消失；普通复制粘贴不触发延迟提示。仅在当前纸片观察本地事件，不增加输入监听权限。

| 操作 | 快捷键 |
| --- | --- |
| 操作菜单 | ⌘K |
| 新建纸片 | ⌘N |
| 折叠 / 展开 | ⌘M |
| 关闭并收纳当前纸片 | ⌘W |
| 置顶 / 取消置顶 | ⌘⇧P |
| 添加 / 更改表情 | ⌘⇧I |
| 原色 / 黄 / 绿 / 蓝 / 粉 / 紫 | ⌘1 / ⌘2 / ⌘3 / ⌘4 / ⌘5 / ⌘6 |
| 复制全部图文 | ⌘⇧C |
| 收纳架 | ⌘⇧O |
| 设置 | ⌘, |
| 删除当前纸片 | 从操作菜单选择 |

面板右下角对齐操作按钮，向左上展开，不带气泡箭头；列表在小纸片内滚动。颜色可按 → 展开侧边子菜单，← / Esc 返回，也可直接按数字快捷键选择。复制全部同时提供 RTFD / HTML / 纯文本 / Foldpin 区块结构，支持图文混排；目标应用选择其支持的格式，Foldpin 内粘贴保留区块结构。

「删除当前纸片」移入收纳架底部的「最近删除」，展开后点击「恢复纸片」找回。保留正文、图片与窗口偏好，重启后仍可恢复；暂无永久删除或自动清理。⌘W 保持收纳语义。退出应用保留在菜单栏，不再出现在纸片操作列表。

操作仍使用原有保存与只读保护，设置 / 其他应用保留原生窗口快捷键。保存状态上的悬停提示保留全局唤出组合及注册错误信息。

**⌘M（Command + M）**：纸片获得焦点时，在一行折叠条和展开正文之间切换。先点击纸片，再使用 Raycast 或系统窗口调整快捷键。纸片已按标准窗口参与识别；本轮实际检查了 Raycast 的 Left Half 和系统窗口菜单的左半屏 / 恢复尺寸操作。⌘M 不注册为全局热键，其他应用保持自己的快捷键行为。

**⌘W（Command + W）**：关闭当前获得焦点的窗口。纸片（包括折叠条）会先保存再收纳，内容保留；保存失败时保留窗口和重试入口。设置窗口沿用系统关闭行为。⌘W 不注册为全局热键。

这一版只维护一张纸片。“打开纸片”始终找回同一条记录，不清空内容，也不会悄悄新建第二张。

跨屏高度问题仍是间歇性反馈，折叠 / 展开后用户暂未再次复现。现已加入拖动前的缩放会话清理和尺寸上下限核对，并在 Debug 的 `WindowGeometry` 分类记录不含笔记内容的尺寸诊断；仅完成构建，未宣称已复现或解决。不要按应用名称启动旧实例来验证，使用当前 Xcode 工程运行。

## 原生块编辑器（2026-09-08）

设置 →「代码样式」可选择 GitHub、VS Code Light+ / Dark+、Monokai、Solarized Light / Dark，选择后立即更新。导入支持 VS Code `.json` / `.jsonc` 与 TextMate `.tmTheme`；涉及依赖文件时会提示选择共同文件夹。导入后保留本地副本，可移除，不修改原文件。默认 GitHub 跟随应用明暗；其他样式使用自己的配色。完整支持范围与获取文件的方式见 [公共主题格式说明](../docs/engineering/code-theme-formats.md)。

在空段落输入 **/**，或点击编辑区域底部的内容块按钮，可选择正文、四级标题、项目列表、有序列表、待办、引用、分隔线、表格、代码块或图片。右键也有内容块菜单。表格默认 2 列 3 行，直接编辑单元格，Tab / Shift-Tab 切换，末格 Tab 加行，⌘Return 返回正文；六点菜单可增列 / 增行。见[列表、分隔线与表格](../docs/engineering/lists-dividers-tables.md)。

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
| `###` + 空格 | H3 三级标题 |
| `####` + 空格 | H4 四级标题 |
| `-` / `*` / `+` + 空格 | 无序列表 |
| `1.` + 空格 | 有序列表，回车续号 |
| `---` + 回车 / 空格 | 分隔线，并进入后方正文 |
| `[]` / `[ ]` + 空格 | 未完成待办；也支持连续键入 `- [ ] ` |
| `[x]` / `[X]` + 空格 | 已完成待办 |
| `>` + 空格 | 引用 |
| 三个反引号 + 回车或空格 | 代码块；反引号后可接 `swift`、`js`、`ts`、`python`、`json`、`sql`、`shell` 等现有语言 |

转换去掉输入前缀，保留后续文字和可用格式，光标继续留在当前块，可用 **⌘Z / ⇧⌘Z** 撤销 / 重做。正文仍存为结构化 JSON；这些是输入快捷方式，不会自动把粘贴内容或旧笔记当 Markdown 解析，也不在句中、代码块内、选区替换或输入法组合期间触发。当前支持四级标题，尚无嵌套列表、行内 Markdown 自动转换或完整 Markdown 导入 / 导出。

第一阶段使用 **NSTextView + TextKit 2**，没有 WebView 或第三方编辑器依赖。六点手柄现可直接拖动调整区块顺序，蓝线表示插入位置，靠近上下边缘自动滚动；Esc 取消，⌘Z 撤销移动。现支持多纸片；语音、多块 / 跨纸片拖动、嵌套列表、图片图注 / 原图预览和多纸片休眠尚未实现。实际 UI 的已测 / 未测边界见 [原生编辑器验证](../docs/engineering/native-editor-validation.md)。

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
| [ShelfView.swift](Foldpin/ShelfView.swift) | 多纸片收纳列表、状态与新建入口 |
| [NoteLibrary.swift](Foldpin/Core/NoteLibrary.swift) | 独立纸片文件与安全迁移 |
| [PaperWindowController.swift](Foldpin/PaperWindowController.swift) | 单张纸片窗口、保存、折叠与撤销生命周期 |
| [PaperPanel.swift](Foldpin/PaperPanel.swift) | 原生窗口事件、拖动、缩放与快捷键 |
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
~/Library/Containers/dev.jasonyu.Foldpin/Data/Library/Application Support/Foldpin/notes/<UUID>.json
```

旧根目录 `note.json` 首次启动时先备份到 `backups/legacy-note-<UUID>.json`，迁移到独立 UUID 文件，原文件保留；`library-migration.json` 记录完成状态。所有纸片共用根目录 `assets/`，保留既有图片引用。

当前文件为 v2，保存稳定 ID、结构化 content、修改时间及原有窗口状态；正文纯文本、标题和摘要均从 content 派生。读取旧 v1 时在内存转为普通段落，首次写入 v2 前把原始字节备份到同目录 `backups/note-v1-<UUID>.json`，备份失败不会覆盖旧文件。旧文件缺少 `isCollapsed` 时仍按 false 读取。

图片放在纸片库根目录 `assets/<UUID>.original` 和 `assets/<UUID>.png`，分别为原始文件与预览。文档保存前确认附件文件存在。删除图片块不立即清理附件，以保留撤销 / 重做和备份的恢复能力。

折叠条的实际顶边和宽度用于更新展开坐标，52 点的显示高度不会覆盖记住的展开高度。正文编辑后约 450 ms 合并保存；窗口移动/缩放通知先合并 150 ms，再进入保存队列。折叠、收起和退出前立即记录实际窗口位置并写入，唤出时也先采纳尚未记录的位置，避免短时间内操作导致位置回跳。原子替换减少写入中断造成半个 JSON 的风险，但不等于完整备份系统。

- 保存失败：保持内存内容，纸片显示错误与重试入口；不会折叠或收起到看不到错误的地方，已折叠时展开显示错误。
- 退出前保存失败：取消退出，让用户重试，避免静默丢失内容。
- 读取失败：保留原文件，阻止编辑与覆盖，提供重试读取。
- 重启时保持之前的收纳状态；收起的纸片不会自动全部弹出。
- 本轮不提供删除、归档或自动过期操作。

## 当前范围与后续验证

已具备多纸片新建、独立编辑与保存、手动置顶、单行折叠、边缘收纳/恢复、菜单栏设置、全局快捷键注册与切换、自动保存和错误反馈。已增加原生块编辑第一阶段与清单、图片、基础代码高亮和 Markdown 输入快捷方式；纸片全文搜索、Markdown 文件导入 / 导出、归档、永久删除、语音和 AI 尚未实现；最近删除与恢复已支持；剪贴板 Markdown 解析已支持。

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

### 代码块语言与悬浮工具条（2026-09-08）

Java 已支持自动识别、手动选择及 java 围栏，原生高亮包括关键字、类型、注解、方法、字符串 / 文本块和数字。滚动闪烁修复把工具条放在滚动区域上层，只更新定位，不再逐帧隐藏、显示。构建及相关离屏检查通过，未反复启动用户窗口。

鼠标移到代码块上，右上角显示语言菜单和复制按钮。新代码块默认自动识别，输入 / 粘贴代码后按本机识别结果着色，工具条显示「自动 · HTML」等状态。也可手动选择语言；明确选择纯文本会关闭着色。旧块保留原选择，可从菜单改为自动识别。选择模式随块保存；三个反引号不带语言时创建自动块，带 html / text 则明确指定 HTML / 纯文本。选择语言可撤销，复制保留原文与缩进。工具条操作悬浮块，不移动别处的编辑选区；主题和界面语言保持即时更新。

实现与验证边界见 [代码工具条记录](../docs/engineering/code-block-toolbar.md)。
