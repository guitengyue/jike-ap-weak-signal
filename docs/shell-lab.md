# 已有管理员 shell 时，怎样试用公开工具

同一台 AP 上可以分开试两件事：

- **已连上的终端太弱，想看看谁会被踢** → [观察，按需启用剔除](#observe)。原厂驱动即可，约 10 秒能看完第一组结果。
- **想在弱信号终端连进来之前拒绝它** → [从自己的原厂模块构建补丁](#build)。可以直接做这一项。构建在电脑上完成，装载才需要重启 AP。

本页适用于已经有 **AP 管理员 shell 和文件传输通道** 的读者。示例用 Windows PowerShell、已配置的 SSH 和 SCP。仅有原厂网页账号的读者，请看[通过 Web 管理后台完成的实装记录](getting-started.md)。

<a id="prepare"></a>
## 开始前：电脑上备好仓库和地址

从 GitHub 的 **Code → Download ZIP** 下载、解压，在能看到 `README.md` 和 `tools` 的目录打开 PowerShell。用 Git 也可以：

```powershell
git clone https://github.com/guitengyue/jike-ap-weak-signal.git
cd jike-ap-weak-signal
```

**电脑 · PowerShell**　选一台测试 AP，记下其管理页显示的型号和完整固件构建号，再填写这台 AP 自己的地址。下面的电脑命令都在这个窗口执行；新开窗口时要切回仓库目录并重设 `$Ap`。

```powershell
Get-Item .\tools\rssi_kick.lua
$Ap = Read-Host '测试 AP 的管理 IP 或主机名'
```

首次 SSH 或 SCP 连接时核对主机指纹。如果 AP 已提供其他管理员文件传输通道或本地控制台，也可以按文中的目标路径上传，并在控制台执行标为“AP”的命令。

<a id="observe"></a>
## A. 观察已连接终端

**电脑 · PowerShell**　上传脚本并打开 AP shell。脚本放在临时目录，重启后需要重新上传。

```powershell
scp .\tools\rssi_kick.lua "root@${Ap}:/tmp/rssi_kick.lua"
ssh "root@$Ap"
```

**AP · shell**　检查权限和固件自带的工具。要启用剔除，`id -u` 应输出 `0`。最后一行应打印 `Lua dependencies OK`。

```sh
id -u
command -v lua
ls -l /usr/sbin/iw /usr/sbin/cfg80211tool
lua -e 'assert(require("uci").cursor); assert(require("iwinfo").qcawifi.assoclist); assert(require("nixio").nanosleep); print("Lua dependencies OK")'
```

**AP · shell**　让测试终端连上你准备观察的 Wi-Fi。在下面两条命令的输出里，找出同时满足三个条件的接口：SSID 是测试网络，类型为 `AP`，接口名也出现在 `br-lan` 的成员列表。双频共用一个 SSID 时看 `channel` 的频率。跳过 Mesh、救援和无线回程接口。

```sh
iw dev
ls /sys/class/net/br-lan/brif/
```

下例假定查到的接口叫 `ath0`；请替换成你自己的。再看一次接口信息，确认后开始观察。测试终端持续发送一些数据，AP 才有新读数可看。

```sh
TEST_VAP=ath0
iw dev "$TEST_VAP" info
lua /tmp/rssi_kick.lua --iface "$TEST_VAP" --threshold -82 --once --dry-run
```

约 10 秒内会打印三行。下面的例子表示第三轮已出现一个可剔除的候选，观察模式会让它继续连接：

```text
mode=observe readable_vaps=1 fresh=1 weak=1 eligible=0 threshold=-82
mode=observe readable_vaps=1 fresh=1 weak=1 eligible=0 threshold=-82
mode=observe readable_vaps=1 fresh=1 weak=1 eligible=1 threshold=-82
```

- `readable_vaps=1`：已读到这个业务接口的关联表。`fresh=0` 表示这轮没有符合条件的近期活动读数，例如终端正在休眠。
- `weak` 是低于 −82 dBm 的非豁免终端数。`eligible` 还要求同一连接有三次新的低读数，并且已过冷却期。恰好 −82 dBm 时保留连接。

<a id="kick"></a>
### 需要实际剔除时

**AP · shell**　确认选对接口后，在同一窗口以前台方式持续执行。若有需要保护的设备，**启动前**就在命令末尾加上 `--protect 00:00:5e:00:53:01`，并将示例 MAC 换成该设备实际使用的 Wi-Fi 地址。

```sh
lua /tmp/rssi_kick.lua --iface "$TEST_VAP" --threshold -82 --loop --apply
```

`mode=apply` 表示已启用。每轮最多处理一个终端；断开前会再读一次信号和关联身份。日志中的 `result=association-absent` 表示终端已离开原接口，`still-associated` 表示它仍在，`unverified` 表示结果未能确认。一次尝试后对同一 MAC 冷却 180 秒。

按 **Ctrl+C** 停止剔除，输入 `exit` 回电脑。要换门槛，先用新值重新观察。多接口可在**一个进程**中重复写 `--iface`，多台受保护终端可重复写 `--protect`。这套用法只在前台进程运行期间生效。

<a id="build"></a>
## B. 离线构建拒绝弱信号接入的补丁

准备一台可以重启、有线管理或控制台可用的测试 AP，从管理页导出配置，留在电脑上。打开前面[准备好的 PowerShell](#prepare)；如果刚才在 AP 上运行了剔除脚本，先 Ctrl+C 并 `exit`。

**电脑 · PowerShell**　下面第一条命令通过已有 SSH 只读查询 AP。确认内核为 `4.4.60`，并按下方清单逐字核对原厂模块的 SHA-256。型号、构建或哈希不匹配时停止试用。

```powershell
ssh "root@$Ap" 'uname -r; sha256sum /rom/lib/modules/4.4.60/umac.ko'
```

<details>
<summary>查看支持的三个原厂模块指纹</summary>

- AX1800MI / AX5RM · `7.1_2022032400`<br>
  `54171772269e778d3133174dcb6e5d677539e501a1cef2c975ca6a61fbda2319`
- N3000 · `7.2_2022111500`<br>
  `f8f83ac4c34a3eacbd32126785ed0cf61ff945eda09044335192c9fd2e25e0cc`
- N3000 · `8.0_2024061700`<br>
  `9ece3e2c6bef524d0ee78fdc4af8363f44618e2b22978ad135631ca9b926cb50`

</details>

**电脑 · PowerShell**　把原件下载到仓库目录，给本机副本计算哈希，并与 AP 刚输出的值对照。首次试用请用本地 NTFS 等支持硬链接的磁盘，并使用没有同名输入、输出文件的工作副本。

```powershell
if ((Test-Path .\umac.stock.ko) -or (Test-Path .\patched.ko)) { throw '已有同名文件，请换用干净的工作副本' }
scp "root@${Ap}:/rom/lib/modules/4.4.60/umac.ko" .\umac.stock.ko
(Get-FileHash .\umac.stock.ko -Algorithm SHA256).Hash.ToLowerInvariant()
```

仍在**电脑**上创建 Python 3 环境。若你的 Windows 只有 `python` 命令，用 `python -m venv .venv` 代替第一行。

```powershell
py -3 -m venv .venv
& .\.venv\Scripts\python.exe -m pip install keystone-engine==0.9.2
```

运行下面一条命令生成补丁。如果要豁免一台固定设备，在**首次构建时**给这条命令追加 `--exempt-mac 00:00:5e:00:53:01`，将示例 MAC 换成该终端的 Wi-Fi 地址。接入侧支持一个豁免地址；同时启用剔除时，也要在 A 的脚本中为同一设备设置 `--protect`。

```powershell
& .\.venv\Scripts\python.exe .\tools\build_umac.py .\umac.stock.ko .\patched.ko
```

成功时会打印匹配的机型、`Stock SHA-256`、`Patched SHA-256` 和 `Wrote ... bytes to patched.ko`。保存两项摘要；到这里仅在电脑生成了文件。接下来按[单次启动试用与恢复](boot-trial.md)上传、校验、重启并设置目标业务接口的接入门槛。验证手机究竟被拒接还是自行漫游，见[空口验证方法](verification.md)。

<details>
<summary>常见卡点</summary>

- **SSH 被拒绝或 SCP 找不到 SFTP 子系统。** 先确认 AP 已开放相应管理服务。如果设备只提供旧式 SCP，可在电脑端改用 `scp -O`。只有网页访问权限时，请阅读[原厂实装流程](getting-started.md)。
- **`cannot open ...rssi_kick.lua`。** 在 AP 上执行 `ls -l /tmp/rssi_kick.lua`；脚本须先传入，重启后要重传。
- **`readable_vaps=0`。** 核对业务接口在 UCI 中有唯一配置，`ifname` 和 `athname` 一致，`mode=ap`、`network=lan`、`hidden=0`，且无线设备已启用。脚本还会比对实时 SSID 和 LAN 网桥成员。
- **`another apply process holds the lock`。** 先停掉自己的旧进程，再用一个进程管理所有选定接口；不要重复启动。
- **`Unsupported stock SHA-256` 或输出已存在。** 前者请重新核对原件与构建号；后者请检查已有文件或换用干净的工作副本。构建器会保留已有输出。

</details>
