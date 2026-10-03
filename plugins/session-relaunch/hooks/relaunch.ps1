# Opens a new terminal tab that resumes a Claude Code session once the
# current claude process has exited.
#
# Run by the session-relaunch mod through $.process.run, so this process is a
# descendant of the claude being replaced (claude.exe, or node.exe running the
# npm CLI script). It finds that ancestor, reuses its command line minus the
# session-picking flags, and hands the new tab a script that waits on the old
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
# The worktree flags go too: --resume already reopens the session's worktree,
# and sending them again would create another one.
$DropAlone = @('-c', '--continue', '--fork-session', '-p', '--print', '--tmux')
$DropWithValue = @('-r', '--resume', '--session-id', '--from-pr', '-w', '--worktree')

# Per-session variables the old claude set in its own environment. A new tab
# can inherit them, and they would start the new CLI as a child session.
$SessionEnvNames = @(
    'CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_CHILD_SESSION', 'CLAUDE_CODE_SESSION_ID',
    'CLAUDE_PID', 'CLAUDE_EFFORT', 'CLAUDE_CODE_MESSAGING_SOCKET', 'CLAUDE_CODE_MESSAGING_TOKEN',
    'CLAUDE_CODE_BRIDGE_SESSION_ID', 'CLAUDE_CODE_SESSION_ATTENDED', 'CLAUDE_CODE_EXECPATH'
)

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

