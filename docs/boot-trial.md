# 单次启动试用与回退

本示例适用于已核对固件的测试 AP，需要现有的管理员 shell、有线管理路径、一份原厂配置备份和可操作的原厂恢复手段。请先检查本机的 `/sbin/wifi` 会在装载 `umac` **之前**引入 `/lib/wifi/*.sh`。这一顺序决定了单次引导挂载能否生效。

## 准备

1. 在电脑上，从本机原厂模块构建 `patched.ko`，记录这一次构建**输入和输出**各自的 SHA-256。分别存成 `stock.sha256`、`patched.sha256`；每个文件一行，只含 64 个小写十六进制字符，使用 LF 换行。
2. 通过已有管理通道把上述两个摘要和 `patched.ko` 放入 AP 上新建的 `/etc/gecoos/rssi-policy-trial/`，目录只允许管理员写入。用 `sha256sum` 对照电脑上的输出，并核实 `/rom/lib/modules/4.4.60/umac.ko` 与输入摘要一致。
3. 确认 `/lib/wifi/00-rssi-trial.sh` 路径空闲，再放入 [单次启动钩子](../examples/00-rssi-trial.sh)。先阅读脚本；它只在存在 `armed` 标志且 `umac` 尚未装载时工作。

```sh
# 在目标 AP 的管理 shell 执行。重启会中断这台 AP 的无线业务。
touch /etc/gecoos/rssi-policy-trial/armed
sync
reboot
```

## 核对这次启动

重新连上有线管理路径后，检查以下各项。内核模块已加载、启动标志已消费、模块装载路径是临时绑定挂载、当前模块文件摘要等于本次构建输出，且只读分区中的原件仍与输入摘要一致。

```sh
ls -d /sys/module/umac
cat /tmp/rssi-policy-trial.bound
grep -F ' /lib/modules/4.4.60/umac.ko ' /proc/mounts
sha256sum /lib/modules/4.4.60/umac.ko /rom/lib/modules/4.4.60/umac.ko
ls /etc/gecoos/rssi-policy-trial/consumed
```

这些是引导顺序和文件证据。完成后设置一个业务接口的准入阈值，并用实际终端确认关联响应；详细步骤见[验证方法](verification.md)。驱动的默认门槛 `-90` 保留原厂路径，单次试用钩子本身不会设置接口门槛或启动剔除脚本。

## 恢复

停止本地剔除进程，将已启用接口的 `min_asoc_rssi` 设回 `-90`。保持 `armed` 缺席并重启：本次试用的绑定挂载随重启消失。若试用时无线没有起来，通过有线或控制台重启；标志是在尝试加载前消费的。

重启后，确认模块装载路径的摘要与 `/rom` 相同、该路径已无绑定挂载，且业务 Wi-Fi 能正常关联。最后可移走本次添加的钩子和试用目录。设备若已有其他启动脚本或以前部署的同类策略，应先查明其行为，避免两套逻辑同时装载模块。
