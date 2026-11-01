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

## 转发本机的鼠标

```powershell
powershell -File tools/capture.ps1
```

每 20 ms 读一次本机光标位置，把增量写成鼠标包发到 COM 口（`dx`/`dy` 钳到 ±127，一个 HID 报告能带的最大增量）。按键状态从 `GetKeyState` 读，放在 `flags`。串口自己按 VID 1A86 找，不用手动指定；`-DryRun` 只打印包、不开串口。

桌面上放一个快捷方式指向这条命令，双击即开始转发。

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
| `tools/capture.ps1` | 读本机鼠标 → 写成包发到 COM 口 |
