# 事件驱动转发: 把本机的鼠标和键盘动作发到板子, 板子从 USBHS 输出到另一台机器。
#
# 这一版按参考实现(mouse-forwarder-pre-nn)的做法取事件, 和 capture.ps1 的 -Live 有三点不同:
#   1. 不轮询光标。注册 Raw Input (WM_INPUT + RIDEV_INPUTSINK), 系统每来一个鼠标事件
#      就出一个包, 包率 = 系统事件率(鼠标一般 125~1000Hz), 不是 60ms 一轮的 16fps。
#   2. 增量超过 ±127 拆成多个包(参考的 encode_packets): 中间的包只带移动, 最后一个带按键和滚轮。
#      之前用 Clamp127 直接夹掉, 一次大移动会丢坐标。
#   3. 键盘用 Raw Input 的 VKey 映射到 HID usage, 每次按下/释放发一次 6KRO 快照(参考的 keyboard_monitor)。
#      之前这个脚本没有任何键盘采集, 键盘通路只有手动跑 .kb.ps1 时才被用到。
#   4. 转发的时候不读状态行。读状态行是一个会挂住的往返(实测每次 1.5s), 挂住的这段时间采集线程还在
#      出包, 读回来以后一次性全倒出去 —— 那边就是"卡一下然后跳一段"。帧率从包数自己算, 不需要读设备;
#      状态行只在安静了 QuietSec 秒以后读(那时候没有在转发, 挂住也不影响)。
#
#   powershell -File tools\forward.ps1                # 转发
#   powershell -File tools\forward.ps1 -Debug         # 每 50 包打印包和帧率(不读设备)
#   powershell -File tools\forward.ps1 -Status        # 安静 5 秒以后读一次状态行(判断断在哪一段)
#   powershell -File tools\forward.ps1 -DryRun        # 只打印包, 不开串口
#   powershell -File tools\forward.ps1 -SelfTest      # 不接串口, 直接验证映射和拆分
#   powershell -File tools\forward.ps1 -NoKeyboard    # 只转发鼠标

param(
    [string]$Com = '',
    [switch]$DryRun,
    [switch]$Debug,
    [switch]$Status,
    [switch]$SelfTest,
    [switch]$NoKeyboard,
    [int]$QuietSec = 5,
    [int]$PrintEvery = 50,
    [int]$ReadTimeoutMs = 3000
)

# 板子的 CDC 口: VID 1A86, 被 usbser.sys 绑定后设备名里带 (COMx)
function FindCdcPort()
{
    $d = Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue |
        Where-Object { $_.PNPDeviceID -match 'VID_1A86' -and $_.Name -match 'COM\d+' }
    foreach( $e in $d )
    {
        $m = [regex]::Match( $e.Name, 'COM\d+' )
        if( $m.Success ) { return $m.Value }
    }
    return ''
}

Add-Type @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;

public class RawCap {

    /* 采集线程把包放进这个队列, PowerShell 取出来写串口。
     * 必须是 ConcurrentQueue: 一边是消息循环线程, 一边是 PowerShell。 */
    public static ConcurrentQueue<byte[]> Packets = new ConcurrentQueue<byte[]>();

    const int WM_INPUT = 0x00FF;
    const int RIDEV_INPUTSINK = 0x100;      // 焦点不在本进程也收
    /* RIDEV_EXINPUTSINK(0x10) 本来是用来收 SendInput 注入的事件的, 但这台机器上
     * RegisterRawInputDevices 带这个 flag 一律返回错误 87(单个和组合都试过),
     * 所以注入的事件收不到。-SelfTest 因此不走事件路径, 直接调映射和拆分。 */
    const int RID_INPUT = 0x10000003;
    const uint PM_REMOVE = 1;

