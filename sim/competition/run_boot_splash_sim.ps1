$ErrorActionPreference = 'Stop'
$simRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent (Split-Path -Parent $simRoot)
$modelSimBin = 'E:/FPGA/zilaio/Modelsim/modelsim_ae/win32aloem'
$localLicense = 'E:/FPGA/zilaio/Modelsim/modelsim_ae/license/LICENSE.TXT'
$workLib = Join-Path $simRoot 'work_boot_splash'

if (-not $env:MGLS_LICENSE_FILE -and -not $env:LM_LICENSE_FILE -and
    (Test-Path -LiteralPath $localLicense -PathType Leaf)) {
    $env:MGLS_LICENSE_FILE = $localLicense
}
if (-not (Test-Path -LiteralPath $workLib)) {
    & "$modelSimBin/vlib.exe" $workLib
    if ($LASTEXITCODE -ne 0) { throw 'vlib failed' }
}

$sources = @(
    (Join-Path $projectRoot 'src/competition/rtl/display/boot_splash_overlay.v'),
    (Join-Path $simRoot 'tb_boot_splash.v')
)
& "$modelSimBin/vlog.exe" -work $workLib @sources
if ($LASTEXITCODE -ne 0) { throw 'boot splash vlog failed' }
$out = & "$modelSimBin/vsim.exe" -c -lib $workLib tb_boot_splash -do 'run -all; quit -f' 2>&1
$out | Write-Output
if ($LASTEXITCODE -ne 0 -or -not ($out -match '^# PASS: visible loading screen')) {
    throw 'boot splash simulation failed'
}
