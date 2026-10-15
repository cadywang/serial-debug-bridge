# 支持（Support）

* **使用问题 / 疑似缺陷**：先跑一遍自测定位范围
  * 纯软件问题：`powershell -File tests/selftest.ps1` 或 `python3 tests/test_e2e.py`
  * 真实链路问题：`bash tests/verify-live.sh <client-ip>:7801`
  并附上 `devctl ... info` 输出、agent 日志（`-LogFile`）、串口参数与设备型号。
* **新功能请求**：开 Issue（用 feature 模板），说明使用场景。
* **紧急/敏感问题**：见 `SECURITY.md`，不要公开提 Issue。

提问时请尽量提供：

1. client 与 server 的操作系统、版本；
2. 串口设备名与波特率（如 `COM3 @ 460800`）；
3. 设备 shell 类型（如 busybox ash）与 `command -v base64 awk od md5sum` 的结果；
4. 完整的 devctl 命令与退出码。
