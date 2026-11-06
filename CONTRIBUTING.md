# 参与 Foldpin

请先阅读 [README](README.md)、[原生工程说明](macOS/README.md) 和 [AGENTS.md](AGENTS.md)。工程文档包含阶段验证边界，不代表已完成所有实机验收。

报告问题时，请提供 macOS 版本、Intel / Apple Silicon、Foldpin 版本、复现步骤和预期行为。截图、日志和示例纸片请先移除个人内容、文件路径与凭据；不要上传真实纸片库。

修改应保持原生多窗口与现有保存、撤销、组合输入和失败恢复路径。测试使用临时数据，不操作开发者的真实笔记或系统偏好。提交前运行与修改相关的检查；修改翻译时运行 `python3 scripts/check-localizations.py`。

贡献原创代码意味着允许其按本项目 GPL-3.0-only 许可发行。引入第三方内容时保留原许可证、作者及来源，并先核对兼容性。不要将研究参考图或未经授权的截图作为正式应用资源。

发行包生成方法见[发行说明](docs/engineering/distribution.md)。不要提交 dist/、构建缓存、个人 Xcode 状态、签名凭据或用户数据。
