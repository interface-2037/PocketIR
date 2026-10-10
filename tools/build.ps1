# Full build: Quartus compile -> timing summary -> package for the SD card.
# Usage (from the repo root):
#   powershell -ExecutionPolicy Bypass -File tools\build.ps1                 # Quartus 25.1 Lite (default)
#   powershell -ExecutionPolicy Bypass -File tools\build.ps1 -Quartus 18.1   # another installed version
#   powershell -ExecutionPolicy Bypass -File tools\build.ps1 -Quartus C:\path\to\quartus_sh.exe
# The version is always explicit, so a newly installed Quartus never upgrades
# the project by accident. PATH is ignored.

param([string]$Quartus = '25.1')
$DefaultQuartus = '25.1'          # keep in sync with the param default above

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fpga = Join-Path $root 'src\fpga'

$installRoots = 'C:\intelFPGA_lite', 'C:\altera_lite', 'C:\intelFPGA', 'C:\altera'
$installed = Get-ChildItem $installRoots -Directory -ErrorAction SilentlyContinue |
             Where-Object { Test-Path (Join-Path $_.FullName 'quartus\bin64\quartus_sh.exe') }

if (Test-Path $Quartus -PathType Leaf) {
    $qsh = (Resolve-Path $Quartus).Path
} else {
    # version folders look like "18.1" or "25.1std"
    $match = $installed | Where-Object { $_.Name -like "$Quartus*" } | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $match) {
        $list = if ($installed) { ($installed | ForEach-Object { "$($_.Name) ($($_.FullName))" }) -join ', ' } else { 'none' }
        throw "Quartus $Quartus not found. Installed: $list. Use -Quartus <version> or a path to quartus_sh.exe."
    }
    $qsh = Join-Path $match.FullName 'quartus\bin64\quartus_sh.exe'
}

Write-Host "== Compiling with $qsh"
Push-Location $fpga
try {
    & $qsh --flow compile ap_core
    if ($LASTEXITCODE -ne 0) { throw "Quartus compile failed (exit $LASTEXITCODE). See src\fpga\output_files\*.rpt" }
} finally { Pop-Location }

Write-Host "`n== Timing summary"
$sta = Join-Path $fpga 'output_files\ap_core.sta.summary'
if (Test-Path $sta) {
    $slacks = Select-String -Path $sta -Pattern '^Slack\s*:\s*(-?[\d.]+)' | ForEach-Object { [double]$_.Matches[0].Groups[1].Value }
    $bad = @($slacks | Where-Object { $_ -lt 0 })
    if ($bad.Count) { Write-Warning "$($bad.Count) timing check(s) FAILED (negative slack). See $sta" }
    else { Write-Host "All $($slacks.Count) timing checks met (worst slack $(($slacks | Measure-Object -Minimum).Minimum) ns)." }
} else { Write-Warning "No timing summary found at $sta" }

Write-Host "`n== Packaging"
# builds from a non-default Quartus get a tag so they never overwrite the main package
$tag = if ($Quartus -eq $DefaultQuartus) { '' } elseif (Test-Path $Quartus -PathType Leaf) { 'qcustom' } else { "q$Quartus" }
if ($tag) { python (Join-Path $root 'tools\package_core.py') --tag $tag } else { python (Join-Path $root 'tools\package_core.py') }
if ($LASTEXITCODE -ne 0) { throw 'Packaging failed' }
