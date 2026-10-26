# protects: llama.cpp compose file, models.ini and llamacpp-check.sh invariants
# run-after: The llama.cpp compose file, preset, templates or checker
# test-llamacpp-stack.ps1 - regression guard for the llama.cpp trial's server stack
# (server/docker/docker-compose.llamacpp.yml, server/llamacpp/models.ini,
# server/scripts/llamacpp-check.sh; docs/llamacpp-trial.md).
#
# Why this exists: the stack is only worth measuring if it is the SAME model on the
# SAME weights at the SAME context as the Ollama seat it is compared with, and if it
# can not quietly lose the GPU the way the Ollama container did on 2026-10-12. Each
# of those is a line in a file that a later edit can break without anything failing.
#
# What it does:
#   1. The compose file's invariants, read from the REAL file: its own project (so it
#      never orphans the Ollama stack), an image pinned by build tag AND digest and
#      not the CUDA 13 build, no restart at boot, the SAME five GPU device nodes as
#      the Ollama compose file, a healthcheck that runs nvidia-smi inside the
#      container, the Ollama volume external and read-only, and the preset mounted
#      where the command reads it. Every model path in the preset sits under the
#      mount point.
#   2. The REAL llamacpp-check.sh on the real preset and seat table (all OK), then on
#      deliberately broken copies, each of which must FAIL for the stated reason:
#      a blob that is not the pinned one, a missing or different `c`, four slots, a
#      CPU seat with GPU layers, a ':' section with no alias, a section with no seat row, a quantized V cache
#      without flash attention, an unpinned (non-Ollama) weights path (a WARN, not a
#      failure), a missing file (exit 2).
#   3. The Python unit tests for the sampling and live-server logic
#      (tests/test_llamacpp_check.py).
# Parts 2-3 need bash and python3 (both standard on the server); without them they
# are reported SKIP and part 1 still runs. Exit 1 on any failure.
#
# Usage:  .\tests\test-llamacpp-stack.ps1
param()

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$compose = Join-Path $repo "server/docker/docker-compose.llamacpp.yml"
$ollamaCompose = Join-Path $repo "server/docker/docker-compose.yml"
$ini = Join-Path $repo "server/llamacpp/models.ini"
$seats = Join-Path $repo "models/server-seats.tsv"
$checker = Join-Path $repo "server/scripts/llamacpp-check.sh"

$script:fail = 0
$script:skipped = 0
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}
function Has([string]$name, [string]$text, [string]$pattern) { Check $name ($text -match $pattern) "True" }

foreach ($f in $compose, $ollamaCompose, $ini, $seats, $checker) {
    if (-not (Test-Path -LiteralPath $f)) { Write-Host "FAIL: missing $f"; exit 1 }
}

