# 接口文档：用我们的软件控制另一台机器

通路只有一条：

```
本端(跑服务的这台) --COM 口(USBFS CDC, VID 1A86)--> 板子 --USBHS HID(键鼠)--> 另一台机器
```

控制另一台机器有两种方式，走的是同一条通路、同一套包：

1. **转发**：本机的鼠标键盘动作原样送过去。服务采集事件，主循环把包写进串口。
2. **主动控制**：程序自己发坐标和按键，不动本机的光标。接口调用走的是和采集同一个函数（同一个拆分、同一个校验和、同一个队列），所以两边的行为完全一致。

服务：`app/server.ps1`，前端 `app/index.html`（只有一个锁定按钮）。

```
powershell -File app\server.ps1              # 起服务，http://localhost:8765
powershell -File app\server.ps1 -Open        # 起服务并打开浏览器
powershell -File app\server.ps1 -DryRun      # 不开串口，只统计包（接口照样能调）
```

## 锁定按钮

点一下 = 参考实现（mouse-forwarder-pre-nn）的锁定模式，逻辑照它抄：

- 本端光标不再跟着手走：跑过半屏的 `OffPct`（默认 80%）就被拉回屏幕中心。
- 再点一下，或者按 Esc，退出。
- 锁定时是**真全屏**的黑屏：点按钮时调用 `screen.requestFullscreen()`（只能在用户手势里同步调用，所以先进全屏再发请求），`::backdrop` 也设成黑色。全屏里只留这一个按钮和一行状态。采集走 Raw Input（`RIDEV_INPUTSINK`），和焦点在哪个窗口无关，所以黑屏期间转发照旧。
- 全屏里按 Esc 被浏览器先用来退出全屏，`keydown` 收不到，所以在 `fullscreenchange` 里处理：从全屏退出 = 退出锁定。程序自己退出的全屏用 `exitByUs` 标记，免得把程序退出当成按 Esc。
- 实测（在浏览器里点按钮）：`document.fullscreenElement` 指向 `#screen`，`#panel` 被隐藏，`#screen` 是 `rgb(0,0,0)` 铺满整个视口（1280×720），按钮被搬进黑屏里；按 Esc 退出全屏并解锁；再点一次回到原面板并退出全屏。
- 转发路径不变。参考实现里锁定也没有改转发（它连 `mouse.set_suppress()` 都没有调用），这里同样不改：锁定只改本端光标的处理。

一个实际差别：参考实现用低级钩子取事件，所以拉回光标以前要先 `skip_next_move()`，不然 `SetCursorPos` 会被当成一次移动发出去。这里用 Raw Input，它只报设备来的输入，程序改光标不产生事件（实测：连 `SetCursorPos` 十次，`WM_INPUT` 计数不变），所以不需要跳过。

阈值按半屏的百分比算，不照抄参考的 950/500 像素：参考那台是 1920×1080（半屏 960/540），在 1536×864（半屏 768/432）上 900 永远达不到，一次都不会触发。

## HTTP 接口

Base：`http://localhost:8765`。请求和响应都是 JSON（UTF-8）。

| 接口 | 方法 | 请求 | 响应 |
|---|---|---|---|
| `/` | GET | — | 前端页面 |
| `/api/state` | GET | — | 状态（见下） |
| `/api/lock` | POST | `{"enabled":true}` 或 `{"toggle":true}` | `{"lock":true}` |
| `/api/mouse` | POST | `{"dx":120,"dy":-40,"buttons":1,"wheel":0}` | `{"queued":2}` |
| `/api/key` | POST | `{"vk":65,"down":true}` 或 `{"usage":4,"down":true}` | `{"usage":4,"queued":1}` |
| `/api/status` | POST | `{}` | `{"queued":true,"quiet":6.8}` |

### `/api/mouse`

- `dx`、`dy`：相对移动，int8。超过 ±127 会被拆成多个包（一个 HID 报告最多带 ±127），中间的包只带移动，最后一个带按键和滚轮。所以 `{"dx":200,"dy":0}` 返回 `queued:2`。
- `buttons`：位掩码，和线上格式一样 — bit0 左、bit1 右、bit2 中、bit4 X1、bit5 X2。`bit6` 由服务自己置（这一包带滚轮）。
- `wheel`：格数（1 格 = 120 单位，服务已经除好了）。
- 按键状态是保持的：发 `{"buttons":1}` 表示按下，要放开就再发 `{"buttons":0}`。不给 `buttons` 时，包里带的是此刻仍然按着的键（和采集路径一样）。这一段以前是坏的：状态只在局部变量里算、没有写回，所以每一包的按钮都是 0，点击转不过去（见 `analysis.md` 第六节）。

### `/api/key`

- 给 `vk`（Windows 虚拟键码）或 `usage`（HID usage page 0x07）都行；`vk` 会被映射成 usage（映射在 `tools/lib.ps1`）。
- `down:true` 按下，`down:false` 释放。每次状态变化发一次完整的 6KRO 快照（最多 6 个键），全 0 表示没有键按下。
- 修饰键就是 usage 0xE0~0xE7（左 ctrl / shift / alt / gui 和右半），`vk` 0x11、0x10、0x12、0x5B 会映射到它们。

### `/api/status`

状态行不在请求里现读，只排队。原因：读是一个会挂住的往返（实测每次 1.5s），而主循环还要取采集队列；挂住的这段时间采集线程还在出包，读回来以后一次性全倒出去，另一台机器就是"卡一下然后跳一段"。所以状态行只在安静 5 秒（`QuietSec`）以后读，结果存着给 `/api/state` 读。

### `/api/state`

