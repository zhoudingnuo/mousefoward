# api.ps1 - 命令行调接口(主动控制)。服务要先跑着: powershell -File app\server.ps1
#
# 接口文档在 api.md。这里只是把同样的接口从命令行调一遍:
#
#   powershell -File tools\api.ps1 -State                    # 看状态
#   powershell -File tools\api.ps1 -Lock                     # 锁定(本端光标被拉回中心)
#   powershell -File tools\api.ps1 -Unlock
#   powershell -File tools\api.ps1 -Move 200,0               # 另一台机器的光标向右 200(超过 127 会被拆成两个包)
#   powershell -File tools\api.ps1 -Click left               # 按下再放开
#   powershell -File tools\api.ps1 -Tap a                    # 按一个键
#   powershell -File tools\api.ps1 -Down ctrl -Tap a -Up ctrl   # ctrl+a
#   powershell -File tools\api.ps1 -Status                   # 排队读状态行(安静了以后由服务读, 不在请求里读)

param(
    [string]$Server = 'http://localhost:8765',
    [switch]$State,
    [switch]$Lock,
    [switch]$Unlock,
    [string]$Move = '',
    [string]$Click = '',
    [string]$Tap = '',
    [string]$Down = '',
    [string]$Up = '',
    [switch]$Status
)

function Post( [string]$path, $body )
{
    $j = '{}'
    if( $body ) { $j = ( ConvertTo-Json $body -Compress ) }
    $r = Invoke-RestMethod -Uri ( $Server + $path ) -Method POST -Body $j -ContentType 'application/json' -TimeoutSec 10
    Write-Output ( 'POST ' + $path + ' ' + $j + '  ->  ' + ( ConvertTo-Json $r -Compress ) )
}

function Get( [string]$path )
{
    return ( Invoke-RestMethod -Uri ( $Server + $path ) -TimeoutSec 10 )
}

# 名字 -> VKey。接口要的是 VKey 或 HID usage; 服务里 VKey -> usage 用的是 tools/lib.ps1 的映射。
function Vk( [string]$name )
{
    $n = $name.ToLower()
    $map = @{ 'ctrl' = 0x11; 'shift' = 0x10; 'alt' = 0x12; 'gui' = 0x5B; 'enter' = 0x0D; 'esc' = 0x1B;
             'space' = 0x20; 'tab' = 0x09; 'backspace' = 0x08; 'left' = 0x25; 'up' = 0x26; 'right' = 0x27; 'down' = 0x28 }
    if( $map.ContainsKey( $n ) ) { return $map[ $n ] }
    if( $n.Length -eq 1 )
    {
        $c = [int][char]$n
        if( $c -ge 97 -and $c -le 122 ) { return $c - 32 }      # a-z -> VK 0x41~0x5A
        if( $c -ge 48 -and $c -le 57 ) { return $c }            # 0-9
    }
    return -1
}

$btn = @{ 'left' = 1; 'right' = 2; 'middle' = 4; 'x1' = 16; 'x2' = 32 }

if( -not ( $State -or $Lock -or $Unlock -or $Move -or $Click -or $Tap -or $Down -or $Up -or $Status ) )
{
    Write-Output '至少要给一个动作。'
    exit 1
}

if( $Lock ) { Post '/api/lock' @{ enabled = $true } }
if( $Unlock ) { Post '/api/lock' @{ enabled = $false } }

if( $Move )
{
    $p = $Move.Split( ',' )
    $dx = [int]$p[0]
    $dy = 0
    if( $p.Length -gt 1 ) { $dy = [int]$p[1] }
    Post '/api/mouse' @{ dx = $dx; dy = $dy }
}

if( $Click )
{
    if( -not $btn.ContainsKey( $Click.ToLower() ) ) { Write-Output '按钮要是 left/right/middle/x1/x2。'; exit 1 }
    $b = $btn[ $Click.ToLower() ]
    Post '/api/mouse' @{ buttons = $b }
    Post '/api/mouse' @{ buttons = 0 }
}

if( $Down ) { Post '/api/key' @{ vk = Vk $Down; down = $true } }
if( $Tap ) { Post '/api/key' @{ vk = Vk $Tap; down = $true }; Post '/api/key' @{ vk = Vk $Tap; down = $false } }
if( $Up ) { Post '/api/key' @{ vk = Vk $Up; down = $false } }

if( $Status ) { Post '/api/status' $null }

if( $State )
{
    $s = Get '/api/state'
    Write-Output ( '锁定 ' + $s.lock + '  串口 ' + $s.port + '  已发 ' + $s.sent.total + ' 包(接口 ' + $s.sent.queued + ')' )
    Write-Output ( '包率 ' + $s.rate + ' 包/秒  安静 ' + $s.quiet + 's  拉回中心 ' + $s.recenter + ' 次' )
    if( $s.status )
    {
        Write-Output ( '板子: ' + ( $s.status | ConvertTo-Json -Compress ) )
    }
    if( $s.verdict ) { Write-Output $s.verdict }
}
