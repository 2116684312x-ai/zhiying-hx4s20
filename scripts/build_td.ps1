param(
    [ValidateSet('integrated', 'lab4')]
    [string]$Variant = 'integrated',

    [ValidateSet('synthesis', 'full')]
    [string]$Stage = 'full',

    [string]$RunSuffix = ''
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$tdExe = 'E:/FPGA/zilaio/TD/bin/td_commands_prompt.exe'
$tdFlow = 'E:/FPGA/zilaio/TD/doc/scripts/DefaultFlow.tcl'

if ($Variant -eq 'integrated') {
    $tdProject = Join-Path $projectRoot 'src/td_project'
    $projectName = 'HDMI1.4b_Transmitter_v1.0'
} else {
    $tdProject = Join-Path $projectRoot 'baselines/lab_ex4_tf/src/td_project'
    # The official lab_ex4 project itself carries this historical name.
    $projectName = 'lab_ex5_i2s_v1.0'
}

if (-not (Test-Path -LiteralPath $tdExe)) { throw "TD executable not found: $tdExe" }
$runRoot = Join-Path $tdProject ($projectName + '_Runs' + $RunSuffix)
$templateRoot = Join-Path $projectRoot "scripts/td_templates/$Variant"
$stages = @('syn_1')
if ($Stage -eq 'full') { $stages += 'phy_1' }

foreach ($runName in $stages) {
    $runDir = Join-Path $runRoot $runName
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $templateRoot "$runName.prj") -Destination (Join-Path $runDir "$projectName.prj") -Force
    Copy-Item -LiteralPath (Join-Path $templateRoot "$runName.cfg") -Destination (Join-Path $runDir 'settings.cfg') -Force
    Set-Content -LiteralPath (Join-Path $runDir 'invoke.tcl') -Encoding ascii -Value @(
        'source ./settings.cfg',
        "source $tdFlow"
    )

    $started = Get-Date
    $logPath = Join-Path $runDir 'manual_build.log'
    Push-Location $runDir
    try {
        & $tdExe 'invoke.tcl' | Out-File -LiteralPath $logPath -Encoding utf8
    } finally {
        Pop-Location
    }

    $expectedEnd = if ($runName -eq 'syn_1') { '.opt_gate.end.f' } else { '.bitgen.end.f' }
    $marker = Join-Path $runDir $expectedEnd
    if (-not (Test-Path -LiteralPath $marker) -or (Get-Item -LiteralPath $marker).LastWriteTime -lt $started.AddSeconds(-1)) {
        Get-Content -LiteralPath $logPath -Tail 35
        throw "$Variant $runName did not finish; inspect $logPath"
    }
    Write-Output "$Variant $runName completed: $logPath"
}

if ($Stage -eq 'full') {
    $bitPath = Join-Path (Join-Path $runRoot 'phy_1') "$projectName.bit"
    if (-not (Test-Path -LiteralPath $bitPath)) { throw "Bitstream missing: $bitPath" }
    Write-Output "Bitstream: $bitPath"
    $statusPath = Join-Path (Join-Path $runRoot 'phy_1') 'route_flow.status'
    if (Test-Path -LiteralPath $statusPath) {
        Select-String -LiteralPath $statusPath -Pattern 'Setup|Hold' | ForEach-Object { $_.Line }
    }
}
