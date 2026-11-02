# doc-integrity.ps1 - two of the owner's standing hard blocks for Markdown, checked on every attempt
# (docs/planner-tests-experiment.md, "Standing hard blocks", 2026-11-01). Dot-sourced by tests/test-tasks.ps1; guard:
# tests/test-doc-integrity.ps1.
#
# The owner merges small gaps and leaves them to later cleanup runs, but never merges these, whatever a task's own
# tests say:
#   * Nothing lost: every heading a changed Markdown file had at the base is still there, at the same level, with
#     the same text; a Markdown file the base had is not deleted. (real-02, 2026-11-01: an attempt demoted every `##`
#     to `###` and passed the hidden tests, whose `toContain('## Project')` matched `### Project`.)
#   * Nothing wrong: a file path the change ADDS to a Markdown file, in backticks, exists in the repository (as
#     written from the root, or as the name of a file somewhere in it). A stale reference the base already had is
#     not the attempt's doing and does not block.
# Headings and paths inside fenced code blocks are ignored: they are examples, not structure or claims.
#
# Test-DocIntegrity -Worktree <path> -Base <commit>   ->  @{ Status = PASS|FAIL|SKIP; Lost = @(); Wrong = @(); Files = @(); Detail }
# SKIP when the change touches no Markdown file.

function Get-MarkdownLines([string]$Text) {
    # Lines outside fenced code blocks (``` or ~~~).
    $out = New-Object System.Collections.Generic.List[string]
    $fence = $null
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^\s{0,3}(```+|~~~+)') {
            $mark = $Matches[1].Substring(0, 3)
            if (-not $fence) { $fence = $mark } elseif ($mark -eq $fence) { $fence = $null }
            continue
        }
        if (-not $fence) { $out.Add($line) }
    }
    return , $out.ToArray()
}

function Get-MarkdownHeadings([string]$Text) {
    # "## Text" for each ATX heading, closing #s and trailing spaces dropped.
    $h = foreach ($line in (Get-MarkdownLines $Text)) {
        if ($line -match '^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$' -and $Matches[2]) { "$($Matches[1]) $($Matches[2])" }
    }
    return , @($h)
}

function Get-MarkdownPathRefs([string]$Text) {
    # Backticked tokens that look like a file path: a known extension, or a slash with a word on both sides.
    # Not URLs, globs, placeholders, flags or variables.
    $refs = foreach ($line in (Get-MarkdownLines $Text)) {
        foreach ($m in [regex]::Matches($line, '`([^`\s]+)`')) {
            $t = $m.Groups[1].Value.TrimEnd('.', ',', ':', ';', ')')
            if ($t -match '://|[*{}<>$|]|^-|^@|^\.\.\.') { continue }
            if ($t -match '\.(md|ts|js|mjs|cjs|tsx|jsx|json|ya?ml|sh|ps1|py|sql|toml|ini|html|css|txt)$' -or $t -match '^[\w.-]+/[\w./-]*$') { $t }
        }
    }
    return , @($refs | Select-Object -Unique)
}

function Test-DocIntegrity {
    param([Parameter(Mandatory)][string]$Worktree, [Parameter(Mandatory)][string]$Base)
    # git's output decoded as UTF-8, like the file read below: otherwise a heading with an em dash reads back
    # differently from the base and counts as lost.
    $prevEnc = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    try { return Test-DocIntegrityCore -Worktree $Worktree -Base $Base } finally { [Console]::OutputEncoding = $prevEnc }
}

function Test-DocIntegrityCore {
    param([string]$Worktree, [string]$Base)
    $status = @(& git -C $Worktree status --porcelain -uall 2>$null)
    $md = @()
    foreach ($line in $status) {
        if ($line.Length -lt 4) { continue }
        $p = $line.Substring(3).Trim().Trim('"')
        if ($p -match ' -> ') { $p = ($p -split ' -> ')[-1] }
        $p = $p -replace '\\', '/'
        if ($p -match '\.(md|markdown)$') { $md += [pscustomobject]@{ Path = $p; Code = $line.Substring(0, 2) } }
    }
    if (-not $md.Count) { return [pscustomobject]@{ Status = "SKIP"; Lost = @(); Wrong = @(); Files = @(); Detail = "no Markdown file changed" } }

    $tracked = @(& git -C $Worktree ls-files --cached --others --exclude-standard 2>$null | ForEach-Object { $_ -replace '\\', '/' })
    $names = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $dirs = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($f in $tracked) {
        [void]$names.Add(($f -split '/')[-1])
        $parts = $f -split '/'
        for ($i = 1; $i -lt $parts.Count; $i++) { [void]$dirs.Add(($parts[0..($i - 1)] -join '/')) }
    }
    $trackedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([string[]]$tracked, [StringComparer]::Ordinal)

    $lost = @(); $wrong = @()
    foreach ($f in $md) {
        $old = (& git -C $Worktree show "${Base}:$($f.Path)" 2>$null) -join "`n"
        $inBase = ($LASTEXITCODE -eq 0)
        $full = Join-Path $Worktree $f.Path
        if (-not (Test-Path -LiteralPath $full)) {
            if ($inBase) { $lost += "$($f.Path): the file was deleted" }
            continue
        }
        $new = [System.IO.File]::ReadAllText($full)
        if ($inBase) {
            $now = Get-MarkdownHeadings $new
            foreach ($h in (Get-MarkdownHeadings $old)) {
                if ($now -cnotcontains $h) { $lost += "$($f.Path): heading '$h' is gone" }
            }
        }
        $before = if ($inBase) { Get-MarkdownPathRefs $old } else { @() }
        foreach ($r in (Get-MarkdownPathRefs $new)) {
            if ($before -ccontains $r) { continue }
            $clean = $r.TrimStart('.', '/').TrimEnd('/')
            if ($trackedSet.Contains($clean) -or $dirs.Contains($clean) -or ($clean -notmatch '/' -and $names.Contains($clean))) { continue }
            $wrong += "$($f.Path): names ``$r``, which is not in the repository"
        }
    }
    $ok = -not $lost.Count -and -not $wrong.Count
    $detail = if ($ok) { "{0} Markdown file(s): nothing lost, every added path exists" -f $md.Count } else { (@($lost) + @($wrong)) -join "; " }
    return [pscustomobject]@{ Status = $(if ($ok) { "PASS" } else { "FAIL" }); Lost = @($lost); Wrong = @($wrong); Files = @($md.Path); Detail = $detail }
}
