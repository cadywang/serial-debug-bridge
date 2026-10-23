# 审查与合并规则（REVIEW_POLICY）

> 一句话：**`main` 上的任何改动都必须来自一个 Pull Request，并通过 CI 的全部必需检查；
> 没有人（包括管理员）可以直接推送或改写 `main`。**

本仓库与 `cadywang.github.io` 使用同一套审查思路：**闸门不可绕过、自动校验先行、合并前必须有人过目**。
区别只在于本仓库没有「发布」环节——落地动作就是 PR 合并本身。

## 一、三道闸门

| 闸门 | 位置 | 拦什么 | 能不能绕过 |
| --- | --- | --- | --- |
| ① 分支保护 | `governance/branch-protection.json` + `governance/repository-settings.json`（由 `tools/create-github-repo.ps1` 施加） | 直推 `main`、强推、删分支、检查没绿就合并、**用 Squash 把 PR 压成一个提交**（只允许 `Rebase and merge`） | 不能：`enforce_admins: true` + 空 bypass，管理员也一样 |
| ② 自动校验 | `.github/workflows/ci.yml` + `.github/workflows/pr-gate.yml` | BOM/CRLF、语法、两套实现自测、交叉验证、commit 规范 + DCO、**PR 标题与「合并前清单」** | 不能：改 CI 自己也要走同一个 PR 流程 |
| ③ 人工审查 | PR 本身 | 维护者看过 diff、复现步骤、自测输出后才合并 | 单人维护时维护者即作者（GitHub 不允许自批，因此不设强制批准数）；有协作者后提升为「必须他人批准」 |

## 二、日常流程

```bash
git switch -c agent/hex-retry        # <subsystem>/<short-description>
# ... 改代码、文档、自测 ...
python3 tools/check-commits.py --range main..HEAD
git commit -s                        # DCO 签名，见 CONTRIBUTING.md §3
git rebase main                      # 保持线性历史
git push -u origin agent/hex-retry
# 在 GitHub 开 PR（模板自动带上）→ 等 CI 六个 job 全绿 → 维护者审阅 → Rebase and merge
```

## 三、补丁必须保持同步（本仓库最容易踩的雷）

只改一半，会让「四种版本任意组合」当场失效。**以下必须同一次提交里一起更新**：

| 改了 | 必须同时改 |
| --- | --- |
| `agent/serial_agent.ps1` | `agent/serial_agent.py` |
| `cli/devctl.ps1` | `cli/devctl.py` |
| 协议行为（帧格式、编码、超时语义） | `PROTOCOL.md` + 两套实现 + 两套 mock（`tests/*`） |
| 面向用户的行为 | `README.md`、`CHANGELOG.md` |
| skill 用到的入口/参数（`scripts/sdb`、环境变量） | [cadywang/skills](https://github.com/cadywang/skills) 的 `skills/serial-debug-bridge/SKILL.md` 与 `references/`（不在本仓库；跨仓库改动两边分别提 PR） |

CI 的 `Cross implementation check` 只能验证「ps 的 CLI 连 py 的 agent」这类组合，
**覆盖不了语义是否一致**——所以人工审查时要专门盯这一项。

## 四、几个实测过的坑

1. **只能用 Rebase and merge，不许 Squash**（`repository-settings.json` 只开了 rebase）：
   Squash 会把整个 PR 压成一个提交，标题变成 PR 标题、正文被拼成一坨、每个提交的
   `Signed-off-by:` 也不再是原文——#7 就是这么把 `main` 判红的（标题 `Agent/shutdown op (#7)`
   不合内核规范，而 commit 门禁只能在**合并之后**才发现）。rebase 保留 PR 中每个提交的
   作者与信息，代价是提交信息必须一开始就写对。
2. **`strict` 检查要求 PR 追上最新 `main`**：main 前进后旧 PR 需要 rebase / update 才能合并
   （dependabot 的 PR 会自动更新）。
3. **单人维护不要设 `required_approving_review_count: 1`**：GitHub 不允许自己批准自己的 PR，
   设了就会把自己锁死。
4. **`.github/CODEOWNERS` 只有在开启「Require review from Code Owners」时才有强制力**；
   单人模式下该开关保持关闭是刻意的。
5. **网页端 squash 合并用的是 PR 标题**：标题不合内核规范时，`Hygiene` 的 commit 门禁
   只能在**合并之后**把 `main` 判红，而受保护的历史改不回来（#7 实测：标题写成
   `Agent/shutdown op (#7)`，合并后 main 的构建就红了）。所以标题规范由 `pr-gate` 在
   **合并前**拦，模板里的「合并前清单」也一样；提交门禁对这种由 GitHub 自己写出的提交
   （committer 是 `GitHub <noreply@github.com>`、标题以 ` (#N)` 结尾）只做 DCO 与正文校验。
6. **dependabot 的提交永远不符合内核风格**：它自动生成 `ci: bump <pkg> from 4 to 7`，
   而 `bump` 属于被禁止的动词（实测在本仓库的两个 dependabot PR 上就是这么红的）。
   CI 用 `--skip-bots` 放行 `*[bot]` 的提交、其余检查照跑；否则一旦把 CI 设为必需检查，
   依赖更新的 PR 会永久卡住。

## 五、调整规则

| 想做什么 | 怎么做 |
| --- | --- |
| 收紧到「必须他人批准」 | 先加协作者 / 第二账号，再把 `required_approving_review_count` 设为 1，`require_code_owner_reviews`、`require_last_push_approval` 设为 true，重跑 `tools/create-github-repo.ps1` |
| 只要最基础保护（禁强推 / 禁删除） | 把 `required_pull_request_reviews` 与 `required_status_checks` 置空后重新施加 |
| 改合并方式 | 改 `governance/repository-settings.json` 的 `allow_squash_merge` / `allow_rebase_merge` / `allow_merge_commit`，再跑 `tools/create-github-repo.ps1` |
| 临时救急 | 改 GitHub Settings → Rules 后重跑脚本恢复；**不要**长期留 bypass |

## 六、提交前的本地自查

```bash
python3 tools/check-commits.py --range main..HEAD   # commit 规范 + DCO
python3 tools/check-pr.py --title "<subsystem>: 祈使句摘要>" --body-file pr.md   # PR 门禁本地预演
powershell -ExecutionPolicy Bypass -File tests/selftest.ps1
powershell -ExecutionPolicy Bypass -File tests/selftest.ps1 -Codec hex
python3 tests/test_e2e.py
python3 tests/test_e2e.py --agent-args '--codec hex'
bash tests/verify-live.sh <client-ip>:7801          # 有真机时再跑
```