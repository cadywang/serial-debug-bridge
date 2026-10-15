# 贡献指南（Contributing Guide）

感谢参与！本仓库所有改动**必须通过 Pull Request 合入**，且需要代码所有者（CODEOWNERS）
审核批准，CI 必须为绿色。请按下述流程工作。

## 1. 开发环境

| 组件 | 要求 |
| --- | --- |
| client 侧代理 | Windows：PowerShell 5.1+（零依赖）；Linux/macOS：Python 3.8+，真实串口需 `pyserial` |
| server 侧 CLI | Python 3.8+（`cli/devctl.py`），或 PowerShell 5.1+（`cli/devctl.ps1`） |
| 自测 | 无需任何硬件（内置 mock 设备） |

```bash
git clone https://github.com/<owner>/serial-debug-bridge.git
cd serial-debug-bridge
```

## 2. 提交前必须本地通过

```powershell
# Windows：agent + devctl 全链路（mock 设备）
powershell -ExecutionPolicy Bypass -File tests/selftest.ps1
powershell -ExecutionPolicy Bypass -File tests/selftest.ps1 -Codec hex
```

```bash
# 跨平台：devctl.py 全链路（mock 设备）
python3 tests/test_e2e.py
python3 tests/test_e2e.py --agent-args '--codec hex'
```

有真实设备/串口时，再跑一次端到端确认：

```bash
DEVCTL=cli/devctl.py bash tests/verify-live.sh <client-ip>:7801
```

## 3. 提交规范：遵循 Linux 内核补丁约定

本仓库**强制**采用 Linux 内核的 commit message 规范，不使用 Conventional Commits
（`feat:` / `fix:` 这类标签会被 CI 拒绝）。

### 3.1 格式

```
<subsystem>: <祈使句摘要，不超过 72 字符，结尾不加句号>

<正文：说明 what 与 why，每行不超过 72~75 字符，可用空行分段>

<可选标签：Reported-by: / Link: / Fixes: / Reviewed-by: / Tested-by:>
Signed-off-by: <作者姓名> <作者邮箱>
```

* **subsystem 前缀**取受影响的目录或模块名，例如
  `agent:`、`cli:`、`tests:`、`ci:`、`docs:`、`tools:`、`repo:`；
  也可更细：`agent/py:`。
* **摘要用祈使语气**（`fix`、`keep`、`add`，不是 `fixed`/`adds`/`adding`），
  且禁止使用 `feat:`、`chore:`、`wip:`、`various:` 等。
* **摘要与正文之间必须有一个空行**；正文与签名块之间也要有空行。
* 正文解释**为什么**要改，而不是逐行复述 diff；受影响的既有行为、
  复现现象、被放弃的替代方案都值得写下来。
* 修 bug 时用内核格式标注来源：
  `Fixes: 0d75a9b ("agent: keep the final serial chunk undrained")`。

### 3.2 DCO 签名（必须）

每个提交都要有 `Signed-off-by:`，且与作者身份一致（开发者原创证书）。用参数即可自动加上：

```bash
git commit -s
```

### 3.3 一个提交只做一件逻辑上的事

* 功能、重构、格式化、文档不要混在同一提交里；每个提交都应可独立编译/自测通过，
  保证 `git bisect` 有效。
* 提交顺序按依赖排列：先基础配置，再实现，再测试，最后文档与 CI。

### 3.4 本地校验与钩子

```bash
# 只读校验（也可在 CI 中运行）
python3 tools/check-commits.py --all                 # 全量
python3 tools/check-commits.py --range main~3..main  # 一段范围

# 安装提交钩子（推荐，每次 commit 自动把关）
git config core.hooksPath tools/git-hooks
```

紧急绕过：`git commit --no-verify`（CI 仍会拦住，PR 无法合入）。

### 3.5 分支与历史

* 从 `main` 切出分支：`<subsystem>/<简短描述>`，例如 `agent/hex-codec`、`tests/live-verify`。
* 合入前 **rebase 到最新 `main`**，不要产生 merge commit（`main` 要求线性历史）。
* 不要提交 `.tmp-*/`、`*.log`、`__pycache__/`（已在 `.gitignore` 中）。
## 4. 代码风格约定（重要）

* **代码与注释一律使用英文**；面向使用者的文档（`README.md`、`PROTOCOL.md`、本文档等）使用中文。
* 文件使用 **UTF-8（无 BOM）** 与 **LF** 换行（`.editorconfig` / `.gitattributes` 已强制）。
* Python：4 空格缩进，标准库优先，不引入新的第三方依赖（`pyserial` 除外，且必须**延迟导入**，
  以保证 `--mock` 自测在纯净环境下可运行）。
* PowerShell：兼容 Windows PowerShell 5.1（不使用 `??`、三元、`-As` 等 PS7 语法）。
* 命名沿用现有前缀：协议帧 `Send-Message` / `write_message`，设备侧执行 `Invoke-OnDevice` / `run_on_device`。

## 5. 修改传输/协议时的注意事项

本协议的正确性依赖几个**已被真实设备验证过的**前提，改动时请勿破坏：

1. **结束标记的配对引号技巧**：探针回显与真实输出必须可区分，
   例如 `echo __DEVCTL_A''CK_<i>__` —— 回显里是 `A''CK`，真实输出是 `ACK`。
   ⚠️ 引号必须**成对**，单个 `"` 会让设备 shell 卡在续行状态。
2. **不要排空最后一个数据块的回显**，否则结束标记会被一起丢弃（曾导致 push 超时）。
3. **串口会偶发丢字符**（实测 460800 下约 1/40000），因此上传必须
   **逐块校验 + 失败重传**，且只有 `cat >>` 追加成功才回 `ACK`。
4. **提示符与 ANSI 颜色**必须在清洗阶段剥离，否则 `pull` 的编码解析会失败。
5. 新增编码方式时，请同时更新 `serial_agent.ps1`、`serial_agent.py` 两个实现、
   两套 mock 以及 `PROTOCOL.md`，并补充 `--codec <name>` 的自测用例。

## 6. PR 流程

1. git rebase main 确认无冲突且历史线性，git push -u origin <branch>，然后开 PR（使用仓库模板填写）。
2. CI 全绿（含 `Commit style` 检查）；本地自测命令与输出贴在 PR 里。
3. 至少 1 位 CODEOWNER 批准；required status checks 未通过不可合入。
4. 由 maintainer 以 **Squash merge** 合入 `main`，标题遵循 Conventional Commits。
5. 发布：打 tag `vX.Y.Z`，同步更新 `CHANGELOG.md`。

## 7. 许可

提交即表示同意你的贡献在 MIT 许可下发布（见 `LICENSE`）。
