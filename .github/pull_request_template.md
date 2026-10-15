## 变更说明

<!-- 这个 PR 解决什么问题？为什么需要它？ -->

## 变更类型

- [ ] 新功能（feat）
- [ ] 缺陷修复（fix）
- [ ] 仅文档（docs）
- [ ] 重构 / 性能（refactor / perf）
- [ ] 构建、CI、打包（build / ci）
- [ ] 涉及**协议或传输行为**的改动（需要同时更新 `PROTOCOL.md` 与两套实现）

## 影响面清单

- [ ] `agent/serial_agent.ps1`
- [ ] `agent/serial_agent.py`
- [ ] `cli/devctl.py`
- [ ] `cli/devctl.ps1`
- [ ] `tests/*`
- [ ] 文档 / 仓库治理文件

> ⚠️ 代理与 CLI 各有两个实现，**协议改动必须 4 个文件同步修改**，
> 否则会出现 ps↔py 混搭时不兼容（本项目一直支持交叉使用）。

## 测试

请在本地执行并粘贴结果（无硬件即可运行）：

```
powershell -ExecutionPolicy Bypass -File tests/selftest.ps1
powershell -ExecutionPolicy Bypass -File tests/selftest.ps1 -Codec hex
python3 tests/test_e2e.py
python3 tests/test_e2e.py --agent-args "--codec hex"
```

- [ ] 上述自测全部通过
- [ ] 已在**真实设备**上验证（如适用），命令：`bash tests/verify-live.sh <client>:<port>`

设备与链路信息（涉及传输改动时必填）：

| 项 | 值 |
| --- | --- |
| client OS |  |
| 串口 / 波特率 |  |
| 设备 shell / 系统 |  |
| 可用工具（`base64`/`awk`/`od`/`md5sum`） |  |

## 自检

- [ ] 代码与注释为英文，文档为中文
- [ ] 文件为 UTF-8（无 BOM）+ LF
- [ ] 未提交临时产物（`.tmp-*/`、`*.log`、`__pycache__/`）
- [ ] 每个 commit 遵循内核规范：`<subsystem>: 祈使句摘要`、正文 72 列折行、并带 `Signed-off-by:`（`git commit -s`）
- [ ] 已更新 `CHANGELOG.md`（如面向用户的行为有变化）
- [ ] 已阅读并遵守 `SECURITY.md`（不引入默认对外暴露、无鉴权的行为）