```json
{
  "lock": false,
  "port": "COM3",
  "screen": { "w": 1536, "h": 864 },
  "cursor": { "x": 1315, "y": 571 },
  "recenter": 1,
  "capture": { "registered": true, "stage": "atom=50066 hwnd=6490342",
               "nInput": 1114, "mouse": 1100, "key": 14, "unmapped": 0,
               "dumps": ["size=44 header=24 字节: 01 00 00 00 2C 00 00 00 88 1A 00 00 41 00 00 00 ... -> VKey=0x41 usage=0x04"] },
  "sent": { "total": 553, "queued": 8 },
  "rate": 86.3,
  "quiet": 0.1,
  "status": { "b": 10, "cdc": 1, "hs": 1, "ok": 553, "err": 0, "drop": 0,
              "ms": 553, "kb": 0, "p0": 1, "p1": 1 },
  "verdict": "本端口已枚举, 字节进得来。 另一台机器已枚举键鼠口。 ..."
}
```

`status` 是上一次读到的状态行（没读到就是 `null`），`verdict` 是它的判断。字段含义见 README。

`capture` 里三个数是分开的，因为键盘停在哪儿有三种可能，光看包数分不出来：`key` 是收到的真键盘事件数，`unmapped` 是事件到了但 VKey 不在映射表里的数，`sent` 是真正发出去的包。按下键以后：`key` 不动 = 事件没到窗口；`key` 动而 `unmapped` 也动 = 那个键不在表里；`key` 动、`unmapped` 不动、包在出 = 这条通了。自测里手摆的字节不算进这三个数。

`dumps` 存前 5 个真键盘事件的原始字节（整块十六进制 + 读到的 VKey + 表给的结果）。`unmapped` 动了以后只有它能分清是哪种：字节里 `0x41` 在数据段第 10 字节而表返回 `-1` = 表缺那个键；`0x41` 在别的位置 = 头和数据的分界错了；读到的 VKey 是 0 = 这个设备报的 usage 系统映射不出 VK。页面上的采集格会显示最后一个的 VKey。

## 从命令行调

`tools/api.ps1` 就是同一套接口的命令行客户端：

```
powershell -File tools\api.ps1 -Lock                        # 锁定
powershell -File tools\api.ps1 -Move 200,0                  # 另一台机器的光标向右 200（拆成两个包）
powershell -File tools\api.ps1 -Click left                  # 按下再放开
powershell -File tools\api.ps1 -Down ctrl -Tap a -Up ctrl  # ctrl+a
powershell -File tools\api.ps1 -Status                      # 排队读状态行
powershell -File tools\api.ps1 -State
```

实测输出：

```
POST /api/mouse {"dx":200,"dy":0}  ->  {"queued":2}
POST /api/key {"down":true,"vk":65}  ->  {"usage":4,"queued":1}
POST /api/key {"down":false,"vk":65}  ->  {"usage":4,"queued":1}
```

## 不经过我们的软件：直接说字节

谁都可以直接开 COM 口写包，格式和上面完全一样（校验和 = 除最后一个字节以外全部字节的 XOR）：

- 鼠标 6 字节：`0xAA | flags | dx(int8) | dy(int8) | wheel(int8) | xor`
- 键盘 10 字节：`0xAB | modifier | 0x00 | 6 个 HID usage | xor`
- 状态查询：写一个 `'S'`（0x53），板子回一行。必须有一个读请求挂着驱动才会去取 IN 数据，而且要用 `ReadTotalTimeoutConstant`（`ReadIntervalTimeout` 只在已经有第一个字节以后起作用）。

Python 最小例子：

```python
import serial

def pkt(*b):
    x = 0
    for v in b: x ^= v
    return bytes(b) + bytes([x])

s = serial.Serial('COM3', 115200, timeout=1.5)
s.write(pkt(0xAA, 0x01, 100, 0, 0))      # 左键按下, 向右 100
s.write(pkt(0xAA, 0x00, 0, 0, 0))         # 放开
s.write(pkt(0xAB, 0x00, 0x00, 0x04))      # a 按下(6KRO 快照)
s.write(b'S')
print(s.readline().decode())               # 状态行
```

## 用这套接口时必须知道的几条

1. **转发的路上不能读设备。** 读会挂住（实测 1.5s），挂住的这段时间包还在出，读回来以后一次性全倒出去 —— 那边就是"卡一下然后跳一段"。写是 0.22 ms/包（200 包 44 ms），所以慢的不是板子。
2. **端点忙的时候包会被丢。** 板子的 IN 端点只在主机轮询时才空。`drop` 计数就是被丢的包。另外 `ep_busy[3]`（状态行用的那个）只在主机取走上一行以后才清；一旦漏读一行，不重启板子就不再回答 `'S'`。
3. **一次 HID 报告最多 ±127。** 大移动必须拆包，不能夹掉（夹掉会丢坐标）。
4. **键盘是 6KRO 快照**，不是单个按键事件：每次状态变化发一次完整的当前状态。最多 6 个键，超出的键被忽略。
5. **主动控制和采集互不干扰。** 程序改本端光标不产生 Raw Input 事件（实测），所以接口发的包不会被采集回路重新拾起来。
6. **锁定不改转发**，只把本端光标拉回中心。
7. **采集线程不能靠轮询。** 系统的计时精度默认 15.625 ms，`Thread.Sleep(1)` 实际睡 15.58 ms，`PeekMessage` 轮询一圈要 15.58 ms（约 64 次/秒），事件要等到下一轮才处理 —— 这就是帧率低和一阵一阵的来源。改成挂住的 `GetMessage` 加 `timeBeginPeriod(1)` 以后，从"消息到了"到"处理它"实测 0 ms。剩下的上限是鼠标自己的上报率（一般 125 Hz）。
