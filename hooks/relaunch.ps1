# Opens a new terminal tab that resumes a Claude Code session once the
# current claude.exe has exited.
#
# Run by the session-relaunch mod through $.process.run, so this process is a
# descendant of the claude.exe being replaced. It finds that ancestor, reuses
# its command line minus the resume flags, and hands the new tab a command
# that waits on the old PID before running `claude --resume <id>`, so two
# processes never write the same transcript at once.
#
# Prints one JSON line: { ok, pid, terminal, args } or { ok: false, error }.

param(
    [Parameter(Mandatory = $true)][string]$SessionId,
    [Parameter(Mandatory = $true)][string]$Cwd,
    [int]$WaitSeconds = 120,
    # Print what would be launched, open nothing.
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Find-ClaudeAncestor {
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$PID"

    for ($depth = 0; $depth -lt 8 -and $proc; $depth++) {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.ParentProcessId)"

        if ($proc -and $proc.Name -ieq 'claude.exe') {
            return $proc
        }
    }

    return $null
}

# Flags that pick which session to open. They are replaced by --resume <id>;
# the ones with an optional value also drop that value when it is not a flag.
$DropAlone = @('-c', '--continue', '--fork-session', '-p', '--print')
$DropWithValue = @('-r', '--resume', '--session-id', '--from-pr')

function Get-KeptArgs([string]$commandLine) {
    $tokens = [regex]::Matches($commandLine, '"[^"]*"|\S+') | ForEach-Object { $_.Value.Trim('"') }
    $kept = New-Object System.Collections.Generic.List[string]

    # Token 0 is the executable itself.
    for ($i = 1; $i -lt $tokens.Count; $i++) {
        $token = $tokens[$i]
        $name = $token.Split('=')[0]

        if ($DropAlone -contains $name) {
            continue
        }

        if ($DropWithValue -contains $name) {
            if (-not $token.Contains('=') -and $i + 1 -lt $tokens.Count -and -not $tokens[$i + 1].StartsWith('-')) {
                $i++
            }

            continue
        }

        $kept.Add($token)
    }

    return , $kept
}

function Quote-Ps([string]$text) {
    return "'" + $text.Replace("'", "''") + "'"
}

try {
    $claude = Find-ClaudeAncestor

    if (-not $claude) {
        throw 'could not find the parent claude.exe'
    }

    $kept = Get-KeptArgs $claude.CommandLine
    $argList = @('--resume', $SessionId) + $kept
    $quotedArgs = ($argList | ForEach-Object { Quote-Ps $_ }) -join ' '
    $exe = Quote-Ps $claude.ExecutablePath

    $script = @"
`$host.UI.RawUI.WindowTitle = 'claude relaunch'
`$deadline = (Get-Date).AddSeconds($WaitSeconds)
Write-Host 'Waiting for the old session (PID $($claude.ProcessId)) to exit...'
while ((Get-Process -Id $($claude.ProcessId) -ErrorAction SilentlyContinue) -and (Get-Date) -lt `$deadline) { Start-Sleep -Milliseconds 300 }
if (Get-Process -Id $($claude.ProcessId) -ErrorAction SilentlyContinue) {
    Write-Host 'The old session is still running. Type /exit there, then run:'
    Write-Host '  claude --resume $SessionId'
} else {
    & $exe $quotedArgs
}
"@

    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    $shellArgs = @('-NoLogo', '-NoExit', '-EncodedCommand', $encoded)

    # Start-Process joins ArgumentList with bare spaces, so a path with spaces
    # needs its own quotes, and a trailing backslash would escape the closing one.
    $dir = $Cwd.TrimEnd('\')
    if ($dir.EndsWith(':')) { $dir += '\.' }

    if ($DryRun) {
        $terminal = 'dry-run'
    } elseif ($env:WT_SESSION) {
        # -w 0 is the current Windows Terminal window. The encoded command
        # keeps wt's own `;` parsing away from the script.
        $wtArgs = @('-w', '0', 'new-tab', '-d', "`"$dir`"",'--title', 'claude relaunch', 'powershell.exe') + $shellArgs
        Start-Process -FilePath 'wt.exe' -ArgumentList $wtArgs
        $terminal = 'windows-terminal'
    } else {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $shellArgs -WorkingDirectory $Cwd
        $terminal = 'console'
    }

    $report = [ordered]@{ ok = $true; pid = $claude.ProcessId; terminal = $terminal; args = $argList }
    if ($DryRun) { $report.dir = $dir; $report.script = $script }
    [pscustomobject]$report |
        ConvertTo-Json -Compress
} catch {
    [pscustomobject]@{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
}
