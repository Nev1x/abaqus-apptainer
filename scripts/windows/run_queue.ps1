# Очередь расчётов в Windows: все *.inp, не более PARALLEL задач одновременно.
#
#   .\scripts\windows\run_queue.ps1                         # все *.inp из INPUT_DIR
#   .\scripts\windows\run_queue.ps1 inputs                  # каталог
#   .\scripts\windows\run_queue.ps1 inputs\a.inp inputs\b.inp
#
# Повторный запуск продолжает с места остановки (DONE пропускаются).
# Остановить: Ctrl+C — идущие задачи помечаются INTERRUPTED.
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Paths)

. "$PSScriptRoot\common.ps1"
$cfg = Get-AbqConfig
$tag = 'queue'

# --- Список задач --------------------------------------------------------------
if (-not $Paths) { $Paths = @($cfg.INPUT_DIR) }
$files = @()
foreach ($p in $Paths) {
    if (Test-Path $p -PathType Container) { $files += Get-ChildItem -Path $p -Filter '*.inp' -File }
    elseif (Test-Path $p -PathType Leaf) { $files += Get-Item $p }
    else { Write-Log "нет такого файла или каталога: $p" $tag; exit 2 }
}
$files = @($files | Sort-Object { Get-NaturalKey $_.Name })
if ($files.Count -eq 0) { Write-Log 'не найдено ни одного .inp' $tag; exit 2 }

# --- Ресурсы -------------------------------------------------------------------
$cores = [Environment]::ProcessorCount
$cpus = [int]$cfg.CPUS
$parallel = if ($cfg.PARALLEL) { [int]$cfg.PARALLEL } else { [Math]::Max(1, [Math]::Floor($cores / $cpus)) }
$memory = if ($cfg.MEMORY) { $cfg.MEMORY } else { "$([Math]::Floor(90 / $parallel))%" }
$env:PARALLEL = "$parallel"; $env:MEMORY = $memory
$tokens = [Math]::Floor(5 * [Math]::Pow($cpus, 0.422))
if ($parallel * $cpus -gt $cores) {
    Write-Log "ВНИМАНИЕ: PARALLEL*CPUS = $($parallel * $cpus) больше числа ядер ($cores) — расчёты будут мешать друг другу" $tag
}
$doneBefore = @(Get-ChildItem -Path $cfg.RESULTS_DIR -Filter STATUS -Recurse -Depth 1 -ErrorAction SilentlyContinue |
    Where-Object { (Get-Content $_.FullName -Raw).Trim() -eq 'DONE' }).Count
Write-Log ("задач: {0} (уже готово: {1}); одновременно: {2} x {3} ядер (на сервере {4}); память на задачу: {5}; токены: {6} на задачу, {7} всего" -f
    $files.Count, $doneBefore, $parallel, $cpus, $cores, $memory, $tokens, ($tokens * $parallel)) $tag
Write-Log "результаты: $($cfg.RESULTS_DIR)" $tag

# --- Запуск --------------------------------------------------------------------
$psExe = Get-PsExe
$runJob = Join-Path $PSScriptRoot 'run_job.ps1'
$running = New-Object System.Collections.ArrayList
$failed = 0
function Wait-Slot([int]$limit) {
    while ($running.Count -ge $limit) {
        foreach ($p in @($running)) {
            if ($p.HasExited) {
                if ($p.ExitCode -ne 0) { $script:failed++ }
                $running.Remove($p)
            }
        }
        if ($running.Count -ge $limit) { Start-Sleep -Milliseconds 500 }
    }
}
try {
    foreach ($f in $files) {
        Wait-Slot $parallel
        $p = Start-Process -FilePath $psExe -NoNewWindow -PassThru -ArgumentList (
            "-NoProfile -ExecutionPolicy Bypass -File `"$runJob`" `"$($f.FullName)`"")
        $null = $p.Handle
        [void]$running.Add($p)
    }
    Wait-Slot 1
}
finally {
    # Ctrl+C: дочерние run_job.ps1 получают его сами (общая консоль) и завершаются корректно
    foreach ($p in @($running)) { if (-not $p.HasExited) { $null = $p.WaitForExit(60000) } }
}

& "$PSScriptRoot\status.ps1"
if ($failed -gt 0) {
    Write-Log "задач с ошибками: $failed — исправьте причину и запустите очередь повторно" $tag
    exit 1
}
Write-Log 'все задачи выполнены' $tag
