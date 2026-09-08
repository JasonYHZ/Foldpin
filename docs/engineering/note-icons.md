# 纸片图标

2026-09-09，补充 FP-013 / FP-016 的单张纸片标识。

## 使用

鼠标移入纸片，点击标题栏正中的笑脸「添加图标」。展开时相对整个窗口居中，折叠后移到正文首个非空行标题之前。已选图标在鼠标离开后仍可见，收纳架同样展示；无图标入口随工具按钮显隐。标题栏继续 52 点高，关闭与右侧三个按钮尺寸不变。

表情面板参考用户提供的 Notion 布局：顶部仅「表情符号」与移除 / 关闭，中间搜索框及随机选择、10 列网格，底部分类栏。同一个滚动列表从 40 个常用 Emoji 开始，后面依次为表情、人物、自然、食物、旅行、活动、物品、符号和旗帜，共 1,906 个基础表情。各分组按自身内容高度首尾衔接，直接向下滚动即可浏览全部；底部分类按钮仅跳到相应标题，随滚动同步当前分组，不再替换列表。搜索时才显示过滤结果，清空搜索恢复完整列表；搜索中点击分类会清空并跳到该组。输入中英文在全部分类内搜索，例如「电脑」或 laptop。分类网格不重复展示肤色变体；在搜索框直接粘贴一个完整 Emoji，可以选择带肤色或 ZWJ 的自选组合。当前不提供图片上传、SVG 或独立图标库。

搜索框按 ↓ 进入结果，回车选择首项；网格方向键跨分组移动、空格选择，Tab 移动控件焦点；Esc / 关闭 / 点击外部取消。悬停仅改变底色，不重置键盘选择。中文 marked text 期间回车与 ↓ 继续交给输入法。未确认的搜索内容不写入纸片；每个面板绑定当前纸片，不随其他窗口焦点切换目标。

## 实现

- JSON v2 新增可选 `icon` 字段，旧文件缺省 nil，非法字符串回退 nil，读取不改原字节。图标不属于 NoteContent，不添加到 text / 摘要 / 首行标题，不改变正文修改时间。验证限制单个完整 Unicode grapheme、最多 128 字节，保留肤色、组合 Emoji、国旗与键帽。
- `NoteStore.setIcon` 共享现有合并保存、收纳 / 退出 flush、失败重试和读取失败保护；非法自选输入不覆盖现有图标，移除通过 nil 表达。
- 标题栏展开图标叠在整个标题栏中心；`NoteWindowDragView.containsDragPoint` 与原生 hitTest 排除该 26 × 28 点按钮，其他空白继续由 PaperPanel 路由给系统 performDrag。折叠按钮放在原生拖动区之前。
- 选择框采用 [SwiftUI 原生 popover](https://developer.apple.com/documentation/swiftui/view/popover%28ispresented%3Aattachmentanchor%3Aarrowedge%3Acontent%3A%29)，只在打开时创建；不重建正文 NSTextView、清理撤销或重跑代码高亮。选择图标即时更新标题栏与收纳行；正文加载入口发现内容不变时直接返回。折叠、收纳或加载失败时关闭面板。
- 所有分组共用一个 ScrollView 和单一 LazyVStack。标题行与表情行都固定为 36 点，分组高度在构造 `NoteEmojiGridLayout` 时确定；不再嵌套十个独立 LazyVGrid 或测量各组的动态边界。每行最多十个表情，按可视区域懒加载。
- 全列表只有一个 `onScrollGeometryChange`，依据实际可见区域顶部直接索引行表，返回唯一分类；不保留十组可能先后抵达的几何回调。分类仅在改变时发布，由独立底栏视图观察，更新标记不刷新整个网格，也不触发自动滚动。
- 浏览行表全应用共用只读缓存，滚动不扫描 / 过滤 1,906 个 Emoji。分组锚点、项目位置一次生成，方向键通过位置表跨行 / 跨组；常用区和原分类继续使用不同 ID。搜索内容改变时才构造结果行，排队滚动带版本校验，过期任务不能覆盖新搜索的位置。
- `NoteEmojiCatalog.shared` 仍共享本地目录与搜索索引，单格悬停状态局部更新。没有 WebView、运行时联网或每张纸片常驻一份表情库。

## 数据来源与维护

[Unicode Emoji 16.0](https://www.unicode.org/Public/emoji/16.0/emoji-test.txt) 提供 fully-qualified 序列、分类与英文名称，[CLDR 46](https://github.com/unicode-org/cldr/tree/release-46/common/annotations) 提供中文名称和关键词，补充 annotationsDerived 的组合名称。移除重复肤色变体和独立组件，保留 1,906 项；少数缺少中文名称的项回退英文。

生成结果为 274,965 字节 JSON，字形由系统 Emoji 字体绘制，未打包位图或字体。固定来源 URL、SHA-256 与输出哈希见 [emoji-sources.json](../../macOS/Foldpin/EmojiResources/emoji-sources.json)，许可见 [Unicode-LICENSE.txt](../../macOS/Foldpin/EmojiResources/Unicode-LICENSE.txt)，也随应用 ThirdPartyNotices 分发。

按 [生成脚本](../../scripts/generate-emoji-catalog.py) 中 SOURCES 下载到临时目录后执行：

```sh
python3 scripts/generate-emoji-catalog.py /path/to/source-directory
```

脚本只读取提供的来源目录，不访问网络或笔记。升级时核对版本、名称缺失、基础字符数和许可证；同步更新目录数据检查。Xcode 同步资源组可能把文件平铺，加载兼容 EmojiResources 子目录与根目录；SwiftPM 显式复制整个资源目录。资源缺失时回退 40 常用，但构建交付必须检查完整资源已打包。

## 验证

本轮针对用户反馈的卡顿与分类跳变调整了滚动路径。代码检查发现多组懒加载高度和多个分类回调会形成不稳定定位，已移除；这不等于已实测全部卡顿来源。一次 Debug 构建与 3 项 `noteEmojiGrid` 检查通过，覆盖正向 / 反向不同跨度的滚动位置、远距离分类跳转、首尾越界、全部项目与唯一锚点、跨组键盘、搜索 / 自选表情。日志分别为 `/private/tmp/Foldpin-emoji-scroll-build.log`、`/private/tmp/Foldpin-emoji-scroll-tests.log`。

本轮未启动 Foldpin、操作用户纸片或运行可见窗口；检查验证的是确定性布局 / 分类算法，不是屏幕帧率或真实触控板手感，实际改善程度仍待新版使用确认。下面保留前两轮验证记录。

连续滚动调整只做一次 Debug 构建，已通过：`/private/tmp/Foldpin-emoji-continuous-build.log`。未启动应用、操作真实窗口或重复数据测试；连续滚轮 / 触控板滚动、分类跳转、指示联动、搜索后返回与跨组键盘交互仍待实际 UI 确认。以下为前一轮数据与存储验证。

本次一次 Debug 构建通过，3 项针对性检查通过：完整目录 / 每类 / 每个表情可保存、中英文与全角英文搜索、跨分类匹配、自选组合与展示变体。应用包内资源、哈希与双语新文案检查通过。此前已完成 4 项图标存储、兼容、内容保持、失败重试及损坏文件保护检查，本次未重复。详见 [M1 记录](m1-validation.md)。

本轮未启动 Foldpin 或创建可见测试窗口。居中图标真实点击 / 拖动、popover 的键盘 / VoiceOver、中文输入法和分类滚动仍待从当前 Xcode 工程实机使用确认，构建和数据检查不等于 UI 验证。
