# Расчёт одной задачи Abaqus в Windows (Abaqus для Windows, без контейнера).
#
#   .\scripts\windows\run_job.ps1 inputs\Job-24-12-01-1.inp
#
# Поведение совпадает с scripts/run_job.sh: результаты в RESULTS_DIR\<JOB>\, файлы
# STATUS (RUNNING | DONE | FAILED | INTERRUPTED), job.meta, run.out, <JOB>_history.csv.
# Задача со статусом DONE пропускается ($env:FORCE = '1' — пересчитать).
param([Parameter(Mandatory = $true)][string]$Inp)

. "$PSScriptRoot\common.ps1"
$cfg = Get-AbqConfig

$Inp = (Resolve-Path $Inp).Path
$job = [System.IO.Path]::GetFileNameWithoutExtension($Inp)
$runDir = Join-Path $cfg.RESULTS_DIR $job
$statusFile = Join-Path $runDir 'STATUS'
$meta = Join-Path $runDir 'job.meta'
New-Item -ItemType Directory -Force -Path $runDir, $cfg.SCRATCH_DIR | Out-Null

if ($env:FORCE -ne '1' -and (Test-Path $statusFile) -and ((Get-Content $statusFile -Raw).Trim() -eq 'DONE')) {
    Write-Log 'уже рассчитана, пропуск' $job
    exit 0
}

# --- Блокировка: создание каталога атомарно ----------------------------------
$lock = Join-Path $runDir '.lock'
try {
    New-Item -ItemType Directory -Path $lock -ErrorAction Stop | Out-Null
} catch {
    $owner = ''
    $ownerFile = Join-Path $lock 'owner'
    if (Test-Path $ownerFile) { $owner = (Get-Content $ownerFile -Raw).Trim() }
    $ownerHost, $ownerPid = $owner.Split(':', 2)
    if ($ownerHost -eq [Environment]::MachineName -and -not (Get-Process -Id ([int]$ownerPid) -ErrorAction SilentlyContinue)) {
        Write-Log "снимаю устаревшую блокировку ($owner)" $job
        Remove-Item -Recurse -Force $lock
        New-Item -ItemType Directory -Path $lock | Out-Null
    } else {
        Write-Log "уже выполняется другим процессом ($owner), пропуск" $job
        exit 0
    }
}
Set-Text (Join-Path $lock 'owner') ("{0}:{1}" -f [Environment]::MachineName, $PID)

$proc = $null
$finalStatus = 'INTERRUPTED'
try {
    # --- Подготовка ----------------------------------------------------------
    $localInp = Join-Path $runDir "$job.inp"
    if ($Inp -ne $localInp) { Copy-Item $Inp $localInp -Force }
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $runDir "$job.lck")
    $mem = $cfg.MEMORY; if (-not $mem) { $mem = '90%' }

    $abqArgs = @("job=$job", "input=$job.inp", "cpus=$($cfg.CPUS)", "mp_mode=$($cfg.MP_MODE)",
                 "memory=$mem", "scratch=$($cfg.SCRATCH_DIR)", 'interactive', 'ask_delete=OFF')
    if ($cfg.PRECISION -eq 'double') { $abqArgs += 'double=both' }

    $sha = (Get-FileHash -Algorithm SHA256 $localInp).Hash.ToLower()
    Set-Text $meta (@(
        "job=$job", "host=$([Environment]::MachineName)", 'runtime=native-windows',
        "image=$($cfg.ABAQUS_CMD)", "inp_sha256=$sha",
        "cmd=$($cfg.ABAQUS_CMD) $($abqArgs -join ' ')",
        "start=$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')") -join "`n")
    Add-Text $meta "`n"
    Set-Text $statusFile "RUNNING`n"

    # --- Расчёт --------------------------------------------------------------
    Write-Log "старт: $($abqArgs -join ' ')" $job
    $t0 = Get-Date
    $runOut = Join-Path $runDir 'run.out'
    $proc = Start-Abaqus $cfg $runDir $abqArgs $runOut
    $proc.WaitForExit()
    $rc = $proc.ExitCode
    $proc = $null
    $wall = [int]((Get-Date) - $t0).TotalSeconds
    Add-Text $meta "exit_code=$rc`nwall_seconds=$wall`n"

    # Код возврата не всегда отражает ошибку решателя — проверяем файлы задачи
    $log = Join-Path $runDir "$job.log"
    $sta = Join-Path $runDir "$job.sta"
    $ok = ($rc -eq 0) -and
          (Test-Path $log) -and (Select-String -Path $log -SimpleMatch "Abaqus JOB $job COMPLETED" -Quiet) -and
          (Test-Path $sta) -and (Select-String -Path $sta -SimpleMatch 'THE ANALYSIS HAS COMPLETED SUCCESSFULLY' -Quiet)

    if (-not $ok) {
        Write-Log "ОШИБКА (код $rc, $wall с). Последние строки журнала:" $job
        foreach ($f in @($log, $runOut, "$runOut.err")) {
            if (Test-Path $f) { Get-Content $f -Tail 15 | ForEach-Object { Write-Host "    $_" } }
        }
        foreach ($f in @((Join-Path $runDir "$job.msg"), (Join-Path $runDir "$job.dat"))) {
            if (Test-Path $f) {
                Select-String -Path $f -Pattern '\*\*\*ERROR' -Context 0, 4 | Select-Object -First 5 |
                    ForEach-Object { Write-Host "    $($_.Line)"; $_.Context.PostContext | ForEach-Object { Write-Host "    $_" } }
            }
        }
        $finalStatus = 'FAILED'
        exit 1
    }
    Write-Log "расчёт завершён за $wall с" $job

    # --- После расчёта -------------------------------------------------------
    if ($cfg.KEEP_RESTART -ne '1') {
        foreach ($ext in 'abq', 'pac', 'res', 'sel', 'stt', 'mdl', 'prt') {
            Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $runDir "$job.$ext")
        }
    }
    if ($cfg.POSTPROCESS -eq '1') {
        $script = Join-Path (Join-Path $script:ProjectDir 'abaqus_scripts') 'extract_history.py'
        $pp = Start-Abaqus $cfg $runDir @('python', $script, "$job.odb") (Join-Path $runDir 'postprocess.out')
        $pp.WaitForExit()
        if ($pp.ExitCode -eq 0) { Add-Text $meta "postprocess=ok`n" }
        else {
            Add-Text $meta "postprocess=failed`n"
            Write-Log 'предупреждение: постобработка не удалась, см. postprocess.out (расчёт при этом успешен)' $job
        }
    }
    $finalStatus = 'DONE'
    Write-Log 'готово' $job
}
finally {
    # Выполняется и при Ctrl+C: останавливаем решатель, чтобы он не остался работать
    if ($null -ne $proc -and -not $proc.HasExited) {
        Write-Log 'прерывание: останавливаю расчёт' $job
        try {
            $t = Start-Abaqus $cfg $runDir @('terminate', "job=$job") (Join-Path $runDir 'terminate.out')
            $null = $t.WaitForExit(30000)
        } catch { }
        Stop-Tree $proc.Id
    }
    Set-Text $statusFile "$finalStatus`n"
    Add-Text $meta "status=$finalStatus`nend=$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')`n"
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $lock
}
