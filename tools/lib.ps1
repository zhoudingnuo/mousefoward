# lib.ps1 - 采集(Raw Input)和串口(CDC)两段, tools/forward.ps1 和 app/server.ps1 共用。
#
# 只留一份实现的原因: 这两段各有一个不明显的坑, 复制两份会各自漂移。
#   采集必须在别的线程跑(它要一个消息循环), 包放进 ConcurrentQueue 交给调用方。
#   取队列不能用 $q.Dequeue(): PowerShell 对集合成员访问会走"成员枚举", 把方法套到每个元素上,
#   于是报的是 [System.Byte] 没有 Dequeue —— 要用 TryDequeue([ref])。
#   串口读必须用 ReadTotalTimeoutConstant: ReadIntervalTimeout 只在已经有第一个字节以后起作用,
#   一个字节都没有时 ReadFile 立刻返回 0, 驱动不会去取设备的 IN 数据。
#   读是一个会挂住的往返(实测 1.5s), 所以调用方在转发的路上不能读, 只能在安静的时候读。

# ---------------- 采集 ----------------

Add-Type @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;

public class RawCap {

    /* 采集线程把包放进这个队列, 调用方取出来写串口。
     * 必须是 ConcurrentQueue: 一边是消息循环线程, 一边是调用方。 */
    public static ConcurrentQueue<byte[]> Packets = new ConcurrentQueue<byte[]>();

    const int WM_INPUT = 0x00FF;
    const int RIDEV_INPUTSINK = 0x100;      // 焦点不在本进程也收
    /* RIDEV_EXINPUTSINK(0x10) 本来是用来收 SendInput 注入的事件的, 但这台机器上
     * RegisterRawInputDevices 带这个 flag 一律返回错误 87(单个和组合都试过),
     * 所以注入的事件收不到。自测因此不走事件路径, 直接调映射和拆分。 */
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
        public ushort usFlags; public ushort pad;          // C 在这里放 2 字节填充: 后面的 union 是 4 字节对齐
        public ushort usButtonFlags; public ushort usButtonData;
        public uint ulRawButtons; public int lLastX; public int lLastY; public uint ulExtraInformation;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct RAWKEYBOARD {
        public uint MakeCode; public uint Flags;
        public ushort Reserved; public ushort VKey;
        public uint Message; public uint ExtraInformation;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct MSG {
        public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam;
        public uint time; public int x; public int y;
    }

    /* lpszMenuName 在 lpszClassName 前面: 顺序写错, 类名会被当成菜单名, 建窗口失败。 */
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
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool GetMessage(ref MSG msg, IntPtr hwnd, uint min, uint max);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool TranslateMessage(ref MSG msg);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr DispatchMessage(ref MSG msg);
    [DllImport("winmm.dll")] static extern uint timeBeginPeriod(uint ms);

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
    public static IntPtr Hwnd = IntPtr.Zero;

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
        Hwnd = hwnd;

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

        /* 系统的计时精度默认是 15.625 ms: 以前这里 Sleep(1) 实际睡 15.6 ms, 也就是每秒只转 64 圈,
         * 事件要等到下一轮才处理。改成挂住的 GetMessage(来了立刻处理), 再把精度提到 1 ms,
         * 主循环里 Start-Sleep -Milliseconds 5 也才真的是 5 ms。 */
        timeBeginPeriod(1);

        MSG msg = new MSG();
        while (true) {
            if (!GetMessage(ref msg, IntPtr.Zero, 0, 0)) continue;
            if (msg.message == WM_INPUT) nInput++;
            TranslateMessage(ref msg);
            DispatchMessage(ref msg);
        }
    }

    /* WndProc 的函数体里不能直接调 P/Invoke。
     * GetFunctionPointerForDelegate 对这种方法返回的不是真正的非托管 thunk:
     * RegisterClassEx 照样返回 atom, 但 CreateWindowEx 会失败(返回 0, 不设置错误码)。
     * 把调用挪到一个普通方法里就好了 —— 实测: 同一个类, 函数体改成 HandleInput(lParam) 就能建窗口。 */
    /* 测"消息到了"到"处理它"隔多久: 轮询要等下一次 PeekMessage, 挂住的 GetMessage 立刻处理。
     * 投一个 WM_USER, 这里计数; 调用方量从投到计数变化的时间。 */
    public static int nProbe = 0;
    public static bool PostProbe() {
        if (Hwnd == IntPtr.Zero) return false;
        return PostMessage(Hwnd, 0x0400, IntPtr.Zero, IntPtr.Zero);
    }

