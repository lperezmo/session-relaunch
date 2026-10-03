# Opens a new terminal tab that resumes a Claude Code session once the
# current claude process has exited.
#
# Run by the session-relaunch mod through $.process.run, so this process is a
# descendant of the claude being replaced (claude.exe, or node.exe running the
# npm CLI script). It finds that ancestor, reuses its command line minus the
# session-picking flags, and hands the new tab a command that waits on the old
# PID before running `claude --resume <id>`, so two processes never write the
# same transcript at once.
#
# Prints one JSON line: { ok, pid, terminal, exe, args, title } (plus dir and
# script with -DryRun) or { ok: false, error }.

param(
    [Parameter(Mandatory = $true)][string]$SessionId,
    [Parameter(Mandatory = $true)][string]$Cwd,
    # 0 waits for the old session forever.
    [int]$WaitSeconds = 120,
    # Replaces any --model from the original command line.
    [string]$Model = '',
    # Print what would be launched, open nothing.
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# Flags that pick which session to open. They are replaced by --resume <id>;
# the ones with an optional value also drop that value when it is not a flag.
$DropAlone = @('-c', '--continue', '--fork-session', '-p', '--print')
$DropWithValue = @('-r', '--resume', '--session-id', '--from-pr')

# Splits a command line the way the MSVC runtime builds argv, so
# --flag="a b" and "--flag=a b" both come back as the one value --flag=a b.
function Split-CommandLine([string]$line) {
    $parts = New-Object System.Collections.Generic.List[string]
    $sb = New-Object System.Text.StringBuilder
    $inQuotes = $false
    $hasPart = $false
    $i = 0

    while ($i -lt $line.Length) {
        $c = $line[$i]

        if ($c -eq [char]'\') {
            $n = 0
            while ($i -lt $line.Length -and $line[$i] -eq [char]'\') { $n++; $i++ }

            if ($i -lt $line.Length -and $line[$i] -eq [char]'"') {
                [void]$sb.Append([char]'\', [int][Math]::Floor($n / 2))

                # An odd run escapes the quote; an even one leaves it to toggle.
                if ($n % 2 -eq 1) {
                    [void]$sb.Append([char]'"')
                    $i++
                }
            } else {
                [void]$sb.Append([char]'\', $n)
            }

            $hasPart = $true
            continue
        }

        if ($c -eq [char]'"') {
            if ($inQuotes -and $i + 1 -lt $line.Length -and $line[$i + 1] -eq [char]'"') {
                [void]$sb.Append([char]'"')
                $i += 2
            } else {
                $inQuotes = -not $inQuotes
                $i++
            }

            $hasPart = $true
            continue
        }

        if (-not $inQuotes -and ($c -eq [char]' ' -or $c -eq [char]"`t")) {
            if ($hasPart) {
                $parts.Add($sb.ToString())
                [void]$sb.Clear()
                $hasPart = $false
            }

            $i++
            continue
        }

        [void]$sb.Append($c)
        $hasPart = $true
        $i++
    }

    if ($hasPart) { $parts.Add($sb.ToString()) }

    return , $parts
}

# The nearest claude ancestor: claude.exe itself, or a node/bun process whose
# command line runs the claude CLI script. ScriptIndex is the argv position
# the CLI's own flags follow.
function Find-ClaudeAncestor {
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$PID"

    for ($depth = 0; $depth -lt 8 -and $proc; $depth++) {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.ParentProcessId)"

        if (-not $proc -or -not $proc.CommandLine) {
            continue
        }

        if ($proc.Name -ieq 'claude.exe') {
            return [pscustomobject]@{ Process = $proc; Parts = (Split-CommandLine $proc.CommandLine); ScriptIndex = 0 }
        }

        if ($proc.Name -match '^(node|bun)(\.exe)?$') {
            $parts = Split-CommandLine $proc.CommandLine

            for ($j = 1; $j -lt $parts.Count; $j++) {
                if ($parts[$j] -match '(?i)(claude-code[\\/].*\.[cm]?js|[\\/]claude(\.[cm]?js)?)$') {
                    return [pscustomobject]@{ Process = $proc; Parts = $parts; ScriptIndex = $j }
                }
            }
        }
    }

    return $null
}

function Get-KeptArgs($parts, [int]$scriptIndex, [string]$model) {
    $kept = New-Object System.Collections.Generic.List[string]

    for ($i = $scriptIndex + 1; $i -lt $parts.Count; $i++) {
        $part = $parts[$i]
        $name = $part.Split('=')[0]

        if ($DropAlone -ccontains $name) {
            continue
        }

        if ($DropWithValue -ccontains $name) {
            if (-not $part.Contains('=') -and $i + 1 -lt $parts.Count -and -not $parts[$i + 1].StartsWith('-')) {
                $i++
            }

            continue
        }

        if ($model -and $name -ceq '--model') {
            if (-not $part.Contains('=') -and $i + 1 -lt $parts.Count) {
                $i++
            }

            continue
        }

        $kept.Add($part)
    }

    if ($model) {
        $kept.Add('--model')
        $kept.Add($model)
    }

    return , $kept
}

function Quote-Ps([string]$text) {
    return "'" + $text.Replace("'", "''") + "'"
}

# One argv element as the MSVC runtime expects it on a command line.
# Start-Process in Windows PowerShell 5.1 joins -ArgumentList with bare
# spaces and quotes nothing, so callers pass it one string built from these.
function ConvertTo-CrtArg([string]$value) {
    if ($value.Length -gt 0 -and $value -notmatch '[\s"]') {
        return $value
    }

    $escaped = $value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

# PowerShell 5.1 passes a value to a native exe in bare double quotes when it
# has whitespace, without escaping inner quotes or a trailing backslash.
# Escaping those first makes the exe see the original value. Still wrong for
# whitespace that follows an odd number of quotes; 5.1 cannot express that.
function ConvertTo-NativeArg([string]$value) {
    if ($value -eq '') {
        return '""'
    }

    $escaped = $value -replace '(\\*)"', '$1$1\"'

    if ($value -match '\s') {
        $escaped = $escaped -replace '(\\+)$', '$1$1'
    }

    return $escaped
}

# The script the new tab runs: wait for the old PID, then start the command.
# The command is resolved there, so `claude` is whatever PATH holds after an
# auto-update; an exe gets 5.1-escaped values, a .ps1 shim the raw ones.
function New-TabScript([int]$waitPid, [string]$command, [string[]]$arguments, [string]$title, [int]$waitSeconds) {
    $raw = ($arguments | ForEach-Object { Quote-Ps $_ }) -join ', '
    $native = ($arguments | ForEach-Object { Quote-Ps (ConvertTo-NativeArg $_) }) -join ', '
    $manual = Quote-Ps ('  ' + ((@($command) + $arguments | ForEach-Object { ConvertTo-CrtArg $_ }) -join ' '))
    $alive = "Get-Process -Id $waitPid -ErrorAction SilentlyContinue"

    $launch = @"
`$cmd = Get-Command $(Quote-Ps $command) -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not `$cmd) {
    Write-Host $(Quote-Ps "Could not find $command. Run it yourself:")
    Write-Host $manual
} elseif (`$cmd.CommandType -eq 'Application') {
    `$argv = @($native)
    & `$cmd @argv
} else {
    `$argv = @($raw)
    & `$cmd @argv
}
"@

    if ($waitSeconds -le 0) {
        return @"
`$host.UI.RawUI.WindowTitle = $(Quote-Ps $title)
Write-Host 'Waiting for the old session (PID $waitPid) to exit (no time limit)...'
while ($alive) { Start-Sleep -Milliseconds 300 }
$launch
"@
    }

    return @"
`$host.UI.RawUI.WindowTitle = $(Quote-Ps $title)
`$deadline = (Get-Date).AddSeconds($waitSeconds)
Write-Host 'Waiting up to $waitSeconds seconds for the old session (PID $waitPid) to exit...'
while (($alive) -and (Get-Date) -lt `$deadline) { Start-Sleep -Milliseconds 300 }
if ($alive) {
    Write-Host 'The old session is still running. Type /exit there, then run:'
    Write-Host $manual
} else {
$launch
}
"@
}

# Opens the tab (or a console window outside Windows Terminal) running the
# script. Returns the terminal kind.
function Start-Tab([string]$script, [string]$dir, [string]$title, [bool]$keepOpen) {
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    $shell = '-NoLogo'
    if ($keepOpen) { $shell += ' -NoExit' }
    $shell += ' -ExecutionPolicy Bypass -EncodedCommand ' + $encoded

    if ($env:WT_SESSION) {
        # -w 0 is the current Windows Terminal window. wt splits its own
        # arguments on `;` unless escaped as `\;`; the base64 has none.
        $wtDir = ConvertTo-CrtArg $dir.Replace(';', '\;')
        $wtTitle = ConvertTo-CrtArg $title.Replace(';', '\;')
        Start-Process -FilePath 'wt.exe' -ArgumentList "-w 0 new-tab -d $wtDir --title $wtTitle powershell.exe $shell"
        return 'windows-terminal'
    }

    Start-Process -FilePath 'powershell.exe' -ArgumentList $shell -WorkingDirectory $dir
    return 'console'
}

try {
    $ancestor = Find-ClaudeAncestor

    if (-not $ancestor) {
        throw 'could not find the parent claude process'
    }

    $proc = $ancestor.Process
    $kept = Get-KeptArgs $ancestor.Parts $ancestor.ScriptIndex $Model
    $argList = @('--resume', $SessionId) + $kept

    if (Get-Command claude -CommandType Application, ExternalScript -ErrorAction SilentlyContinue) {
        $exe = 'claude'
    } else {
        $exe = $proc.ExecutablePath
        if (-not $exe) { $exe = $ancestor.Parts[0] }

        # node.exe needs the CLI script ahead of the CLI's own flags.
        if ($ancestor.ScriptIndex -gt 0) {
            $argList = @($ancestor.Parts[$ancestor.ScriptIndex]) + $argList
        }
    }

    # A trailing backslash only matters to wt's quoting; a bare drive root
    # needs one, so it gets `\.` instead.
    $dir = $Cwd.TrimEnd('\')
    if ($dir.EndsWith(':')) { $dir += '\.' }

    $leaf = ($Cwd.TrimEnd('\', '/') -split '[\\/]')[-1]
    if (-not $leaf) { $leaf = $Cwd }
    $title = $leaf + ' ' + $SessionId.Substring(0, [Math]::Min(8, $SessionId.Length))

    $script = New-TabScript $proc.ProcessId $exe $argList $title $WaitSeconds

    if ($DryRun) {
        $terminal = 'dry-run'
    } else {
        $terminal = Start-Tab $script $dir $title $true
    }

    $report = [ordered]@{ ok = $true; pid = $proc.ProcessId; terminal = $terminal; exe = $exe; args = $argList; title = $title }
    if ($DryRun) { $report.dir = $dir; $report.script = $script }
    [pscustomobject]$report | ConvertTo-Json -Compress
} catch {
    [pscustomobject]@{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
}
