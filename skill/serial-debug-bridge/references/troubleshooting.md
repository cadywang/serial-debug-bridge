# 排障手册

## 1. 连接建立了但立刻关闭 / 一直卡住

症状：`devctl: agent closed the connection`、或连上后长时间无输出、或 `info` 都超时。

排查顺序：

1. `scripts/sdb-check.sh` —— 它会打印端点解析结果、`info`、设备身份。
2. 端点被占用：一个端口上可能同时存在**两个监听**，例如 client 上
   `0.0.0.0:17801`（我们的 agent）与 `127.0.0.1:17801`（VS Code 的自动端口转发）。
   Windows 会优先匹配更具体的 `127.0.0.1`，于是反向隧道（`-R ...:127.0.0.1:17801`）
   连到的是 VS Code 的转发器，协议不匹配 → 立刻关闭。
   处理：隧道/客户端改连 `127.0.0.2:17801`（Windows 回环 /8 都可用），或换端口，
   或在 VS Code 的 Ports 面板里取消该端口的转发。
3. agent 是单线程的：某个会话卡住（比如设备不回话）会让后续连接排队、看起来像超时。
   等它超时退出，或在 client 上重启 agent。

## 2. 设备 shell 被卡住（提示符变成 `>`）

原因：上一次操作被中断，留下未闭合的引号或 here-document，设备 shell 在等收尾。

处理：

* agent 在命令超时后会自动发送 Ctrl-C（`\x03` + 换行），多数情况能自己恢复；
* 若仍未恢复：`python3 devctl.py --tcp <t> shell` 后按 Ctrl-C，
  或让 client 侧用任意串口工具发 Ctrl-C；
* 兜底：`devctl ... reset`（DTR 复位），**执行前确认不会影响设备上的重要状态**。

## 3. 上传/下载不一致

* `push` 的 `verified=True` 才算成功；`verified=False` 直接重试。
* 连续失败：降低波特率（例如 460800 → 115200）、换短一点/屏蔽更好的线、
  或先把文件 `tar cz` 压缩后传（体积小，链路上的出错窗口就小）。
* `pull` 后 devctl 会比对 md5；不一致时不要使用该文件。

## 4. 设备缺少工具

`push`/`pull` 依赖设备自带工具，探测顺序：

| 能力 | 需要的设备工具 |
| --- | --- |
| 上传/下载（首选） | `base64`（或 `busybox base64`、`openssl base64`） |
| 上传/下载（回退） | `awk` + `od` + `md5sum` |
| 校验 | `md5sum`（必需） |

用 `exec "command -v base64 awk od md5sum"` 确认。若 `md5sum` 都没有，
校验会退化，此时不要用串口搬重要文件。

## 5. 交互式 shell

* 只支持 TCP 传输（SSH 的 stdio 是纯协议通道，会返回 `shell-requires-tcp`）。
* `Ctrl+]` 退出（devctl.ps1 与 devctl.py 同）。
* 需要登录的设备：先在 `shell` 里登录，agent 会保持同一条串口会话，之后的 `exec` 就可以用。

## 6. 复位

`reset` 拉低再拉高 DTR。仅在设备的 DTR 接到了复位脚时有效；复位会中断一切正在进行的操作，
执行前必须与用户确认。

## 7. 超时（`SDB_TIMEOUT`）

`sdb` 默认给 devctl 套一层外层硬超时（默认 180 秒），因为 devctl 自己不会主动放弃一个卡死的 agent。
串口传输很慢：**60 KB ≈ 50 秒**，200 KB ≈ 3 分钟。所以：

```bash
SDB_TIMEOUT=0                    sdb push big.bin /tmp/big.bin      # 关闭外层超时
SDB_EXTRA="-q" SDB_TIMEOUT=600   sdb push big.bin /tmp/big.bin
```

被外层 `timeout` 杀掉的表现是进程返回 124、设备上留下**半个文件**——重传前先删掉目标文件，
或者让它保持最后覆盖的语义（`push` 开头会 `: >` 截断目标）。

## 8. 从别的机器/脚本里调用时的引号

`sdb exec 'uname -a; id -un'` 里的参数会被逐层解析：本地 shell → ssh → 远端 shell → sdb → devctl。
少一层引号就会让 `;`、`|`、`$` 在**错误的机器上**执行（典型症状：`id -un` 打印出了 server 的用户名，
而不是设备的 `root`）。

可靠做法：

* 在 server 上把命令写进脚本文件再执行（`scp` 上去后 `bash script.sh`）；
* 或远端外层用单引号、内部避免再嵌套引号；
* 单条命令优先用 `sdb exec '...'` 且不要在 ssh 的同一层再包双引号。
## 9. 传输中途失败，控制台出现启动横幅 / `login:`

如果 `push`/`pull` 中途报 `upload failed (lock-step ack timeout)`，而随后 `sdb-check.sh`
或 `sdb exec` 的输出里出现内核启动横幅、`login:` 或 `Poky ... ttyS0`，
那**不是桥的故障——是设备自己重启了**（看门狗、掉电、被其它工具打断等）。

agent 在超时时会把控制台最后约 200 字节写进日志（`-LogFile`），
先看那条 `console said: ...` / `timeout waiting for the marker; console said: ...` 再判断。

处理：

* 在控制台重新登录（需要登录的镜像；多数开发板 root 无密码），提示符回来后重传；
* 中途重启会留下半个文件：重传前删掉目标文件，或让 `push` 直接覆盖；
* 若频繁重启，先排查设备侧（供电、看门狗、内存）——串口传输本身不会导致重启。

> 实测：一次 200 KB 上传失败正是因为设备在传输中重启；重新登录后同一操作
> 90 秒完成且 md5 一致。

## 10. 确认是桥的 bug 之后

本文列的多半是使用姿势与环境问题。若确认是桥自身的缺陷（稳定复现、与设备无关），
按 `SKILL.md` 的「发现 bug：请提交 patch」把最小复现 + `fix.patch` + 自测输出交回上游，
不要只在上层脚本里绕过去——绕过会让下一个人再踩一次。
