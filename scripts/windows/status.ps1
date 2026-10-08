# Сводка по задачам в RESULTS_DIR:  .\scripts\windows\status.ps1
. "$PSScriptRoot\common.ps1"
$cfg = Get-AbqConfig

if (-not (Test-Path $cfg.RESULTS_DIR)) { Write-Host "Каталог результатов пуст: $($cfg.RESULTS_DIR)"; exit 0 }

function Get-MetaValue([string]$file, [string]$key) {
    if (-not (Test-Path $file)) { return '-' }
    $line = Select-String -Path $file -Pattern "^$key=" | Select-Object -First 1
    if ($line) { return $line.Line.Split('=', 2)[1] } else { return '-' }
}

$counts = @{ DONE = 0; RUNNING = 0; FAILED = 0; INTERRUPTED = 0 }
'{0,-28} {1,-14} {2,8}  {3}' -f 'JOB', 'STATUS', 'WALL,s', 'HOST' | Write-Host
Get-ChildItem -Path $cfg.RESULTS_DIR -Directory | Sort-Object { Get-NaturalKey $_.Name } | ForEach-Object {
    $d = $_.FullName; $job = $_.Name
    $statusFile = Join-Path $d 'STATUS'; $sta = Join-Path $d "$job.sta"; $metaFile = Join-Path $d 'job.meta'
    $st = '-'
    if (Test-Path $statusFile) { $st = (Get-Content $statusFile -Raw).Trim() }
    if ($counts.ContainsKey($st)) { $counts[$st]++ }
    $shown = $st
    if ($st -eq 'RUNNING' -and (Test-Path $sta)) {
        # последняя строка с номером инкремента: время шага — во втором столбце
        $last = Get-Content $sta | Where-Object { $_ -match '^\s*\d+\s+\S+' } | Select-Object -Last 1
        if ($last) { $shown = "RUNNING t=" + ($last.Trim() -split '\s+')[1] }
    }
    '{0,-28} {1,-14} {2,8}  {3}' -f $job, $shown, (Get-MetaValue $metaFile 'wall_seconds'), (Get-MetaValue $metaFile 'host') | Write-Host
}
Write-Host ''
Write-Host ("DONE: {0}  RUNNING: {1}  FAILED: {2}  INTERRUPTED: {3}" -f $counts.DONE, $counts.RUNNING, $counts.FAILED, $counts.INTERRUPTED)
