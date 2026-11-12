# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\run.ps1 [-Checker <path>]
# PowerShell twin of tests/run.sh. Runs every example under
# tests\cases\{ok,english,english-lines,bidi} through hooks\stop-check.ps1
# (or the script given with -Checker), each in its own powershell.exe process,
# plus a few special cases. Prints FAIL: <case> for each failure and
# PASS: <n>/<total>. Exit 1 on failure.
#
# The input goes to the child as UTF-8 bytes on a redirected stdin
# (System.Diagnostics.Process), never through the PowerShell pipeline, which
# mangles Hebrew in Windows PowerShell 5.1. Corpus files are read as UTF-8.
# The run.sh cases "closed stdout" and "broken pipe" have no counterpart here.
# This file is ASCII only and written for Windows PowerShell 5.1.
param([string]$Checker = '')

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:Root = Split-Path -Parent $PSScriptRoot
if ($Checker.Length -eq 0) { $Checker = Join-Path $script:Root 'hooks\stop-check.ps1' }
$script:Checker = $Checker
$script:PowerShellExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$script:Utf8 = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false

$script:TAG_EN = '[hebrew-rtl-bidi:english]'
$script:TAG_LINES = '[hebrew-rtl-bidi:english-lines]'
$script:TAG_BIDI = '[hebrew-rtl-bidi:bidi]'
$script:total = 0
$script:passed = 0

# A JSON string literal. Only quote, backslash and control characters are
# escaped, so Hebrew stays as it is and reaches the checker as UTF-8 bytes.
function ConvertTo-JsonString {
    param([string]$Text)
    $sb = New-Object -TypeName System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int]$ch
        if ($code -eq 34) { [void]$sb.Append('\"') }
        elseif ($code -eq 92) { [void]$sb.Append('\\') }
        elseif ($code -eq 10) { [void]$sb.Append('\n') }
        elseif ($code -eq 13) { [void]$sb.Append('\r') }
        elseif ($code -eq 9) { [void]$sb.Append('\t') }
        elseif ($code -lt 32) { [void]$sb.Append('\u' + $code.ToString('x4')) }
        else { [void]$sb.Append($ch) }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

# The Stop event for a message, as UTF-8 bytes (no byte order mark).
function New-EventBytes {
    param([string]$Message, [bool]$Active)
    $flag = 'false'
    if ($Active) { $flag = 'true' }
    $json = '{"hook_event_name":"Stop","stop_hook_active":' + $flag + ',"last_assistant_message":' + (ConvertTo-JsonString $Message) + '}'
    $bytes = $script:Utf8.GetBytes($json)
    return ,$bytes
}

