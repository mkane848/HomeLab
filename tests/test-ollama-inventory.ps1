# protects: the Ollama uninstall dry runs (server/scripts/ollama-inventory.sh, desktop/scripts/ollama-inventory.ps1): read-only, and READY only when nothing still needs Ollama's files
# run-after: server/scripts/ollama-inventory.sh, desktop/scripts/ollama-inventory.ps1, or llamacpp-check.sh's weights check
# mutation: desktop/scripts/ollama-inventory.ps1
# mutation-from: else { $blockers.Add("$full (sha256 $sha) matches no weights pin in $SeatsPath, so the Ollama store may hold the only good copy") }
# mutation-to: else { }
# mutation-expect: FAIL\s+NOT READY, naming the unpinned file
# test-ollama-inventory.ps1 - regression guard for the two Ollama uninstall dry runs.
#
# Why this exists: deleting Ollama's volume and model stores is not reversible, and the owner runs the delete
# commands these scripts print (AGENTS.md: dry run and hash-compare before deleting). So two things must hold:
#   - the scripts never delete anything themselves;
#   - they say READY, and print a delete command, only when nothing still needs the files.
# What it does:
#   A. (Linux only; CI runs it in the Linux job, Windows SKIPs this part.) The real ollama-inventory.sh runs against a
#      stand-in `docker` and `llamacpp-check.sh` that log every call. Scenarios: ready; --no-hash; a non-Ollama
#      container mounting the volume; a failing weights check; llama.cpp not running; nothing left; a bad argument.
#   B. (Any OS.) The real ollama-inventory.ps1 runs against a fixture store, models.ini and seat table. Scenarios:
#      ready; a model whose hash matches no pin; a preset loading from inside the store; -NoHash; no preset model on
#      this machine; nothing left; a missing path.
# Each scenario checks the exit code and the verdict line, and that a refusal prints no delete command. The fixtures
# hash the same before and after, and the stand-in docker never received a destructive verb.
#
# Usage:  .\tests\test-ollama-inventory.ps1 [-ShPath <ollama-inventory.sh>] [-Ps1Path <ollama-inventory.ps1>]
param([string]$ShPath = "", [string]$Ps1Path = "")

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$sh = if ($ShPath) { $ShPath } else { Join-Path $repo "server/scripts/ollama-inventory.sh" }
$ps1 = if ($Ps1Path) { $Ps1Path } else { Join-Path $repo "desktop/scripts/ollama-inventory.ps1" }
foreach ($p in $sh, $ps1) { if (-not (Test-Path -LiteralPath $p)) { Write-Host "FAIL: missing $p"; exit 1 } }

$script:fail = 0
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}
function Write-Lf([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n")) }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("ollama-inventory-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    # ======================================================================== A. the server's script
    if (-not $IsLinux -or -not (Get-Command bash -ErrorAction SilentlyContinue)) {
        Write-Host "SKIP A: ollama-inventory.sh is the Ubuntu server's script; CI runs this part in the Linux job"
    } else {
        $tree = Join-Path $tmp "tree/server/scripts"; $fx = Join-Path $tmp "fx"; $st = Join-Path $fx "state"
        New-Item -ItemType Directory -Force -Path $tree, $fx, $st, (Join-Path $st "mounts") | Out-Null
        Copy-Item -LiteralPath $sh -Destination (Join-Path $tree "ollama-inventory.sh")
        # State: containers.tsv (name, image, status), running.txt, images.tsv, volumes.txt, mounts/<volume>, check_rc.
        Write-Lf (Join-Path $fx "docker") @'
#!/usr/bin/env bash
S="$FX_STATE"
echo "docker $*" >> "$S/calls.log"
case "$1" in
  ps)
    vol=""; name=""
    for a in "$@"; do
      case "$a" in volume=*) vol="${a#volume=}" ;; name=*) name="${a#name=^}"; name="${name%\$}" ;; esac
    done
    if [ -n "$vol" ]; then [ -f "$S/mounts/$vol" ] && tr ',' '\n' < "$S/mounts/$vol"; exit 0; fi
    if [ -n "$name" ]; then grep -qx "$name" "$S/running.txt" 2>/dev/null && echo "$name"; exit 0; fi
    cat "$S/containers.tsv"; exit 0 ;;
  image) cat "$S/images.tsv"; exit 0 ;;
  volume) cat "$S/volumes.txt"; exit 0 ;;
