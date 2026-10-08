# Заглушка abaqus для проверки Windows-скриптов без Abaqus (аналог tests/fake_abaqus.sh).
# Подключается через config.env: ABAQUS_CMD=<полный путь>\tests\fake_abaqus.ps1
# Переменные: FAKE_SECONDS (длительность, по умолчанию 3), FAKE_FAIL (regex имён задач с ошибкой).
$opt = @{}
foreach ($a in $args) {
    $s = [string]$a
    if ($s.Contains('=')) { $k, $v = $s.Split('=', 2); $opt[$k] = $v } else { $opt[$s] = '1' }
}

if ($args.Count -ge 2 -and $args[0] -eq 'python') {
    $odb = [string]$args[2]
    if (-not (Test-Path $odb)) { [Console]::Error.WriteLine("odb not found: $odb"); exit 1 }
    $job = [System.IO.Path]::GetFileNameWithoutExtension($odb)
    $lines = @('time,U3,RF3')
    for ($i = 0; $i -le 50; $i++) {
        $t = $i / 50; $u = 5 * $t
        if ($t -lt 0.6) { $f = 2.5e9 * $t / 0.6 } else { $f = 2.5e9 * (1 - ($t - 0.6) / 0.3) }
        if ($f -lt 0) { $f = -1e6 }
        $lines += [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.0000},{1:G6},{2:G6}', $t, $u, $f)
    }
    [System.IO.File]::WriteAllLines((Join-Path (Get-Location) "${job}_history.csv"), $lines)
    Write-Output "${job}_history.csv: 51 points (fake)"
    exit 0
}
if ($opt.ContainsKey('terminate')) { Write-Output "fake abaqus terminate job=$($opt['job'])"; exit 0 }
if ($opt.ContainsKey('information')) { Write-Output 'Abaqus 2022 (FAKE, PowerShell)'; exit 0 }

$job = $opt['job']
$inp = "$($opt['input'])"; if (-not $inp.EndsWith('.inp')) { $inp += '.inp' }
if (-not (Test-Path $inp)) { [Console]::Error.WriteLine("Abaqus Error: input file $inp not found"); exit 1 }
if (-not $opt.ContainsKey('interactive')) { [Console]::Error.WriteLine('fake: ожидается interactive'); exit 1 }
if (-not (Test-Path $opt['scratch'])) { [Console]::Error.WriteLine('fake: scratch недоступен'); exit 1 }

$sep = [IO.Path]::DirectorySeparatorChar
$trace = Join-Path $opt['scratch'] 'trace'
$now = { [DateTime]::UtcNow.Subtract([DateTime]'1970-01-01').TotalSeconds.ToString([Globalization.CultureInfo]::InvariantCulture) }
[System.IO.File]::AppendAllText($trace, "start $job $(& $now)`n")
[System.IO.File]::WriteAllText((Join-Path $PWD "$job.log"),
    "Abaqus JOB $job`nAbaqus 2022 (FAKE) cpus=$($opt['cpus']) mp_mode=$($opt['mp_mode']) memory=$($opt['memory'])`n")
$sec = 3; if ($env:FAKE_SECONDS) { $sec = [double]$env:FAKE_SECONDS }
Start-Sleep -Milliseconds ([int]($sec * 1000))
[System.IO.File]::AppendAllText($trace, "end $job $(& $now)`n")

if ($env:FAKE_FAIL -and $job -match $env:FAKE_FAIL) {
    [System.IO.File]::WriteAllText("$PWD$sep$job.msg", "***ERROR: fake failure for $job`n")
    [System.IO.File]::AppendAllText("$PWD$sep$job.log", "Abaqus/Explicit Analysis exited with an error`n")
    exit 1
}
foreach ($ext in 'odb', 'abq', 'pac', 'res', 'sel', 'stt', 'mdl', 'prt') {
    [System.IO.File]::WriteAllBytes("$PWD$sep$job.$ext", (New-Object byte[] 1024))
}
[System.IO.File]::WriteAllText("$PWD$sep$job.sta", "  THE ANALYSIS HAS COMPLETED SUCCESSFULLY`n")
[System.IO.File]::AppendAllText("$PWD$sep$job.log", "Abaqus JOB $job COMPLETED`n")
exit 0
