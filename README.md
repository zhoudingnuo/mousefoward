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

`capture.ps1 -Live` 每 60 ms 读一次光标，上限 16.7 包/秒，而且没有键盘采集。`forward.ps1` 的采集线程不轮询：注册 Raw Input（`WM_INPUT` + `RIDEV_INPUTSINK`），用挂住的 `GetMessage` 处理，并 `timeBeginPeriod(1)`。以前是 `PeekMessage` + `Thread.Sleep(1)` 轮询，而系统计时精度默认是 15.625 ms，`Sleep(1)` 实际睡 15.58 ms，一圈 15.58 ms → 每秒只转 64 圈，事件要等到下一轮才处理（实测投 200 个消息：轮询平均 15.6 ms、最大 20 ms；改成挂住的 `GetMessage` 是 0 ms）。包率 = 系统事件率，天花板是鼠标自己的上报率（常见 125 Hz）。增量超过 ±127 拆成多个包（中间的包只带移动，最后一个带按键和滚轮），键盘按 VKey → HID usage 出 6KRO 快照。

`-SelfTest` 只能验映射和拆分：`RIDEV_EXINPUTSINK` 是 `0x1000`（以前写的 `0x10` 本身不合法，所以那个错误 87 是我们自己传错值，不是机器拒绝它——用 `0x1000` 注册是成功的），但 `SendInput` 在这个进程里还是返回 0、错误 87（没有可交互桌面），所以事件路径要靠真的操作鼠标键盘。（顺带：`INPUT` 在 x64 上是 32 字节不是 20，`extraInfo` 是 `ULONG_PTR`，`type` 后面有 4 字节填充；按 20 传就是 87。）

自测现在也能验头和数据的分界：按 C 的布局把头也摆出来（24 字节头 + 20 字节数据），走的是真事件同一个 `Parse`。这只证明代码自己一致，Windows 把数据放在哪个偏移只有真事件能证明。

所以真事件按类型分开数：收到的键盘事件、到了映射但 VKey 不在表里的、和发出去的包。按一次键就能看出断在哪一段——键盘数不动是事件没到窗口；键盘数动而"没映射"也动是那个键不在表里；两个都不动而包在出就是通了。这三个数在 `-SelfTest` 和 `/api/state`（`capture.mouse` / `capture.key` / `capture.unmapped`）都有，页面上也显示。

"没映射"动了以后还要再看一层：前 5 个真键盘事件的原始字节存下来了（`capture.dumps`，页面显示最后一个的 VKey）。字节里 `0x41` 在数据段第 10 字节而表返回 `-1` 是表缺那个键；`0x41` 在别的位置是分界错了；读到的 VKey 是 0 是那个设备报的 usage 系统映射不出 VK。这些计数和字节是进程里的，改代码以后必须重启进程才生效。

桌面快捷方式指向这条。

## 前端（只有一个锁定按钮）

```powershell
powershell -File app/server.ps1            # 起服务，浏览器打开 http://localhost:8765
powershell -File app/server.ps1 -Open      # 起服务并打开浏览器
powershell -File app/server.ps1 -DryRun    # 不开串口，只统计包（接口照样能调）
```

点一下 = 参考实现的锁定模式：本端光标被拉回屏幕中心（跑过半屏的 80%），手只控制另一台机器；再点一下或按 Esc 退出。转发路径不变（参考实现里也没有改它，它连 `mouse.set_suppress()` 都没调用）。

锁定时是**真全屏**的黑屏：点按钮时调用 `requestFullscreen()`（只能在用户手势里同步调用，所以先进全屏再发请求），`::backdrop` 也设成黑色。全屏里按 Esc 被浏览器先用来退出全屏，`keydown` 收不到，所以在 `fullscreenchange` 里处理：退出全屏 = 退出锁定。实测（在浏览器里点按钮）：`document.fullscreenElement` 指向 `#screen`，`#panel` 被隐藏，`#screen` 是 `rgb(0,0,0)` 铺满整个视口，按钮被搬进黑屏里；按 Esc 退出全屏并解锁，再点一次回到原面板。采集走 Raw Input（`RIDEV_INPUTSINK`），和焦点在哪个窗口无关，所以黑屏期间转发照旧。

接口两种用法：转发（本机的输入原样送过去）和主动控制（程序自己发坐标和按键，不动本机的光标）。接口文档在 `api.md`，命令行客户端是 `tools/api.ps1`。

实测：`{"dx":200,"dy":0}` 出 2 个包（超过 ±127 被拆），`{"vk":65,"down":true}` 出 1 个 6KRO 快照；锁定以后把光标放到离中心 732/368 的位置，两秒内被拉回中心，`WM_INPUT` 计数不变 —— 程序改光标不产生 Raw Input 事件，所以不需要参考实现里拉回以前的 `skip_next_move()`（它用低级钩子，会被自己发的移动绊到）。

主循环里不能有会挂住的调用，所以 HTTP 用 `BeginGetContext`，状态行照旧只在安静的时候读（`POST /api/status` 只是排队，结果存着给 `/api/state`）。

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
| `tools/lib.ps1` | 采集和串口两段，`forward.ps1` 和 `app/server.ps1` 共用同一份 |
| `tools/api.ps1` | 从命令行调接口（主动控制） |
| `app/server.ps1` | 后端：采集 + 写串口 + 锁定 + HTTP 接口 |
| `app/index.html` | 前端：只有一个锁定按钮 |
| `api.md` | 接口文档：怎么调用我们的软件控制另一台机器（转发 + 主动控制） |
