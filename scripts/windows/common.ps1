# Общие функции для scripts\windows\*.ps1 (Windows PowerShell 5.1 и PowerShell 7).
# Подключается через точку:  . "$PSScriptRoot\common.ps1"

$ErrorActionPreference = 'Stop'
$script:ProjectDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:OnWindows = ($env:OS -eq 'Windows_NT')
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# Одна запись строки целиком — сообщения параллельных задач не склеиваются
function Write-Log([string]$Message, [string]$Tag = 'abq') {
    [Console]::Out.Write(("{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Tag, $Message) + [Environment]::NewLine)
}
# PowerShell 7 раскрашивает ошибки ANSI-кодами — в файлах журналов они не нужны
if ($PSVersionTable.PSVersion.Major -ge 7) { $PSStyle.OutputRendering = 'PlainText' }

# Запись текста без BOM — файлы читают и Python-скрипты, и Linux-версия инфраструктуры
function Set-Text([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, $script:Utf8NoBom)
}
function Add-Text([string]$Path, [string]$Text) {
    [System.IO.File]::AppendAllText($Path, $Text, $script:Utf8NoBom)
}

function Resolve-ProjectPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return [System.IO.Path]::GetFullPath((Join-Path $script:ProjectDir $Path))
}

# Тот же config.env, что и для Linux: строки KEY=VALUE. Переменные окружения
# имеют приоритет:  $env:CPUS = 8; .\scripts\windows\run_job.ps1 ...
function Get-AbqConfig {
    $cfgPath = $env:ABQ_CONFIG
    if (-not $cfgPath) { $cfgPath = Join-Path $script:ProjectDir 'config.env' }
    $file = @{}
    if (Test-Path $cfgPath) {
        foreach ($line in [System.IO.File]::ReadAllLines($cfgPath)) {
            $l = $line.Trim()
            if ($l -eq '' -or $l.StartsWith('#') -or -not $l.Contains('=')) { continue }
            $k, $v = $l.Split('=', 2)
            $file[$k.Trim()] = $v.Trim().Trim('"')
        }
    }
    $defaults = [ordered]@{
        RUNTIME = 'native'; ABAQUS_CMD = 'abaqus'
        INPUT_DIR = '.\inputs'; RESULTS_DIR = '.\results'
        SCRATCH_DIR = (Join-Path ([System.IO.Path]::GetTempPath()) 'abaqus-scratch')
        CPUS = '20'; PARALLEL = ''; MEMORY = ''; MP_MODE = 'threads'; PRECISION = 'single'
        POSTPROCESS = '1'; KEEP_RESTART = '0'; ABAQUSLM_LICENSE_FILE = ''
    }
    $cfg = @{}
    foreach ($k in $defaults.Keys) {
        $envValue = [Environment]::GetEnvironmentVariable($k)
        if ($null -ne $envValue) { $cfg[$k] = $envValue }
        elseif ($file.ContainsKey($k)) { $cfg[$k] = $file[$k] }
        else { $cfg[$k] = $defaults[$k] }
    }
    if ($cfg.RUNTIME -ne 'native') {
        throw "В Windows поддерживается только RUNTIME=native (Abaqus для Windows). Для контейнера используйте WSL2 и scripts/*.sh."
    }
    $cfg.INPUT_DIR = Resolve-ProjectPath $cfg.INPUT_DIR
    $cfg.RESULTS_DIR = Resolve-ProjectPath $cfg.RESULTS_DIR
    $cfg.SCRATCH_DIR = Resolve-ProjectPath $cfg.SCRATCH_DIR
    if ($cfg.ABAQUSLM_LICENSE_FILE) { $env:ABAQUSLM_LICENSE_FILE = $cfg.ABAQUSLM_LICENSE_FILE }
    return $cfg
}

# Путь к текущему интерпретатору PowerShell (powershell.exe или pwsh)
function Get-PsExe { return (Get-Process -Id $PID).Path }

function Format-Arg([string]$a) {
    if ($a -match '[\s"]') { return '"' + $a.Replace('"', '\"') + '"' }
    return $a
}

# Запуск abaqus в каталоге задачи; вывод — в OutFile (stdout) и OutFile.err (stderr).
# Возвращает объект процесса (для ожидания и остановки).
function Start-Abaqus($Cfg, [string]$WorkDir, [string[]]$AbqArgs, [string]$OutFile) {
    $cmd = $Cfg.ABAQUS_CMD
    if ($cmd.EndsWith('.ps1')) {
        # заглушка для тестов (tests\fake_abaqus.ps1)
        $exe = Get-PsExe
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $cmd) + $AbqArgs
    } elseif ($script:OnWindows) {
        # abaqus — это abaqus.bat (C:\SIMULIA\Commands), запускается через cmd.exe
        $exe = $env:ComSpec
        $argList = @('/c', $cmd) + $AbqArgs
    } else {
        $exe = $cmd
        $argList = $AbqArgs
    }
    $argString = ($argList | ForEach-Object { Format-Arg $_ }) -join ' '
    $p = Start-Process -FilePath $exe -ArgumentList $argString -WorkingDirectory $WorkDir `
        -NoNewWindow -PassThru -RedirectStandardOutput $OutFile -RedirectStandardError "$OutFile.err"
    $null = $p.Handle   # без этого ExitCode после завершения бывает пустым
    return $p
}

# Остановка процесса вместе со всеми дочерними (решатель, MPI и т. п.)
function Stop-Tree([int]$ProcessId) {
    if ($script:OnWindows) {
        & taskkill.exe /PID $ProcessId /T /F 2>$null | Out-Null
    } else {
        & pkill -TERM -P $ProcessId 2>$null
        Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
    }
}

# Ключ "естественной" сортировки: Job-2 < Job-10. Без [regex]::Replace со
# scriptblock-делегатом — в PowerShell 7 внутри Sort-Object он роняет процесс.
function Get-NaturalKey([string]$s) {
    $parts = foreach ($p in ($s -split '(\d+)')) { if ($p -match '^\d+$') { $p.PadLeft(12, '0') } else { $p } }
    return ($parts -join '')
}
