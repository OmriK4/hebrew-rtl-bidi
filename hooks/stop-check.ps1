# Stop hook (PowerShell twin of stop-check.pl) for Windows without Git Bash.
# Reads the Stop event JSON on stdin. Prints nothing when the last assistant
# message is fine, or one ASCII JSON line asking Claude to fix it. Always
# exits 0 and never writes to stderr. Run as: powershell -File stop-check.ps1
#
# Verdicts, first match wins (same as stop-check.pl):
#   english        the message has no Hebrew word and has an English word.
#   english-lines  a line (or table cell) has no Hebrew word, 4+ English words,
#                  and at least 2 of them start with a lowercase letter.
#   bidi           a line contains Hebrew but its first letter is Latin.
#
# Written for Windows PowerShell 5.1: no && or ||, no ?? or ternary, no
# -AsHashtable. This file is ASCII only: Hebrew letters are written as the
# regex escape \u05D0-\u05EA. Regex work goes through [regex] objects because
# the -match, -replace and -split operators are case-insensitive.
# Stdin is read as bytes and decoded as UTF-8 (the pipeline would mangle Hebrew).

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Escapes a string as a JSON string literal, ASCII only: every character above
# 0x7E (and every control character) becomes \uXXXX or a short escape.
function ConvertTo-JsonAscii {
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
        elseif ($code -eq 8) { [void]$sb.Append('\b') }
        elseif ($code -eq 12) { [void]$sb.Append('\f') }
        elseif ($code -lt 32 -or $code -gt 126) { [void]$sb.Append('\u' + $code.ToString('x4')) }
        else { [void]$sb.Append($ch) }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

# Perl truthiness of a decoded JSON value, for stop_hook_active: null, false,
# 0, "" and "0" are false; everything else (including arrays and objects) is true.
function Test-Truthy {
    param($Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return $Value }
    if ($Value -is [string]) { return ($Value.Length -gt 0 -and $Value -cne '0') }
    if ($Value -is [System.ValueType]) { return ([double]$Value -ne 0) }
    return $true
}

# Cuts a string to at most $Max characters, counting a surrogate pair as one
# character (Perl counts code points, .NET counts UTF-16 units).
function Limit-Chars {
    param([string]$Text, [int]$Max)
    $count = 0
    $i = 0
    $n = $Text.Length
    while ($i -lt $n) {
        if ($count -eq $Max) { return $Text.Substring(0, $i) }
        if (([char]::IsHighSurrogate($Text[$i])) -and (($i + 1) -lt $n) -and ([char]::IsLowSurrogate($Text[$i + 1]))) {
            $i = $i + 2
        } else {
            $i = $i + 1
        }
        $count = $count + 1
    }
    return $Text
}

# make_quote (stop-check.pl 67-74): a unit as a one-line quote, no leading list
# or blockquote marker, at most MAX_QUOTE_LEN characters.
function Get-Quote {
    param([string]$Unit)
    $q = $Unit.Replace($script:CTRL1, '|')
    $q = $script:RE_CONTAINER_LEAD.Replace($q, '')
    $q = $script:RE_TRAILING_WS.Replace($q, '')
    return (Limit-Chars $q $script:MAX_QUOTE_LEN)
}

# mask_pipes_in_code (stop-check.pl 77-81): hides "|" inside `code` so that it
# does not split a table cell.
function Hide-CodePipes {
    param([string]$Row)
    $m = $script:RE_CODE_SPAN.Match($Row)
    if (-not $m.Success) { return $Row }
    $sb = New-Object -TypeName System.Text.StringBuilder
    $pos = 0
    while ($m.Success) {
        [void]$sb.Append($Row, $pos, $m.Index - $pos)
        [void]$sb.Append($m.Value.Replace('|', $script:CTRL1))
        $pos = $m.Index + $m.Length
        $m = $m.NextMatch()
    }
    [void]$sb.Append($Row, $pos, $Row.Length - $pos)
    return $sb.ToString()
}

# s/!?\[([^\]]*)\](...)/link_title($1)/ge (stop-check.pl 85-88 and 99): a
# Markdown link or image is dropped, except that a title with Hebrew is kept.
function Remove-Links {
    param([string]$Text)
    $m = $script:RE_LINK.Match($Text)
    if (-not $m.Success) { return $Text }
    $sb = New-Object -TypeName System.Text.StringBuilder
    $pos = 0
    while ($m.Success) {
        [void]$sb.Append($Text, $pos, $m.Index - $pos)
        $title = $m.Groups[1].Value
        if ($script:RE_HEBREW.IsMatch($title)) { [void]$sb.Append($title) }
        $pos = $m.Index + $m.Length
        $m = $m.NextMatch()
    }
    [void]$sb.Append($Text, $pos, $Text.Length - $pos)
    return $sb.ToString()
}

# "- quote" lines between a head and a tail, joined with newlines.
function Join-Correction {
    param([string]$Head, $Quotes, [string]$Tail)
    $parts = New-Object -TypeName 'System.Collections.Generic.List[string]'
    [void]$parts.Add($Head)
    foreach ($quote in $Quotes) { [void]$parts.Add('- ' + $quote) }
    [void]$parts.Add($Tail)
    return [string]::Join("`n", $parts.ToArray())
}

# check_message (stop-check.pl 115-166). Returns the correction text, or $null
# when the message is fine. count_tokens and is_bidi_problem are written in
# place inside the loop (the loop is the hot path; PowerShell function calls
# are slow). Two simplifications that do not change any verdict:
#   - the Perl counts Hebrew tokens but only ever compares the count with 0,
#     so here it is a yes/no flag ($hebrewSeen, and the Hebrew test per unit);
#   - English words are counted only for units with no Hebrew, because the
#     word count is only used for such units (verdicts 1 and 2 need h == 0).
function Get-Correction {
    param([string]$Message)

    $hebrewSeen = $false
    $wordTotal = 0
    $englishLines = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $bad = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $fenceChar = ''
    $fenceLen = 0
    $hasCR = ($Message.IndexOf([char]13) -ge 0)

    foreach ($rawLine in $Message.Split($script:SEP_LF)) {
        $line = $rawLine
        if ($hasCR -and $line.Length -gt 0 -and $line[$line.Length - 1] -eq [char]13) {
            $line = $line.Substring(0, $line.Length - 1)
        }
        # An empty line changes nothing: it cannot open or close a fence and
        # it has no tokens.
        if ($line.Length -eq 0) { continue }

        # Fenced code blocks are skipped. An unclosed fence runs to the end.
        if ($fenceChar.Length -gt 0) {
            $m = $script:RE_FENCE_CLOSE.Match($line)
            if ($m.Success) {
                $fence = $m.Groups[1].Value
                if (($fence.Substring(0, 1) -ceq $fenceChar) -and ($fence.Length -ge $fenceLen)) {
                    $fenceChar = ''
                }
            }
            continue
        }
        if (($line.IndexOf($script:BACKTICK) -ge 0) -or ($line.IndexOf($script:TILDE) -ge 0)) {
            $m = $script:RE_FENCE_OPEN_TICKS.Match($line)
            if (-not $m.Success) { $m = $script:RE_FENCE_OPEN_TILDES.Match($line) }
            if ($m.Success) {
                $fence = $m.Groups[1].Value
                $fenceChar = $fence.Substring(0, 1)
                $fenceLen = $fence.Length
                continue
            }
        }

        # Units: the whole line, or each cell of a table row.
        $units = $line
        if (($line.IndexOf($script:PIPE) -ge 0) -and $script:RE_TABLE_ROW.IsMatch($line)) {
            $units = (Hide-CodePipes $line).Split($script:SEP_PIPE)
        }
        foreach ($unit in $units) {
            # count_tokens: drop code spans, Markdown links and images, URLs.
            $clean = $unit
            if ($clean.IndexOf($script:BACKTICK) -ge 0) { $clean = $script:RE_CODE_SPAN.Replace($clean, '') }
            if ($clean.IndexOf($script:LBRACKET) -ge 0) { $clean = Remove-Links $clean }
            if ($clean.IndexOf('://', $script:ORD) -ge 0) { $clean = $script:RE_URL.Replace($clean, '') }
            # A Markdown reference definition line is not prose: no tokens.
            if (($unit.IndexOf(']:', $script:ORD) -ge 0) -and $script:RE_REFDEF.IsMatch($unit)) { $clean = '' }
            if ($script:RE_HEBREW.IsMatch($clean)) {
                $hebrewSeen = $true
            } else {
                $wordCount = $script:RE_WORD.Matches($clean).Count
                $wordTotal = $wordTotal + $wordCount
                if (($wordCount -ge 4) -and ($englishLines.Count -lt $script:MAX_QUOTES)) {
                    # At least 2 of the words start with a lowercase letter.
                    if ($script:RE_LOWER_WORD.Matches($clean).Count -ge 2) {
                        [void]$englishLines.Add((Get-Quote $unit))
                    }
                }
            }

            # is_bidi_problem: Hebrew in the unit, first letter Latin. The bidi
            # rule keeps inline code: it does set the line direction.
            if ($bad.Count -lt $script:MAX_QUOTES) {
                $probe = $unit
                if ($probe.IndexOf($script:LBRACKET) -ge 0) { $probe = $script:RE_CHECKBOX.Replace($probe, '$1') }
                if ($script:RE_BIDI.IsMatch($probe)) { [void]$bad.Add((Get-Quote $unit)) }
            }
        }
    }

    if ((-not $hebrewSeen) -and ($wordTotal -ge 1)) { return $script:TEXT_ENGLISH }
    if ($englishLines.Count -gt 0) {
        return (Join-Correction $script:TEXT_ENGLISH_LINES_HEAD $englishLines $script:TEXT_ENGLISH_LINES_TAIL)
    }
    if ($bad.Count -gt 0) {
        return (Join-Correction $script:TEXT_BIDI_HEAD $bad $script:TEXT_BIDI_TAIL)
    }
    return $null
}

# main (stop-check.pl 168-190). Returns early, printing nothing, whenever the
# event is not worth checking; anything unexpected throws and is swallowed by
# the catch at the bottom of the file.
function Invoke-StopCheck {
    $utf8 = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false, $true
    $stdin = [Console]::OpenStandardInput()
    $ms = New-Object -TypeName System.IO.MemoryStream
    $stdin.CopyTo($ms)
    $bytes = $ms.ToArray()
    if ($bytes.Length -eq 0) { return }

    # Skip a UTF-8 byte order mark. Invalid UTF-8 throws (as JSON::PP does).
    $start = 0
    if (($bytes.Length -ge 3) -and ($bytes[0] -eq 239) -and ($bytes[1] -eq 187) -and ($bytes[2] -eq 191)) { $start = 3 }
    $text = $utf8.GetString($bytes, $start, $bytes.Length - $start)

    # Only a JSON object is an event; ConvertFrom-Json would also unroll arrays.
    if (-not $text.TrimStart().StartsWith('{', [System.StringComparison]::Ordinal)) { return }
    $evt = ConvertFrom-Json -InputObject $text
    if (-not ($evt -is [System.Management.Automation.PSCustomObject])) { return }

    $active = $null
    $msg = $null
    foreach ($prop in $evt.PSObject.Properties) {
        if ($prop.Name -ceq 'stop_hook_active') { $active = $prop.Value }
        elseif ($prop.Name -ceq 'last_assistant_message') { $msg = $prop.Value }
    }
    if (Test-Truthy $active) { return }
    if (-not ($msg -is [string])) { return }
    if ($msg.Length -eq 0) { return }

    $correction = Get-Correction $msg
    if ($null -eq $correction) { return }

    $json = '{"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":' + (ConvertTo-JsonAscii $correction) + '}}'
    [Console]::Out.Write($json + "`n")
    [Console]::Out.Flush()
}

try {
    $script:MAX_QUOTES = 3       # at most this many offending units are quoted
    $script:MAX_QUOTE_LEN = 80   # each quote is cut to this many characters

    $script:BACKTICK = [char]96
    $script:TILDE = [char]126
    $script:LBRACKET = [char]91
    $script:PIPE = [char]124
    $script:CTRL1 = [string][char]1
    $script:ORD = [System.StringComparison]::Ordinal
    $script:SEP_LF = [char[]]@([char]10)
    $script:SEP_PIPE = [char[]]@([char]124)

    # The correction texts, word for word as in stop-check.pl.
    $script:TEXT_ENGLISH = '[hebrew-rtl-bidi:english] Your last message was written in English, ' +
        'and the user reads Hebrew. Write the same message again in Hebrew, following ' +
        'the Hebrew and mixed-text rules from the start of the session. Output only ' +
        'the rewritten message, with no apology and no explanation of the correction.'
    $script:TEXT_ENGLISH_LINES_HEAD = '[hebrew-rtl-bidi:english-lines] These lines in your last message ' +
        'are in English, and the user reads Hebrew:'
    $script:TEXT_ENGLISH_LINES_TAIL = 'Write only these lines again in Hebrew. Text that has to stay in ' +
        'English, such as a command, a path, an error message or text the user asked for ' +
        'in English, goes inside backticks or a code block. ' +
        'Output only the corrected lines, with no apology and no explanation of the correction.'
    $script:TEXT_BIDI_HEAD = '[hebrew-rtl-bidi:bidi] These lines in your last message contain Hebrew ' +
        'but start with an English word, so the interface lays them out left-to-right ' +
        'and the Hebrew comes out scrambled:'
    $script:TEXT_BIDI_TAIL = 'Write only these lines again, rephrased so that each one opens with a ' +
        'Hebrew word and still reads as natural Hebrew. Usually a Hebrew noun that ' +
        'describes the term goes first, such as the Hebrew word for command, library or ' +
        'file. Do not just attach a Hebrew prefix letter to the English word when that ' +
        'makes the sentence ungrammatical. ' +
        'Output only the corrected lines, with no apology and no explanation of the correction.'

    # Regexes. $heb is the Hebrew letter range. $container is what may come
    # before a fence or a quoted line: spaces, blockquote markers (">") and
    # list markers ("-", "*", "+", "1.", "1)") followed by a space.
    $heb = '\u05D0-\u05EA'
    $container = '(?:\s|>|(?:[-*+]|\d+[.)])\s)*'
    $script:RE_CONTAINER_LEAD = New-Object -TypeName System.Text.RegularExpressions.Regex -ArgumentList ('^' + $container)
    $script:RE_FENCE_CLOSE = New-Object -TypeName System.Text.RegularExpressions.Regex -ArgumentList ('^' + $container + '(`{3,}|~{3,})\s*\z')
    $script:RE_FENCE_OPEN_TICKS = New-Object -TypeName System.Text.RegularExpressions.Regex -ArgumentList ('^' + $container + '(`{3,})[^`]*\z')
    $script:RE_FENCE_OPEN_TILDES = New-Object -TypeName System.Text.RegularExpressions.Regex -ArgumentList ('^' + $container + '(~{3,})')
    $script:RE_TABLE_ROW = New-Object -TypeName System.Text.RegularExpressions.Regex -ArgumentList '^\s*\|'
    # An inline code span: a run of N backticks, up to the next run of exactly N.
    $script:RE_CODE_SPAN = New-Object -TypeName System.Text.RegularExpressions.Regex -ArgumentList '((?<!`)(`+)(?!`).*?(?<!`)\2(?!`))'
    $script:RE_LINK = New-Object -TypeName System.Text.RegularExpressions.Regex -ArgumentList '!?\[([^\]]*)\](?:\([^)]*\)|\[[^\]]*\])'
    $script:RE_URL = New-Object -TypeName System.Text.RegularExpressions.Regex -ArgumentList 'https?://\S+'
    $script:RE_CHECKBOX = New-Object -TypeName System.Text.RegularExpressions.Regex -ArgumentList '^((?:\s*>)*\s*(?:(?:[-*+]|\d+[.)])\s+)?)\[[ xX]\]'
    $script:RE_HEBREW = New-Object -TypeName System.Text.RegularExpressions.Regex -ArgumentList ('[' + $heb + ']')
    $script:RE_TRAILING_WS = New-Object -TypeName System.Text.RegularExpressions.Regex -ArgumentList '\s+\z'
    # An English word: a whitespace-delimited token that, without the characters
    # that are not letters or digits at both ends, is 2+ ASCII letters (inner
    # apostrophe and hyphen allowed). \x27 is the apostrophe.
    $script:RE_WORD = New-Object -TypeName System.Text.RegularExpressions.Regex -ArgumentList '(?<!\S)[^A-Za-z0-9\s]*[A-Za-z]{2,}(?:[\x27-][A-Za-z]+)*[^A-Za-z0-9\s]*(?!\S)'
    # A lowercase English word: an English word (as above) that starts with [a-z].
    # Case-sensitive, like every [regex] object created without options.
    $script:RE_LOWER_WORD = New-Object -TypeName System.Text.RegularExpressions.Regex -ArgumentList '(?<!\S)[^A-Za-z0-9\s]*[a-z][A-Za-z]+(?:[\x27-][A-Za-z]+)*[^A-Za-z0-9\s]*(?!\S)'
    # A Markdown reference definition line: [label]: target "title".
    $script:RE_REFDEF = New-Object -TypeName System.Text.RegularExpressions.Regex -ArgumentList '^\s*\[[^\]]+\]:\s'
    # A bidi problem: the first Hebrew-or-Latin letter is Latin and the unit
    # also has Hebrew (necessarily after that letter).
    $script:RE_BIDI = New-Object -TypeName System.Text.RegularExpressions.Regex -ArgumentList ('^[^A-Za-z' + $heb + ']*[A-Za-z](?=.*[' + $heb + '])')

    $null = Invoke-StopCheck
} catch {
}
exit 0
