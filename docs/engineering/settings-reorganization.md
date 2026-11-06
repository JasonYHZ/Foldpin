# 设置面板重整 · S1

2026-09-16：纸片与编辑已合并到外观，恢复左右双材质预览；新增正文／代码字体与字号、行距、纸感／通透背景不透明度、标准／清澈原生玻璃，以及字体与背景默认值恢复。系统标题清空并启用 hiddenTitleBar，保留页面标题。新建默认值、Markdown 开关和标题栏常显仍属后续范围。

## 参考图窗口样式修订

用户随后提供 Raycast 设置截图，要求采用其窗口效果。最终改用原生 NSSplitViewController／NSSplitViewItem(sidebarWithViewController:) 的内嵌圆角液态玻璃侧栏；保持红黄绿按钮、原生拖动／缩放与阴影。NSTrackingSeparatorToolbarItem 关联标题栏分区，侧栏玻璃延伸到窗口控制区。撤销上一版全窗 NSGlassEffectView 背景方案，避免遮住系统侧栏装饰；右侧采用动态明暗底色与原生分组表单。

当前默认 900×680 pt；最小内容约 780×560 pt，窗口包含系统工具栏安全区。侧栏范围 220–280 pt，右侧最小 520 pt。原有七类设置保持不变，不复制参考图中的账户、订阅、搜索或其他产品入口。原生蓝色选中状态与窗口装饰尊重系统，不使用私有 API。

本机 Debug 构建通过（`/private/tmp/Foldpin-settings-reference-build.log`）。更新后的隔离检查通过（`/private/tmp/Foldpin-settings-reference-native/native-check.log`），涵盖中英文明暗两种尺寸、原生两栏最小宽度、标题栏属性、快捷键跳转和原权限／资料库保持。新增原生工具栏后测试最小高度需计入 52 pt 安全区，已修正检查计量并重跑通过。

独立临时 App 的实际 WindowServer 显示已检查：暗色通用／外观、明亮外观、类别鼠标切换、主题菜单切换均正常。首次实机检查发现侧栏顶端空隙和重复标题，已通过 full-size 布局及跟踪工具栏分区修复，并重新截取实机图。正式应用没有启动或替换，测试仅使用空库、模拟登录状态和独立偏好；未注册登录项或打开 MCP。VoiceOver 完整朗读、所有辅助功能组合和多屏拖动仍未实机验收。完整对照见[标题栏视觉检查](settings-header-visual-qa.md)。

![最终暗色原生窗口](screenshots/settings-s1/reference-dark-live.png)

![最终明亮原生窗口](screenshots/settings-s1/reference-light-live.png)

以下是此前 S1 初版的过程记录；涉及窗口尺寸与玻璃结构的描述以本节为准。

## 已实现

- 唯一 SwiftUI Settings scene 保留，改为左侧原生 List 分类与右侧内容。初始 860×660 pt，最小 740×560 pt，可缩放；侧栏 200 pt。子页不再固定窗口尺寸，较长内容在本页滚动。
- 七个分类：通用、外观、纸片与编辑、快捷键、数据与存储、外部 AI 连接、关于与帮助。英文长标签允许换行。
- 语言移到通用，与登录启动放在一起；保留语言自称、即时切换、登录授权状态与错误重试。
- 外观保留主题／纸感与通透和一个合成纸片预览，去掉宣传标题及重复保存提示；继续使用原有材质与可访问性回退。
- 代码主题、主题导入／移除和背景透明度移到纸片与编辑。
- 存储与 MCP 使用自适应分组表单。帮助、版本和图标移入关于与帮助，并可查看应用随附的 ThirdPartyNotices.txt。
- 偏好键、客户端权限、库位置与原有保存／撤销逻辑未改。快捷键设置直达继续使用 showShortcuts；菜单、⌘逗号、AppKit 打开设置仍走同一 Settings scene。

源码入口：SettingsView.swift 管理分类和统一尺寸；FoldpinApp.swift 管理 Settings scene 默认大小。各页仍复用原来的视图与模型。没有添加新的全局恢复按钮，也没有开放未实现的功能。

