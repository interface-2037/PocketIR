# Full build: Quartus compile -> timing summary -> package for the SD card.
# Usage (from the repo root):  powershell -ExecutionPolicy Bypass -File tools\build.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fpga = Join-Path $root 'src\fpga'

# Find quartus_sh: PATH first, then default Lite install locations (newest first).
$qsh = (Get-Command quartus_sh -ErrorAction SilentlyContinue).Source
if (-not $qsh) {
    $qsh = Get-ChildItem 'C:\altera_lite\*\quartus\bin64\quartus_sh.exe', 'C:\intelFPGA_lite\*\quartus\bin64\quartus_sh.exe' -ErrorAction SilentlyContinue |
           Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
    if (-not $qsh) { Write-Error 'quartus_sh not found. Install Quartus Prime Lite or add quartus\bin64 to PATH.' }
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
python (Join-Path $root 'tools\package_core.py')
if ($LASTEXITCODE -ne 0) { throw 'Packaging failed' }
