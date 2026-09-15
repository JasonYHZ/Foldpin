# Foldpin MCP 全功能开放开发方案

日期：2026-09-15\
状态：2026-09-15 已接入开发版本（80 个工具），实现及尚待实机验收边界见 [MCP 接入与实现记录](mcp-support.md) 和 [工具覆盖表](mcp-tool-coverage.md)。下文保留需求与验收目标；未实现的产品能力仍不注册工具。用户最新方向：首版取消内置 AI 聊天，向外部 AI 开放 MCP，并覆盖所有 Foldpin 可操作功能。此前 HTML Codex App Server 验证不是本方案的实现。

## 1. 产品范围

外部 AI 客户端负责模型、对话和推理；Foldpin 提供资料访问、编辑及应用操作。无需 Foldpin 云推理后台。首版不实施内置聊天、本地模型下载或 Codex 专属 App Server 适配；此前买断附送本地模型的规划在本路线下暂缓，已公开文案需单独核对，不静默改写已有购买承诺。

“全部开放”指 Foldpin 的全部业务能力都纳入接口覆盖，包括彻底删除、录音、剪贴板、设置和未来存储管理；不再永久排除高影响动作。开放不等于默认授权所有客户端，也不等于允许读取任意系统文件、执行 shell、调用私有方法或绕过购买状态。

优先 Mac App Store 构建；沙盒连接与审核分别验证，不能以“localhost 能访问”宣称审核通过。

## 2. 连接与设置

设置新增“连接 AI 工具”：启用开关、连接地址、客户端授权、可操作资料范围、权限组、最近调用记录、撤销授权。默认关闭，用户开启后运行于现有 Foldpin 进程；没有纸片可见时可继续提供服务，退出应用则停止。不添加后台守护进程，不自动启动外部 Agent。

采用标准 Streamable HTTP，在本机回环地址的 `/mcp` 提供服务；端口可配置，冲突时提示可用端口并更新配置，不能自动暴露局域网。使用 `network.server` entitlement，是否需要 client entitlement 由实际联网功能决定。

固定实施时支持的协议版本并协商，支持 initialize、tools/list、tools/call、分页及必要取消／进度行为；未实现的能力不宣告。GET 不启用事件流时按规范返回 405。不要把当前实验 HTML 的自定义 HTTP API 改个名字称为 MCP。

每个授权连接生成独立高熵凭据，存 Keychain，可撤销／轮换；不使用会话 ID 当授权。校验 Host、有效 Origin、协议版本、请求大小和速率；非浏览器没有 Origin 时仍须凭据。禁止凭据进入 URL、日志、导出或资料库同步。客户端自报 name 仅供显示，不作为可靠身份。

先支持用户显式配置授权头的本机客户端；需 OAuth 的客户端按对应 MCP 授权规范单独实现，不声称静态令牌等于 OAuth。配置向导只提供经过版本验证的示例，不读写用户 Agent 配置文件。仅支持 stdio 的客户端不直接兼容；桥接工具可后续独立提供，不能强制下载可执行程序来绕过商店限制。

## 3. 共用业务架构

MCP Transport → Schema/权限校验 → FoldpinCommandService → 现有库、Store、编辑会话、媒体与窗口协调器。

- UI 与 MCP 共用命令服务；禁止模拟鼠标、快捷键或直接写 notes JSON。
- AppDelegate / ShelfView 中内嵌的集合、导出、删除及选择逻辑逐步提取；界面是一个调用方，不是后台操作的必要前置。
- 维护机器可读 OperationRegistry：动作 ID、输入输出 schema、版本、权限组、状态、可撤销性、是否需用户操作、影响对象和测试入口。
- 每个现有 UI 操作必须映射一个业务动作，或注明“仅展示某菜单，其业务能力已由哪些动作覆盖”。不为“展开颜色菜单”制造重复工具，但保留打开相关界面的入口。
- 尚未实现的产品功能在覆盖表标为 planned，不出现在当前 tools/list。已有但当前状态不可执行的动作返回明确错误和原因。
- 不把所有动作压成一个接受任意字符串／任意 JSON 的万能 execute。以下分组是接口族，写入与只读动作分别注册，枚举动作须有严格判别 schema。

