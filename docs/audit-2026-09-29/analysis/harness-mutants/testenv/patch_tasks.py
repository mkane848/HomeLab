import sys
path = '/home/user/HomeLab/tests/test-tasks.ps1'
raw = open(path, 'rb').read()
assert raw.count(b'\r\n') > 100 and raw.count(b'\n') == raw.count(b'\r\n'), 'expected pure CRLF'
txt = raw.decode('utf-8')

def crlf(s):
    return s.replace('\n', '\r\n')

def sub(old, new):
    global txt
    old, new = crlf(old), crlf(new)
    assert txt.count(old) == 1, 'anchor not unique/present (%d): %r' % (txt.count(old), old[:70])
    txt = txt.replace(old, new)

# (a) header paragraph
sub("""# inspected, extracting them is a follow-up; this harness does not assume a
# shape it hasn't verified.
""", """# inspected, extracting them is a follow-up; this harness does not assume a
# shape it hasn't verified.
#
# Test environment: a task's manifest `testEnv` (name -> value; null or "" =
# unset) is applied to the test command AND to the `opencode run` process, so
# the model's own shell and every gate see the same variables whatever the
# harness process happens to hold, and is restored afterwards. It is recorded
# in each run JSON as `testEnv` (absent on earlier rows, which ran under the
# ambient environment). asohav-02 needs it: see that task's `testEnvNote`.
""")

# (b) helpers + Invoke-Test
sub("""function Invoke-Test {
    param($Task, [string]$WtPath)
    $testDir = Join-Path $WtPath $Task.testDir
    return Run-Native $Task.testCmd[0] @($Task.testCmd[1..($Task.testCmd.Count - 1)]) $testDir
}
""", """# A task's `testEnv` pins the environment its test command and the model's own
# shell run under. Without it a gate result depends on whatever the harness
# process happens to hold: asohav-02's model-written test imports the real
# repo.ts, which imports pgPool.ts, which throws at import time unless
# DATABASE_URL is set - so that kind of test file could not load on 2026-09-27
# (variable absent: the models' own vitest runs show the error) and passed on
# 2026-09-29 (present), with nothing in the result saying which. Set-TaskTestEnv
# applies the pins and returns what Restore-TaskTestEnv needs to put the process
# back, so one task's pins never leak into the next task of the same batch.
function Set-TaskTestEnv {
    param($Task)
    $saved = [ordered]@{}
    if ($Task -and $Task.PSObject.Properties["testEnv"] -and $Task.testEnv) {
        foreach ($p in $Task.testEnv.PSObject.Properties) {
            $saved[$p.Name] = [Environment]::GetEnvironmentVariable($p.Name)
            $value = if ($null -eq $p.Value) { "" } else { [string]$p.Value }
            [Environment]::SetEnvironmentVariable($p.Name, $value)   # "" removes the variable
        }
    }
    return , $saved
}

function Restore-TaskTestEnv {
    param($Saved)
    if (-not $Saved) { return }
    foreach ($name in @($Saved.Keys)) { [Environment]::SetEnvironmentVariable($name, $Saved[$name]) }
}

function Invoke-Test {
    param($Task, [string]$WtPath)
    $testDir = Join-Path $WtPath $Task.testDir
    $savedEnv = Set-TaskTestEnv $Task
    try {
        return Run-Native $Task.testCmd[0] @($Task.testCmd[1..($Task.testCmd.Count - 1)]) $testDir
    } finally {
        Restore-TaskTestEnv $savedEnv
    }
}
""")

# (c) the opencode call site
sub("""    $run = Invoke-OpencodeRun -WtPath $wt.Wt -ModelId $Model -Prompt $prompt -PromptHash $promptHashes[$tk.id] -TimeoutSec $RunTimeout
""", """    # The model's own shell gets the pinned environment too: a test it sees pass
    # has to be one the gates can run (opencode inherits this process's env).
    $savedEnv = Set-TaskTestEnv $tk
    try {
        $run = Invoke-OpencodeRun -WtPath $wt.Wt -ModelId $Model -Prompt $prompt -PromptHash $promptHashes[$tk.id] -TimeoutSec $RunTimeout
    } finally {
        Restore-TaskTestEnv $savedEnv
    }
""")

# (d) run JSON
sub("""        numCtx          = $numCtx
        samplingControl""", """        numCtx          = $numCtx
        testEnv         = $(if ($tk.PSObject.Properties["testEnv"]) { $tk.testEnv } else { $null })
        samplingControl""")

open(path, 'wb').write(txt.encode('utf-8'))
print('patched OK')
