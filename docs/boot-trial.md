# 单次启动试用与回退

这项实验只在**一台已有管理员 shell 的测试 AP** 上试用弱信号拒接。先在电脑上[构建补丁](shell-lab.md#build)，得到 `umac.stock.ko` 和 `patched.ko`。只想观察或剔除已连接终端，可直接做[原厂驱动上的观察实验](shell-lab.md#observe)。

**开始条件**：配置备份已导出到电脑，有线管理或本地控制台已试通，能在无线启动失败时重启设备。已经安装定制面板或其他无线模块装载脚本的 AP，请先参阅[原厂 AP 实装记录](getting-started.md)，避免叠加两套启动方式。

**退出路线**：[取消待执行试用，或恢复原厂](#restore)。这套钩子只尝试一个启动周期，启用它会中断一次该 AP 的无线服务。

## 1 · 在 AP 确认原厂状态

保持两个窗口：一个是测试 AP 的 root shell，另一个是电脑仓库根目录的 PowerShell。AP 上执行：

```sh
module=/lib/modules/4.4.60/umac.ko
id -u
uname -r
sha256sum "/rom$module" "$module"
grep -F " $module " /proc/mounts
df -k /overlay /tmp
```

**通过条件**：UID 为 `0`，内核为 `4.4.60`，两个摘要均等于构建时显示的 `Stock SHA-256`，挂载查询无输出。持久分区还要放得下 `patched.ko`，并留有运行空间。

还须确认本机在装载 `umac` **之前**会读入 `/lib/wifi/*.sh`。顺序不确定或发现其他定制钩子时，停在这里。

<details>
<summary>怎样检查启动顺序？</summary>

```sh
grep -nE 'include /lib/wifi|/lib/wifi/|insmod|kmodloader' /sbin/wifi
ls -l /lib/wifi/*.sh
```

这些输出用于定位代码。查看引入脚本的位置以及后续装载无线驱动的函数，确认本仓库的[钩子](../examples/00-rssi-trial.sh)有机会在模块装载前运行。

</details>

## 2 · 在电脑准备摘要，在 AP 新建目录

**电脑 · PowerShell**　在仓库根目录执行。以下写法给两个摘要文件使用小写十六进制、ASCII 编码和单个 LF 换行，适用于 Windows PowerShell 5.1 和 PowerShell 7。

```powershell
$stock = (Get-FileHash ./umac.stock.ko -Algorithm SHA256).Hash.ToLowerInvariant()
$patched = (Get-FileHash ./patched.ko -Algorithm SHA256).Hash.ToLowerInvariant()
$ascii = [Text.Encoding]::ASCII
[IO.File]::WriteAllText((Join-Path $PWD 'stock.sha256'), "$stock`n", $ascii)
[IO.File]::WriteAllText((Join-Path $PWD 'patched.sha256'), "$patched`n", $ascii)
$stock
$patched
$hookFile = './examples/00-rssi-trial.sh'
(Get-FileHash $hookFile -Algorithm SHA256).Hash.ToLowerInvariant()
```

前两行摘要要与构建器显示的输入、输出值分别一致。保留第三个摘要，用来核对上传后的脚本。

**AP · shell**　在同一台测试 AP 上创建全新目录：

```sh
trial=/etc/gecoos/rssi-policy-trial
hook=/lib/wifi/00-rssi-trial.sh
test ! -e "$hook" && test ! -L "$hook" &&
    mkdir -m 700 "$trial" && echo '目录就绪'
```

**通过条件**：看到 `目录就绪`。若目录或钩子已存在，先查明归属，勿覆盖后继续。

## 3 · 上传四个文件，核验后安装钩子

**电脑 · PowerShell**　填写与第 1 步相同的 AP 地址，并核实 SSH 主机指纹。通过 SCP 以二进制传输这四个文件：

```powershell
$Ap = Read-Host '测试 AP 的管理地址或主机名'
$target = "root@${Ap}:/etc/gecoos/rssi-policy-trial/"
scp ./patched.ko ./stock.sha256 ./patched.sha256 $hookFile $target
```

**AP · shell**　先检查钩子。摘要要与电脑上记录的第三个值一致，语法检查应无报错：

```sh
cd /etc/gecoos/rssi-policy-trial
sha256sum 00-rssi-trial.sh
sh -n 00-rssi-trial.sh
```

再执行整段核验。任一项失败都会退出子 shell；只有看到 `钩子就绪` 才进入下一步。

```sh
(
    set -e
    cd /etc/gecoos/rssi-policy-trial
    module=/lib/modules/4.4.60/umac.ko
    hook=/lib/wifi/00-rssi-trial.sh
    digest() { sha256sum "$1" | cut -d ' ' -f 1; }
    test "$(digest "/rom$module")" = "$(cat stock.sha256)"
    test "$(digest "$module")" = "$(cat stock.sha256)"
    test "$(digest patched.ko)" = "$(cat patched.sha256)"
    test "$(cat stock.sha256)" != "$(cat patched.sha256)"
    test ! -e "$hook" && test ! -L "$hook" || exit 1
    cp 00-rssi-trial.sh "$hook"
    chmod 644 "$hook"
    cmp 00-rssi-trial.sh "$hook"
    echo '钩子就绪'
)
```

<details>
<summary>SCP 或摘要检查失败怎么办？</summary>

- 客户端提示 SFTP 子系统不可用，而且 AP 已提供传统 SCP 时，可在 `scp` 后加 `-O` 重试。也可使用已有的管理员文件传输通道，上传至同一目录。
- 摘要对不上时，重新核对目标 AP、输入原件以及 Windows 生成摘要文件时使用的编码和换行。此时不要创建 `armed`。

</details>

## 4 · 只启用这一次启动

**AP · shell**　确认已腾出重启时间、有线管理仍可用，再执行：

```sh
trial=/etc/gecoos/rssi-policy-trial
cmp "$trial/00-rssi-trial.sh" /lib/wifi/00-rssi-trial.sh &&
    touch "$trial/armed" && sync && reboot
```

重新连入这台 AP 的 shell，查看启动结果：

```sh
trial=/etc/gecoos/rssi-policy-trial
module=/lib/modules/4.4.60/umac.ko
ls -d /sys/module/umac
ls "$trial/consumed"
cat /tmp/rssi-policy-trial.bound
grep -F " $module " /proc/mounts
sha256sum "$module" "/rom$module"
```

**通过条件**：模块已经装载，`armed` 已被改名为 `consumed`；挂载列表出现该模块路径。`.bound` 和装载路径的摘要等于 `Patched SHA-256`，`/rom` 副本的摘要等于 `Stock SHA-256`。单独看到 `consumed` 只说明钩子尝试过。任一项不符，跳到[恢复原厂](#restore)；可用 `logread | grep -F rssi-policy-trial` 查找错误。

## 5 · 先对一个业务接口启用

**AP · shell**　用 `iw dev` 找到手机使用的可见业务 SSID。把下面的 `ath0` 改为对应接口，核对 `type AP`、SSID 与信道。跳过 Mesh 回程和救援接口。

```sh
TEST_VAP=ath0
iw dev "$TEST_VAP" info
```

核对正确后，在同一 shell 执行：

```sh
cfg80211tool "$TEST_VAP" min_asoc_rssi -75
cfg80211tool "$TEST_VAP" g_min_asoc_rssi
```

**通过条件**：输出包含选定接口和 `g_min_asoc_rssi:-75`。接下来用[手机和目标 AP 的记录验证](verification.md#phone)。若还要开启在线剔除，按[观察与剔除](shell-lab.md#observe)执行；AP 的 `/tmp` 会随重启清空，临时上传的 Lua 脚本需再次传入。

<a id="restore"></a>

## 退出或恢复原厂

**尚未重启，或重启后仍看到 `armed`**：从 AP 的管理 shell 撤销待执行的试用。钩子遇到已装载的 `umac` 会跳过并保留该标志。

```sh
rm -f /etc/gecoos/rssi-policy-trial/armed && sync
```

**已经启用接口门槛**：若同时运行了剔除脚本，先在其前台窗口按 Ctrl+C。把 `TEST_VAP` 设为试用过的接口，逐个恢复并确认读回 `-90`：

```sh
cfg80211tool "$TEST_VAP" min_asoc_rssi -90
cfg80211tool "$TEST_VAP" g_min_asoc_rssi
```

**恢复驱动**：通过有线管理或本地控制台执行下列命令。即使无线没有起来，也应先撤销标志再重启。

```sh
rm -f /etc/gecoos/rssi-policy-trial/armed && sync && reboot
```

再次登录后检查：

```sh
module=/lib/modules/4.4.60/umac.ko
ls -d /sys/module/umac
sha256sum "$module" "/rom$module"
grep -F " $module " /proc/mounts
```

**恢复完成**：两个摘要相同且等于原厂值，挂载查询为空。测试手机能重新关联并传输数据后，可移走**本次添加**的钩子和试用目录；电脑上保留原始配置备份。
