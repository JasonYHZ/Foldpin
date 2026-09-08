# 代码样式与公共主题格式

当前词元由 highlight.js 本地引擎提供，继续通过公共 scope 适配主题。下方旧词法扫描器记录已被[语法引擎方案](syntax-engine.md)取代，交换格式与导入边界不变。

2026-09-08。设置的「代码样式」包含下拉选择、示例预览、导入和移除导入主题。选择即时生效并记住，影响代码块的背景、文字高亮、光标与选区；不修改纸片正文或应用明暗设置。

## 内置样式

- GitHub：默认，跟随应用明暗。
- VS Code Light+、VS Code Dark+。
- Monokai。
- Solarized Light、Solarized Dark。

后五项保留主题本身的明暗配色，因此可以在明亮纸片中使用暗色代码块。原始主题 JSON/JSONC 和依赖文件随应用打包，运行不联网；文件来源与校验值见 [来源清单](code-theme-sources.json)。GitHub 配色沿用已有原生适配，Microsoft 主题的 MIT 许可已加入 [ThirdPartyNotices.txt](../../macOS/Foldpin/ThirdPartyNotices.txt)。

## 导入

使用已有的 [VS Code Color Theme 格式](https://code.visualstudio.com/api/extension-guides/color-theme)（`.json` / `.jsonc`），兼容 TextMate `.tmTheme` plist。不定义 Foldpin 专属主题扩展名或交换协议。

获取文件的一种方式：在 VS Code 选好主题后，运行 **Developer: Generate Color Theme from Current Settings**，保存生成的 JSON。也可从主题作者发布的源码中获取主题文件。导入的是主题配置文件，不是扩展的 `package.json`，也不是 `.vsix` 安装包。

点击「导入主题…」并选择文件。如果包含 `include` 或外置 `tokenColors`，再选择包含主题及依赖的共同文件夹。解析完成后复制为不依赖外部文件的标准 VS Code 主题 JSON，存于应用 Application Support 下的 `Foldpin/CodeThemes`；不会修改原文件。相同主题内容不会重复添加；移除只删除应用自己的副本，并回到 GitHub。

## 兼容范围

- 支持 JSONC 注释、尾逗号，正确保留字符串中的 URL、引号和注释样式字符。
- 支持 VS Code `colors` 的代码背景、前景、代码边线、光标、选区；TextMate 无 scope 的前景 / 背景设置。
- 支持 `tokenColors` 数组、逗号分隔 / 数组 scope、常见点分 scope 与祖先选择器；高亮类别为当前词法扫描器的注释、字符串、关键字、数字、函数。
- 支持高亮词元的 `fontStyle`：粗体、斜体、下划线、删除线。不同语言使用对应的 `source.*` 进行有限映射。
- 支持本地相对 `include` 和外置 `.tmTheme` 引用；继承后当前主题的颜色覆盖基主题，词元规则按匹配具体程度及顺序应用。
- 不运行 VS Code 扩展、TextMate 语法或语言服务器。复杂 scope 表达式、semanticTokenColors、编辑器侧栏等工作台样式不参与渲染，因此并非所有主题效果都能逐项复刻。保存的本地副本只保留当前适配器读取的标准主题字段。

导入在后台读取，单文件最多 2 MiB、最多读取 16 个文件、总计最多 16 MiB、引用深度少于 8；只读取所选文件 / 获授权文件夹内的依赖，拒绝循环引用、远程引用及越界路径。标准十六进制颜色支持 `#RGB`、`#RGBA`、`#RRGGBB`、`#RRGGBBAA`。缺失或不支持的配色使用与主题明暗一致的默认值。解析或保存失败保持当前选择。

## 即时更新与验证

代码背景不透明度可在设置中从 0% 调到 100%，默认 100%，实时生效并以 `codeBackgroundOpacity` 保存为应用偏好。0% 透出下面的纸片材质，100% 使用主题原始底色；主题文件已含 alpha 时，最终 alpha 是两者乘积。只降低背景填充的不透明度，细边框、文本高亮、光标、选区和语言 / 复制工具条保持原样。设置预览采用同样的背景层混合，不变更公共主题文件或笔记数据。

滑杆走独立通知，使已有编辑器 `needsDisplay`，不调用 `refreshStyles`、语法引擎或属性渲染；原生绘制在填充背景前保存图形状态、设置 alpha，完成填充后立即恢复，避免影响后续边线与文字。更换主题也保留该偏好。

背景不透明度专项验证（2026-09-08）：Debug 构建及两项相关离屏检查通过。实际位图采样覆盖明暗外观下 0% / 40% / 100% 与导入主题 alpha 相乘；同时验证偏好重开、切换主题保留数值，以及正文、字符属性、选区、undo / redo、组合输入保留。新增两条文案的中英打包翻译匹配。日志为 `/private/tmp/Foldpin-code-opacity-tests.log` 和 `/private/tmp/Foldpin-code-opacity-build.log`；没有启动或操作用户窗口，实际滑杆操作与桌面玻璃叠加尚未实机验证。

`CodeThemeSettings` 管理主题与导入副本，通过通知刷新已有 NSTextView 的显示属性；热路径使用已解析的主题和缓存词元样式。保持同一个编辑器、正文、块 ID、选区和撤销记录。输入法组合期间不重写文字属性，组合完成后采用最新主题。设置预览使用同一原生颜色和高亮适配器，不读取用户笔记。

最终 Debug 构建通过。9 项相关测试通过，包含 7 项新增代码主题检查和 2 项既有主题 / 高亮回归：格式与颜色、scope 优先级、TextMate 与标准 JSON 往返、依赖与路径边界、内置资源、导入去重 / 重开 / 删除 / 写入失败、编辑器即时刷新与 undo / redo / 组合输入、固定暗色主题在明亮应用中光标仍可读。18 条相关文案的中英打包翻译逐项匹配；7 个内置主题文件及依赖与源码字节一致。

日志：`/private/tmp/Foldpin-code-themes-build.log`、`/private/tmp/Foldpin-code-theme-tests.log`。测试过滤条件：`codeTheme|githubCodeColors|themeSwitchPreserves`。构建只剩既有模拟器服务与 App Intents 环境提示。未启动或操作用户窗口；实际设置布局、文件选择面板授权和真实中文输入法尚未专项实机验证。没有修改真实主题偏好或笔记。

HTML 已接入标签、属性、标签标点和实体的常见 TextMate 作用域，HTML 根作用域为 `text.html.basic`；`script` 内的基础 JavaScript / JSON 使用对应语言高亮。仍是本地词法适配，未实现完整 HTML/CSS/模板语法引擎。
