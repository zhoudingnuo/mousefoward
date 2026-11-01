param(
    [string]$Toolchain = $( if( $env:XPACK_RISCV_GCC ) { $env:XPACK_RISCV_GCC } else { 'xpack-riscv-none-elf-gcc-14.2.0-3\bin' } )
)

$ErrorActionPreference = 'Continue'

$proj = $PSScriptRoot
$obj  = Join-Path $proj 'obj'
New-Item -ItemType Directory -Force -Path $obj | Out-Null

$gcc     = Join-Path $Toolchain 'riscv-none-elf-gcc.exe'
$objcopy = Join-Path $Toolchain 'riscv-none-elf-objcopy.exe'
$size    = Join-Path $Toolchain 'riscv-none-elf-size.exe'
$nm      = Join-Path $Toolchain 'riscv-none-elf-gcc-nm.exe'
$od      = Join-Path $Toolchain 'riscv-none-elf-objdump.exe'

$arch = @('-march=rv32imac_zicsr_zifencei', '-mabi=ilp32')
$cflags = $arch + @('-msmall-data-limit=8', '-mno-save-restore', '-Os',
    '-ffunction-sections', '-fdata-sections', '-fomit-frame-pointer', '-Wall',
    '-I.', '-I./Peripheral', '-DCH32V305', '-DCH32V30x_D8C')

Push-Location $proj
$objects = @()
foreach ($s in (Get-ChildItem $proj -File -Filter '*.c' | ForEach-Object { $_.Name })) {
    $objPath = Join-Path $obj ($s + '.o')
    & $gcc @cflags -c $s -o $objPath
    if ($LASTEXITCODE -ne 0) { Write-Output "COMPILE FAILED: $s"; Pop-Location; exit 1 }
    $objects += $objPath
}
foreach ($s in (Get-ChildItem (Join-Path $proj 'Peripheral') -File -Filter '*.c' | ForEach-Object { $_.Name })) {
    $objPath = Join-Path $obj ('Peripheral_' + $s + '.o')
    & $gcc @cflags -c (Join-Path 'Peripheral' $s) -o $objPath
    if ($LASTEXITCODE -ne 0) { Write-Output "COMPILE FAILED: Peripheral/$s"; Pop-Location; exit 1 }
    $objects += $objPath
}

& $gcc @cflags -c 'startup.S' -o (Join-Path $obj 'startup.o')
if ($LASTEXITCODE -ne 0) { Write-Output 'COMPILE FAILED: startup.S'; Pop-Location; exit 1 }
$objects += (Join-Path $obj 'startup.o')

$linkflags = $arch + @('-msmall-data-limit=8', '-mno-save-restore', '-nostartfiles', '-Os',
    '-ffunction-sections', '-fdata-sections', '-Wl,--gc-sections',
    '-Wl,-Map=obj/firmware.map', '-Tlink.ld')
& $gcc @linkflags -o 'obj/firmware.elf' $objects -lm
if ($LASTEXITCODE -ne 0) { Write-Output 'LINK FAILED'; Pop-Location; exit 1 }

& $objcopy -O ihex 'obj/firmware.elf' 'firmware.hex'
& $size 'obj/firmware.elf'

# 描述符声明的长度必须和实际字节数一致, 否则主机只拿到前 64 字节
Write-Output '--- descriptor sizes (must match the declared lengths) ---'
& $nm -S 'obj/usbfs_cdc.c.o' 'obj/usbhs_km.c.o'

Write-Output '--- vector table placement ---'
Select-String -Path 'obj/firmware.map' -Pattern '\.vector' | ForEach-Object { $_.Line }

Write-Output '--- ISR epilogue must be mret, not ret ---'
foreach ($h in @('TIM2_IRQHandler', 'USBFS_IRQHandler', 'USBHS_IRQHandler', 'HardFault_Handler')) {
    $d = & $od -d --disassemble=$h 'obj/firmware.elf'
    if ($d) {
        Write-Output "[$h]"
        $hit = $d | Select-String -Pattern 'mret'
        if ($hit) { $hit | ForEach-Object { Write-Output $_.Line } }
        else {
            Write-Output '  no mret — 不返回的 handler(死循环), 或不是 ISR'
            $d | Select-Object -Last 3 | ForEach-Object { Write-Output $_ }
        }
    } else {
        Write-Output "[$h] not in image"
    }
}

Pop-Location
