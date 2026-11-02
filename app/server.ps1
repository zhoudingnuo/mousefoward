# app/server.ps1 - 只有一个锁定按钮的前端, 和它的后端。
#
# 点一下按钮 = 参考实现(mouse-forwarder-pre-nn)的锁定模式, 逻辑照它抄:
#   本端光标不再跟着手走(被拉回屏幕中心), 手只控制另一台机器; 再点一下或按 Esc 退出。
#   参考实现里锁定不改转发路径(它连 mouse.set_suppress 都没有调用), 这里也不改:
#   锁定只改本端光标的处理, 转发照旧。
#
# 和参考实现的一个实际差别: 它用低级钩子取事件, 所以拉回光标以前要先 skip_next_move(),
#   不然 SetCursorPos 会被当成一次移动发出去。这里用 Raw Input, 它只报设备来的输入,
#   程序改光标不产生事件(实测: 连 SetCursorPos 10 次, WM_INPUT 计数不变), 所以不需要跳过。
#
# 接口两种用法(见 api.md):
#   转发: 本机的输入原样送过去(采集线程出包, 主循环写串口)。
#   主动控制: 程序自己发坐标和按键(POST /api/mouse, POST /api/key), 不动本机的光标。
#
#   powershell -File app\server.ps1              # 起服务: http://localhost:8765
#   powershell -File app\server.ps1 -Open        # 起服务并打开浏览器
#   powershell -File app\server.ps1 -DryRun      # 不开串口, 只统计包(接口照样能调)

param(
    [int]$HttpPort = 8765,
    [string]$Com = '',
    [switch]$DryRun,
    [switch]$Open,
    [int]$QuietSec = 5,
    [int]$ReadTimeoutMs = 3000,
    [int]$OffPct = 80
)

. ( Join-Path $PSScriptRoot '..\tools\lib.ps1' )

Add-Type @'
using System;
using System.Runtime.InteropServices;
public class Scr {
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int x; public int y; }
    [DllImport("user32.dll")] public static extern bool GetCursorPos(ref POINT p);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int idx);   // 0 = SM_CXSCREEN, 1 = SM_CYSCREEN
}
'@

$script:lock = $false
$script:com = ''
$script:h = [IntPtr]::Zero
$script:total = 0
$script:ctrl = 0
$script:recenter = 0
$script:rate = 0.0
$script:winStart = Get-Date
$script:winSent = 0
$script:quietSince = Get-Date
$script:retryAt = Get-Date
$script:wantStatus = $false
$script:status = $null
$script:verdict = ''
$script:base = $null
$script:sw = [Scr]::GetSystemMetrics( 0 )
$script:sh = [Scr]::GetSystemMetrics( 1 )

$html = Join-Path $PSScriptRoot 'index.html'
$q = [RawCap]::Packets

# ---------------- 状态 ----------------

# 帧率从包数自己算。这里不能读设备: 读是一个会挂住的往返(实测 1.5s),
# 挂住的这段时间采集线程还在出包, 读回来以后一次性全倒出去, 那边就是"卡一下然后跳一段"。
function Rate()
{
    $sec = (( Get-Date ) - $script:winStart).TotalSeconds
    if( $sec -lt 1.0 ) { return }
    $script:rate = $script:winSent / $sec
    $script:winStart = Get-Date
    $script:winSent = 0
}

function CursorPos()
{
    $p = New-Object 'Scr+POINT'
    if( -not [Scr]::GetCursorPos( [ref]$p ) ) { return $null }
    return @{ x = $p.x; y = $p.y }
}

# 锁定模式里唯一做的事: 本端光标跑得太远就拉回中心(参考实现的 _recenter_loop)。
# 阈值按半屏的百分比算, 不照抄参考的 950/500 像素: 参考那台是 1920x1080(半屏 960/540),
# 在这台 1536x864(半屏 768/432)上 900 永远达不到, 一次都不会触发。
function Recenter()
{
    $p = CursorPos
    if( -not $p ) { return }
    $cx = [int]( $script:sw / 2 )
    $cy = [int]( $script:sh / 2 )
    $limx = [int]( $cx * $OffPct / 100 )
    $limy = [int]( $cy * $OffPct / 100 )
    if( [math]::Abs( $p.x - $cx ) -gt $limx -or [math]::Abs( $p.y - $cy ) -gt $limy )
    {
        [Scr]::SetCursorPos( $cx, $cy ) | Out-Null
        $script:recenter++
    }
}