## 4. 全量操作覆盖表

名称为设计建议；实施时逐项固定 schema，并完成 UI → 命令 → 测试映射。除标记计划项外，以最新源码能力为准，不凭历史文档假定实现。

| 接口族 | 动作与主要参数 | 结果／约束 |
| --- | --- | --- |
| `foldpin_get_capabilities` | 应用／接口版本、已开放动作、限制、购买能力 | 不暴露密钥、磁盘私有路径 |
| `foldpin_get_status` | 活动库 ID、连接／忙碌状态、录音状态 | 状态不等于全部资料授权 |
| `foldpin_list_notes` / `search_notes` | 查询、收藏、类型、集合、桌面／收纳／最近删除、排序、游标、数量 | 默认摘要；删除区单独授权；只在授权集合内搜索 |
| `foldpin_read_note` / `read_blocks` | 库 ID、纸片／块 ID、范围、期望格式 | 结构正文或 Markdown、修订号；大内容分段 |
| `foldpin_create_note` | 结构块／文字／Markdown、颜色、图标、集合、可选来源 ID | 新 UUID，默认收纳；保存成功才返回完成 |
| `foldpin_duplicate_note` | 源 ID、修订、目标展示偏好 | 独立纸片和块 ID，资产沿用现有规则 |
| `foldpin_update_note` | 目标 ID、expectedRevision、正文替换或元数据 patch | 全文替换也支持，明确影响范围；不凭标题猜目标 |
| `foldpin_insert_blocks` / `update_blocks` | 锚点 ID、前后位置、块内容／格式 | H1–H4、文字、代码语言、列表、引用、分隔线等现有类型 |
| `foldpin_move_blocks` / `duplicate_blocks` / `delete_blocks` | 同纸片块 ID 列表、明确落点 | 保持顺序与撤销；跨纸片移动需新事务实现后宣告 |
| `foldpin_set_todo` | 块 ID、completed 布尔值 | 设置目标状态，不用不可重试的 toggle |
| `foldpin_edit_inline_format` | 文本修订、UTF-16 范围、受支持格式／链接操作 | 拒绝拆断 grapheme、过期范围；不假定下划线等已支持 |
| `foldpin_find_in_note` / `replace_in_note` | 查询、范围、替换文本、预览／执行 | 先返回匹配计数与位置；实际替换受修订保护 |
| `foldpin_edit_table` | 表格块 ID、单元格、增删行列、表头开关 | 原生表格限制不变，无合并单元格等虚假能力 |
| `foldpin_set_note_metadata` | 收藏、颜色、Emoji 图标及移除 | 复用验证及保存；不改无关正文时间 |
| `foldpin_show_notes` / `shelve_notes` | 明确 ID 列表、activate 默认 false | 不抢焦点；可显式请求定位并激活 |
| `foldpin_set_window_state` | 置顶、折叠、frame、显示器 ID | 校验坐标和可达性，按设备状态方案保存 |
| `foldpin_close_note` | ID | 沿用有内容收纳／空白最近删除语义，不等同永久删除 |
| `foldpin_arrange_windows` / `undo_arrangement` | 目标屏幕／范围，排列操作 ID | 复用现有一次撤销及手动移动跳过规则 |
| `foldpin_show_shelf` / `show_settings` | 分类／集合／纸片或设置页面 | UI 导航，读取界面状态需单独授权，不冒充编辑成功 |
| `foldpin_list_collections` / `create_collection` / `rename_collection` / `delete_collection` | ID、名称、expectedRevision | 删除集合不删除纸片 |
| `foldpin_set_collection_membership` | 集合 ID、纸片 IDs、included | 多对多，批量部分失败明确报告 |
| `foldpin_trash_notes` / `restore_notes` | IDs、各自修订 | 保留内容及资产；恢复默认收纳 |
| `foldpin_purge_notes` | 最近删除 IDs、修订、确认票据 | 彻底删除开放；只处理审批时固定目标，不可撤销 |
| `foldpin_list_assets` / `read_asset` | 纸片／块／资产 ID、范围 | 仅授权纸片实际引用资产，不允许猜 UUID 枚举整库 |
| `foldpin_import_asset` | 有类型的受限上传句柄或授权文件句柄、目标块 | 图片／音频／视频／普通文件；保持现有大小与格式保护 |
| `foldpin_update_image` | 块 ID、宽度、标题、恢复原始尺寸 | 复用等比缩放和撤销 |
| `foldpin_update_audio` | 块 ID、名称等已有可写属性 | 不擅自加入剪辑／转写 |
| `foldpin_play_media` / `pause_media` / `seek_media` / `set_playback` | 块 ID、时间、支持的速度／音量 | 遵守录音互斥；能力按媒体类型区分 |
| `foldpin_start_recording` / `stop_recording` | 新建或既有纸片 ID、录音会话 ID | 主动授权、清晰录音指示；停止完成并保存，不默默抹掉录音 |
| `foldpin_export_notes` / `export_asset` | IDs、格式、授权目标／下载句柄 | Markdown／HTML及资源包、原始附件；不允许任意覆盖路径 |
| `foldpin_open_attachment` / `reveal_file` | 资产／库句柄 | 打开外部应用或访达为独立权限，拒绝危险 scheme |
| `foldpin_copy_content` / `copy_image` / `copy_block` | 明确 ID、格式 | 写系统剪贴板单独授权，先完整构建后替换 |
| `foldpin_paste_clipboard` | 明确目标与模式 | 读取剪贴板需单独授权，仅主动一次读取，无持续监听 |
| `foldpin_get_settings` / `update_settings` | 允许字段列表、expectedRevision | 语言、主题、纸感／通透、代码样式、代码底色、既有快捷键；设置不重建正文 |
| `foldpin_import_code_theme` / `remove_code_theme` | 授权资源句柄／主题 ID | 原有格式验证，不执行主题携带的代码 |
| `foldpin_get_operation` / `cancel_operation` | 操作 ID | 导入、导出、扫描等长任务；取消不撤回已提交效果 |
| `foldpin_list_changes` / `undo_change` / `redo_change` | 当前会话／操作 ID、期望修订 | 明确撤销对象，不盲目 undo 当前焦点窗口 |
| `foldpin_retry_storage` | 指定库／纸片及错误 ID | 只重试，不默认覆盖损坏数据 |
| `foldpin_quit` | 完成保存后退出 | 需本机确认；返回已接受不等于退出已完成，失败保留运行 |
| 计划：Markdown 文件导入 | 复用专项方案的文件／资源授权、结果列表 | N4 实现后公开，不把任意 `.md` 附件冒充导入 |
| 计划：资料库位置／切换 | 查看、迁移、打开已有库、默认位置 | 复用迁移日志及系统目录面板；提交前固定库身份 |
| 计划：空间统计／清理 | 扫描、定位、隔离、恢复、最终清理 | 引用保护完成后公开；同步库清理依专项限制 |
| 计划：登录启动／帮助／购买 | 设置登录项、打开引导／购买／恢复页面 | 用户完成系统确认；不允许 AI 自动付款或伪造权益 |