esac
exit 0
'@
        Write-Lf (Join-Path $tree "llamacpp-check.sh") @'
#!/usr/bin/env bash
echo "check $*" >> "$FX_STATE/calls.log"
exit "$(cat "$FX_STATE/check_rc")"
'@
        & chmod +x (Join-Path $fx "docker") (Join-Path $tree "llamacpp-check.sh") (Join-Path $tree "ollama-inventory.sh")

        function Set-State([string]$Containers, [string]$Running, [string]$Images, [string]$Volumes, [hashtable]$Mounts, [int]$CheckRc) {
            Get-ChildItem -LiteralPath $st -Recurse -File | Remove-Item
            Write-Lf (Join-Path $st "containers.tsv") $Containers
            Write-Lf (Join-Path $st "running.txt") $Running
            Write-Lf (Join-Path $st "images.tsv") $Images
            Write-Lf (Join-Path $st "volumes.txt") $Volumes
            foreach ($k in $Mounts.Keys) { Write-Lf (Join-Path $st "mounts/$k") $Mounts[$k] }
            Write-Lf (Join-Path $st "check_rc") "$CheckRc"
            Write-Lf (Join-Path $st "calls.log") ""
        }
        function Invoke-Sh([string[]]$ShArgs) {
            $old = $env:PATH; $env:PATH = "${fx}:$old"; $env:FX_STATE = $st
            try { $out = & bash (Join-Path $tree "ollama-inventory.sh") @ShArgs 2>&1 | Out-String; $rc = $LASTEXITCODE }
            finally { $env:PATH = $old; Remove-Item Env:FX_STATE -ErrorAction SilentlyContinue }
            $calls = Get-Content -Raw -LiteralPath (Join-Path $st "calls.log")
            [pscustomobject]@{ Out = $out; Exit = $rc; Calls = $calls }
        }
        $containers = "ollama-server`tollama/ollama:0.34.3`tExited (0) 2 days ago`nllamacpp-server`tghcr.io/ggml-org/llama.cpp:server-cuda`tUp 3 hours`nhousehold-openwebui`tghcr.io/open-webui/open-webui:v0.6`tUp 3 hours`n"
        $images = "ollama/ollama:0.34.3`tabc123`t3.4GB`nghcr.io/ggml-org/llama.cpp:server-cuda`tdef456`t2.1GB`n"
        $volumes = "docker_ollama_data`nhousehold_openwebui`n"
        $destructive = '(?m)^docker (rm|stop|kill|volume rm|image rm|rmi|compose)'

        Write-Host "-- A1 ready: only Ollama mounts its volume, the weights check passes"
        Set-State $containers "llamacpp-server`n" $images $volumes @{ docker_ollama_data = "ollama-server" } 0
        $r = Invoke-Sh @()
        Check "exit 0" $r.Exit 0
        Check "says READY and that nothing was deleted" ($r.Out -match 'READY\. Nothing has been deleted') "True"
        Check "prints the container removal for ollama-server only" ($r.Out -match '(?m)^\s+docker rm -f ollama-server\s*$') "True"
        Check "prints the volume removal for docker_ollama_data only" ($r.Out -match '(?m)^\s+docker volume rm docker_ollama_data\s*$') "True"
        Check "prints the image removal for the Ollama image only" ($r.Out -match '(?m)^\s+docker image rm ollama/ollama:0\.34\.3\s*$') "True"
        Check "the weights check ran on llamacpp-server with --hash" ($r.Calls -match '(?m)^check --weights-container llamacpp-server --hash\s*$') "True"
        Check "docker received no destructive verb" ($r.Calls -match $destructive) "False"

        Write-Host "-- A2 --no-hash"
        $r = Invoke-Sh @("--no-hash")
        Check "exit 0" $r.Exit 0
        Check "the check ran without --hash" ($r.Calls -match '(?m)^check --weights-container llamacpp-server\s*$') "True"
        Check "it says the weights were not re-hashed" ($r.Out -match 'not re-hashed') "True"

        Write-Host "-- A3 another container mounts the Ollama volume"
        Set-State $containers "llamacpp-server`n" $images $volumes @{ docker_ollama_data = "ollama-server,household-openwebui" } 0
        $r = Invoke-Sh @()
        Check "exit 1" $r.Exit 1
        Check "NOT READY, naming the container" ($r.Out -match 'NOT READY' -and $r.Out -match 'mounted by household-openwebui, which is not an Ollama container') "True"
        Check "no delete command printed" ($r.Out -match '(?m)^\s+docker (rm|volume rm|image rm) ') "False"

        Write-Host "-- A4 the weights check fails"
        Set-State $containers "llamacpp-server`n" $images $volumes @{ docker_ollama_data = "ollama-server" } 1
        $r = Invoke-Sh @()
        Check "exit 1" $r.Exit 1
        Check "NOT READY, saying the check failed" ($r.Out -match 'llamacpp-check\.sh failed') "True"
        Check "no delete command printed" ($r.Out -match '(?m)^\s+docker (rm|volume rm|image rm) ') "False"

        Write-Host "-- A5 llama.cpp is not running"
        Set-State $containers "" $images $volumes @{ docker_ollama_data = "ollama-server" } 0
        $r = Invoke-Sh @()
        Check "exit 1" $r.Exit 1
        Check "says the container is not running" ($r.Out -match 'llamacpp-server is not running') "True"
        Check "the weights check was not run" ($r.Calls -match '(?m)^check ') "False"

        Write-Host "-- A6 nothing Ollama is left"
        Set-State "llamacpp-server`tghcr.io/ggml-org/llama.cpp:server-cuda`tUp`n" "llamacpp-server`n" "ghcr.io/ggml-org/llama.cpp:server-cuda`tdef456`t2.1GB`n" "household_openwebui`n" @{} 0
        $r = Invoke-Sh @()
        Check "exit 0" $r.Exit 0
        Check "says nothing is left" ($r.Out -match 'nothing Ollama is left') "True"
        Check "the weights check was not needed" ($r.Calls -match '(?m)^check ') "False"

        Write-Host "-- A7 a bad argument"
        $r = Invoke-Sh @("--delete")
        Check "exit 2" $r.Exit 2
    }

    # ======================================================================== B. the Windows script
    $b = Join-Path $tmp "win"; $store = Join-Path $b "ollama/models"; $models = Join-Path $b "models"
    New-Item -ItemType Directory -Force -Path (Join-Path $store "blobs"), $models | Out-Null
    Write-Lf (Join-Path $store "blobs/sha256-aaaa") "an Ollama blob"
    Write-Lf (Join-Path $store "blobs/sha256-bbbb") "another Ollama blob"
    $gguf = Join-Path $models "qwen3-8b.gguf"
    Write-Lf $gguf "GGUF fixture weights"
    $pin = (Get-FileHash -LiteralPath $gguf -Algorithm SHA256).Hash.ToLowerInvariant()
    $seats = Join-Path $b "server-seats.tsv"
    Write-Lf $seats ("# fixture`ntag`tnum_ctx`tnum_gpu`tfrom`tweights`tsource`tnote`nqwen3:8b`t32768`t-`t-`tsha256:$pin`timport-server`tfixture`n")
    $ini = Join-Path $b "models.ini"
    function Set-Ini([string]$ModelPath) { Write-Lf $ini "[*]`n[qwen3:8b]`nmodel = $ModelPath`n" }
    function Get-TreeHash { (Get-ChildItem -LiteralPath $b -Recurse -File | Sort-Object FullName | ForEach-Object { "$($_.FullName)=$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" }) -join "`n" }
    function Invoke-Ps1([string[]]$More) {
        $psExe = (Get-Process -Id $PID).Path
        $out = & $psExe -NoProfile -File $ps1 -SeatsPath $seats -IniPath $ini @More 2>&1 | Out-String
        [pscustomobject]@{ Out = $out; Exit = $LASTEXITCODE }
    }

    Write-Host "-- B1 ready: the preset loads a pinned file outside the store"
    Set-Ini $gguf
    $before = Get-TreeHash
    $r = Invoke-Ps1 @("-StorePath", $store)
    Check "exit 0" $r.Exit 0
    Check "lists the store with its file count" ($r.Out -match 'store\s+.*models \(2 files') "True"
    Check "the preset's file matches its pin" ($r.Out -match 'matches the pin of qwen3:8b') "True"
    Check "READY, with the store's removal printed" ($r.Out -match 'READY\. Nothing has been deleted' -and $r.Out -match "Remove-Item -LiteralPath '.*models' -Recurse -Force") "True"

    Write-Host "-- B2 the preset's file matches no pin"
    Write-Lf $gguf "GGUF fixture weights, but different bytes"
    $r = Invoke-Ps1 @("-StorePath", $store)
    Check "exit 1" $r.Exit 1
    Check "NOT READY, naming the unpinned file" ($r.Out -match 'NOT READY' -and $r.Out -match 'matches no weights pin') "True"
    Check "no delete command printed" ($r.Out -match 'Remove-Item -LiteralPath') "False"

    Write-Host "-- B3 -NoHash does not hash, and says so"
    $r = Invoke-Ps1 @("-StorePath", $store, "-NoHash")
    Check "exit 0" $r.Exit 0
    Check "it says the weights were not re-hashed" ($r.Out -match 'not re-hashed') "True"
    Write-Lf $gguf "GGUF fixture weights"

    Write-Host "-- B4 the preset loads from inside the Ollama store"
    Set-Ini (Join-Path $store "blobs/sha256-aaaa")
    $r = Invoke-Ps1 @("-StorePath", $store)
    Check "exit 1" $r.Exit 1
    Check "NOT READY, saying the file is inside the store" ($r.Out -match 'inside the Ollama store') "True"
    Check "no delete command printed" ($r.Out -match 'Remove-Item -LiteralPath') "False"

    Write-Host "-- B5 no preset model on this machine (the desktop)"
    Set-Ini (Join-Path $b "nowhere/qwen3-8b.gguf")
    $r = Invoke-Ps1 @("-StorePath", $store)
    Check "exit 0" $r.Exit 0
    Check "says no preset loads a file here" ($r.Out -match 'no llama\.cpp preset in .* loads a file on this machine') "True"

    Write-Host "-- B6 nothing left"
    Set-Ini $gguf
    if ($IsWindows -and (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA "Programs\Ollama"))) {
        Write-Host "SKIP B6: this machine has an Ollama install"
    } else {
        $r = Invoke-Ps1 @("-StorePath", (Join-Path $b "no-such-store"))
        Check "exit 0" $r.Exit 0
        Check "says nothing is left" ($r.Out -match 'nothing Ollama is left') "True"
    }

    Write-Host "-- B7 a path that does not exist"
    $psExe = (Get-Process -Id $PID).Path
    $out = & $psExe -NoProfile -File $ps1 -SeatsPath (Join-Path $b "missing.tsv") -IniPath $ini 2>&1 | Out-String
    Check "exit 2" $LASTEXITCODE 2

    Write-Host "-- nothing was deleted"
    Set-Ini $gguf
    Check "the fixture store and models hash the same as before" (Get-TreeHash) $before
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"
exit 0
