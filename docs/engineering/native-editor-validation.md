# 原生块编辑器第一阶段验证

日期：2026-09-08。环境：Xcode 26.6 (17F113)、macOS 26.6.2、Apple Silicon；部署基线 macOS 26.5。

## 已完成

- 最终 Xcode Debug 构建成功，使用临时 DerivedData 和命令行 ad-hoc 签名覆盖；没有修改 Team、Bundle ID 或 App Sandbox。
- Swift Testing 共 **26 项通过**，包含此前保存 / 布局测试及新增块编辑检查。
- **112 个 String Catalog 键**在英文和简体中文资源中都有翻译，且均存在于最终构建产物内。
- `git diff --check` 通过；新增 Swift 文件额外检查尾随空格。

新增检查覆盖：

1. v1 读取保留字面 Markdown、中文、组合字符、emoji、CRLF、缩进与末尾空行；身份与窗口状态保持。
2. 首次 v2 写入前逐字节备份；重复保存不重复备份；备份失败保留旧文件。
3. 重复块 ID、越界格式范围和缺失图片引用被拒绝；失败不替换原文档。
4. 原生 attributed string 与结构化块往返，保留标题、勾选、行内格式、代码换行、图片和末尾空块。
5. 多行粘贴产生不同块 ID；编辑其他位置不会改变末尾空块身份。
6. 原生标题拆分后，系统撤销 / 重做恢复正文、类型与 ID；代码转正文后块索引保持有效。
7. TextKit 2 编辑器内代码回车与文字输入保留同一个代码块。
8. 图片预览 / 原图先写入，再保存文档；重读恢复同一引用，移除块后仍保留撤销需要的文件。
9. 图片边界退格先选中图片，再删除；后面的正文不丢失。

测试创建无可见窗口的 NSTextView，并使用独立临时文件。没有启动 / 重启 Foldpin，没有操作用户正在使用的窗口，没有读取或改写真实 note.json。

## 尚未完成

- 真实中文输入法候选词、组合输入及跨块选择的人工体验。
- `/` 弹出菜单的实际定位、菜单取消、键盘焦点和辅助功能朗读。
- 系统文件选择器、剪贴板与真实鼠标拖入图片的全流程。
- 新增内容块在纸感 / 玻璃、深浅色、最小窗口及中英文切换下的实际排版。
- 新编辑器与 ⌘M / ⌘W、Raycast、系统缩放、全屏 / Spaces 的集中回归。
- 多纸片内存、CPU、恢复耗时及玻璃窗口合成开销。当前应用仍是单纸片，不能给出多窗口性能结论。

## 命令与日志

从 `macOS/` 执行，具体命令见 [工程 README](../../macOS/README.md)。本轮日志在开发机临时目录：

- `/private/tmp/Foldpin-native-build.log`
- `/private/tmp/Foldpin-native-tests.log`

SwiftPM 用户级缓存目录在受限环境中不可写，已把模块缓存指向临时目录并关闭 SwiftPM 自身的嵌套沙盒；没有改变应用沙盒权限。构建日志包含模拟器服务不可用及 App Intents 元数据跳过提示，本次目标为 macOS App，最终构建成功。


## 2026-09-08 斜杠菜单删除修复

根因是自动弹出的 NSMenu 进入菜单事件跟踪，删除键没有送到 NSTextView。现改用不能成为 key / main 的原生子面板，编辑焦点留在正文。系统原生文本输入、删除与撤销继续工作；只有上下键、回车及菜单可见时的 Esc 参与建议选择。

本次 Debug 构建成功，仅运行 **3 项针对性测试，全部通过**：删除 `/` 与撤销同步、继续输入和 Esc 不收纳、方向键 / 回车转为标题且不多插换行。使用无可见窗口编辑器，没有启动或调整用户纸片；真实浮层位置、鼠标点选和输入法候选窗仍未做 UI 自动化验证。

日志：`/private/tmp/Foldpin-slash-build.log`、`/private/tmp/Foldpin-slash-tests.log`。先前的 26 项结果属于上一轮完整检查，本次未重复全部测试。

## 2026-09-08 Markdown 输入快捷方式

最终 Debug 构建成功；本次选中的 **11 项相关测试全部通过**，没有重复全部测试。范围包括 6 项 Markdown 检查、前述 3 项斜杠菜单检查，以及既有的原生拆块 / 撤销和代码换行检查。

- 行首输入一级 / 二级标题、列表、待办、引用后加空格，转换为预期块类型；支持连续输入 `- [ ] `，保留原块 ID，后续文字保持该类型。
- 代码围栏以回车或空格触发，保留代码语言，代码中的 `# ` 继续作为原文。
- 前缀后已有的中文、emoji 和行内粗体在转换后保留，光标定位正确；经 NoteStore 保存、重读 JSON v2 后类型、身份和正文一致。
- 原生撤销 / 重做恢复输入与结构，覆盖空标题、空代码块及重做后继续输入。检查中发现并修复空 attributed string 无法携带块类型的问题，使用同一个原生 UndoManager 补存空块元信息。
- 恢复的字面 Markdown、批量插入、句中符号、转义前缀、缩进、未支持的标题语法及粘贴插入路径保留原文。粘贴检查调用应用共用的纯文本插入入口，没有操作用户剪贴板；不代表系统剪贴板全流程已经验证。
- 选区替换和通过 NSTextView marked-text API 模拟的组合输入不触发转换；真实中文输入法候选窗仍属未测范围。