“全部”范围还需实施时扫描菜单、NoteAction、EditorShortcutAction、插入菜单、块右键、媒体工具条、收纳批量及设置页，补齐新出现动作。没有对应业务功能的 UI 装饰不算遗漏。AI 不获得接口授权配置、令牌导出、静默扩大自身范围的能力；可请求打开授权页面，由用户决定。

## 5. 授权与用户控制

权限组：读取文字、读取附件、创建、修改、集合管理、桌面控制、软删除／恢复、永久删除、剪贴板、录音／播放、导入导出、设置、存储管理。用户可以给一个可信客户端开启全部业务权限，也可限定某些纸片／集合；全部权限不包含自动修改授权本身。

同一次已授权普通操作不反复弹窗。永久删除／最终空间清理、切换或迁移资料库、启动麦克风、外部文件覆盖、退出等高影响动作默认在 Foldpin 本机展示确认。该规则用于将来产品调用，不是要求本次方案编写额外批准。

确认采用预备／提交：prepare 固定对象 ID、版本、数量、动作及文件目标 → 显示本机请求 → 用户确认生成一次性短期票据 → 执行前再校验。模型声称“用户同意”、描述里的指令或传入 confirmed=true 均不能代替确认。用户可预先授予普通批量整理持续权限；系统目录选择和麦克风授权仍按系统执行。