Write-Host "-- docker-compose.llamacpp.yml invariants"
$text = Get-Content -LiteralPath $compose -Raw
$lines = @(Get-Content -LiteralPath $compose | Where-Object { $_ -notmatch '^\s*#' })
$code = $lines -join "`n"
Check "its own compose project, not the Ollama stack's"      ([regex]::IsMatch($code, '(?m)^name:\s*llamacpp\s*$')) "True"
$image = ($lines | Where-Object { $_ -match '^\s*image:' } | Select-Object -First 1)
Has   "image pinned by build tag AND sha256 digest"           $image 'server-cuda-b\d+@sha256:[0-9a-f]{64}\s*$'
Check "...never :latest, and never the CUDA 13 build (driver 580)" (($image -match 'latest') -or ($image -match 'cuda13')) "False"
Check "restart is `"no`" (a trial must not start at boot and fight Ollama for the GPU)" ([regex]::IsMatch($code, '(?m)^\s*restart:\s*"no"\s*$')) "True"
$devs = @($lines | Where-Object { $_ -match '^\s*-\s*/dev/nvidia' } | ForEach-Object { ($_ -replace '^\s*-\s*', '').Trim() } | Sort-Object)
$ollamaDevs = @(Get-Content -LiteralPath $ollamaCompose | Where-Object { $_ -notmatch '^\s*#' -and $_ -match '^\s*-\s*/dev/nvidia' } | ForEach-Object { ($_ -replace '^\s*-\s*', '').Trim() } | Sort-Object)
Check "lists five GPU device nodes explicitly"                $devs.Count 5
Check "...the SAME five the Ollama compose file lists"        ($devs -join ",") ($ollamaDevs -join ",")
Has   "healthcheck runs nvidia-smi -L inside the container"   $code 'healthcheck:[\s\S]*nvidia-smi -L'
Has   "...and probes llama-server's own /health on 8090 (the image's built-in one probes 8080)" $code 'healthcheck:[\s\S]*127\.0\.0\.1:8090/health'
Has   "Ollama's volume is mounted read-only at /ollama"       $code '(?m)^\s*-\s*ollama_data:/ollama:ro\s*$'
Has   "...declared external, under its real name"              $code '(?s)volumes:\s*\n\s*ollama_data:\s*\n\s*external:\s*true\s*\n\s*name:\s*docker_ollama_data'
Has   "port 8090 published, and served on 8090"                $code '(?s)"8090:8090".*--port\s*\n\s*-\s*"8090"'
Has   "router mode: --models-preset /config/models.ini"        $code '--models-preset\s*\n\s*-\s*/config/models\.ini'
Has   "...and that file is mounted read-only from server/llamacpp" $code '\.\./llamacpp/models\.ini:/config/models\.ini:ro'
Has   "chat templates mounted read-only from server/llamacpp/templates" $code '(?m)^\s*-\s*\.\./llamacpp/templates:/config/templates:ro\s*$'
$tplRefs = @(Get-Content -LiteralPath $ini | Where-Object { $_ -match '^\s*chat-template-file\s*=' } | ForEach-Object { ($_ -split '=', 2)[1].Trim() })
$tplMissing = @($tplRefs | Where-Object { -not ($_ -match '^/config/templates/([^/]+)$' -and (Test-Path -LiteralPath (Join-Path $repo "server/llamacpp/templates/$($Matches[1])"))) })
Check "every chat-template-file in the preset is a file in server/llamacpp/templates" "$($tplRefs.Count) referenced, $($tplMissing.Count) missing" "$($tplRefs.Count) referenced, 0 missing"
$badPaths = @(Get-Content -LiteralPath $ini | Where-Object { $_ -match '^\s*model\s*=' -and $_ -notmatch '=\s*/ollama/models/blobs/sha256-[0-9a-f]{64}\s*$' })
Check "every model path in the preset is an Ollama blob under the /ollama mount" $badPaths.Count 0

# --- the checker, the real thing -----------------------------------------------
# A bash that can read the checker by its Windows path. On Windows the first `bash` on PATH can be
# WSL's launcher (C:\Windows\System32\bash.exe). On the desktop it exits 1 without starting ("WSL2 is
# unable to start since virtualization is not enabled"), so every checker scenario failed there
# (2026-10-19) while CI's Git bash passed; with WSL running, it would get C:\ paths it can't open.
# Git's own paths come first, and each candidate must pass the probe.
$bash = $null
$bashCandidates = @("C:\Program Files\Git\bin\bash.exe", "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe" |
    Where-Object { Test-Path -LiteralPath $_ }) + @(Get-Command bash -All -ErrorAction SilentlyContinue | ForEach-Object { $_.Source })
foreach ($b in $bashCandidates) {
    $ErrorActionPreference = "Continue"
    $o = & $b -c 'test -f "$1" && echo 42' probe $checker 2>&1 | Out-String
    $ErrorActionPreference = "Stop"
    if ($LASTEXITCODE -eq 0 -and $o.Trim() -eq "42") { $bash = Get-Command $b; break }
}
# A python that RUNS: on Windows python3 can be the Microsoft Store placeholder (on PATH, exits 49).
$python = $null
foreach ($cand in "python3", "python") {
    foreach ($c in @(Get-Command $cand -All -ErrorAction SilentlyContinue)) {
        $ErrorActionPreference = "Continue"
        $o = & $c.Source -c "print(40 + 2)" 2>&1 | Out-String
        $ErrorActionPreference = "Stop"
        if ($LASTEXITCODE -eq 0 -and $o.Trim() -eq "42") { $python = $c; break }
    }
    if ($python) { break }
}
if (-not $bash -or -not $python) {
    Write-Host "SKIP llamacpp-check.sh scenarios and the Python unit tests: need bash and python3 (found: bash=$([bool]$bash), python=$([bool]$python))"
    $script:skipped++
} else {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("llamacpp-stack-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    try {
        function Invoke-Checker([string]$IniPath, [string]$SeatsPath = $seats) {
            $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
            try {
                $out = & $bash.Source $checker --ini $IniPath --seats $SeatsPath 2>&1 | Out-String
                [pscustomobject]@{ Exit = $LASTEXITCODE; Out = $out }
            } finally { $ErrorActionPreference = $prev }
        }
        # LF, whatever the checkout: Git for Windows defaults to core.autocrlf=true, and the mutations
        # below search for multi-line text joined with `n (first seen on the CI Windows runner, 2026-10-13).
        $iniText = [IO.File]::ReadAllText($ini) -replace "`r`n", "`n"
        function Mutate([string]$Name, [string]$Old, [string]$New) {
            if (-not $iniText.Contains($Old)) { throw "mutation '$Name': text not found in the preset: $Old" }
            $p = Join-Path $tmp "$Name.ini"
            [IO.File]::WriteAllText($p, $iniText.Replace($Old, $New), $utf8)
            return $p
        }

        Write-Host "-- llamacpp-check.sh on the real preset and seat table"
        $r = Invoke-Checker $ini
        Check "exit 0, nothing FAILs"                             $r.Exit 0
        Has   "...every seat's weights are the pinned blob"        $r.Out '(?s)qwen3\.6:35b-a3b-coding\s+weights are the pinned blob.*qwen3:8b\s+weights are the pinned blob.*qwen2\.5-coder-3b-cpu\s+weights are the pinned blob'
        Has   "...and the summary line is 0 FAIL"                  $r.Out '0 FAIL'

        Write-Host "-- ...on deliberately broken copies"
        $flip = "d372de8e934898a59e6ccfabc3368474711384d8f1fd4d22d87a3f0a45400cdc"
        $r = Invoke-Checker (Mutate "wrong-blob" $flip ("0" * 64))
        Check "a blob that is not the pinned one: exit 1"         $r.Exit 1
        Has   "...names the blob and the pin"                      $r.Out 'blob sha256 0{12}\.\.\. != server-seats\.tsv weights'

        $r = Invoke-Checker (Mutate "no-c" "model = /ollama/models/blobs/sha256-a3de86cd1c132c822487ededd47a324c50491393e6565cd14bafa40d0b8e686f`nc = 32768" "model = /ollama/models/blobs/sha256-a3de86cd1c132c822487ededd47a324c50491393e6565cd14bafa40d0b8e686f")
        Check "a section with no explicit context: exit 1"        $r.Exit 1
        Has   "...says it would be inherited"                      $r.Out 'qwen3:8b\s+no explicit context'

        $r = Invoke-Checker (Mutate "wrong-c" "c = 65536" "c = 32768")
        Check "a context different from the seat table: exit 1"   $r.Exit 1
        Has   "...shows both numbers"                              $r.Out 'c = 32768 but server-seats\.tsv num_ctx = 65536'

        $r = Invoke-Checker (Mutate "four-slots" "parallel = 1" "parallel = 4")
        Check "four slots: exit 1"                                 $r.Exit 1
        Has   "...says the context is shared across slots"         $r.Out 'parallel = 4 \(must be 1: c is shared across slots\)'

        $r = Invoke-Checker (Mutate "cpu-seat-on-gpu" "n-gpu-layers = 0`ndevice = none" "n-gpu-layers = 99")
        Check "the CPU seat with GPU layers: exit 1"               $r.Exit 1
        Has   "...says the seat table wants zero"                  $r.Out 'num_gpu 0 but n-gpu-layers = 99'

        $r = Invoke-Checker (Mutate "no-alias" "alias = qwen3:8b`n" "")
        Check "a ':' section with no alias: exit 1"                $r.Exit 1
        Has   "...says router mode rewrites it"                    $r.Out "qwen3:8b\s+a ':' in the section name is rewritten by router mode"

        $r = Invoke-Checker (Mutate "orphan-section" "[qwen3:8b]" "[qwen3:99b]")
        Check "a section with no seat row: exit 1"                 $r.Exit 1
        Has   "...says so"                                         $r.Out 'qwen3:99b\s+no row in models/server-seats\.tsv'

        $r = Invoke-Checker (Mutate "qv-no-fa" "flash-attn = on" "flash-attn = off")
        Check "a quantized V cache without flash attention: exit 1" $r.Exit 1
        Has   "...says it needs flash attention"                   $r.Out 'quantized V cache \(q8_0\) needs flash attention'

        $r = Invoke-Checker (Mutate "unpinned" "model = /ollama/models/blobs/sha256-a3de86cd1c132c822487ededd47a324c50491393e6565cd14bafa40d0b8e686f" "model = /models/some-other-qwen3-8b.gguf")
        Check "weights that are not an Ollama blob: a WARN, not a failure (exit 0)" $r.Exit 0
        Has   "...says it is unpinned, a different era"            $r.Out '\[WARN\s*\]\s+qwen3:8b\s+weights are not an Ollama blob'

        $r = Invoke-Checker (Join-Path $tmp "does-not-exist.ini")
        Check "a missing file: exit 2"                             $r.Exit 2

        Write-Host "-- Python unit tests (sampling and live-server logic)"
        $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        try { $py = & $python.Source -I (Join-Path $PSScriptRoot "test_llamacpp_check.py") 2>&1 | Out-String; $pyExit = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
        Check "test_llamacpp_check.py passes"                      $pyExit 0
        if ($pyExit -ne 0) { Write-Host $py }
        Has   "...and ran its 22 tests"                            $py 'Ran 22 tests'
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
}

Write-Host ""
if ($script:fail) { Write-Host "$script:fail FAILED"; exit 1 }
Write-Host $(if ($script:skipped) { "all run checks passed ($script:skipped part skipped)" } else { "all passed" })
exit 0