function StateJson()
{
    $o = [ordered]@{
        lock    = [bool]( $script:lock )
        port    = $script:com
        screen  = @{ w = $script:sw; h = $script:sh }
        cursor  = CursorPos
        recenter = [int]( $script:recenter )
        capture = @{
            registered = [bool]( [RawCap]::Registered )
            stage      = [RawCap]::Stage
            nInput     = [int]( [RawCap]::nInput )
            mouse      = [int]( [RawCap]::nMouse )
            key        = [int]( [RawCap]::nKeyEvents )
            unmapped   = [int]( [RawCap]::nKeyUnmapped )
            dumps      = @( [RawCap]::KeyDumps )
        }
        sent    = @{ total = [int]$script:total; queued = [int]$script:ctrl }
        rate    = [math]::Round( $script:rate, 1 )
        quiet   = [math]::Round((( Get-Date ) - $script:quietSince).TotalSeconds, 1 )
        status  = $script:status
        verdict = $script:verdict
    }
    return ( $o | ConvertTo-Json -Compress -Depth 6 )
}

# 状态行只在安静了 QuietSec 秒以后读(这时候没有在转发, 挂住也不影响)。
# 读的结果存起来给前端, 不在请求里现读: 请求处理必须在主循环里, 不能挂。
function Query()
{
    if( $DryRun ) { $script:verdict = '没开串口, 读不到状态行。'; return }

    $w = [uint32]0
    [Port]::WriteFile( $script:h, [byte[]]( 0x53 ), [uint32]1, [ref]$w, [IntPtr]::Zero ) | Out-Null

    $line = ReadLine $script:h 1500
    if( -not $line )
    {
        $script:verdict = '读不到状态行。要先发一个 S 再阻塞读。'
        $script:retryAt = ( Get-Date ).AddSeconds( 30 )
        return
    }

    $now = Parse $line
    if( -not $now )
    {
        $script:verdict = '状态行读不全(计数器到 10 位会把 64 字节缓冲区写穿, 行被截)。'
        $script:retryAt = ( Get-Date ).AddSeconds( 30 )
        return
    }

    $script:status = $now

    if( -not $script:base ) { $script:base = $now }

    $dok   = $now.ok   - $script:base.ok
    $dms   = $now.ms   - $script:base.ms
    $dkb   = $now.kb   - $script:base.kb
    $ddrop = $now.drop - $script:base.drop

    $v = @()
    if( $now.cdc -eq 0 ) { $v += '本端口没被枚举: COM 口存在但枚举没走完。' }
    else { $v += '本端口已枚举, 字节进得来。' }

    if( $now.hs -eq 0 ) { $v += '另一台机器没枚举键鼠口: 那边不会动。' }
    else { $v += '另一台机器已枚举键鼠口。' }

    if( $now.p1 -eq 0 ) { $v += '鼠标接口没被绑定 (p1=0)。' } else { $v += '鼠标接口被绑定了 (p1=' + $now.p1 + ')。' }
    if( $now.p0 -eq 0 ) { $v += '键盘接口没被绑定 (p0=0)。' } else { $v += '键盘接口被绑定了 (p0=' + $now.p0 + ')。' }

    if( $dok -lt $script:winSent ) { $v += '这一段发了 ' + $script:winSent + ' 包, 只解析到 ' + $dok + ' 个: 本端到板这一段断了。' }
    elseif( $dms + $dkb -lt $dok ) { $v += '解析对了 ' + $dok + ' 个, 只有 ' + $dms + ' 个鼠标 + ' + $dkb + ' 个键盘写进端点, drop=' + $ddrop + ': 端点一直忙(主机没在轮询)。' }
    else { $v += $dok + ' 个包全部解析并写进端点 (鼠标 ' + $dms + ', 键盘 ' + $dkb + ')。' }

    $script:verdict = ( $v -join ' ' )
}