如果需等用户选目录或批准，返回 awaiting_user 与操作 ID；批准后继续原操作，避免因客户端重复请求执行两次。客户端关闭或取消后不擅自继续尚未提交的高影响操作。

读取笔记等于可能把内容交给外部模型：授权页说明外部 AI 服务的数据处理由其配置决定，本机 MCP 不保证推理离线。日志默认只记录客户端、动作、对象 ID、状态和耗时，不记录正文／凭据／绝对路径；用户可清除。

## 6. 参数、事务与编辑一致性

- 统一输入含 `libraryId`，写操作含 `expectedRevision` 与 `idempotencyKey`；新建／导入用幂等键无需旧修订。所有 IDs 校验归属及权限，未授权和不存在避免泄露差异。
- 修订覆盖所有受影响字段，不只使用 modifiedAt；正文、集合、设备状态可独立版本。现有外部修订与存储协调实现若已加入，必须复用，禁止再造不兼容写入链。
- 输出统一含 operationId、status、structuredContent、受影响 IDs、新修订及可撤销信息；业务失败使用工具错误，协议错误按 JSON-RPC 处理。
- 错误码至少包含 invalid_input、permission_denied、not_found_or_denied、revision_conflict、busy_editing、awaiting_user、library_unavailable、save_failed、asset_unavailable、limit_exceeded、unsupported、entitlement_required、cancelled。
- 保存前检查 IME、表格、图片标题、录音及未完成导入。不能为了 AI 写入强行提交半个拼音；返回 busy 或排队，安全边界后再复查修订。
- 同一 UUID 仍仅一套真实编辑会话，UI 和 MCP 串行提交。MCP 修改进入同一撤销模型；未打开的纸片可用数据事务和变更记录处理，不能为了批量写入启动上千个 NSTextView。
- 撤销绑定明确 changeId，只撤销自己可撤销且基线未变化的操作；存在后续人工编辑时返回冲突或安全反向补丁，不能回退整张纸片擦掉新内容。
- 批量先解析固定目标并校验，默认返回逐项成功／失败；不承诺跨文件原子事务。批量每项拥有稳定子幂等键，重试不重复副本／导入／删除。
- 本机持久幂等台账与提交恢复记录必须协调，崩溃在“保存成功、响应未送达”之间仍能识别已执行；不能只在内存缓存请求 ID。
- 用户切库、迁移、外部同步更新或权限撤销会改变执行上下文；排队动作提交前复查，不能自动套用新库中的同名纸片。
- 权益限制与 UI 共用：试用结束后已允许的查看、复制、导出仍可用，付费写操作不能通过 MCP 绕过；MCP 本身不收模型费用。

## 7. 文件和内容边界

使用库内资产 ID、应用授权书签或有界上传句柄，不接收任意磁盘路径直接读写。需要外部文件时打开系统选择器，由用户授予特定目标；上传文件暂存绑定客户端、库、有效期和总量。原始二进制不能无限塞入 JSON，上限及分块协议写入 schema。

建议初始限制：搜索每页默认 30／最多 100；批量写默认最多 100 张；工具 JSON 请求最多 2 MiB；大正文及媒体使用分段和受限句柄。沿用现有媒体导入更严格的限制，数值可测后调整，不截断后仍宣称内容完整。下载／资源读取同样进行范围与凭据校验，返回下载句柄不暴露本机路径。

