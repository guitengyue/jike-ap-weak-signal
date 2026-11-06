# 第一次使用：从观察信号到启用策略

第一次建议只拿**一台 AP、一个业务 SSID、一台可以暂时断网的测试终端**。下面以 Windows PowerShell 和已配置 SSH 的 AP 为例。只想剔除已连接的弱信号终端，做到第 3 步就够了；需要在新终端接入前拒绝，再做第 4 步和单次启动试用。

<a id="prepare"></a>
## 1. 在电脑上下载，确认能登录 AP

**电脑 · PowerShell**　从 GitHub 的 **Code → Download ZIP** 下载并解压，在包含 `README.md` 和 `tools` 的文件夹打开 PowerShell。装有 Git 的电脑也可以用：

```powershell
git clone https://github.com/guitengyue/jike-ap-weak-signal.git
cd jike-ap-weak-signal
```

确认能找到脚本，再登录**准备测试的那台 AP**。下面假定你已有合法的 `root` 管理权限，并使用默认 SSH 端口。

```powershell
Get-Item .\tools\rssi_kick.lua
$Ap = Read-Host '输入测试 AP 自己的管理 IP 或主机名'
ssh "root@$Ap"
```

**AP · shell**　登录后运行以下只读检查。后续启用剔除需要 `id -u` 输出 `0`。记录 AP 网页上显示的型号和完整固件构建号，核对 [README 兼容表](../README.md)。本项目验证过的内核版本为 `4.4.60`。

```sh
id -u
uname -r
command -v lua
ls -l /usr/sbin/iw /usr/sbin/cfg80211tool
lua -e 'assert(require("uci").cursor); assert(require("iwinfo").qcawifi.assoclist); assert(require("nixio").nanosleep); print("Lua dependencies OK")'
```

最后一行应该打印 `Lua dependencies OK`。如果 SSH 提示连接被拒绝，先向设备管理员确认 shell 的可用方式；网页密码可用也不代表 SSH 已开放。只有网页访问权限时，到这里停止设备端操作。

## 2. 在 AP 上找接口，再上传脚本

**AP · shell**

```sh
iw dev
ls /sys/class/net/br-lan/brif/
```

在 `iw dev` 输出中，找到 **SSID 与测试 Wi-Fi 名称一致**、`type AP` 的一组，再读它上方的 `Interface`。用 `channel` 后面的频率区分同名 SSID 的两个频段。选中的接口也应在第二条命令的 LAN 网桥成员列表里。跳过 SOS、Mesh 回程和 `type managed` 的接口。各型号的接口编号可能不同。

假设查到的是 `ath0`。再核对一次，并在 AP 的临时目录准备上传位置：

```sh
TEST_VAP=ath0
iw dev "$TEST_VAP" info
mkdir -p /tmp/rssi-guide
exit
```

**电脑 · PowerShell**　现在回到了刚才设置 `$Ap` 的窗口。上传仓库自带的 Lua 文件，再次登录 AP：

```powershell
scp .\tools\rssi_kick.lua "root@${Ap}:/tmp/rssi-guide/rssi_kick.lua"
ssh "root@$Ap"
```

如果设备已有其他管理员文件传输方式，可以用它把同一文件放到同一路径。如果 SCP 提示缺少 SFTP 子系统，先确认设备已提供旧式 SCP 服务；确认后可把上条命令的 `scp` 改为 `scp -O`。下面的 `/tmp` 文件在 AP 重启后需要重新上传。

<a id="observe"></a>
## 3. 先观察三轮，再选择是否开始剔除

**AP · shell**　这是一次新登录，重新设置接口变量，把 `ath0` 换成第 2 步核实的名字。让测试终端连上该 SSID，保持少量上行流量。

```sh
TEST_VAP=ath0
lua /tmp/rssi-guide/rssi_kick.lua --iface "$TEST_VAP" --threshold -82 --once --dry-run
```

默认每 5 秒采一次，共三轮，约 10 秒后返回命令行。以下是**示例**：一台终端在三轮里都提供了新的低信号读数。

```text
mode=observe readable_vaps=1 fresh=1 weak=1 eligible=0 threshold=-82
mode=observe readable_vaps=1 fresh=1 weak=1 eligible=0 threshold=-82
mode=observe readable_vaps=1 fresh=1 weak=1 eligible=1 threshold=-82
```

| 字段 | 怎么看 |
| --- | --- |
| `readable_vaps` | 通过接口和关联表检查的数量。只选一个接口时应为 `1`；连续为 `0`，先查下方故障表。 |
| `fresh`、`weak` | 本轮有可用近期活动读数的非豁免终端数，以及其中低于门槛的数量。接口可读而 `fresh=0` 很常见，例如终端正在休眠。 |
| `eligible` | 已连续积累三个新低读数且不在冷却期的终端数。`mode=observe` 时即使这里大于零也不会下发断开。 |

确认业务接口和读数都正确后，才切到执行模式。以下命令在前台持续运行：

```sh
lua /tmp/rssi-guide/rssi_kick.lua --iface "$TEST_VAP" --threshold -82 --loop --apply
```

看到 `mode=apply` 表示进入执行模式。程序会先复查信号与关联身份，每轮最多处理一台。日志 `result=association-absent` 表示复查时终端已离开原接口；`still-associated` 表示仍在原接口；`unverified` 表示未能确认断开结果。一次尝试后，对同一 MAC 有 180 秒冷却时间。