## 验证

Debug 构建通过，日志 `/private/tmp/Foldpin-settings-s1-build.log`。仅本机 ad-hoc 构建，不代表发行审核。

1 项隔离原生检查通过：七个分类 × 中英文 × 明暗 × 两种窗口尺寸，共 56 张页面截图，并生成 4 张从通用跳到快捷键的截图；核对窗口尺寸不因跳转而改变，MCP 没有启用、没有新增授权、登录状态及资料库实例保持不变。截图检查修复了旧 Appearance 中文缺项和英文侧栏长标题截断。

复跑（不会启动正式应用）：

```sh
python3 scripts/check-library-window.py /private/tmp/Foldpin-settings-s1-native settingsNative Settings.swift
```

检查使用临时空库、独立语言／快捷键偏好域和模拟登录状态，无真实笔记、登录注册或 MCP 网络监听。原生辅助进程的“关于”截图使用其自身图标／版本，不能用作正式 App 图标验收。第三方许可资源已核对存在于构建产物。测试首次把英语选择写入与 refresh 不同的测试偏好域，导致语言回退；已修正辅助进程配置并加入语言状态断言后重跑。

以下是不可见原生窗口的内容截图，不包含系统标题栏；失焦侧栏和玻璃合成不等同于真实桌面激活态。真实指针／键盘遍历、VoiceOver 播报、系统授权面板和 Settings scene 的重开体验仍待新版实际使用验收。没有启动或替换用户正在运行的 Foldpin。

![中文外观页](screenshots/settings-s1/appearance-zh.png)

![英文编辑设置](screenshots/settings-s1/editing-en.png)

[开发方案](settings-reorganization-plan.md)

## 2026-09-16 移除顶部空白栏

用户实际 Settings 窗口仍显示右侧空白工具栏底色和分隔线。本轮在 SwiftUI Settings 根视图显式隐藏 windowToolbar 背景，并让右侧独立 hosting view 忽略顶部 safe area，使页面延伸到顶部；保留原生侧栏、窗口按钮及标题栏拖动机制。

Debug 构建和隔离布局检查通过（日志 `/private/tmp/Foldpin-settings-titlebar-build.log`、`/private/tmp/Foldpin-settings-titlebar-native-run.log`）。已准备与产品相同 Settings scene 的临时预览，但启动被自动审批拒绝，要求用户明确确认运行自签名测试应用。未启动该预览或正式实例，实际显示与拖动效果待验收；此前真实截图不能代表本轮改动。

## 2026-09-16 字体与背景个性化

2026-09-16：纸片与编辑已合并到外观，恢复左右双材质预览；新增正文／代码字体与字号、行距、纸感／通透背景不透明度、标准／清澈原生玻璃，以及字体与背景默认值恢复。系统标题清空并启用 hiddenTitleBar，保留页面标题。新建默认值、Markdown 开关和标题栏常显仍属后续范围。

- 本机偏好 `noteStyle.v1` 不写入正文、修改时间或共享资料库。正文 11–28 pt、代码 10–24 pt、行距 0–12 pt；正文可选已安装字体家族，代码限等宽字体，缺失字体回退系统字体。
- 纸感背景不透明度 20%–100%，通透阅读底色 0%–100%，独立记忆；文字和按钮不变淡。真实纸感改由原生 surface 单独绘制背景，避免两层同色叠加。减少透明度／增强对比度优先使用实色。
- 原生 NSGlassEffectView.style 和 SwiftUI Glass 统一支持 regular／clear。公开 SDK 没有模糊半径参数，不提供连续模糊度滑杆；界面使用“标准／清澈”，不把不透明度冒充模糊度。
- NSTextView 对排版通知做 60 ms 合并，组合输入期间延后；保留选区、滚动位置、正文和撤销。标题比例、列表缩进、表格字体与高度、代码 token 字体缓存同步更新。
- 外观页保留原有代码主题、导入及代码背景透明度。恢复默认只重置本轮字体／背景偏好，不改主题、纸片材质或代码主题。
- 设置窗口启用 hiddenTitleBar，并清空 navigationTitle／NSWindow.title；只显示右侧页面标题，避免“Foldpin 设置”与“外观”重叠。