用户笔记、文件名和附件中的指令均为资料，不赋予工具权限。服务端只执行结构化已授权调用。来源笔记列表可附在生成结果的操作记录中，不向正文偷偷插入追踪标记。链接下载不能借 SSRF 访问未授权地址，默认不自动联网读取远程资源。

## 8. 实施顺序与交付

| 阶段 | 任务 | 出口 |
| --- | --- | --- |
| M0 | UI 全量动作盘点、注册表、schema、当前支持状态 | 每个动作可追踪，无“已实现”冒认 |
| M1 | 沙盒本机服务、认证、设置、能力发现、搜索读取 | 原生签名应用与真实客户端连通 |
| M2 | 提取共用写入服务、修订、幂等、变更撤销 | 创建／编辑／集合／窗口／删除恢复完整闭环 |
| M3 | 块、表格、媒体、剪贴板、导出、设置全覆盖 | 当前已实现 UI 业务动作全部映射 |
| M4 | 高影响操作确认、永久删除、录音、退出与故障恢复 | 操作真实可用且授权不能由模型伪造 |
| M5 | 未来迁移／导入／空间模块接入及兼容文档 | 随功能实现公开，不是首轮虚假占位工具 |

分阶段用于减少实现风险，不把用户要求的全量接口偷偷缩减成三个演示工具。发布前生成覆盖报告：UI 动作、工具名、是否实现、测试证据、已知限制；已存在功能未接入必须明确列为缺口。

## 9. 验收

1. 开关、退出、端口占用、IPv4／IPv6 回环、错误 Origin／Host、无效及撤销令牌、会话冒用均符合规则。
2. 至少两种真实 MCP 客户端验证初始化、发现、读取、写入、取消和重连；记录版本及认证方式，不宣称所有 Agent 兼容。
3. 每个接口具备成功、无权限、非法参数和过期目标检查；tool annotations 只是提示，服务器实际强制权限。
4. UI 与 AI 同时编辑、中文 IME、表格、录音中写入、两个客户端并发不丢内容；同一编辑器和撤销保持。
5. 幂等重放、响应丢失、进程崩溃、批量部分失败不会重复创建或误报完成。
6. 彻底删除只影响确认目标，审批后变更／恢复目标被拒绝；正文删除不擅自清扫共享资产。
7. 剪贴板读写、麦克风、外部应用启动、路径授权都能拒绝／取消，不静默实施。
8. 媒体缺失／云占位、恶意路径、大文件、下载取消、库迁移中操作不越界或写错库。
9. 受限集合搜索、资产猜 ID、日志及资源 URL 不泄露其他内容；外部文档中的伪指令不扩大权限。
10. 试用到期、恢复购买、退款等能力状态与 UI 一致；读取导出不误锁。
11. 大库只读不为全部纸片创建窗口，批量操作界面可响应；记录千张合成库与大资源负载实测值。
12. 全量 UI 操作映射表无未解释遗漏；标记当前未实现产品功能和明确版本计划。

仅操作临时库和合成媒体；真实录音、授权设置和用户数据操作另由用户明确触发。App Store 沙盒测试通过不等同于审核批准。审核说明清晰描述服务仅供用户授权的本机客户端操作 Foldpin 资料，不借此获得任意系统权限。

## 10. 参考与交接

- [MCP Streamable HTTP](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)：本机传输、安全检查与协议协商。实施时复核兼容版本。
- [MCP Tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)：工具 schema、结果与发现。
- [Apple network.server](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.server)：沙盒入站连接权限。
- [非 AI 收尾方案](non-ai-release-readiness-plan.md)、[存储位置与同步方案](library-location-and-sync-plan.md)、[App Store 收费方案](app-store-purchase-and-trial-plan.md)。

本文件作为新方向专项交接；不删除旧 HTML 或 Codex 验证资料，不把历史方案当作仍需实施的内置聊天任务。实施阶段同步修改相关路线说明与公开承诺；本次仅产出开发方案。