# ---------------- HTTP ----------------

function Reply( $ctx, [string]$body, [string]$type )
{
    $buf = [System.Text.Encoding]::UTF8.GetBytes( $body )
    $ctx.Response.StatusCode = 200
    $ctx.Response.ContentType = $type
    $ctx.Response.ContentLength64 = $buf.Length
    $ctx.Response.OutputStream.Write( $buf, 0, $buf.Length )
    $ctx.Response.Close()
}

function Body( $ctx )
{
    $s = New-Object System.IO.StreamReader( $ctx.Request.InputStream )
    $t = $s.ReadToEnd()
    $s.Close()
    if( -not $t ) { return $null }
    try { return ( ConvertFrom-Json $t ) } catch { return $null }
}

function Handle( $ctx )
{
    $path = $ctx.Request.Url.PathAndQuery

    if( $path -eq '/' -or $path -eq '/index.html' )
    {
        if( -not ( Test-Path $html ) ) { Reply $ctx 'index.html 不在 ' + $PSScriptRoot 'text/plain; charset=utf-8'; return }
        Reply $ctx ( Get-Content -Raw -Encoding UTF8 $html ) 'text/html; charset=utf-8'
        return
    }

    if( $path -eq '/api/state' ) { Reply $ctx ( StateJson ) 'application/json; charset=utf-8'; return }

    if( $path -eq '/api/lock' )
    {
        $b = Body $ctx
        if( -not $b ) { Reply $ctx '{"error":"要一个 JSON 对象, 比如 {\"enabled\":true}"}' 'application/json; charset=utf-8'; return }
        $on = $b.enabled
        if( $b.toggle ) { $on = -not $script:lock }
        $script:lock = [bool]$on
        Write-Output ( '锁定 ' + $( if( $script:lock ) { '开' } else { '关' } ) )
        Reply $ctx ( '{"lock":' + ( $script:lock | ConvertTo-Json ) + '}' ) 'application/json; charset=utf-8'
        return
    }

    if( $path -eq '/api/mouse' )
    {
        $b = Body $ctx
        if( -not $b ) { Reply $ctx '{"error":"要 {\"dx\":120,\"dy\":0,\"buttons\":1,\"wheel\":0}"}' 'application/json; charset=utf-8'; return }

        # buttons 给的是"按下后"的状态, 所以先写进保持的状态再发; 没给就沿用当前状态
        # (和采集路径一样: 只给坐标时, 包里带的是此刻仍然按着的键)。
        if( $b.buttons -ne $null ) { [RawCap]::SetButtons( [int]$b.buttons ) }
        $flags = [RawCap]::Buttons()

        $dx = 0; $dy = 0; $wheel = 0
        if( $b.dx ) { $dx = [int]$b.dx }
        if( $b.dy ) { $dy = [int]$b.dy }
        if( $b.wheel ) { $wheel = [int]$b.wheel }

        # 走的是和采集同一条路: 超过 ±127 在这里被拆成多个包, 校验和在这里加。
        $before = $q.Count
        [RawCap]::EmitSplit( $flags, $dx, $dy, $wheel )
        $n = $q.Count - $before
        $script:ctrl += $n
        Reply $ctx ( '{"queued":' + $n + '}' ) 'application/json; charset=utf-8'
        return
    }

    if( $path -eq '/api/key' )
    {
        $b = Body $ctx
        if( -not $b ) { Reply $ctx '{"error":"要 {\"vk\":65,\"down\":true} 或 {\"usage\":4,\"down\":true}"}' 'application/json; charset=utf-8'; return }

        $usage = -1
        if( $b.usage -ne $null ) { $usage = [int]$b.usage }
        elseif( $b.vk -ne $null ) { $usage = [RawCap]::Usage( [int]$b.vk ) }
        if( $usage -lt 0 ) { Reply $ctx '{"error":"这个键没有 HID usage"}' 'application/json; charset=utf-8'; return }

        $down = $true
        if( $b.down -ne $null ) { $down = [bool]$b.down }

        $before = $q.Count
        [RawCap]::ApplyKey( $usage, $down )
        $n = $q.Count - $before
        $script:ctrl += $n
        Reply $ctx ( '{"usage":' + $usage + ',"queued":' + $n + '}' ) 'application/json; charset=utf-8'
        return
    }

    if( $path -eq '/api/status' )
    {
        # 不在这里读: 读会挂住(实测 1.5s), 主循环还要取采集队列。挂个标志, 安静了以后由主循环读。
        $script:wantStatus = $true
        Reply $ctx ( '{"queued":true,"quiet":' + [math]::Round((( Get-Date ) - $script:quietSince).TotalSeconds, 1 ) + '}' ) 'application/json; charset=utf-8'
        return
    }

    $ctx.Response.StatusCode = 404
    $ctx.Response.ContentType = 'application/json; charset=utf-8'
    $buf = [System.Text.Encoding]::UTF8.GetBytes( '{"error":"没有这个接口"}' )
    $ctx.Response.ContentLength64 = $buf.Length
    $ctx.Response.OutputStream.Write( $buf, 0, $buf.Length )
    $ctx.Response.Close()
}

