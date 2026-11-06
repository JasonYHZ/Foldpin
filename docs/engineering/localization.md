# 多语言设置与验证

2026-11-06：在现有简体中文、英文上增加繁体中文、日语、韩语、德语、法语、西班牙语。直接在 main 的现有设置与资源中扩展，没有新增窗口、翻译服务或联网翻译流程。

## 使用方式

「设置 → 通用 → 语言」提供跟随系统，以及以下八种语言；用各语言自称显示选项，切换后仍可识别：

| 语言 | 选项 | 标识 |
| --- | --- | --- |
| 简体中文 | 简体中文 | zh-Hans |
| 繁体中文 | 繁體中文 | zh-Hant |
| 英文 | English | en |
| 日语 | 日本語 | ja |
| 韩语 | 한국어 | ko |
| 德语 | Deutsch | de |
| 法语 | Français | fr |
| 西班牙语 | Español | es |

沿用 LanguageSettings 的单个 configuration 发布和 AppKit 菜单原位更新。语言仅保存到本应用 AppleLanguages 偏好，不修改全局语言、不翻译笔记正文、不重建正文编辑器。已有使用说明纸片是普通笔记，仍保留创建时的语言；不会因切换覆盖用户编辑。

跟随系统用 Foundation 的地区/文字匹配：台湾、香港匹配繁体中文，日本、韩国及德法西语地区变体匹配对应语言。没有可支持语言时回退英文；语言选项与匹配共用 AppLanguage 标识列表。MCP 的 update_settings 语言参数同样来自 AppLanguage，保留原主题和其他参数限制。

## 文案范围

Localizable.xcstrings 的 738 个条目补齐六种新语言，覆盖设置、纸片与收纳、菜单、编辑区块、搜索、导入导出、错误、删除确认、MCP 本机授权、使用说明及辅助功能标签；语言中性的产品名、数字格式和空字符串保持一致。InfoPlist.xcstrings 补齐麦克风权限说明。繁体版本在简繁文字转换后调整了檔案、資料夾、快速鍵、剪貼簿、匯入／匯出等用语。

系统提供的菜单和授权窗口仍由 macOS 处理，不承诺所有系统控件在运行中立即切换。Emoji 数据仍沿用已打包的中英文名称与搜索词，新语言的分类和控件已翻译，单个 Emoji 名称未增加六套 CLDR 数据；非中文界面沿用英文名称。

## 验证

环境：macOS 27.0.1、Xcode 27.2、Apple Silicon。

- 临时 Debug 应用构建通过，包含八个 lproj；没有启动或替换用户正在运行的应用。
- 八种语言的文案覆盖率及 printf 参数数量、类型检查通过。
- 对编译产物逐项核对 5,912 个界面/麦克风文案值，通过。检查兼容 Xcode 对源语言格式串参数位置的处理。
- 3 项新增 LanguageSettingsTests 通过，覆盖即时 bundle 切换、重启持久化、清除本应用覆盖、系统地区/文字匹配、英文回退、刷新偏好及 MCP 参数；相关 15 项 MCP 回归同时通过，共 18 项。
- git diff --check 通过。

新增测试只使用独立偏好域、合成语言 bundle 和临时文件，未修改真实笔记或系统设置。新语言尚未经母语使用者校对、逐屏桌面排版、中文/日韩 IME 或 VoiceOver 实机验收；构建和资源检查不替代这些检查。

在仓库根目录复核：

```sh
python3 scripts/check-localizations.py
python3 scripts/check-localizations.py --app /absolute/path/Foldpin.app
```

从 macOS/ 执行已有 SwiftPM 测试命令并加 `--no-parallel --filter 'LanguageSettingsTests|MCPTests'` 可复核相关行为。完整构建命令见该目录 README。

本次临时日志：`/private/tmp/Foldpin-languages-build-final.log`、`/private/tmp/Foldpin-languages-and-mcp-tests.log`。测试文件与翻译校验脚本均已保留在仓库；新增文案应同步维护八种语言并运行校验。
