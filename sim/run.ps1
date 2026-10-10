# Run every sim\tb_*.v testbench with Icarus Verilog and report PASS/FAIL.
# Usage (from the repo root):  powershell -ExecutionPolicy Bypass -File sim\run.ps1 [tb_name]

param([string]$Only = '')

$root = Split-Path -Parent $PSScriptRoot
$out  = Join-Path $PSScriptRoot 'out'
New-Item -ItemType Directory -Force $out | Out-Null

# RTL sources available to every testbench.
$rtl = @(Get-ChildItem (Join-Path $root 'src\fpga\core\ir'), (Join-Path $root 'src\fpga\core\ui'), (Join-Path $root 'src\fpga\core\input') `
        -Filter *.v -ErrorAction SilentlyContinue | ForEach-Object FullName)

$failed = 0
foreach ($tb in Get-ChildItem $PSScriptRoot -Filter 'tb_*.v') {
    if ($Only -and $tb.BaseName -ne $Only) { continue }
    $vvp = Join-Path $out ($tb.BaseName + '.vvp')
    iverilog -g2012 -o $vvp $tb.FullName $rtl
    if ($LASTEXITCODE -ne 0) { Write-Host "FAIL $($tb.BaseName) (compile error)"; $failed++; continue }
    $result = vvp -n $vvp | Out-String
    Write-Host $result.Trim()
    if ($result -notmatch '(?m)^PASS') { $failed++ }
}

if ($failed) { Write-Host "`n$failed testbench(es) FAILED"; exit 1 }
Write-Host "`nAll testbenches passed"