# ---------------- 起 ----------------

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add( 'http://localhost:' + $HttpPort + '/' )
try { $listener.Start() }
catch
{
    Write-Output ( '监听 http://localhost:' + $HttpPort + ' 失败: ' + $_.Exception.Message )
    exit 1
}

if( -not $DryRun )
{
    if( -not $Com ) { $Com = FindCdcPort }
    if( -not $Com )
    {
        Write-Output '没找到板子的串口 (VID 1A86 的设备没有被 usbser.sys 绑定)。用 -DryRun 只看接口。'
    }
    else
    {
        $script:h = OpenPort $Com $ReadTimeoutMs
        if( $script:h.ToInt64() -eq -1 )
        {
            Write-Output ( '打不开 ' + $Com + ' (错误 ' + [System.Runtime.InteropServices.Marshal]::GetLastWin32Error() + ')' )
            $listener.Stop()
            exit 1
        }
        $script:com = $Com
    }
}

[RawCap]::Start()

Write-Output ( '前端: http://localhost:' + $HttpPort + ( $( if( $DryRun ) { ' (没开串口)' } else { ' ' + $script:com } ) ) )
Write-Output '只有一个按钮: 点一下锁定(本端光标被拉回中心, 手只控制另一台机器), 再点一下或按 Esc 退出。'

if( $Open ) { Start-Process ( 'http://localhost:' + $HttpPort ) }

# 主循环里不能有会挂住的调用: HTTP 用 BeginGetContext, 状态行只在安静的时候读。
$ar = $listener.BeginGetContext( $null, $null )

try
{
    while( $true )
    {
        if( $ar.IsCompleted )
        {
            $ctx = $listener.EndGetContext( $ar )
            Handle $ctx
            $ar = $listener.BeginGetContext( $null, $null )
        }

        $n = 0
        while( $true )
        {
            $pk = Take $q
            if( -not $pk ) { break }
            WritePacket $script:h $pk | Out-Null
            $script:total++
            $n++
        }
        if( $n -gt 0 ) { $script:quietSince = Get-Date }

        Rate

        if( $script:lock ) { Recenter }

        if( $n -eq 0 -and $script:wantStatus -and ( ( Get-Date ) - $script:quietSince ).TotalSeconds -ge $QuietSec -and ( Get-Date ) -ge $script:retryAt )
        {
            Query
            $script:wantStatus = $false
        }

        # 采集线程现在是挂住的 GetMessage(消息来了立刻处理), 这里只在没包要发时歇一下。
        # lib.ps1 里调了 timeBeginPeriod(1), 所以这个 1 ms 才真的是 1 ms(默认计时精度 15.625 ms)。
        if( $n -eq 0 ) { Start-Sleep -Milliseconds 1 }
    }
}
finally
{
    $listener.Stop()
    if( $script:h.ToInt64() -ne -1 ) { [Port]::CloseHandle( $script:h ) | Out-Null }
}
