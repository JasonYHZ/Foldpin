# 多纸片窗口与表格设置

2026-09-08，用户确认接入多窗口，并要求表格支持直接增行列及专用块菜单设置。

## 使用

- 激活 Foldpin 后按 **⌘N** 创建空白纸片；菜单栏「新建纸片」、收纳架右上「＋」是同一入口。每张纸片有独立内容、位置、大小、置顶和折叠状态。
- **⌘W** / 左上关闭按钮保存并收纳当前纸片，**⌘M** 折叠或展开当前纸片。关闭不删除内容。设置窗口继续使用系统关闭行为。
- 菜单栏「打开收纳架」查看全部纸片；每项显示首行摘要、置顶和「桌面上 / 已收纳」状态，点击找回或聚焦对应纸片。已有纸片复用原窗口和编辑器。
- 「收起所有纸片」保存并收纳当前可见纸片，保存失败的纸片保持可见。应用退出会保存每张纸片；任一保存失败时取消退出。
- 重启只显示上次未收纳的纸片，恢复置顶、折叠和窗口几何；收纳纸片按需创建窗口。显示器变化时逐张校正到可达区域。
- 原全局唤出 / 收纳快捷键操作当前或最近活动纸片；普通 ⌘N / ⌘M / ⌘W 不注册为全局快捷键。

表格悬停或编辑时显示下方 / 右侧「＋」，分别添加新行 / 新列并进入新单元格。六点块菜单提供增行列及「标题行 / 标题列」开关，使用原生选中标记与图标。表头使用较粗文字和轻底色，随纸片保存，可撤销；列宽自动均分纸片可用宽度。详情见[表格说明](lists-dividers-tables.md)。

2026-09-09 更新：表格单元格右键支持当前位置上下增行、左右增列及删除当前行列，至少保留一行一列。⌘K 可创建独立纸片副本，或删除当前纸片并从收纳架「最近删除」恢复。删除不会清除资产，会话内保留编辑器与撤销历史；重启不会打开已删除纸片。副本使用新的纸片与块 UUID，共用本地图片资产，先保存成功再显示窗口。

当前不包含数据库、列宽拖动、拖动加号批量增减、合并单元格。纸片全文搜索、归档、永久删除、多块跨纸片拖动和编辑器休眠尚未实现。

## 数据与窗口归属

`NoteLibrary` 持有条目和独立 `NoteStore`。AppDelegate 协调菜单、收纳入口和焦点，用 UUID 查找 `PaperWindowController`。每个控制器持有自己的 PaperPanel、阴影、SwiftUI 内容和原生编辑器；窗口事件不会无条件转发给某一个全局 Store。

收纳和折叠保留原 NSTextView / UndoManager。尚未打开的收纳纸片只有数据对象；本次会话已打开的纸片收纳后仍保留编辑器以保留撤销历史。应用重启恢复内容和窗口状态，不持久化撤销历史。

应用沙盒下的数据布局（Bundle ID 为 `dev.jasonyu.Foldpin`）：

```text
~/Library/Containers/dev.jasonyu.Foldpin/Data/Library/Application Support/Foldpin/
  notes/<UUID>.json                 每张独立保存，NoteDocument v2
  assets/<UUID>.original            各纸片共用原图
  assets/<UUID>.png                 各纸片共用预览
  note.json                        迁移前文件，原样保留
  backups/legacy-note-<UUID>.json   迁移前原始字节备份
  library-migration.json           成功迁移标记
```

文件名 UUID 与内容 ID 必须一致。新建先保存空白文件，再加入列表和创建窗口；不能把写入失败的临时草稿显示为已保存纸片。每张沿用 450 ms 合并正文保存、150 ms 合并窗口几何，关闭 / 折叠 / 退出前立即采集并保存。

表格 `headerRow` / `headerColumn` 为默认 false 的可选兼容字段，旧表格仍按普通网格读取。正文仍为结构化 JSON；颜色、字体和按钮几何不进入文档。

## 旧笔记迁移与错误路径

1. 读取并验证旧 `note.json`，保留原始数据。v1 在内存转换为结构化内容，v2 保留已有区块和图片引用。
2. 逐字节写备份，已有同名备份必须与原始字节一致；备份失败停止迁移。
3. 写入对应 UUID 文件。目标已存在时先验证并保留它，避免迁移中断重试时用旧笔记覆盖后续编辑。
4. 最后原子写入成功标记。原始 `note.json` 和备份不删除，图片继续从共用 assets 加载。

库目录 / 迁移失败会显示错误和「重试读取」，阻止新建。单张 UUID 文件损坏只让对应纸片只读并提供恢复提示，其他纸片可用。重试库索引保留既有 Store 与未保存编辑，不重建当前编辑器。文件原子写入和迁移备份不是完整版本历史，也没有引入外部文件自动合并功能。

## 验证与边界

环境：macOS 26.6.2，Xcode 26.6 / Swift 6.3.3，Apple Silicon。

- 完整 Core / Editor 检查 136 项通过，覆盖创建、独立保存、重开、旧 v1 / v2 迁移、图片路径、迁移重试、备份 / 目录失败、坏文件隔离、ID 不匹配保护以及新表格行为。
- 表格实际附件定位修正后，17 项表格相关检查通过。使用 TextKit 2 的 [frameForTextAttachment(at:)](https://developer.apple.com/documentation/appkit/nstextlayoutfragment/framefortextattachment(at:)) 取得实际绘制坐标，并在排版完成后合并同步单元格与加号，避免行间距或尚未完成的布局导致错位。
- 独立临时进程的窗口控制器集成检查通过：两张纸片的内容 / UndoManager 分离、⌘M / ⌘W 路由、独立置顶、折叠 / 收纳后仍为同一编辑器、撤销 / 重做、重新加载恢复窗口状态、保存失败保留可见内容。使用合成笔记，不启动已安装的 Foldpin、不注册热键、不读写真实纸片或剪贴板。
- Debug Xcode 构建通过，中英新增资源已打包。

必要时复现窗口检查（需 WindowServer 访问权限，会短暂显示临时纸片）：

```sh
python3 scripts/check-multi-windows.py /private/tmp/Foldpin-multi-window-check
```

日志：`/private/tmp/Foldpin-multi-window-tests.log`、`/private/tmp/Foldpin-table-controls-tests.log`、`/private/tmp/Foldpin-multi-window-check/native-check.log`、`/private/tmp/Foldpin-multi-window-build.log`。

这次未重复运行 1 / 10 / 30 张性能矩阵，之前报告见[性能整理](editor-performance.md)。当前没有新增 WebView 或每单元格常驻编辑器。收纳列表的 SwiftUI 离屏位图未完整捕获滚动内容，未作为排版通过的证据。真实滚轮 / 触控板、输入法候选窗口、跨屏 / Spaces、Raycast 与系统窗口管理、多窗口 VoiceOver 仍需实际使用验证；上述集成检查不等同于这些完整场景已验收。