    [StructLayout(LayoutKind.Sequential)]
    struct RAWINPUTDEVICE {
        public ushort usUsagePage; public ushort usUsage; public uint dwFlags; public IntPtr hwndTarget;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct RAWINPUTHEADER {
        public uint dwType; public uint dwSize; public IntPtr hDevice; public IntPtr wParam;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct RAWMOUSE {
        public ushort usFlags; public ushort usButtonFlags; public ushort usButtonData;
        public uint ulRawButtons; public int lLastX; public int lLastY; public uint ulExtraInformation;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct RAWKEYBOARD {
        public ushort MakeCode; public ushort Flags; public ushort Reserved;
        public ushort VKey; public uint ScanCode; public uint ExtraInformation;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct MSG {
        public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam;
        public uint time; public int x; public int y;
    }

    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    struct WNDCLASSEX {
        public uint cbSize; public uint style; public IntPtr lpfnWndProc;
        public int cbClsExtra; public int cbWndExtra; public IntPtr hInstance;
        public IntPtr hIcon; public IntPtr hCursor; public IntPtr hbrBackground;
        public string lpszMenuName; public string lpszClassName; public IntPtr hIconSm;
    }

    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern ushort RegisterClassEx(ref WNDCLASSEX w);
    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern IntPtr CreateWindowEx(uint exStyle, string cls, string title,
        uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
    [DllImport("user32.dll", SetLastError=true)] static extern bool RegisterRawInputDevices(RAWINPUTDEVICE[] rids, uint num, uint size);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern uint GetRawInputData(IntPtr hInput, uint cmd, IntPtr data, ref uint size, uint headerSize);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool PeekMessage(ref MSG msg, IntPtr hwnd, uint min, uint max, uint remove);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool TranslateMessage(ref MSG msg);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr DispatchMessage(ref MSG msg);

    /* WndProc 是原生回调。委托必须被静态字段引用住, 被 GC 回收以后原生那边会踩空。 */
    delegate void WndProcDelegate(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam);
    static WndProcDelegate _proc = WndProc;

    /* 按键状态是保持的: Raw Input 只报"按下/释放"这个变化, 报告里要的是当前状态。 */
    static int _mflags = 0;
    static int _mod = 0;
    static readonly List<int> _keys = new List<int>();

    public static void Start() {
        Thread t = new Thread(new ThreadStart(Loop));
        t.IsBackground = true;
        t.Start();
    }

    /* 每一步是走通了还是没走通, 不能靠"有没有包"猜。 */
    public static bool Registered = false;
    public static int nInput = 0;
    public static string Stage = "";

    static void Loop() {
        WNDCLASSEX wc = new WNDCLASSEX();
        wc.cbSize = (uint)Marshal.SizeOf(typeof(WNDCLASSEX));
        wc.lpfnWndProc = Marshal.GetFunctionPointerForDelegate(_proc);
        wc.lpszClassName = "zcode_rawcap";
        ushort atom = RegisterClassEx(ref wc);
        if (atom == 0) { Stage = "RegisterClassEx " + Marshal.GetLastWin32Error(); return; }
        Stage = "atom=" + atom;

        IntPtr hwnd = CreateWindowEx(0, wc.lpszClassName, "rawcap", 0, 0, 0, 0, 0,
            new IntPtr(-3), IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);   // -3 = HWND_MESSAGE
        if (hwnd == IntPtr.Zero) { Stage += " CreateWindowEx " + Marshal.GetLastWin32Error(); return; }
        Stage += " hwnd=" + hwnd;

        RAWINPUTDEVICE[] rids = new RAWINPUTDEVICE[2];
        rids[0].usUsagePage = 1; rids[0].usUsage = 2;   // 鼠标
        rids[1].usUsagePage = 1; rids[1].usUsage = 6;   // 键盘
        rids[0].dwFlags = RIDEV_INPUTSINK; rids[0].hwndTarget = hwnd;
        rids[1].dwFlags = RIDEV_INPUTSINK; rids[1].hwndTarget = hwnd;
        if (!RegisterRawInputDevices(rids, 2, (uint)Marshal.SizeOf(typeof(RAWINPUTDEVICE)))) {
            Stage = "RegisterRawInputDevices " + Marshal.GetLastWin32Error();
            return;
        }
        Registered = true;

        MSG msg = new MSG();
        while (true) {
            if (!PeekMessage(ref msg, IntPtr.Zero, 0, 0, PM_REMOVE)) { Thread.Sleep(1); continue; }
            if (msg.message == WM_INPUT) nInput++;
            TranslateMessage(ref msg);
            DispatchMessage(ref msg);
        }
    }

    /* WndProc 的函数体里不能直接调 P/Invoke。
     * GetFunctionPointerForDelegate 对这种方法返回的不是真正的非托管 thunk:
     * RegisterClassEx 照样返回 atom, 但 CreateWindowEx 会失败(返回 0, 不设置错误码)。
     * 把调用挪到一个普通方法里就好了 —— 实测: 同一个类, 函数体改成 HandleInput(lParam) 就能建窗口。 */
    static void WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam) {
        if (msg != WM_INPUT) return;
        nInput++;
        HandleInput(lParam);
    }

    static void HandleInput(IntPtr lParam) {
        uint size = 0;
        GetRawInputData(lParam, RID_INPUT, IntPtr.Zero, ref size, (uint)Marshal.SizeOf(typeof(RAWINPUTHEADER)));
        if (size == 0) return;

        IntPtr buf = Marshal.AllocHGlobal((int)size);
        try {
            if (GetRawInputData(lParam, RID_INPUT, buf, ref size, (uint)Marshal.SizeOf(typeof(RAWINPUTHEADER))) == 0) return;
            RAWINPUTHEADER h = (RAWINPUTHEADER)Marshal.PtrToStructure(buf, typeof(RAWINPUTHEADER));
            IntPtr data = IntPtr.Add(buf, Marshal.SizeOf(typeof(RAWINPUTHEADER)));
            if (h.dwType == 0) HandleMouse((RAWMOUSE)Marshal.PtrToStructure(data, typeof(RAWMOUSE)));
            else if (h.dwType == 1) HandleKey((RAWKEYBOARD)Marshal.PtrToStructure(data, typeof(RAWKEYBOARD)));
        } finally {
            Marshal.FreeHGlobal(buf);
        }
    }

    static void HandleMouse(RAWMOUSE m) {
        int flags = _mflags;
        int wheel = 0;
        bool changed = false;

        if ((m.usButtonFlags & 0x0001) != 0) { flags |= 0x01; changed = true; }
        if ((m.usButtonFlags & 0x0002) != 0) { flags &= ~0x01; changed = true; }
        if ((m.usButtonFlags & 0x0004) != 0) { flags |= 0x02; changed = true; }
        if ((m.usButtonFlags & 0x0008) != 0) { flags &= ~0x02; changed = true; }
        if ((m.usButtonFlags & 0x0010) != 0) { flags |= 0x04; changed = true; }
        if ((m.usButtonFlags & 0x0020) != 0) { flags &= ~0x04; changed = true; }
        if ((m.usButtonFlags & 0x0040) != 0) { flags |= 0x10; changed = true; }
        if ((m.usButtonFlags & 0x0080) != 0) { flags &= ~0x10; changed = true; }
        if ((m.usButtonFlags & 0x0100) != 0) { flags |= 0x20; changed = true; }
        if ((m.usButtonFlags & 0x0200) != 0) { flags &= ~0x20; changed = true; }
        if ((m.usButtonFlags & 0x0400) != 0) { wheel = (short)m.usButtonData / 120; changed = true; }

        if (m.lLastX == 0 && m.lLastY == 0 && !changed) return;
        EmitSplit(flags, m.lLastX, m.lLastY, wheel);
    }

    /* 一个 HID 报告最多带 ±127。超过就拆成多个包(参考的 encode_packets):
     * 中间的包只带移动, 最后一个带按键和滚轮。夹掉会丢坐标。 */
    public static void EmitSplit(int flags, int dx, int dy, int wheel) {
        int n = 1;
        if (Math.Abs(dx) > 127) n = Math.Max(n, (int)Math.Ceiling(Math.Abs(dx) / 127.0));
        if (Math.Abs(dy) > 127) n = Math.Max(n, (int)Math.Ceiling(Math.Abs(dy) / 127.0));

        for (int i = 0; i < n; i++) {
            bool last = (i == n - 1);
            EmitMouse(last ? flags : 0, Part(dx, n, i), Part(dy, n, i), last ? wheel : 0);
        }
    }

    static int Part(int v, int n, int i) {
        int q = v / n;
        return q + (i == n - 1 ? v - q * n : 0);
    }

    static void HandleKey(RAWKEYBOARD k) {
        int usage = Usage(k.VKey);
        if (usage < 0) return;
        ApplyKey(usage, (k.Flags & 1) == 0);   // 0 = down, 1 = up
    }

    /* 状态机单独分出来: -SelfTest 直接调它, 不用真的按键。 */
    public static void ApplyKey(int usage, bool down) {
        if (usage >= 0xE0 && usage <= 0xE7) {
            int bit = 1 << (usage - 0xE0);
            if (down) { if ((_mod & bit) != 0) return; _mod |= bit; }
            else { if ((_mod & bit) == 0) return; _mod &= ~bit; }
            EmitKeyboard();
            return;
        }

        if (down) {
            if (_keys.Contains(usage)) return;            // 按住不放时系统会自动重复, 只发一次
            if (_keys.Count >= 6) { EmitKeyboard(); return; }
            _keys.Add(usage);
        } else {
            if (!_keys.Contains(usage)) return;
            _keys.Remove(usage);
        }
        EmitKeyboard();
    }

    /* 6KRO 快照: 每次状态变化发一次完整的当前状态, 全 0 表示没有键按下 */
    static void EmitKeyboard() {
        byte[] pk = new byte[10];
        pk[0] = 0xAB;
        pk[1] = (byte)_mod;
        pk[2] = 0;
        for (int i = 0; i < _keys.Count && i < 6; i++) pk[3 + i] = (byte)_keys[i];
        EmitRaw(pk);
    }

    static void EmitMouse(int flags, int dx, int dy, int wheel) {
        byte[] pk = new byte[6];
        pk[0] = 0xAA;
        pk[1] = (byte)(flags | (wheel != 0 ? 0x40 : 0));   // bit6 = 这一包带滚轮
        pk[2] = (byte)dx;
        pk[3] = (byte)dy;
        pk[4] = (byte)wheel;
        EmitRaw(pk);
    }

    static void EmitRaw(byte[] pk) {
        byte x = 0;
        for (int i = 0; i < pk.Length - 1; i++) x ^= pk[i];
        pk[pk.Length - 1] = x;
        Packets.Enqueue(pk);
    }

    /* VK -> HID usage page 0x07。参考的 keyboard_monitor 用 pynput 的 char/name,
     * Raw Input 只给 VKey, 所以只能按 VK 反查。 */
    public static int Usage(int vk) {
        if (vk >= 0x41 && vk <= 0x5A) return 0x04 + (vk - 0x41);
        if (vk >= 0x31 && vk <= 0x39) return 0x1E + (vk - 0x31);
        if (vk == 0x30) return 0x27;
        if (vk >= 0x70 && vk <= 0x7B) return 0x3E + (vk - 0x70);

        switch (vk) {
            case 0x11: return 0xE0; case 0xA2: return 0xE0; case 0xA3: return 0xE4;
            case 0x10: return 0xE1; case 0xA0: return 0xE1; case 0xA1: return 0xE5;
            case 0x12: return 0xE2; case 0xA4: return 0xE2; case 0xA5: return 0xE6;
            case 0x5B: return 0xE3; case 0x5C: return 0xE7;
            case 0x0D: return 0x28; case 0x1B: return 0x29; case 0x08: return 0x2A;
            case 0x09: return 0x2B; case 0x20: return 0x2C;
            case 0xBD: return 0x2D; case 0xBB: return 0x2E;
            case 0xDB: return 0x2F; case 0xDD: return 0x30; case 0xDC: return 0x31;
            case 0xBA: return 0x33; case 0xDE: return 0x34; case 0xC0: return 0x35;
            case 0xBC: return 0x36; case 0xBE: return 0x37; case 0xBF: return 0x38;
            case 0x3A: return 0x39;
            case 0x25: return 0x55; case 0x26: return 0x52; case 0x27: return 0x53; case 0x28: return 0x54;
        }
        return -1;
    }

}
'@

Add-Type @'
using System;
using System.Runtime.InteropServices;
public class Port {
    [StructLayout(LayoutKind.Sequential)]
    public struct COMMTIMEOUTS {
        public uint ReadIntervalTimeout;
        public uint ReadTotalTimeoutMultiplier;
        public uint ReadTotalTimeoutConstant;
        public uint WriteTotalTimeoutMultiplier;
        public uint WriteTotalTimeoutConstant;
    }
    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr sa, uint mode, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetCommTimeouts(IntPtr h, ref COMMTIMEOUTS t);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool WriteFile(IntPtr h, byte[] b, uint len, ref uint written, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool ReadFile(IntPtr h, byte[] b, uint len, ref uint read, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr h);
}
'@

function Hex( [byte[]]$pk ) { return (( $pk | ForEach-Object { $_.ToString('X2') }) -join ' ') }

function Send( [byte[]]$pk )
{
    if( -not $DryRun )
    {
        $w = [uint32]0
        [Port]::WriteFile( $h, $pk, [uint32]$pk.Length, [ref]$w, [IntPtr]::Zero ) | Out-Null
    }
}

# 状态行必须阻塞读: 驱动只有在有一个读请求挂着的时候才会去取设备的 IN 数据。
# 必须用 ReadTotalTimeoutConstant; SerialPort.ReadTimeout 映射的是 ReadIntervalTimeout,
# 一个字节都没有时 ReadFile 立刻返回 0, 驱动不会去取 IN 数据。
function ReadLine( $timeoutMs )
{
    $t = New-Object 'Port+COMMTIMEOUTS'
    $t.ReadIntervalTimeout = 0
    $t.ReadTotalTimeoutMultiplier = 0
    $t.ReadTotalTimeoutConstant = [uint32]$timeoutMs
    $t.WriteTotalTimeoutMultiplier = 0
    $t.WriteTotalTimeoutConstant = 2000
    [Port]::SetCommTimeouts( $h, [ref]$t ) | Out-Null

    $buf = New-Object byte[] 96
    $r = [uint32]0
    if( -not [Port]::ReadFile( $h, $buf, [uint32]96, [ref]$r, [IntPtr]::Zero ) ) { return '' }
    if( $r -eq 0 ) { return '' }
    return [System.Text.Encoding]::ASCII.GetString( $buf[0..($r-1)] )
}

function Parse( [string]$line )
{
    $m = [regex]::Match( $line, 'b=(\d+) cdc=(\d+) hs=(\d+) ok=(\d+) err=(\d+) drop=(\d+) ms=(\d+) kb=(\d+) p0=(\d+) p1=(\d+)' )
    if( -not $m.Success ) { return $null }

    return @{
        b    = [int]$m.Groups[1].Value; cdc = [int]$m.Groups[2].Value; hs = [int]$m.Groups[3].Value
        ok   = [int]$m.Groups[4].Value; err = [int]$m.Groups[5].Value; drop = [int]$m.Groups[6].Value
        ms   = [int]$m.Groups[7].Value; kb  = [int]$m.Groups[8].Value
        p0   = [int]$m.Groups[9].Value; p1  = [int]$m.Groups[10].Value
    }
}

$script:base = $null
$script:winStart = Get-Date
$script:winSent = 0
$script:quietSince = Get-Date
$script:retryAt = Get-Date
$script:qok = $false

# 帧率从包数自己算, 不需要读设备 —— 这是转发过程中唯一能一直打印的东西。
function Rate()
{
    $sec = (( Get-Date ) - $script:winStart).TotalSeconds
    if( $sec -le 0 ) { return }
    Write-Output ( '这一段 ' + $script:winSent + ' 包 / ' + [math]::Round( $sec, 1 ) + 's = ' + [math]::Round( $script:winSent / $sec, 1 ) + ' 包/秒' )
    $script:winStart = Get-Date
    $script:winSent = 0
}

function Query()
{
    $script:qok = $false
    if( $DryRun ) { return }

    $w = [uint32]0
    [Port]::WriteFile( $h, [byte[]]( 0x53 ), [uint32]1, [ref]$w, [IntPtr]::Zero ) | Out-Null

    $line = ReadLine 1500
    if( -not $line )
    {
        Write-Output '读不到状态行。要先发一个 S 再阻塞读。'
        return
    }

    $now = Parse $line
    if( -not $now )
    {
        Write-Output '状态行读不全(计数器到 10 位会把 64 字节缓冲区写穿, 行被截)。'
        return
    }

    Write-Output ( '状态行: ' + $line.TrimEnd() )

    if( -not $script:base ) { $script:base = $now }

    $dok   = $now.ok   - $script:base.ok
    $dms   = $now.ms   - $script:base.ms
    $dkb   = $now.kb   - $script:base.kb
    $ddrop = $now.drop - $script:base.drop

    if( $now.cdc -eq 0 ) { Write-Output '  本端口没被枚举: COM 口存在但枚举没走完。' }
    else { Write-Output '  本端口已枚举, 字节进得来。' }

    if( $now.hs -eq 0 ) { Write-Output '  另一台机器没枚举键鼠口: 那边不会动。' }
    else { Write-Output '  另一台机器已枚举键鼠口。' }

    if( $now.p1 -eq 0 ) { Write-Output '  鼠标接口没被绑定 (p1=0)。' }
    else { Write-Output ( '  鼠标接口被绑定了 (p1=' + $now.p1 + ')。' ) }

    if( $now.p0 -eq 0 ) { Write-Output '  键盘接口没被绑定 (p0=0)。' }
    else { Write-Output ( '  键盘接口被绑定了 (p0=' + $now.p0 + ')。' ) }

    if( $dok -lt $script:winSent )
    {
        Write-Output ( '  这一段发了 ' + $script:winSent + ' 包, 只解析到 ' + $dok + ' 个: 本端到板这一段断了。' )
    }
    elseif( $dms + $dkb -lt $dok )
    {
        Write-Output ( '  解析对了 ' + $dok + ' 个, 只有 ' + $dms + ' 个鼠标 + ' + $dkb + ' 个键盘写进端点, drop=' + $ddrop + ': 端点一直忙(主机没在轮询)。' )
    }
    else
    {
        Write-Output ( '  ' + $dok + ' 个包全部解析并写进端点 (鼠标 ' + $dms + ', 键盘 ' + $dkb + ')。' )
    }

    $script:qok = $true
}

$h = [IntPtr]::Zero
if( -not $DryRun -and -not $SelfTest )
{
    if( -not $Com ) { $Com = FindCdcPort }
    if( -not $Com )
    {
        Write-Output '没找到板子的串口 (VID 1A86 的设备没有被 usbser.sys 绑定)。'
        exit 1
    }

    $h = [Port]::CreateFile( $Com, 3, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero )
    if( $h.ToInt64() -eq -1 )
    {
        Write-Output ( '打不开 ' + $Com + ' (错误 ' + [System.Runtime.InteropServices.Marshal]::GetLastWin32Error() + ')' )
        exit 1
    }

    $t = New-Object 'Port+COMMTIMEOUTS'
    $t.ReadIntervalTimeout = 0
    $t.ReadTotalTimeoutMultiplier = 0
    $t.ReadTotalTimeoutConstant = [uint32]$ReadTimeoutMs
    $t.WriteTotalTimeoutMultiplier = 0
    $t.WriteTotalTimeoutConstant = 2000
    [Port]::SetCommTimeouts( $h, [ref]$t ) | Out-Null
}

$q = [RawCap]::Packets
[RawCap]::Start()

# 不能用 $q.Dequeue(): PowerShell 对集合成员访问会走"成员枚举", 把方法套到每个元素上,
# 于是报的是 [System.Byte] 没有 Dequeue。取队列要用 TryDequeue([ref])。
function Take()
{
    $pk = [byte[]]$null
    if( $q.TryDequeue( [ref]$pk ) ) { return $pk }
    return $null
}

function Drain()
{
    $n = 0
    while( $true )
    {
        $pk = Take
        if( -not $pk ) { break }
        if( $SelfTest -or ( $Debug -and ( $script:sent % $PrintEvery -eq 0 ) ) ) { Write-Output ( '包: ' + ( Hex $pk ) ) }
        Send $pk
        $script:sent++
        $script:winSent++
        $n++
    }
    if( $n -gt 0 ) { $script:quietSince = Get-Date }
    return $n
}

$script:sent = 0
$script:mark = 0

try
{
    if( -not $DryRun -and -not $SelfTest -and $Status ) { Query }

    if( $SelfTest )
    {
        # 事件路径不能自己喂自己: 注入的事件收不到(EXINPUTSINK 被这台机器拒了),
        # 所以这里只验能确定的两段逻辑, 事件路径只看注册走到哪一步。
        Start-Sleep -Milliseconds 500
        $r = '失败'
        if( [RawCap]::Registered ) { $r = '成功' }
        Write-Output ( '注册 ' + $r + ' ' + [RawCap]::Stage )

        Write-Output '映射:'
        $bad = 0
        foreach( $p in @( @( 0x41, 0x04 ), @( 0x11, 0xE0 ), @( 0x0D, 0x28 ), @( 0x20, 0x2C ), @( 0x30, 0x27 ), @( 0x70, 0x3E ) ) )
        {
            $got = [RawCap]::Usage( $p[0] )
            if( $got -ne $p[1] )
            {
                $bad++
                Write-Output ( '  VK ' + ( [byte]$p[0] ).ToString( 'X2' ) + ' 应为 ' + ( [byte]$p[1] ).ToString( 'X2' ) + ', 得到 ' + $got )
            }
        }
        if( -not $bad ) { Write-Output '  都对。' }

        # 200 和 -160 都超过 127: 应该出 2 个包, 中间的包只带移动, 最后一个带滚轮。
        Write-Output '拆分(200, -160, 3):'
        [RawCap]::EmitSplit( 0, 200, -160, 3 )
        while( $true ) { $pk = Take; if( -not $pk ) { break }; Write-Output ( '  包: ' + ( Hex $pk ) ) }

        Write-Output '键盘快照(a + ctrl, 然后释放):'
        [RawCap]::ApplyKey( 0x04, $true )
        [RawCap]::ApplyKey( 0xE0, $true )
        while( $true ) { $pk = Take; if( -not $pk ) { break }; Write-Output ( '  包: ' + ( Hex $pk ) ) }
        [RawCap]::ApplyKey( 0x04, $false )
        [RawCap]::ApplyKey( 0xE0, $false )
        while( $true ) { $pk = Take; if( -not $pk ) { break }; Write-Output ( '  包: ' + ( Hex $pk ) ) }

        exit 0
    }

    Write-Output ( '事件驱动转发: ' + $Com + ' (Ctrl+C 退出)' )

    while( $true )
    {
        $n = Drain
        if( $Debug -and ( $script:sent - $script:mark -ge $PrintEvery ) ) { Rate; $script:mark = $script:sent }
        # 状态行只在安静了 QuietSec 秒以后读。转发的时候不能有任何会挂住的往返:
        # 挂住的这段时间采集线程还在出包, 读回来以后一次性全倒出去, 那边就是"卡一下然后跳一段"。
        if( $Status -and $n -eq 0 -and ( ( Get-Date ) - $script:quietSince ).TotalSeconds -ge $QuietSec -and ( Get-Date ) -ge $script:retryAt )
        {
            # 读不到说明板子那边卡住了(上一次状态行没被取走, 解析器/端点标志不会自己清), 重试没意义。
            Query
            # 读不到说明板子那边卡住了(上一次状态行没被取走, 端点标志不会自己清), 重试没意义。
            if( -not $script:qok ) { $script:retryAt = ( Get-Date ).AddSeconds( 30 ) }
        }
        if( $n -eq 0 ) { Start-Sleep -Milliseconds 5 }
    }
}
finally
{
    if( $h.ToInt64() -ne -1 ) { [Port]::CloseHandle( $h ) | Out-Null }
}
