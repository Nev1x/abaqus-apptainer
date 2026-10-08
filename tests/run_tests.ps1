# Проверка Windows-скриптов (scripts\windows\*.ps1) с заглушкой Abaqus.
# Запускается на Windows (PowerShell 5.1/7) или в PowerShell 7 на Linux/macOS:
#   powershell -ExecutionPolicy Bypass -File tests\run_tests.ps1 <каталог_с_inp>
# Работает в копии проекта во временном каталоге — рабочие results\ не затрагиваются.
param([Parameter(Mandatory = $true)][string]$InputsDir)
$ErrorActionPreference = 'Stop'
$src = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$InputsDir = (Resolve-Path $InputsDir).Path
$sep = [IO.Path]::DirectorySeparatorChar

$work = Join-Path ([IO.Path]::GetTempPath()) ("abq-ps-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work | Out-Null
foreach ($d in 'scripts', 'abaqus_scripts', 'tests', 'tools') { Copy-Item -Recurse (Join-Path $src $d) (Join-Path $work $d) }
New-Item -ItemType Directory -Path "$work${sep}inputs" | Out-Null
Copy-Item (Join-Path $InputsDir '*.inp') "$work${sep}inputs"
$scratch = Join-Path $work 'scratch'
@"
RUNTIME=native
ABAQUS_CMD=$work${sep}tests${sep}fake_abaqus.ps1
INPUT_DIR=.${sep}inputs
RESULTS_DIR=.${sep}results
SCRATCH_DIR=$scratch
CPUS=2
PARALLEL=2
POSTPROCESS=1
KEEP_RESTART=0
"@ | Set-Content -Path "$work${sep}config.env" -Encoding UTF8
$env:ABQ_CONFIG = "$work${sep}config.env"
$env:FAKE_SECONDS = '3'

$script:pass = 0; $script:fail = 0
function Check([string]$name, [bool]$cond) {
    if ($cond) { Write-Host "  [OK]   $name"; $script:pass++ } else { Write-Host "  [FAIL] $name"; $script:fail++ }
}
function St([string]$job) {
    $f = "$work${sep}results${sep}$job${sep}STATUS"
    if (Test-Path $f) { return (Get-Content $f -Raw).Trim() } else { return '' }
}
$ps = (Get-Process -Id $PID).Path
$win = "$work${sep}scripts${sep}windows"
function Run([string]$script, [string[]]$a, [string]$log) {
    $argString = "-NoProfile -ExecutionPolicy Bypass -File `"$win$sep$script`" " + (($a | ForEach-Object { "`"$_`"" }) -join ' ')
    $p = Start-Process -FilePath $ps -ArgumentList $argString -WorkingDirectory $work -NoNewWindow -PassThru `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err"
    $null = $p.Handle; $p.WaitForExit(); return $p.ExitCode
}

$jobs = @(Get-ChildItem "$work${sep}inputs" -Filter *.inp | ForEach-Object { $_.BaseName } |
    Sort-Object { ((($_ -split '(\d+)') | ForEach-Object { if ($_ -match '^\d+$') { $_.PadLeft(12, '0') } else { $_ } }) -join '') })
$first = $jobs[0]; $last = $jobs[-1]
Write-Host "PowerShell $($PSVersionTable.PSVersion) на $([Environment]::OSVersion.VersionString); задач: $($jobs.Count); ошибка будет у $last"

Write-Host '1. Очередь: задачи по 2 одновременно, одна завершается ошибкой'
$env:FAKE_FAIL = "^$last`$"
$rc = Run 'run_queue.ps1' @() "$work${sep}q1.log"
Remove-Item Env:FAKE_FAIL
Check 'очередь вернула код 1 (есть ошибка)' ($rc -eq 1)
foreach ($j in $jobs) {
    if ($j -eq $last) { Check "${j}: FAILED" ((St $j) -eq 'FAILED') } else { Check "${j}: DONE" ((St $j) -eq 'DONE') }
}
Check 'ошибка решателя попала в журнал очереди' ((Get-Content "$work${sep}q1.log" -Raw) -match 'fake failure')
$r1 = "$work${sep}results${sep}$first${sep}$first"
Check 'файлы перезапуска удалены, .odb оставлен' ((Test-Path "$r1.odb") -and -not (Test-Path "$r1.abq") -and -not (Test-Path "$r1.stt"))
Check "постобработка создала ${first}_history.csv" (Test-Path "${r1}_history.csv")
Check 'в job.meta есть sha256 входного файла' ((Get-Content "$work${sep}results${sep}$first${sep}job.meta" -Raw) -match 'inp_sha256=[0-9a-f]{64}')
Check 'abaqus получил cpus=2 mp_mode=threads и долю памяти' ((Get-Content "$r1.log" -Raw) -match 'cpus=2 mp_mode=threads memory=45%')
$ev = Get-Content "$scratch${sep}trace" | ForEach-Object {
    $x = $_ -split ' '; [pscustomobject]@{ T = [double]::Parse($x[2], [Globalization.CultureInfo]::InvariantCulture); D = $(if ($x[0] -eq 'start') { 1 } else { -1 }) } } |
    Sort-Object T
$c = 0; $max = 0; foreach ($e in $ev) { $c += $e.D; if ($c -gt $max) { $max = $c } }
Check "одновременно выполнялось не больше 2 задач (факт: $max)" ($max -eq 2)

Write-Host '2. Повторный запуск продолжает с места остановки'
$startsBefore = @(Get-Content "$scratch${sep}trace" | Where-Object { $_ -like "start $first *" }).Count
$rc = Run 'run_queue.ps1' @() "$work${sep}q2.log"
Check 'очередь вернула 0' ($rc -eq 0)
Check 'готовые задачи пропущены' (@(Get-Content "$scratch${sep}trace" | Where-Object { $_ -like "start $first *" }).Count -eq $startsBefore)
Check "$last пересчитана: DONE" ((St $last) -eq 'DONE')

Write-Host '3. Блокировки'
$lock = "$work${sep}results${sep}$first${sep}.lock"
New-Item -ItemType Directory -Path $lock | Out-Null
Set-Content "$lock${sep}owner" ("{0}:{1}" -f [Environment]::MachineName, $PID)   # "живой" владелец
$env:FORCE = '1'
$null = Run 'run_job.ps1' @("$work${sep}inputs${sep}$first.inp") "$work${sep}q3.log"
Check 'задача с активной блокировкой не запускается повторно' ((Get-Content "$work${sep}q3.log" -Raw) -match 'уже выполняется')
Set-Content "$lock${sep}owner" ("{0}:{1}" -f [Environment]::MachineName, 999999)  # владелец умер
$env:FAKE_SECONDS = '1'
$null = Run 'run_job.ps1' @("$work${sep}inputs${sep}$first.inp") "$work${sep}q4.log"
Remove-Item Env:FORCE
Check 'устаревшая блокировка снята, задача выполнена' (((Get-Content "$work${sep}q4.log" -Raw) -match 'устаревшую') -and ((St $first) -eq 'DONE'))
Check 'блокировка удалена после завершения' (-not (Test-Path $lock))

Write-Host '4. Сводка'
$null = Run 'status.ps1' @() "$work${sep}status.log"
Check "status.ps1: DONE: $($jobs.Count)" ((Get-Content "$work${sep}status.log" -Raw) -match "DONE: $($jobs.Count)\s")

# Сохранить журналы для отчёта/методички (если задан ABQ_TEST_OUT)
if ($env:ABQ_TEST_OUT) {
    New-Item -ItemType Directory -Force -Path $env:ABQ_TEST_OUT | Out-Null
    foreach ($f in 'q1.log', 'q2.log', 'status.log') { Copy-Item (Join-Path $work $f) $env:ABQ_TEST_OUT -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host "Итог: пройдено $($script:pass), ошибок $($script:fail)   (рабочий каталог: $work)"
if ($script:fail -gt 0) { exit 1 }
Remove-Item -Recurse -Force $work