验证：Debug 构建通过。隔离原生布局检查覆盖六分类 × 中英文 × 明暗 × 两尺寸，核对系统标题为空且隐藏。独立编辑回归通过，覆盖字号、代码高亮字体、表格高度、无正文写入、选区和撤销／重做、中文组合输入延期、持久化与非法值回退。日志位于 /private/tmp/Foldpin-style-settings-build.log、/private/tmp/Foldpin-style-check-output/native-check.log、/private/tmp/Foldpin-style-settings-layout/native-check.log。

所有检查使用临时数据及独立偏好；没有启动正式应用或操作真实纸片。当前变更的 WindowServer 玻璃和 Settings scene 实际标题显示仍待新版视觉验收，此前截图不代表本轮结果。

## 2026-09-16 原生标题工具栏与滚动遮罩

用户提供新的标题栏参考后，移除正文 VStack 中的页面标题，把唯一页面标题放到 NSToolbar 的无边框文字项，前置原生 NSToolbarItemGroup 前进／后退按钮。左侧仍使用 tracking separator 对齐侧栏；系统窗口标题继续隐藏，避免重复。

工具栏背景恢复 automatic，右侧滚动页使用 scrollEdgeEffectStyle(.soft, for: .top)，并恢复顶部安全区，让系统处理滚动内容进入工具栏下方的淡出与模糊。此行为是内容的边缘遮罩，不承诺整个标题栏随滚动自动消失；未使用自绘渐变假装系统模糊。依据 Apple 的 [ScrollEdgeEffectStyle](https://developer.apple.com/documentation/swiftui/scrolledgeeffectstyle) 与 [AppKit 新设计说明](https://developer.apple.com/videos/play/wwdc2025/310/)。

分类历史仅属于当前设置窗口，最多 64 条；后退后选择新分类会清除前进记录，无历史时按钮禁用。系统快捷键入口跳到快捷键分类也进入相同历史，切换语言更新当前标题和按钮文案，不重建 split controller。

Debug 构建通过，2 项隔离检查通过：六分类 × 中英文 × 明暗 × 两尺寸的原生工具栏布局、真实 NSToolbarItemGroup action 的前进／后退与宿主复用，以及历史分支／边界。日志：/private/tmp/Foldpin-settings-toolbar-build.log、/private/tmp/Foldpin-settings-toolbar-check/native-check.log。本轮未启动正式应用，WindowServer 下的真实滚动遮罩仍待新版验收，不能用离屏截图确认玻璃合成效果。

## 2026-09-16 Live Raycast comparison and header correction

The source was inspected in the running Raycast Settings window. General at rest has no visible title; Launcher at rest also hides it, then scrolling reveals a compact title immediately after the navigation arrows. The current Foldpin process was inspected without restarting: its title was trailing, always visible, and backed by an opaque horizontal toolbar band.

Changes in SettingsView.swift: mark the title toolbar item navigational, reduce title to 16 pt medium, drive its opacity/accessibility visibility from normalized scroll distance (offset plus top inset, threshold 8 pt), hide the toolbar background, and extend the detail scroll view behind the toolbar with 52 pt scroll-content top margin and soft scroll-edge effect. Returning to the top or changing categories hides the title. Only the threshold crossing updates SwiftUI state, not every scroll pixel.

Debug build and 3 native checks pass. The checks exercise actual scroll-view movement and validate title alpha at top/scrolled/top, leading title placement, language/category labels, history navigation, and controller reuse. The updated isolated Settings scene preview was built at /private/tmp/Foldpin Settings Preview.app. Its launch remains pending explicit user confirmation because an earlier automatic approval review rejected running this temporary self-signed app. The real Foldpin app was not restarted or replaced. Post-fix WindowServer composition remains unverified.
