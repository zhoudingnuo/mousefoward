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
# 采集和串口两段在 tools/lib.ps1, 和 app/server.ps1 共用同一份。
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

. ( Join-Path $PSScriptRoot 'lib.ps1' )

$script:base = $null
$script:winStart = Get-Date
$script:winSent = 0
$script:quietSince = Get-Date
$script:retryAt = Get-Date
$script:qok = $false
$script:sent = 0
$script:mark = 0

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

    $line = ReadLine $h 1500
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

    $h = OpenPort $Com $ReadTimeoutMs
    if( $h.ToInt64() -eq -1 )
    {
        Write-Output ( '打不开 ' + $Com + ' (错误 ' + [System.Runtime.InteropServices.Marshal]::GetLastWin32Error() + ')' )
        exit 1
    }
}

$q = [RawCap]::Packets
[RawCap]::Start()

function Drain()
{
    $n = 0
    while( $true )
    {
        $pk = Take $q
        if( -not $pk ) { break }
        if( $SelfTest -or ( $Debug -and ( $script:sent % $PrintEvery -eq 0 ) ) ) { Write-Output ( '包: ' + ( Hex $pk ) ) }
        if( -not $DryRun ) { WritePacket $h $pk | Out-Null }
        $script:sent++
        $script:winSent++
        $n++
    }
    if( $n -gt 0 ) { $script:quietSince = Get-Date }
    return $n
}

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

        # 结构布局: 按 C 的布局手工摆字节, 走的是和真事件同一条路。
        # RAWMOUSE 的 union 是 4 字节对齐的, usFlags 后面有 2 字节填充; RAWKEYBOARD 的
        # MakeCode / Flags 是 UINT。这两条以前都写短了(见 analysis.md 第七节)。
        Write-Output '结构布局:'
        Write-Output ( '  ' + [RawCap]::Layout() )
        [RawCap]::Reset()
        $m = New-Object -TypeName byte[] -ArgumentList 24
        $m[4] = 0x01                                                   # usButtonFlags = 左键按下
        $m[12] = 5                                                    # lLastX = 5
        $m[16] = 253; $m[17] = 255; $m[18] = 255; $m[19] = 255      # lLastY = -3
        [RawCap]::FeedImage( $m, 0 )
        while( $true ) { $pk = Take $q; if( -not $pk ) { break }; Write-Output ( '  包: ' + ( Hex $pk ) ) }

        $k = New-Object -TypeName byte[] -ArgumentList 20
        $k[10] = 0x41                                                 # VKey = 'a', Flags = 0 -> 按下
        [RawCap]::FeedImage( $k, 1 )
        $k[4] = 1                                                    # Flags = 1 -> 抬起
        [RawCap]::FeedImage( $k, 1 )
        while( $true ) { $pk = Take $q; if( -not $pk ) { break }; Write-Output ( '  包: ' + ( Hex $pk ) ) }

        # 按下→抬起: 状态必须写回并保持, 不然每一包的按钮都是 0(点击转不过去)。
        Write-Output '鼠标按键(按下左键, 然后释放):'
        [RawCap]::Reset()
        [RawCap]::SetBit( 0x01, $true ) | Out-Null
        [RawCap]::EmitSplit( [RawCap]::Buttons(), 0, 0, 0 )
        while( $true ) { $pk = Take $q; if( -not $pk ) { break }; Write-Output ( '  包: ' + ( Hex $pk ) ) }
        [RawCap]::SetBit( 0x01, $false ) | Out-Null
        [RawCap]::EmitSplit( [RawCap]::Buttons(), 0, 0, 0 )
        while( $true ) { $pk = Take $q; if( -not $pk ) { break }; Write-Output ( '  包: ' + ( Hex $pk ) ) }

        # 只给坐标时包里带的是此刻仍然按着的键(主动控制走的是同一个函数)。
        [RawCap]::SetButtons( 0x02 )
        [RawCap]::EmitSplit( [RawCap]::Buttons(), 5, 0, 0 )
        while( $true ) { $pk = Take $q; if( -not $pk ) { break }; Write-Output ( '  包: ' + ( Hex $pk ) ) }
        [RawCap]::Reset()

        # 200 和 -160 都超过 127: 应该出 2 个包, 中间的包只带移动, 最后一个带滚轮。
        Write-Output '拆分(200, -160, 3):'
        [RawCap]::EmitSplit( 0, 200, -160, 3 )
        while( $true ) { $pk = Take $q; if( -not $pk ) { break }; Write-Output ( '  包: ' + ( Hex $pk ) ) }

        Write-Output '键盘快照(a + ctrl, 然后释放):'
        [RawCap]::ApplyKey( 0x04, $true )
        [RawCap]::ApplyKey( 0xE0, $true )
        while( $true ) { $pk = Take $q; if( -not $pk ) { break }; Write-Output ( '  包: ' + ( Hex $pk ) ) }
        [RawCap]::ApplyKey( 0x04, $false )
        [RawCap]::ApplyKey( 0xE0, $false )
        while( $true ) { $pk = Take $q; if( -not $pk ) { break }; Write-Output ( '  包: ' + ( Hex $pk ) ) }

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
            if( -not $script:qok ) { $script:retryAt = ( Get-Date ).AddSeconds( 30 ) }
        }
        if( $n -eq 0 ) { Start-Sleep -Milliseconds 5 }
    }
}
finally
{
    if( $h.ToInt64() -ne -1 ) { [Port]::CloseHandle( $h ) | Out-Null }
}