- **加第二个接口**：在同一条命令里重复 `--iface`，例如 `--iface ath0 --iface ath1`。先逐个观察，确认两个都是目标业务接口。
- **保护固定设备**：在命令末尾加 `--protect 00:00:5e:00:53:01`，并把文档示例地址替换成该终端在 Wi-Fi 下实际使用的 MAC。可重复 `--protect` 添加多台。
- **停止或改阈值**：按 `Ctrl+C` 停止。要改门槛，先用新值运行 `--once --dry-run`，确认后再开 `--loop --apply`。公开脚本需要由这个前台进程持续运行；以上步骤不会创建开机服务。

<a id="build"></a>
## 4. 可选：构建“弱信号拒绝接入”模块

如果只需要第 3 步的剔除，可跳过本节。要启用接入门槛，先从测试 AP 的管理页导出配置，确认通过**网线或控制台**也能管理和恢复这台 AP。在另一台设备或另一个固件版本上试用时，应重新从那台设备取原件。

**AP · shell**　停止前台剔除程序后，读取原厂只读分区中的模块指纹，然后返回电脑：

```sh
sha256sum /rom/lib/modules/4.4.60/umac.ko
exit
```

| 型号与固件 | 原厂 `umac.ko` 的 SHA-256 |
| --- | --- |
| AX1800MI / AX5RM · 7.1_2022032400 | `54171772269e778d3133174dcb6e5d677539e501a1cef2c975ca6a61fbda2319` |
| N3000 · 7.2_2022111500 | `f8f83ac4c34a3eacbd32126785ed0cf61ff945eda09044335192c9fd2e25e0cc` |
| N3000 · 8.0_2024061700 | `9ece3e2c6bef524d0ee78fdc4af8363f44618e2b22978ad135631ca9b926cb50` |

**只有完整指纹一致才继续。** 在电脑的仓库根目录使用一个全新的构建位置；以下示例假定其中还没有 `umac.stock.ko` 和 `patched.ko`。用 SCP 复制二进制原件，并确认下载后的指纹与上表、AP 输出一致。

**电脑 · PowerShell**

```powershell
if ((Test-Path .\umac.stock.ko) -or (Test-Path .\patched.ko)) { throw '请改用干净的仓库工作副本，以免混用原件或输出。' }
scp "root@${Ap}:/rom/lib/modules/4.4.60/umac.ko" .\umac.stock.ko
(Get-FileHash .\umac.stock.ko -Algorithm SHA256).Hash.ToLowerInvariant()
```

构建在电脑上完成，AP 上无需安装 Python。以下命令使用 Windows 的 Python 3 启动器；若电脑只有 `python` 命令，可用 `python -m venv .venv` 创建环境。

```powershell
py -3 -m venv .venv
& .\.venv\Scripts\python.exe -m pip install keystone-engine==0.9.2
& .\.venv\Scripts\python.exe .\tools\build_umac.py .\umac.stock.ko .\patched.ko
```

**需要接入豁免时**，将上面最后一条构建命令换成下面这条，用你自己的终端 MAC。构建器接受一台豁免设备；它只跳过新增的接入信号检查。若还运行第 3 步的剔除程序，记得给那条命令传入相同的 `--protect`。

```powershell
$ProtectedMac = Read-Host '输入需要保护的 Wi-Fi 终端 MAC，使用冒号分隔'
& .\.venv\Scripts\python.exe .\tools\build_umac.py .\umac.stock.ko .\patched.ko --exempt-mac $ProtectedMac
```

成功时会打印型号、`Stock SHA-256`、`Patched SHA-256` 和 `Wrote ... bytes to patched.ko`。保存这两项摘要。**生成文件时 AP 仍在运行原来的驱动。** 下一步按[单次启动试用与回退](boot-trial.md)上传文件、校验、单次装载，再设置和读回 `-75`。要判断一次真实连接是否因门槛被拒绝，见[空口验证步骤](verification.md)。

## 卡在哪一步时看这里

| 现象 | 下一步 |
| --- | --- |
| `cannot open ...rssi_kick.lua` | 在 AP 执行 `ls -l /tmp/rssi-guide/rssi_kick.lua`。若刚重启或传错路径，回到第 2 步重新上传。 |
| Lua 报 `module ... not found` | 用第 1 步的依赖检查定位缺失模块，核对 AP 固件和执行环境，先停在观察阶段。 |
| `readable_vaps=0` | 重新核对 `iw dev` 的实际 SSID、类型、接口名和 `br-lan` 成员。脚本还检查该接口有唯一的 UCI 业务配置、`ifname` 与 `athname` 一致、`mode=ap`、`network=lan`、`hidden=0`，并排除禁用、WDS、Mesh、回程和救援接口。 |
| `another apply process holds the lock...` | 检查先前运行的执行进程。双频应由同一进程指定两个 `--iface`；先停止自己的旧进程再启动新进程。 |
| `Unsupported stock SHA-256` 或输出文件已存在 | 前者应停在原厂驱动并复核原件；后者应核对已有输出或另取新文件名。构建器会拒绝覆盖，输出目录需要支持硬链接，例如本地 NTFS。 |
| 能读回 `-75`，手机却仍有 Wi-Fi | 看手机实际连接的 BSSID。原厂也可能接受参数，先复查本次引导的挂载和哈希，再核对目标 BSSID 的关联响应。 |