验证使用无可见窗口的编辑器与独立临时文件，没有启动 / 重启应用，没有操作用户纸片或真实笔记。源码空白、文档本地链接与 `git diff --check` 检查通过。

测试命令在前述 `swift test` 命令末尾加 `--filter 'markdown|slashSuggestions|nativeSplitAndUndo|typingAndCodeNewline'`。日志：`/private/tmp/Foldpin-markdown-build.log`、`/private/tmp/Foldpin-markdown-tests.log`。构建中的模拟器服务与 App Intents 提示、SwiftPM 用户缓存限制与前述相同，不影响本次 macOS 构建和选中测试结果。

## 2026-09-08 代码状态与菜单入口修复

用户反馈重开后有文字、输入带底色且 `/` 不弹出。只读检查保存文档的类型与长度元信息，确认当前纸片存为代码块；没有输出正文，也没有改写真实笔记。程序本来会恢复已有记录，新文件的默认内容是空正文。补齐清空后回正文、空代码块退格退出、光标跨块时重新设置输入样式，并让底部按钮显示当前类型，代码状态显示回正文快捷键。

最终 Debug 构建成功；一次选中 **16 项相关检查全部通过**，包含新增 5 项编辑状态检查、此前 6 项 Markdown、3 项斜杠菜单及 2 项原生编辑检查。新增覆盖：

1. 独立临时目录中新文件为空正文、没有背景属性；重读已有文件恢复原文与类型，不额外插入字符。
2. 选中并删空代码后发布空正文，undo 恢复原代码、redo 回正文；此时 `/` 可进入建议且字符无代码背景。
3. 在代码 / 空正文 / 代码之间移动光标，输入与粘贴采用目标块样式，保留块 ID；正文不带代码背景，代码中的 `/` 保持字面内容，原生粗体仍有效。
4. 空代码块 Backspace、代码中 ⌘Return 都可回到普通段落并继续调用 `/`，原代码内容保留。
5. 显式将代码转正文保留其中的字面 `/`，不把它当成待删除的菜单触发符。

新增的两条编辑提示在构建产物中均核对英文和简体中文翻译；`git diff --check` 与改动源码空白检查通过。没有启动 / 重启应用，没有改变用户窗口；真实菜单浮层显示、底部按钮排版及中文输入法仍未做本轮 UI 操作验证。

测试过滤条件：`--filter 'editingMode|markdown|slashSuggestions|nativeSplitAndUndo|typingAndCodeNewline'`。日志：`/private/tmp/Foldpin-editing-mode-build.log`、`/private/tmp/Foldpin-editing-mode-tests.log`。构建和测试环境提示同上。

## 2026-09-08 GitHub 风格代码与即时主题

设置加入独立的跟随系统 / 明亮 / 暗色选项；纸感 / 通透都支持所选主题。代码改用原生动态配色、整块圆角底色、细边线与留白，不把背景和缩进字符写入正文。最终 Xcode Debug 构建成功，ThemeSettings 的主线程隔离警告已修复；剩余模拟器服务和 App Intents 环境提示同上。

**8 项相关测试通过**，范围为 4 项新增主题 / 代码检查和 4 项既有编辑回归。发现文档末尾空代码范围位于 viewport 结束点的边界后补齐处理，单独重跑该代码表面检查也通过；未重复完整测试套件。

1. 内存偏好测试：主题立即应用、重建配置后记住选择，跟随系统清除覆盖；不改纸感 / 通透偏好，不写真实 UserDefaults。
2. 无窗口原生视图树继承明暗外观：切换后文字、结构化内容、选区、undo / redo 保留，主题动作不发布内容变更；通过 marked-text API 模拟的组合输入不被替换。跟随系统恢复 nil 外观覆盖。
3. GitHub 风格词法配色：网址和 `#` 保留字符串颜色，注释中的关键字 / 数字不被覆盖，函数名与数字着色；NSTextStorage 与 NoteContent 往返保真，字符上没有代码背景属性。
4. 代码表面：长行软换行、代码内空行、空代码块及整个文档为空代码块时，几何范围正确且背景连续；关闭 AppKit 自动暗色颜色映射。用示例内容离屏绘制了两个主题，并人工查看图片。
5. 既有清空代码后 `/` 可用、跨块样式正确、Markdown 转换撤销 / 重做、斜杠菜单删除撤销均通过。

离屏预览：[明亮](screenshots/github-code-light.png) / [暗色](screenshots/github-code-dark.png)。检查范围是原生编辑区域，不是完整设置窗口或用户正在使用的纸片截图。真实设置切换、玻璃合成、窗口层级、系统外观自动切换及真实中文输入法尚未操作验证；没有启动或重启 Foldpin，没有操作用户窗口或真实笔记。

新增 4 条主题文案及已有「跟随系统」在构建产物中均核对中英翻译；第三方许可文件已打包。`git diff --check`、Swift 源码空白与文档本地链接检查通过。

测试过滤条件：`--filter 'theme|githubCode|editingModeMoving|editingModeClearing|markdownConversion|slashSuggestionsAllowBackspace'`；离屏 PNG 仅在显式设置 `FOLDPIN_THEME_PREVIEW_DIR` 时输出。日志：`/private/tmp/Foldpin-theme-build.log`、`/private/tmp/Foldpin-theme-tests.log`、`/private/tmp/Foldpin-theme-empty-code-tests.log`。官方配色参考：[GitHub VS Code themes](https://github.com/primer/github-vscode-theme)、[主题映射](https://github.com/primer/github-vscode-theme/blob/main/src/theme.js)；许可见工程中的 ThirdPartyNotices.txt。
