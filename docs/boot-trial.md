# 单台 AP 试用弱信号拒绝接入

本页用于试验**接入前的 −75 dBm 门槛**，需要重启测试 AP。若只想看哪些已连接终端低于 −82 dBm，可直接按[观察与剔除步骤](getting-started.md#observe)操作，原厂驱动即可开始观察。

请先按[构建步骤](getting-started.md#build)从自己的 AP 取得 `umac.stock.ko` 并生成 `patched.ko`，两者放在电脑的仓库根目录。下文用两个终端。**电脑**运行 Windows PowerShell，负责文件传输；**AP**运行已授权的 root shell，负责检查和启停。试用时保留有线管理连接，提前导出当前配置并把备份留在电脑上。确认知道设备无法通过 Wi-Fi 管理时怎样经有线或本地控制台恢复。

## 1. AP：确认能用这个启动钩子

如果已有 SSH，在电脑 PowerShell 输入以下命令进入 AP。先核对提示的目标设备和主机指纹。也可用自己的本地管理控制台执行后续标有“AP”的步骤。

```powershell
$Ap = Read-Host '测试 AP 的管理地址或主机名'
ssh "root@$Ap"
```

在 AP shell 查看：

```sh
id -u
uname -r
sha256sum /rom/lib/modules/4.4.60/umac.ko /lib/modules/4.4.60/umac.ko
grep -F ' /lib/modules/4.4.60/umac.ko ' /proc/mounts
grep -nE 'include /lib/wifi|/lib/wifi/|insmod|kmodloader' /sbin/wifi
ls -l /lib/wifi/*.sh
df -k /overlay /tmp
```

确认 UID 是 `0`，内核是 `4.4.60`，两份模块的摘要都等于构建器显示的 `Stock SHA-256`，挂载查询为空。持久分区须容得下 `patched.ko` 和剩余运行空间。检查本机的 `/sbin/wifi` 及它载入的脚本：固件需在加载 `umac` **之前**引入 `/lib/wifi/*.sh`；上面的 grep 只帮助定位代码。原厂校验失败、存在覆盖挂载、已有管理页策略或其他自定义装载钩子、不能确认启动顺序时，到此结束。重复安装可能与正在使用的策略冲突。

## 2. 电脑：准备并核对传输文件

保留 AP 的 SSH 窗口，另开一个 PowerShell，切到**仓库根目录**。以下命令会生成两个纯文本摘要文件，小写、LF 换行，兼容 Windows PowerShell 5.1 和 PowerShell 7。

```powershell
$stock = (Get-FileHash ./umac.stock.ko -Algorithm SHA256).Hash.ToLowerInvariant()
$patched = (Get-FileHash ./patched.ko -Algorithm SHA256).Hash.ToLowerInvariant()
$stock
$patched
[IO.File]::WriteAllText((Join-Path $PWD 'stock.sha256'), "$stock`n", [Text.Encoding]::ASCII)
[IO.File]::WriteAllText((Join-Path $PWD 'patched.sha256'), "$patched`n", [Text.Encoding]::ASCII)
(Get-FileHash ./examples/00-rssi-trial.sh -Algorithm SHA256).Hash.ToLowerInvariant()
```

前两个值应分别等于本次构建输出的 `Stock SHA-256` 和 `Patched SHA-256`。保留第三个值，上传后用来核对启动脚本。

**AP**：为这一次试用创建专用目录。这里刻意使用 `mkdir` 而不带 `-p`；预期看到 `目录就绪`。任一目标路径已有文件、目录或符号链接时，先查明归属，停止安装。

```sh
trial=/etc/gecoos/rssi-policy-trial
hook=/lib/wifi/00-rssi-trial.sh
if [ ! -e "$hook" ] && [ ! -L "$hook" ] && mkdir -m 700 "$trial"; then
    echo '目录就绪'
else
    echo '停在此处：请检查已有路径或目录权限'
fi
```

**电脑**：仅在看到 `目录就绪` 后，从仓库根目录上传这四个文件。使用二进制文件传输，原厂 `umac.stock.ko` 留在电脑。新开的 PowerShell 窗口要重新填写同一台 AP 的地址。

```powershell
$Ap = Read-Host '输入刚才核对过的同一台 AP 的管理地址'
scp ./patched.ko ./stock.sha256 ./patched.sha256 ./examples/00-rssi-trial.sh "root@${Ap}:/etc/gecoos/rssi-policy-trial/"
```

若客户端报告 SFTP 子系统不可用，且 AP 已提供传统 SCP，可在上述命令的 `scp` 后加 `-O` 重试；也可以用已有的管理员文件传输通道，将同名文件放入该目录。只有原厂网页管理权限时，请停在电脑上的离线构建与测试步骤。

## 3. AP：安装前再比一次摘要

```sh
cd /etc/gecoos/rssi-policy-trial
sha256sum 00-rssi-trial.sh
sh -n 00-rssi-trial.sh
```

核对启动脚本的摘要与电脑上第三个值完全一致。`sh -n` 应无语法报错。接下来这段命令只在原厂模块、当前装载路径和补丁三项都通过检查后复制钩子。看到 `钩子已就绪` 再进入下一步。

```sh
(
    set -e
    cd /etc/gecoos/rssi-policy-trial
    module=/lib/modules/4.4.60/umac.ko
    hook=/lib/wifi/00-rssi-trial.sh
    test "$(sha256sum "/rom$module" | cut -d ' ' -f 1)" = "$(cat stock.sha256)"
    test "$(sha256sum "$module" | cut -d ' ' -f 1)" = "$(cat stock.sha256)"
    test "$(sha256sum patched.ko | cut -d ' ' -f 1)" = "$(cat patched.sha256)"
    test "$(cat stock.sha256)" != "$(cat patched.sha256)"
    test ! -e "$hook" && test ! -L "$hook" || exit 1
    cp 00-rssi-trial.sh "$hook"
    chmod 644 "$hook"
    cmp 00-rssi-trial.sh "$hook"
    echo '钩子已就绪'
)
```

## 4. AP：显式启用一次，再重启

重启会中断这台 AP 的无线业务。确认有线连接可用且已安排测试时间后执行：

```sh
trial=/etc/gecoos/rssi-policy-trial
cmp "$trial/00-rssi-trial.sh" /lib/wifi/00-rssi-trial.sh &&
    touch "$trial/armed" && sync && reboot
```

## 5. AP：先查装载结果，再设接入阈值

重启后重新进入同一台 AP 的 root shell。

```sh
trial=/etc/gecoos/rssi-policy-trial
ls -d /sys/module/umac
ls "$trial/consumed"
cat /tmp/rssi-policy-trial.bound
grep -F ' /lib/modules/4.4.60/umac.ko ' /proc/mounts
sha256sum /lib/modules/4.4.60/umac.ko /rom/lib/modules/4.4.60/umac.ko
```

成功时，`umac` 已装载，`armed` 被改名为 `consumed`，挂载列表出现模块路径。`.bound` 的内容和装载路径的摘要都等于电脑记录的补丁摘要，`/rom` 的摘要仍等于原厂值。**看到 `consumed` 只表示钩子尝试过**；如果缺少 `.bound`、挂载或摘要不符，请直接按下一节恢复。可以用 `logread | grep -F rssi-policy-trial` 查看钩子错误。

用 `iw dev` 选择并确认一个终端正在使用的业务 AP 接口。把示例 `ath0` 换成该接口，避开 Mesh 回程和救援接口。

```sh
TEST_VAP=ath0
iw dev "$TEST_VAP" info
```

确认输出中的 `type AP`、SSID 和信道与目标一致，然后在同一 AP shell 执行：

```sh
cfg80211tool "$TEST_VAP" min_asoc_rssi -75
cfg80211tool "$TEST_VAP" g_min_asoc_rssi
```

预期回读类似 `ath0  g_min_asoc_rssi:-75`。先在强信号下用测试终端连接该 BSSID 并收发数据，再移动至弱信号位置做[关联拒绝与漫游的区分测试](verification.md)。需要同时试验在线剔除时，按[入门教程](getting-started.md#observe)另行运行 Lua 脚本。一次重启会清空 AP 的 `/tmp`，此前仅放在该目录的 Lua 脚本需要重新上传。

## 6. 退出试用与恢复原厂

- **重启前取消，或重启后发现 `armed` 还在。** 在 AP 上运行 `rm -f /etc/gecoos/rssi-policy-trial/armed && sync`，撤销待执行的试用。特别是 `umac` 已经加载时，这个示例钩子会跳过装载并保留 `armed`。
- **试用后恢复。** 如已运行剔除脚本，先在其前台终端按 Ctrl+C 停止。对每个设置过的业务接口执行以下两条命令，确认读回 `-90`。如果无线没起来，直接通过有线管理或本地控制台撤销标志并重启。

```sh
cfg80211tool "$TEST_VAP" min_asoc_rssi -90
cfg80211tool "$TEST_VAP" g_min_asoc_rssi
```

准备好恢复后，在 AP 上运行 `rm -f /etc/gecoos/rssi-policy-trial/armed && sync && reboot`。下一次启动通过只读原厂模块装载无线。重新连接管理终端，复查下面三项：

```sh
ls -d /sys/module/umac
sha256sum /lib/modules/4.4.60/umac.ko /rom/lib/modules/4.4.60/umac.ko
grep -F ' /lib/modules/4.4.60/umac.ko ' /proc/mounts
```

两个摘要应相同并等于原厂值，挂载查询应为空。再用测试终端确认原业务 Wi-Fi 能关联、能传输数据。确认恢复后，可移走**本次添加的** `/lib/wifi/00-rssi-trial.sh` 和试用目录；保留电脑上的原始配置备份。