# A single-quoted PowerShell literal. PowerShell also reads the curly quotes
# U+2018 to U+201B as single quotes, so doubling only ' is not enough; the
# parser's own escaper doubles every one of them.
function Quote-Ps([string]$text) {
    return "'" + [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($text) + "'"
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

# The script the new tab runs: delete its own file, drop the old session's
# variables, enter the folder, wait for the old PID, then start the command.
# The command is resolved there, so `claude` is whatever PATH holds after an
# auto-update. An exe gets one command line built here, because 5.1 splits
# values like {"a":["b c"]} when it passes them to a native exe itself; a
# .ps1 shim gets the raw values.
function New-TabScript([int]$waitPid, [string]$command, [string[]]$arguments, [string]$title, [int]$waitSeconds, [string]$location) {
    $raw = ($arguments | ForEach-Object { Quote-Ps $_ }) -join ', '
    $crt = Quote-Ps (($arguments | ForEach-Object { ConvertTo-CrtArg $_ }) -join ' ')
    $manual = Quote-Ps ('  ' + ((@($command) + $arguments | ForEach-Object { ConvertTo-CrtArg $_ }) -join ' '))
    $envPaths = ($SessionEnvNames | ForEach-Object { 'Env:' + $_ }) -join ', '
    $alive = "Get-Process -Id $waitPid -ErrorAction SilentlyContinue"

    # -LiteralPath, so [ and ] in a folder name are not wildcards. Without the
    # folder the resume would look in the wrong project, so stop instead.
    $prelude = @"
Remove-Item -LiteralPath `$PSCommandPath -Force -ErrorAction SilentlyContinue
Remove-Item $envPaths -ErrorAction SilentlyContinue
`$host.UI.RawUI.WindowTitle = $(Quote-Ps $title)
try {
    Set-Location -LiteralPath $(Quote-Ps $location) -ErrorAction Stop
} catch {
    Write-Host $(Quote-Ps "Could not open the folder $location")
    return
}
"@

    # UseShellExecute off keeps the child in this console; WorkingDirectory
    # is needed because Set-Location does not move the process directory.
    $launch = @"
`$cmd = Get-Command $(Quote-Ps $command) -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not `$cmd) {
    Write-Host $(Quote-Ps "Could not find $command. Run it yourself:")
    Write-Host $manual
} elseif (`$cmd.CommandType -eq 'Application') {
    `$psi = New-Object System.Diagnostics.ProcessStartInfo
    `$psi.FileName = `$cmd.Path
    `$psi.Arguments = $crt
    `$psi.WorkingDirectory = (Get-Location).ProviderPath
    `$psi.UseShellExecute = `$false
    `$child = [System.Diagnostics.Process]::Start(`$psi)
    `$child.WaitForExit()
} else {
    `$argv = @($raw)
    & `$cmd @argv
}
"@

    if ($waitSeconds -le 0) {
        return @"
$prelude
Write-Host 'Waiting for the old session (PID $waitPid) to exit (no time limit)...'
while ($alive) { Start-Sleep -Milliseconds 300 }
$launch
"@
    }

    return @"
$prelude
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

# Saves the tab script to a new file in the user's temp folder, UTF-8 with a
# BOM so Windows PowerShell 5.1 reads non-ASCII folder names correctly. A file
# keeps the tab's command line short, where -EncodedCommand could pass the
# 32767-character limit. The script deletes the file when it starts.
function Write-TabScript([string]$script) {
    $attempt = 0

    while ($true) {
        $tmp = [System.IO.Path]::GetTempFileName()
        $file = [System.IO.Path]::ChangeExtension($tmp, '.ps1')

        try {
            [System.IO.File]::Move($tmp, $file)
            break
        } catch {
            # A leftover .ps1 of the same name; try another.
            [System.IO.File]::Delete($tmp)
            $attempt++
            if ($attempt -ge 5) { throw }
        }
    }

    [System.IO.File]::WriteAllText($file, $script, (New-Object System.Text.UTF8Encoding $true))
    return $file
}

# Opens the tab (or a console window outside Windows Terminal) running the
# script. Returns the terminal kind.
function Start-Tab([string]$script, [string]$dir, [string]$title, [bool]$keepOpen) {
    $file = Write-TabScript $script

    try {
        # Bypass is process scoped and only lets this unsigned local file run.
        $shell = '-NoLogo'
        if ($keepOpen) { $shell += ' -NoExit' }
        $shell += ' -ExecutionPolicy Bypass -File '

        if ($env:WT_SESSION) {
            # -w 0 is the current Windows Terminal window. wt splits its own
            # arguments on `;` unless escaped as `\;`.
            $wtDir = ConvertTo-CrtArg $dir.Replace(';', '\;')
            $wtTitle = ConvertTo-CrtArg $title.Replace(';', '\;')
            $wtFile = ConvertTo-CrtArg $file.Replace(';', '\;')
            Start-Process -FilePath 'wt.exe' -ArgumentList "-w 0 new-tab -d $wtDir --title $wtTitle powershell.exe $shell$wtFile"
            return 'windows-terminal'
        }

        # The script enters the folder itself; -WorkingDirectory would treat
        # [ and ] in it as wildcards and fail.
        Start-Process -FilePath 'powershell.exe' -ArgumentList ($shell + (ConvertTo-CrtArg $file))
        return 'console'
    } catch {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        throw
    }
}

# One compact JSON line with every non-ASCII character as \uXXXX, so the
# console code page cannot mangle folder names on the way to the mod.
function ConvertTo-AsciiJson($value) {
    $json = $value | ConvertTo-Json -Compress
    return [regex]::Replace($json, '[^\x00-\x7F]', { param($m) '\u{0:x4}' -f [int][char]$m.Value })
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

    $script = New-TabScript $proc.ProcessId $exe $argList $title $WaitSeconds $Cwd

    if ($DryRun) {
        $terminal = 'dry-run'
    } else {
        $terminal = Start-Tab $script $dir $title $true
    }

    $report = [ordered]@{ ok = $true; pid = $proc.ProcessId; terminal = $terminal; exe = $exe; args = $argList; title = $title }
    if ($DryRun) { $report.dir = $dir; $report.script = $script }
    ConvertTo-AsciiJson ([pscustomobject]$report)
} catch {
    ConvertTo-AsciiJson ([pscustomobject]@{ ok = $false; error = $_.Exception.Message })
}