    static void WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam) {
        if (msg == 0x0400) { nProbe++; return; }
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
        int wheel = 0;
        bool changed = false;

        if ((m.usButtonFlags & 0x0001) != 0) changed |= SetBit(0x01, true);
        if ((m.usButtonFlags & 0x0002) != 0) changed |= SetBit(0x01, false);
        if ((m.usButtonFlags & 0x0004) != 0) changed |= SetBit(0x02, true);
        if ((m.usButtonFlags & 0x0008) != 0) changed |= SetBit(0x02, false);
        if ((m.usButtonFlags & 0x0010) != 0) changed |= SetBit(0x10, true);
        if ((m.usButtonFlags & 0x0020) != 0) changed |= SetBit(0x10, false);
        if ((m.usButtonFlags & 0x0040) != 0) changed |= SetBit(0x10, true);
        if ((m.usButtonFlags & 0x0080) != 0) changed |= SetBit(0x10, false);
        if ((m.usButtonFlags & 0x0100) != 0) changed |= SetBit(0x20, true);
        if ((m.usButtonFlags & 0x0200) != 0) changed |= SetBit(0x20, false);
        if ((m.usButtonFlags & 0x0400) != 0) { wheel = (short)m.usButtonData / 120; changed = true; }

        if (m.lLastX == 0 && m.lLastY == 0 && !changed) return;
        EmitSplit(_mflags, m.lLastX, m.lLastY, wheel);
    }

    /* 按钮状态是保持的: 按下置位、抬起清零, 每一包都带当时的状态(参考实现也是这样)。
     * 之前这里只改局部变量、没有写回 _mflags, 所以每一包的按钮都是 0 —— 点击转不过去。
     * 返回是否真的变了: 只有状态变了才值得发一包。 */
    public static bool SetBit(int bit, bool down) {
        int flags = _mflags;
        if (down) {
            if ((flags & bit) != 0) return false;
            flags |= bit;
        } else {
            if ((flags & bit) == 0) return false;
            flags &= ~bit;
        }
        _mflags = flags;
        return true;
    }

    public static int Buttons() { return _mflags; }

    /* 主动控制用: 接口给的是最终状态, 直接覆盖。 */
    public static void SetButtons(int mask) { _mflags = mask & 0x3F; }

    /* 一个 HID 报告最多带 ±127。超过就拆成多个包: 中间的包只带移动, 最后一个带按键和滚轮。
     * 夹掉会丢坐标。主动控制走的是同一个函数, 所以接口给的 200 也会被拆。 */
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

    /* 状态机单独分出来: 自测和接口都直接调它, 不用真的按键。 */
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

    /* VK -> HID usage page 0x07。Raw Input 只给 VKey, 所以只能按 VK 反查。 */
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

    /* 自测: 按 C 的布局手工摆字节, 走的是和真事件同一条路。
     * 这条本来能挡住 RAWMOUSE / RAWKEYBOARD 的布局错误(见 analysis.md 第七节)。 */
    public static void FeedImage(byte[] laid, int type) {
        IntPtr p = Marshal.AllocHGlobal(laid.Length);
        try {
            Marshal.Copy(laid, 0, p, laid.Length);
            if (type == 0) HandleMouse((RAWMOUSE)Marshal.PtrToStructure(p, typeof(RAWMOUSE)));
            else HandleKey((RAWKEYBOARD)Marshal.PtrToStructure(p, typeof(RAWKEYBOARD)));
        } finally {
            Marshal.FreeHGlobal(p);
        }
    }

    public static string Layout() {
        return "RAWMOUSE size=" + Marshal.SizeOf(typeof(RAWMOUSE)) +
               " usButtonFlags@" + Marshal.OffsetOf(typeof(RAWMOUSE), "usButtonFlags") +
               " lLastX@" + Marshal.OffsetOf(typeof(RAWMOUSE), "lLastX") +
               " | RAWKEYBOARD size=" + Marshal.SizeOf(typeof(RAWKEYBOARD)) +
               " Flags@" + Marshal.OffsetOf(typeof(RAWKEYBOARD), "Flags") +
               " VKey@" + Marshal.OffsetOf(typeof(RAWKEYBOARD), "VKey");
    }

    public static void Reset() {
        _mflags = 0; _mod = 0; _keys.Clear();
        byte[] ignored = null;
        while (!Packets.IsEmpty) { Packets.TryDequeue(out ignored); }
    }
}
'@

# ---------------- 串口 ----------------

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

# 取队列要用 TryDequeue([ref]): $q.Dequeue() 会走 PowerShell 的"成员枚举",
# 把方法套到每个元素上, 于是报的是 [System.Byte] 没有 Dequeue。
function Take( $q )
{
    $pk = [byte[]]$null
    if( $q.TryDequeue( [ref]$pk ) ) { return $pk }
    return $null
}

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

function SetTimeouts( $h, [uint32]$interval, [uint32]$totalConst, [uint32]$writeConst )
{
    $t = New-Object 'Port+COMMTIMEOUTS'
    $t.ReadIntervalTimeout = $interval
    $t.ReadTotalTimeoutMultiplier = 0
    $t.ReadTotalTimeoutConstant = $totalConst
    $t.WriteTotalTimeoutMultiplier = 0
    $t.WriteTotalTimeoutConstant = $writeConst
    [Port]::SetCommTimeouts( $h, [ref]$t ) | Out-Null
}

function OpenPort( [string]$com, [int]$readMs )
{
    $h = [Port]::CreateFile( $com, 3, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero )
    if( $h.ToInt64() -eq -1 ) { return [IntPtr]::Zero }
    SetTimeouts $h 0 ([uint32]$readMs) 2000
    return $h
}

function WritePacket( $h, [byte[]]$pk )
{
    if( $h.ToInt64() -eq -1 ) { return $false }
    $w = [uint32]0
    return [Port]::WriteFile( $h, $pk, [uint32]$pk.Length, [ref]$w, [IntPtr]::Zero )
}

# 状态行必须阻塞读: 驱动只有在有一个读请求挂着的时候才会去取设备的 IN 数据。
# 必须用 ReadTotalTimeoutConstant; SerialPort.ReadTimeout 映射的是 ReadIntervalTimeout,
# 一个字节都没有时 ReadFile 立刻返回 0, 驱动不会去取 IN 数据。
function ReadLine( $h, [int]$timeoutMs )
{
    SetTimeouts $h 0 ([uint32]$timeoutMs) 2000

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
