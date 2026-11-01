# CH32V305 鼠标 + 键盘转发固件（最小版）

从闪灯固件长出来的下一步。整个固件只有：时钟 + 灯 + 两个 USB 口 + 一个解析/转发循环。没有 UART，没有打印。

```
本端 PC ──USBFS(CDC 虚拟串口)──▶ 板 ──USBHS(HID 复合键鼠)──▶ 另一台机器
```

本端往虚拟串口写协议字节，板逐字节解析，校验通过后从 USBHS 的 HID 端点发出去。
**板子不会自己去抓本端的鼠标键盘** —— 本端的动作要由一个程序读出来、按协议写成字节、发到 COM 口。

## 协议（字节流，首字节区分包类型）

| 包 | 字节 | 说明 |
|---|---|---|
| 鼠标 | `0xAA` `flags` `dx` `dy` `wheel` `xor` | flags: bit0 左键 bit1 右键 bit2 中键 bit4 后退 bit5 前进 bit6 滚轮有效 |
| 键盘 | `0xAB` `mod` `0` `key ×6` `xor` | HID usage page 0x07，6KRO 快照 |
| 状态查询 | `'S'` | 板从 CDC IN 回一行 |

校验 = 除最后一个字节以外所有字节的异或。

## 灯（和闪灯固件一样的脚，PA2/PA3）

板子上只有一个灯，所以它只报一个数：频率。

| 频率 | 含义 |
|---|---|
| 1 Hz | 主循环在跑，本端口一个请求都没收到 |
| 2 Hz | 本端口收到过请求，但枚举没走完 |
| 3 Hz | 本端口已枚举（COM 应该出现） |
| 4 Hz | 键鼠口已枚举 —— 只有本端口没动静时才显示这个 |
| 常亮 | HardFault |

## 状态行

发一个 `'S'`，读回来：

```
S cdc=1 hs=1 req=1 ok=0 err=0 drop=0 ms=0 kb=0
```

`ok` 不涨 = 本端没有字节进来；`ok` 涨但 `ms`/`kb` 不涨 = 解析通过但端点没发出去；`ms`/`kb` 涨而另一台机器不动 = 另一台机器那边的 HID 问题。

读这行必须用阻塞读：驱动只有在有一个读请求挂着的时候才会去取设备的 IN 数据，`ReadExisting()` 只清驱动缓冲区，永远读不到。`tools/status_test.ps1` 用 kernel32 的 `CreateFile` + `ReadFile` 做阻塞读。

## 构建

```powershell
powershell -File firmware/build.ps1 -Toolchain 'C:\path\to\xpack-riscv-none-elf-gcc-14.2.0-3\bin'
```

产物 `firmware/firmware.hex`，用 wchisp 烧：

```powershell
wchisp -c CH32V305 -e -f firmware/firmware.hex
```

工具链必须是 xPack GCC 14.2（`rv32imac_zicsr_zifencei` / `ilp32`）。所有 ISR 用 `interrupt("machine")`：xPack GCC 不认 WCH 的 `interrupt("WCH-Interrupt-fast")`，用那个属性生成的结尾不是 `mret`。`build.ps1` 最后会把每个 handler 的结尾打出来核对。

## 测试

```powershell
powershell -File tools/send_test.ps1 -Com COM5
```

往 COM 口发鼠标包和键盘包，看另一台机器的光标动不动。

发完包读状态：

```powershell
powershell -File tools/status_test.ps1
```

发一个鼠标包、一个键盘包，中间读状态行。板子上当前烧的这一版数据位不翻转，总线复位后只能读到第一行，第二行会超时；烧 `firmware/firmware.hex`（它已经修了这条）之后能连续读。

## 判断链路通不通

```powershell
powershell -File tools/capture.ps1
```

脚本里写死了一段轨迹：半径 60 像素的圆，24 步、每步最大 16 像素（一个 HID 报告最多带 ±127），每步 60 ms。它只做一件事——把这段轨迹发到 COM 口，然后读一次状态行，打印断在哪一段。另一台机器的光标照着画出一个圆，就是整条通路通的。

