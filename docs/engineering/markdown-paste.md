# Markdown 粘贴

2026-09-08，用户要求普通粘贴自动识别 Markdown，转成可继续编辑的原生区块。

## 使用

- ⌘V：识别剪贴板文本里的 Markdown。普通文字保持原样；代码块和表格单元格内保持字面文本。
- ⌘⇧⌥V，或「编辑 → 粘贴为纯文本」：保留原始字符，正文右键也有对应入口。
- 支持光标处插入、替换选区和跨块替换；保留选区两侧文字及行内格式，粘贴一次可原生撤销。
- Foldpin 自身复制的区块优先读取结构数据，生成新块 ID，不再次解析 Markdown。直接粘贴图片沿用本机图片导入流程。

## 格式范围

| Markdown | Foldpin 结果 |
| --- | --- |
| `#` 至 `####` 标题、Setext 标题 | H1–H4 原生标题 |
| `-` / `*` / `+` 列表 | 项目符号列表 |
| `1.` / `1)` 等有序列表 | 连续编号的有序列表，编号由显示层生成 |
| `- [ ]` / `- [x]` | 可切换的待办块 |
| `>` 引用 | 引用块，同段换行保存在同一块 |
| 反引号或波浪号围栏、缩进代码 | 原生代码块；语言别名复用现有映射，未指定 / 未知语言自动识别 |
| `---` / `***` / `___` | 原生分隔线 |
| 管道表格 | 可编辑的原生表格，保留空单元格 / 空行；表头作为第一行导入 |
| 粗体、斜体、行内代码、删除线、链接 | 对应文字样式及链接地址，结构化保存 |

H5 / H6、嵌套列表子项、HTML 和远程图片使用原文保留路径。不会把图片地址丢成只有 alt 文本，也不会在解析时下载图片或执行 HTML。表格单元格目前是纯字符串，导入文字值，链接地址同时保留为可见文字；不承诺单元格富文本、列对齐或嵌套块模型。链接只为 http / https / mailto 添加可点击属性，其他协议保留 Markdown 原文。

普通文本没有被识别的格式时使用原有字面粘贴；Markdown 段间空行用于结构分隔，不逐个变成空区块。尚不支持的源片段保留文字，解析失败回退字面文本。

## 实现

`MarkdownPasteParser` 调用 Foundation 的 `AttributedString(markdown:options:)`，根据 PresentationIntent 与 InlinePresentationIntent 映射现有模型。接口提供段落、标题、列表、代码、表格和行内语义，见 [Apple NSPresentationIntent 文档](https://developer.apple.com/documentation/foundation/nspresentationintent)与[解析选项](https://developer.apple.com/documentation/foundation/attributedstring/markdownparsingoptions/interpretedsyntax-swift.property)。关闭扩展属性，只解析剪贴板字符串，不使用 URL 内容加载接口，不增加包依赖、WebView 或 JS 渲染。

Foundation 不为某些空节点输出字符，适配层结合源行号恢复空标题 / 简单空围栏，保留无法表达的原始片段，按源范围恢复表格空行列。转换后的 `NoteContent` 经 `BlockPasteInsertion` 在选区处拼接，一次 `replaceDocument` 进入现有 NSTextView / TextKit 2 原生撤销，不在逐字输入时运行文档解析。块内换行使用既有 U+2028，代码内部保留 LF。

JSON v2 / content schema 1 继续沿用。`NoteTextMark` 增加可缺省的 code、strikethrough、link，旧文件缺失字段按 false / nil 读取；块拆分、斜杠插入、复制与移动保留所有标记。旧版应用不认识新字段，不保证旧版再次保存后保留新增格式。视觉属性由 BlockTextCodec 重建，结构插入先清除旧输入链接 / 背景，避免样式传染到新块。语法高亮继续使用现有引擎与长度策略。

## 验证

macOS 26.6.2 / Xcode 26.6：18 项相关离屏检查和 Xcode Debug 构建通过，包含基本格式、Unicode 标记、CRLF、空标题 / 空代码 / 空表格行、语言别名、原文回退、代码 / 单元格字面粘贴、只读 / 组合输入、光标及跨块选区、撤销重做、旧标记解码、新格式读写及斜杠回归。未读写真实笔记或系统剪贴板，没有操作用户窗口；真实剪贴板多类型优先级、菜单快捷键、链接点击与中文候选面板仍待新版使用确认。
