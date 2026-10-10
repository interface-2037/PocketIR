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

# Python self-checks first: they also write the vectors some testbenches read
# (build/ir_expected). tb_ui_video's frames come from tools/ui/ui_rom.py.
foreach ($py in Get-ChildItem (Join-Path $root 'tools') -Recurse -Filter 'test_*.py') {
    $result = python $py.FullName 2>&1 | Out-String
    Write-Host $result.Trim()
    if ($LASTEXITCODE -ne 0 -or $result -notmatch '(?m)^PASS') { $failed++ }
}

foreach ($tb in Get-ChildItem $PSScriptRoot -Filter 'tb_*.v') {
    if ($Only -and $tb.BaseName -ne $Only) { continue }
    $vvp = Join-Path $out ($tb.BaseName + '.vvp')
    # -s: only the testbench is a root, so unused RTL modules are not elaborated
    iverilog -g2012 -s $tb.BaseName -I (Join-Path $root 'src\fpga\core\ui') -I (Join-Path $root 'src\fpga\core\ir') -o $vvp $tb.FullName $rtl
    if ($LASTEXITCODE -ne 0) { Write-Host "FAIL $($tb.BaseName) (compile error)"; $failed++; continue }
    $result = vvp -n $vvp | Out-String
    Write-Host $result.Trim()
    if ($result -notmatch '(?m)^PASS') { $failed++ }
}

if ($failed) { Write-Host "`n$failed testbench(es) FAILED"; exit 1 }
Write-Host "`nAll testbenches passed"