判断按计数器读：`ok` 不到发的包数 = 本端到板这一段断了；`ok` 到了但 `ms` 不到 = 解析对了却没写进端点（主机没在轮询 EP2，或主循环取包慢）；`ms` 到了 = 报告写进端点，但 `ms` 只表示写进端点、不表示主机取走，那一段只能看那边画不画圆。

状态行必须阻塞读，而且先发包再读：这一版板子只能读总线复位之后的第一行，要让那一行里的计数器是发完包以后的值。读不到这一行，就是数据位那条（拔插一次再跑，或烧 `firmware/firmware.hex`）。

```powershell
powershell -File tools/capture.ps1 -Live          # 改成转发真实鼠标（每 60 ms 读光标，不判断）
powershell -File tools/capture.ps1 -DryRun        # 只打印包，不开串口
powershell -File tools/capture.ps1 -Loops 10      # 跑 10 圈
```

桌面上放一个快捷方式指向这条命令，双击即跑轨迹并打印判断。

## 转发（事件驱动）

```powershell
powershell -File tools/forward.ps1                # 转发
powershell -File tools/forward.ps1 -Debug         # 每 50 包打印包和帧率（不读设备）
powershell -File tools/forward.ps1 -Status        # 安静 5 秒以后读一次状态行（判断断在哪一段）
powershell -File tools/forward.ps1 -SelfTest      # 不接串口，直接验证映射和拆分
powershell -File tools/forward.ps1 -NoKeyboard    # 只转发鼠标
```

转发路径里没有任何会挂住的调用：读状态行是一个会挂住的往返（实测每次 1.5 s），挂住的这段时间采集线程还在出包，读回来以后一次性全倒出去，那边就是"卡一下然后跳一段"。所以帧率从包数自己算，状态行只在安静了 5 秒以后读（那时候没有在转发），读不到就退避 30 秒。

`capture.ps1 -Live` 每 60 ms 读一次光标，上限 16.7 包/秒，而且没有键盘采集。`forward.ps1` 不轮询：注册 Raw Input（`WM_INPUT` + `RIDEV_INPUTSINK`），系统每来一个事件就出一个包，包率 = 系统事件率（鼠标一般 125~1000 Hz）。增量超过 ±127 拆成多个包（中间的包只带移动，最后一个带按键和滚轮），键盘按 VKey → HID usage 出 6KRO 快照。

`-SelfTest` 只能验映射和拆分：这台机器上 `RIDEV_EXINPUTSINK` 被拒（错误 87），`SendInput` 注入的事件到不了 Raw Input，所以事件路径要靠真的操作鼠标键盘。

桌面快捷方式指向这条。

## 目录

| 文件 | 说明 |
|---|---|
| `firmware/main.c` | 解析 + 转发循环 |
| `firmware/fw.h` | 协议、端点号、灯语 |
| `firmware/usbfs_cdc.c` | 本端：CDC 虚拟串口 |
| `firmware/usbhs_km.c` | 输出端：HID 复合键鼠 |
| `firmware/ch32v30x_it.c` | 灯（TIM2 驱动）+ HardFault |
| `firmware/build.ps1` | 构建脚本 |
| `firmware/firmware.hex` | 当前构建产物 |
| `analysis.md` | 失败分析（上一版为什么报 Code 43，v3 为什么跑不通） |
| `tools/send_test.ps1` | 直接往 COM 口发包 |
| `tools/capture.ps1` | 跑写死的轨迹（一个圆）+ 读状态行，判断链路断在哪一段 |
| `tools/forward.ps1` | 事件驱动转发：Raw Input 取鼠标/键盘事件，一个事件一个包 |
| `tools/status_test.ps1` | 阻塞读状态行（`ReadExisting()` 读不到，必须挂一个读请求） |