function Read-CaseFile {
    param([string]$Path)
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

# Runs the checker in a new powershell.exe with the bytes on stdin. Returns an
# object with Code, Out, Err and Seconds (wall time, including PowerShell start).
function Invoke-Checker {
    param([byte[]]$InputBytes)
    $psi = New-Object -TypeName System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:PowerShellExe
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $script:Checker + '"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = [System.Diagnostics.Process]::Start($psi)
    # Read the output asynchronously so that a full pipe cannot block the child.
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    try {
        $stdin = $proc.StandardInput.BaseStream
        if ($InputBytes.Length -gt 0) { $stdin.Write($InputBytes, 0, $InputBytes.Length) }
        $stdin.Flush()
        $proc.StandardInput.Close()
    } catch {
        # The child may exit without reading all of its input; the verdict
        # then comes from its exit code and output.
    }
    try { $proc.StandardInput.Close() } catch { }
    $code = -1
    if ($proc.WaitForExit(60000)) {
        $code = $proc.ExitCode
    } else {
        try { $proc.Kill() } catch { }
    }
    $sw.Stop()
    $out = $outTask.Result
    $err = $errTask.Result
    $proc.Dispose()
    return (New-Object -TypeName PSObject -Property @{ Code = $code; Out = $out; Err = $err; Seconds = $sw.Elapsed.TotalSeconds })
}

# Judges a run: exit code 0, nothing on stderr, and the expected stdout.
# $Want is silent, english, english-lines or bidi. The tag is looked up in the
# raw output (an ordinal, case-sensitive search).
function Test-Verdict {
    param([string]$Name, [string]$Want, $Run)
    $script:total = $script:total + 1
    $ok = $true
    if ($Run.Code -ne 0) { $ok = $false }
    if ($Run.Err.Length -gt 0) { $ok = $false }
    $hasEn = $Run.Out.Contains($script:TAG_EN)
    $hasLines = $Run.Out.Contains($script:TAG_LINES)
    $hasBidi = $Run.Out.Contains($script:TAG_BIDI)
    if ($Want -ceq 'silent') {
        if ($Run.Out.Length -gt 0) { $ok = $false }
    } elseif ($Want -ceq 'english') {
        if (-not ($hasEn -and (-not $hasLines) -and (-not $hasBidi))) { $ok = $false }
    } elseif ($Want -ceq 'english-lines') {
        if (-not ($hasLines -and (-not $hasEn) -and (-not $hasBidi))) { $ok = $false }
    } elseif ($Want -ceq 'bidi') {
        if (-not ($hasBidi -and (-not $hasEn) -and (-not $hasLines))) { $ok = $false }
    } else {
        $ok = $false
    }
    if ($ok) {
        $script:passed = $script:passed + 1
    } else {
        [Console]::Out.WriteLine('FAIL: ' + $Name)
    }
}

# Records one pass or one failure for a check that is not a plain verdict.
function Add-Result {
    param([string]$Name, [bool]$Ok)
    $script:total = $script:total + 1
    if ($Ok) {
        $script:passed = $script:passed + 1
    } else {
        [Console]::Out.WriteLine('FAIL: ' + $Name)
    }
}

try {
    if (-not (Test-Path -LiteralPath $script:Checker)) {
        [Console]::Out.WriteLine('FAIL: checker not found: ' + $script:Checker)
        exit 1
    }

    foreach ($kind in @('ok', 'english', 'english-lines', 'bidi')) {
        $want = $kind
        if ($kind -ceq 'ok') { $want = 'silent' }
        $dir = Join-Path $script:Root ('tests\cases\' + $kind)
        $files = [System.IO.Directory]::GetFiles($dir, '*.md')
        [Array]::Sort($files)
        foreach ($file in $files) {
            $message = Read-CaseFile $file
            $run = Invoke-Checker (New-EventBytes $message $false)
            Test-Verdict ($kind + '/' + [System.IO.Path]::GetFileName($file)) $want $run
        }
    }

    # Special case: stop_hook_active is true, so nothing is checked.
    $message = Read-CaseFile (Join-Path $script:Root 'tests\cases\english\full-answer.md')
    $run = Invoke-Checker (New-EventBytes $message $true)
    Test-Verdict 'special/stop-hook-active' 'silent' $run

    # Special case: input that is not JSON.
    $run = Invoke-Checker ($script:Utf8.GetBytes('not json'))
    Test-Verdict 'special/not-json' 'silent' $run

    # Special case: empty input.
    $emptyBytes = $script:Utf8.GetBytes('')
    $run = Invoke-Checker $emptyBytes
    Test-Verdict 'special/empty-input' 'silent' $run

    # Special case: JSON without last_assistant_message.
    $run = Invoke-Checker ($script:Utf8.GetBytes('{"hook_event_name":"Stop","stop_hook_active":false}'))
    Test-Verdict 'special/missing-field' 'silent' $run

    # Special case: last_assistant_message is not a string.
    $run = Invoke-Checker ($script:Utf8.GetBytes('{"hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":123}'))
    Test-Verdict 'special/non-string-message' 'silent' $run

    # Special case: a UTF-8 byte order mark before the JSON is ignored.
    $bom = [byte[]]@(239, 187, 191)
    $body = $script:Utf8.GetBytes('{"hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"OK"}')
    $withBom = New-Object -TypeName 'System.Byte[]' -ArgumentList ($bom.Length + $body.Length)
    [Array]::Copy($bom, 0, $withBom, 0, $bom.Length)
    [Array]::Copy($body, 0, $withBom, $bom.Length, $body.Length)
    $run = Invoke-Checker $withBom
    Test-Verdict 'special/utf8-bom' 'english' $run

    # Special case: at most three offending lines are quoted. Each quote is a
    # "\n- " in the JSON text of the correction.
    $message = Read-CaseFile (Join-Path $script:Root 'tests\cases\bidi\many-lines.md')
    $run = Invoke-Checker (New-EventBytes $message $false)
    $quoted = [regex]::Matches($run.Out, '\\n- ').Count
    Add-Result 'special/quote-limit' (($quoted -eq 3) -and ($run.Code -eq 0) -and ($run.Err.Length -eq 0))

    # Special case: a valid Hebrew message of at least 200,000 characters must
    # be accepted without output, in under two seconds (wall time of the whole
    # powershell.exe run, startup included).
    $unit = Read-CaseFile (Join-Path $script:Root 'tests\cases\ok\change-summary.md')
    $big = New-Object -TypeName System.Text.StringBuilder
    while ($big.Length -lt 200000) { [void]$big.Append($unit) }
    $run = Invoke-Checker (New-EventBytes $big.ToString() $false)
    Test-Verdict 'special/big-hebrew-message' 'silent' $run
    Add-Result 'special/big-hebrew-message-under-2s' ($run.Seconds -lt 2)
} catch {
    [Console]::Out.WriteLine('ERROR: ' + $_.Exception.Message)
    exit 1
}

[Console]::Out.WriteLine('PASS: ' + $script:passed + '/' + $script:total)
if ($script:passed -ne $script:total) { exit 1 }
exit 0
