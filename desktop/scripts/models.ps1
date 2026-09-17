# models.ps1 — Install models into the desktop Ollama (ROCm) from the catalog
#
# Usage (PowerShell):
#   .\desktop\scripts\models.ps1 -List                 # show catalog
#   .\desktop\scripts\models.ps1 -List -Group coder    # one group
#   .\desktop\scripts\models.ps1 -Info qwen2.5-coder:7b
#   .\desktop\scripts\models.ps1 -Pull qwen2.5-coder:7b,glm4:9b
#   .\desktop\scripts\models.ps1 -Group reasoner
#   .\desktop\scripts\models.ps1 -All
#   .\desktop\scripts\models.ps1 -Profile              # use DEV_DESKTOP_MODELS from the active profile
#
# Options:
#   -Context N   after pulling, also create a derived <tag>-Nk model with num_ctx baked
#                (the same reliable pattern startup.ps1 uses for deepseek-r1-16k).
#   -DryRun      show what would be pulled without doing it

param(
    [switch]$List,
    [string]$Group = "",
    [string]$Info = "",
    [string[]]$Pull = @(),
    [switch]$All,
    [switch]$Profile,
    [int]$Context = 0,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)
$catalogPath = Join-Path $repoRoot "models\catalog.tsv"

if (-not (Test-Path -LiteralPath $catalogPath)) {
    Write-Host "[models] ERROR: catalog not found at $catalogPath" -ForegroundColor Red
    exit 1
}

$rows = Import-Csv -LiteralPath $catalogPath -Delimiter "`t"

if ($List) {
    if ($Group -ne "") {
        $rows = $rows | Where-Object { ($_.groups -split ",") -contains $Group }
    }
    "{0,-24} {1,-8} {2,-10} {3,-7} {4,-24} {5}" -f "TAG", "SIZE", "CLASS", "CTX", "GROUPS", "DESC"
    "".PadRight(96, "-")
    $rows | ForEach-Object {
        "{0,-24} {1,-8} {2,-10} {3,-7} {4,-24} {5}" -f $_.tag, ($_.size_gb + "G"), $_.class, ($_.ctx + "k"), $_.groups, $_.desc
    }
    exit 0
}

if ($Info -ne "") {
    $row = $rows | Where-Object { $_.tag -eq $Info }
    if (-not $row) {
        Write-Host "[models] no catalog entry for '$Info'" -ForegroundColor Red
        exit 1
    }
    $row | Format-List | Out-String | Write-Host
    exit 0
}

# Determine targets
$targets = [System.Collections.Generic.List[string]]::new()

if ($Profile) {
    if ([string]::IsNullOrWhiteSpace($env:DEV_DESKTOP_MODELS)) {
        Write-Host "[models] DEV_DESKTOP_MODELS not set. Source a profile first (e.g. source profiles/dev-local-only.sh)" -ForegroundColor Red
        exit 1
    }
    $env:DEV_DESKTOP_MODELS -split ' ' | Where-Object { $_ } | ForEach-Object { $targets.Add($_) }
}

if ($All) { $targets.Add("all") }
if ($Pull.Count -gt 0) { $Pull | ForEach-Object { $targets.Add($_) } }
if ($Group -ne "") { $targets.Add($Group) }

if ($targets.Count -eq 0) {
    Write-Host "[models] nothing to do. Use -List, -Pull <tags>, -Group <group>, -All, or -Profile." -ForegroundColor Yellow
    exit 0
}

# Expand tags/groups
$tags = [System.Collections.Generic.List[string]]::new()
foreach ($target in $targets) {
    if ($target -eq "all") {
        $rows | ForEach-Object { $tags.Add($_.tag) }
    }
    elseif ($row = $rows | Where-Object { $_.tag -eq $target }) {
        $tags.Add($target)
    }
    else {
        $groupRows = $rows | Where-Object { ($_.groups -split ",") -contains $target }
        if ($groupRows) {
            $groupRows | ForEach-Object { $tags.Add($_.tag) }
        }
        else {
            Write-Host "[models] '$target' is not a catalog tag or group." -ForegroundColor Yellow
        }
    }
}

# Check ollama
if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
    Write-Host "[models] ERROR: ollama not found in PATH. Install from https://ollama.com/download" -ForegroundColor Red
    exit 1
}

foreach ($tag in ($tags | Select-Object -Unique)) {
    $row = $rows | Where-Object { $_.tag -eq $tag }
    $size = if ($row) { $row.size_gb } else { "?" }
    $class = if ($row) { $row.class } else { "?" }

    Write-Host ""
    Write-Host "[models] Pulling $tag  (${size}G weights, class=$class)" -ForegroundColor Cyan

    if ($DryRun) {
        Write-Host "[models] (dry-run) ollama pull $tag"
    }
    else {
        & ollama pull $tag
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[models] pull failed for $tag" -ForegroundColor Red
            continue
        }
    }

    if ($Context -gt 0) {
        $derived = "$tag-$($Context)k"
        Write-Host "[models] Creating derived model $derived (num_ctx $Context)..." -ForegroundColor Cyan
        if ($DryRun) {
            Write-Host "[models] (dry-run) ollama create $derived -f Modelfile(num_ctx $Context)"
        }
        else {
            $mf = Join-Path $env:TEMP "Modelfile-$($derived -replace '[:]', '-')"
            Set-Content -LiteralPath $mf -Value "FROM $tag`nPARAMETER num_ctx $Context" -Encoding ascii
            & ollama create $derived -f $mf | Out-Null
            Remove-Item -LiteralPath $mf -Force
        }
    }
}

Write-Host ""
Write-Host "[models] Done. Verify with: .\desktop\scripts\status.ps1" -ForegroundColor Green