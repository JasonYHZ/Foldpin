# 本地语法高亮引擎

2026-09-08，按用户要求接入 **highlight.js 11.11.1**，替换手写关键词高亮与 HTMLCodeHighlighter。

## 技术选择

编辑与绘制仍为 NSTextView + TextKit 2。系统 JavaScriptCore 只运行随应用打包的语法核心，返回 UTF-16 词元范围；不创建 WebView、不导入 HTML 富文本、不加载 CSS。用户代码作为函数参数传入，只解析字符串、不执行。运行时完全离线。

highlight.js 同时具备高亮和语言识别，适合当前短代码片段。Tree-sitter 更适合后续增量语法树编辑，但需另外集成语言解析器、查询和自动分类。这次采用原生界面加本地 JavaScript 语法核心，并非纯 Swift / C 解析器，也不是 IDE 的语义补全或诊断系统。

来源：[highlight.js API](https://highlightjs.readthedocs.io/en/latest/api.html)、[固定版本源码](https://github.com/highlightjs/highlight.js/tree/11.11.1)。

## 语言与识别

菜单包含 29 个语言选择：HTML/XML、Swift、Java、JavaScript、TypeScript、Python、JSON、SQL、Shell、CSS、C、C++、C#、Go、Rust、Kotlin、Ruby、PHP、YAML、Markdown、Diff、INI/TOML、Objective-C、Lua、Dart、R、Makefile、Dockerfile、GraphQL。另有自动识别与纯文本。打包 30 个语法模块，其中 php-template 为配套模块。

旧 language 原始值保持不变。新代码块默认 auto，检测结果不写入正文，手动选择优先。新语言也可使用 Markdown 围栏，支持 cpp / c++、csharp / c# / cs、rs、kt、yml、toml 等别名。

自动识别最多分析前 8,192 个 UTF-16 单元，先检查明确结构；统计比较先取 1,024 个单元，信心不足时才使用完整样本。明确的 HTML、JSON、shebang 及常用代码入口提供线索，其余由 highlightAuto 比较。专属标记优先于共享关键字，避免 Go 的 func 被当成 Swift、PHP 的 function 被当成 JavaScript、C# 的 public class 被当成 Java。Markdown、Diff、INI、Makefile、R 不参与统计竞争，但有明确文件结构时也可自动识别。相关度不足或分数接近时保留无高亮显示，短片段和相近语言仍可能识别错误。

语言识别与高亮分别处理。工具条先显示「识别中…」，识别结束后显示「自动 · Java」等结果；未能判断显示「自动 · 未识别」，悬停提示可手动选择，空块仍显示「自动识别」。标签无需等待词元生成与原生样式完成。达到高亮长度上限也继续用有限样本识别语言，悬停说明高亮暂停但正文可完整编辑、复制。

HTML 使用上游 XML 语法，支持 script 中的 JavaScript 和 style 中的 CSS。桥接通过继承上游规则，让明确 JSON / importmap script 使用 JSON 语法。颜色分类以上游为准，例如 Java long 属于类型，不再以首字母大写猜测任意类引用。

## 编辑与资源控制

- 全应用共享一个延迟创建的 JavaScriptCore context，串行后台解析。实时编辑与设置预览均异步请求；连续输入合并，在最后一次请求后约 80 ms 开始。只请求缺失结果的代码块，当前编辑块优先；取消标记传到后台，已经取消的排队请求进入 JS 前跳过。已经开始的单次 JS 调用不能中途打断，识别完成后再检查取消标记，避免继续生成过期词元。
- 词元缓存以全文、语言为键，与主题无关；NSCache 配置 64 项、2 MiB 成本限制。语言另用最多 8,192 单元的样本为键缓存，128 项 / 2 MiB 成本限制；只改样本之外的内容可复用识别结果，不反复遍历语法。超长代码不缓存全文词元。主题切换复用词元，悬浮 / 滚动只查缓存，不启动解析。
- 保留 24,000 UTF-16 单元上限，达到上限仅显示等宽文字与代码底色。新片段先显示文字，后台完成后着色；已有片段输入期间保留旧属性，避免整块反复闪回单色。
- 用户随后提出是否改为一万字符。经[离屏性能评估](syntax-performance.md)，决定保留 24,000，不降低为 10,000，也暂不直接放宽到 50,000；限制仅针对高亮，不截断正文。
- 异步结果必须匹配当前块 ID、原文和语言，只更新显示属性，不改变字符、文档、选区、撤销或正文变更通知。IME 期间延后，unmarkText 后使用当前正文与主题。
- 没有逐纸片创建 JS runtime；当前并非增量解析。多纸片 CPU / 内存基准尚未完成，后台与缓存策略不能替代实测结论。

## 主题与依赖维护

上游词元映射到 NativeCodeTheme 的常见 TextMate scope，继续兼容内置主题、VS Code JSON/JSONC 与 TextMate tmTheme。没有新增主题交换格式；完整语法栈、复杂 scope 表达式及 IDE 语义 token 仍不支持。

`macOS/Foldpin/SyntaxResources/highlight.js` 是约 307 KiB 的未压缩模块组合，上游模块内容不改写。版本、来源、原文件 SHA-256 和组合文件 SHA-256 在同目录 `highlight-manifest.json`。BSD-3-Clause 许可随应用打包。

下载官方固定版本 npm 包、解压后，可从产品根目录运行：

```sh
python3 scripts/vendor-highlightjs.py /path/to/extracted/package
```

脚本不安装 npm 依赖、不运行下载包的生命周期命令。升级前必须审查变化并修改固定版本。`foldpin-highlight-bridge.js` 是独立适配层，依赖私有 `_emitter.rootNode`，所以升级必须验证 UTF-16 范围、嵌入语言、自动识别与原文保留，不能盲目追踪 main。Xcode 和 SwiftPM 打包相同资源，构建不需联网下载依赖。

## 验证范围

2026-09-08 自动识别修复：本地小样本诊断复现了上述 Go / PHP / C# 误判及 Objective-C、Lua 等共享关键字冲突；修复后 12 项相关离屏检查通过，覆盖专属语言标记、含糊片段回退、超长代码仍识别、样本缓存复用、取消请求、工具条状态提前更新、手动覆盖、原生选区 / 撤销与 IME。补充排除 namespace 对 TypeScript 的误判后，两项标记 / 歧义检查通过；最终 Xcode Debug 构建通过，打包的桥接与源文件一致，中英文新状态资源齐全。未反复运行用户纸片，也没有据此承诺真实多窗口延迟或任意代码的识别准确率。

初次接入引擎时 Xcode Debug 构建通过，24 项相关检查通过。已核对打包后的引擎、桥接、来源 manifest 与许可证和源码字节一致；引擎组合文件 SHA-256 与固定 manifest 一致。

相关检查覆盖全部菜单语言、Unicode / CRLF 范围、结构化往返与围栏、长度上限、HTML 内 CSS / JavaScript / JSON、自动识别、手动覆盖、过期结果、原生撤销 / 选区 / IME、主题导入与切换、离屏滚动悬浮条稳定性。未反复启动用户正在运行的应用，真实键入、触控板惯性和多纸片性能仍待实际体验。
