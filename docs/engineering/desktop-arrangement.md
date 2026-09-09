# 桌面纸片排列 · 2026-09-09

顶部「窗口」菜单、菜单栏图标、纸片「操作 ⌘K」提供「排列桌面纸片」。保持展开 / 折叠、尺寸和置顶；需要紧凑排列时，可先「折叠所有纸片」。排列不打开收纳架或最近删除中的纸片。

每块显示器独立按库内顺序从左上排布，使用 visibleFrame 避开菜单栏与 Dock，留白 16 点、间距 12 点。按行摆放，放不下时使用 24 点错叠；屏幕比单张纸片还小时保留尺寸和标题栏入口，不能保证整张内容都在屏幕内。没有窗口动画，也不改变键盘焦点或层级；不同置顶层级仍遵循原有遮挡规则。

「撤销排列」保留本会话最近一次实际移动，恢复原位置，不接入正文的 ⌘Z。只恢复当前仍显示、可读且 frame 仍等于排列结果的窗口；后来手动移动 / 缩放、收纳、删除的纸片会跳过。屏幕断开后旧位置限制在现有屏幕内；尺寸不变。退出后不保留此撤销记录，排列后的纸片位置会正常保存。

实现入口：`Core/NoteArrangement.swift` 是不操作窗口的几何计算；`AppDelegate` 选择目标并持有撤销记录；`PaperWindowController.moveForArrangement` 使用原窗口和阴影；`NoteStore.saveArrangedWindowFrame` 先保存位置，写入失败恢复旧位置元数据，保留错误和未保存正文。折叠位置仍通过 NoteLayout 反推完整展开 frame，不把 52 点写成展开高度。

验证：6 项定向检查覆盖混合尺寸 / 折叠条 / 多屏、不缩小的错叠、重复排列、撤销跳过手动调整 / 断屏、内容与元数据保留 / 重启 / 恢复原位置、保存失败重试 / 收纳与删除保护，以及玻璃淡色层的明暗五色。Debug 构建日志为 `/private/tmp/Foldpin-arrangement-build.log`，测试日志为 `/private/tmp/Foldpin-arrangement-tests.log`。

没有启动另一份 Foldpin 或移动用户真实纸片。WindowServer 下的多屏、Spaces、焦点、实际错叠层级与失焦颜色仍需从当前 Xcode 运行新版验收；数据层检查不能替代这些 UI 场景。

## 顶部菜单与阴影边缘修正

顶部「窗口」菜单补齐排列与撤销入口。原生菜单项标识符防止重复插入，沿用 AppKit 可用性校验与已有语言刷新，不绑定正文的 ⌘Z。

用户截图显示排列后底部多出错位轮廓。隔离检查发现，纸片距屏幕可用区顶部 16 点，阴影外扩 36 点，系统默认 constrainFrameRect 会将阴影下推 20 点；隐藏窗口的 setFrame 未自动偏移，因此没有复现完整 WindowServer 合成路径。修正仅让 NoteShadowWindow 的该约束返回请求 frame，使装饰可越过屏幕边缘并保持父窗口对齐；正常纸片的屏幕约束、玻璃、描边和投影绘制保留。

修正后，两块实际屏幕的不可见窗口检查通过：约束结果等于纸片外扩 frame，子窗口移动后仍对齐，不接收鼠标与焦点，窗口始终不可见。Debug 构建通过。日志为 `/private/tmp/Foldpin-shadow-arrangement-probe.log`、`/private/tmp/Foldpin-arrangement-outline-build.log`。真实菜单点击与截图所示合成外观仍待新版验收。
