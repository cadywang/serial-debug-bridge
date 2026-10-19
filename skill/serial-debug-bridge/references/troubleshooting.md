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

## 10. 设备停在 `login:` 提示符（重启后最常见）

**症状**：`exec` 一直超时（rc=124），或 `sdb-check.sh` 的输出里出现
`Poky (Yocto Project Reference Distro) ... ttyS0` 紧跟着 `login:`。

**为什么不能反复用 `exec` 试**：登录提示符期待的是「用户名 + 密码」两行，而 `exec` 发的是
「命令文本 + 探针行」——于是命令被当成用户名、探针行被当成密码，**必然登录失败**，
而且每次都要白等一个 30 秒超时（试三五次就是好几分钟）。

**正确做法：直接以 root 登录（这些开发板 root 通常无密码）**

1. 人在终端前 —— 用交互控制台（仅 TCP）：

   ```bash
   $S shell            # 看到 login: 后输入 root 回车，Ctrl+] 退出
   ```

2. 脚本化 / 无人值守 —— 切到 raw 透传模式，直接发两行：

   ```bash
   # ① client（串口所在机器）上：先停掉协议模式的 agent（串口独占），改用 raw
   powershell -NoProfile -ExecutionPolicy Bypass -File <client>\agent\serial_agent.ps1 `
     -Port COM3 -Baud 460800 -TcpPort 17801 -Raw

   # ② server 侧：先发一个空行清掉残留输入，再发 root
   printf '\nroot\n' | nc 127.0.0.1 17801
   # 期望：myboard login: root   然后   root@myboard:~#
   ```

3. 登录成功后：停掉 raw agent，重新以**协议模式**启动 agent，`info` / `exec` / `push` 全部恢复。

**要点**

* 登录状态由设备侧持有，agent 只负责搬字节：**一次会话只需登录一次**，之后 `exec` 一直可用。
* 不要在登录提示符下"多试几次"——那是纯粹浪费时间；不确定卡在哪，先跑一次 `sdb-check.sh`。
* 少数板子 root 要密码：raw 模式下把密码也发一行即可（`printf '\nroot\n<pw>\n'`）。

## 11. 确认是桥的 bug 之后

本文列的多半是使用姿势与环境问题。若确认是桥自身的缺陷（稳定复现、与设备无关），
按 `SKILL.md` 的「发现 bug：请提交 patch」把最小复现 + `fix.patch` + 自测输出交回上游，
不要只在上层脚本里绕过去——绕过会让下一个人再踩一次。

## 12. 串口被 agent 占住 / agent 停不下来

症状：`info` / `exec` 超时或 `agent closed the connection`，client 上的串口工具报
「访问被拒绝 / busy」，而你以为 agent 早就不在了。

原因：串口是**独占**的，agent 只要还活着就占着它。最常见的两种情况：

* 启动 agent 的窗口 / SSH 会话没了，进程却留了下来（孤儿进程）；
* 想换一个 agent（换波特率、换串口、切到 `-Raw` 去登录控制台），旧的那个还在跑。

处理：

1. **还连得上 agent 时**（TCP 或 SSH）——让 agent 自己退出：

   ```bash
   $S shutdown        # 回应里带 pid，便于确认停的是哪一个
   ```

   注意这会打断别人正在用的链路（agent 单线程，一次只服务一个会话）。

2. **连不上时**（人在 client 机器上）：

   ```powershell
   # Windows：先 -List 只看不杀
   powershell -ExecutionPolicy Bypass -File agent\stop-agent.ps1 -List
   powershell -ExecutionPolicy Bypass -File agent\stop-agent.ps1 -Port COM3
   ```

   ```bash
   # Linux / macOS
   ./agent/stop-agent.sh --list
   ./agent/stop-agent.sh --port /dev/ttyUSB0
   ```

   脚本按**启动方式**匹配 agent（`-File <脚本>`，或脚本作为参数），过滤条件支持串口名与
   TCP 端口，停完会复核进程是否真的没了。装了 systemd 单元的直接 `sudo systemctl stop serial-agent`。

3. **还是打不开**：那就不是 agent。串口终端（PuTTY / MobaXterm / IDE 的串口监视器）也会
   一直占着它，先关掉；Windows 上要确认谁持有句柄，可用 Sysinternals `handle64.exe -a <设备名>`，
   设备名是驱动对象名而不是 `COM3`（本次实测的 FTDI 串口是 `VCP0`），可以用注册表映射查到：

   ```powershell
   Get-ItemProperty 'HKLM:\HARDWARE\DEVICEMAP\SERIALCOMM'   # -> \Device\VCP0 : COM3
   ```

> `shutdown` 与 `stop-agent*` 只结束 **agent 进程**（串口随之释放），不会动设备；别和 `reset`
> 搞混——`reset` 拉 DTR 会重启设备。
