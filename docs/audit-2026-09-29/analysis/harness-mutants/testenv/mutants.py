import subprocess, sys, os, re, shutil, json
REAL = '/home/user/HomeLab/tests/test-tasks.ps1'
TEST = '/home/user/HomeLab/tests/test-task-env.ps1'
MAN = '/home/user/HomeLab/tests/tasks/manifest.json'
W = os.path.dirname(os.path.abspath(__file__))
src = open(REAL, 'rb').read().decode('utf-8')
assert '\r\n' in src
def c(s): return s.replace('\n', '\r\n')

def mut(name, old, new, count=1):
    o, n = c(old), c(new)
    assert src.count(o) == count, '%s: anchor count %d != %d' % (name, src.count(o), count)
    return name, src.replace(o, n)

M = []
# --- Invoke-Test
M.append(mut('M1 Invoke-Test does not apply the pins',
  "    $savedEnv = Set-TaskTestEnv $Task\n    try {\n        return Run-Native", "    $savedEnv = @{}\n    try {\n        return Run-Native"))
M.append(mut('M2 Invoke-Test does not restore',
  "    } finally {\n        Restore-TaskTestEnv $savedEnv\n    }\n}\n\n# Owner-authored", "    } finally {\n    }\n}\n\n# Owner-authored") if False else
  mut('M2 Invoke-Test does not restore',
  "        return Run-Native $Task.testCmd[0] @($Task.testCmd[1..($Task.testCmd.Count - 1)]) $testDir\n    } finally {\n        Restore-TaskTestEnv $savedEnv\n    }",
  "        return Run-Native $Task.testCmd[0] @($Task.testCmd[1..($Task.testCmd.Count - 1)]) $testDir\n    } finally {\n    }"))
M.append(mut('M3 Invoke-Test restores only on the happy path (no finally)',
  "    try {\n        return Run-Native $Task.testCmd[0] @($Task.testCmd[1..($Task.testCmd.Count - 1)]) $testDir\n    } finally {\n        Restore-TaskTestEnv $savedEnv\n    }",
  "    $r = Run-Native $Task.testCmd[0] @($Task.testCmd[1..($Task.testCmd.Count - 1)]) $testDir\n    Restore-TaskTestEnv $savedEnv\n    return $r"))
# --- the opencode call site
M.append(mut('M4 call site not wrapped: the model sees the ambient environment',
  "    $savedEnv = Set-TaskTestEnv $tk\n    try {\n        $run = Invoke-OpencodeRun -WtPath $wt.Wt -ModelId $Model -Prompt $prompt -PromptHash $promptHashes[$tk.id] -TimeoutSec $RunTimeout\n    } finally {\n        Restore-TaskTestEnv $savedEnv\n    }",
  "    $run = Invoke-OpencodeRun -WtPath $wt.Wt -ModelId $Model -Prompt $prompt -PromptHash $promptHashes[$tk.id] -TimeoutSec $RunTimeout"))
M.append(mut('M5 call site applies but never restores: pins leak into the next task',
  "    } finally {\n        Restore-TaskTestEnv $savedEnv\n    }\n    # A run that never reached",
  "    } finally {\n    }\n    # A run that never reached"))
# --- run JSON
M.append(mut('M6 run JSON does not record testEnv',
  "        testEnv         = $(if ($tk.PSObject.Properties[\"testEnv\"]) { $tk.testEnv } else { $null })\n", ""))
# --- the functions
M.append(mut('M7 null is not read as unset',
  "$value = if ($null -eq $p.Value) { \"\" } else { [string]$p.Value }", "$value = if ($null -eq $p.Value) { \"null\" } else { [string]$p.Value }"))
M.append(mut('M8 restore sets empty instead of the saved value',
  "foreach ($name in @($Saved.Keys)) { [Environment]::SetEnvironmentVariable($name, $Saved[$name]) }",
  "foreach ($name in @($Saved.Keys)) { [Environment]::SetEnvironmentVariable($name, \"\") }"))
M.append(mut('M9 the previous value is not saved',
  "$saved[$p.Name] = [Environment]::GetEnvironmentVariable($p.Name)", "$saved[$p.Name] = $null"))
M.append(mut('M10 only the first pin is applied',
  "            [Environment]::SetEnvironmentVariable($p.Name, $value)   # \"\" removes the variable\n",
  "            [Environment]::SetEnvironmentVariable($p.Name, $value)   # \"\" removes the variable\n            break\n"))
M.append(mut('M11 a task with testEnv: null object is not guarded',
  "if ($Task -and $Task.PSObject.Properties[\"testEnv\"] -and $Task.testEnv) {", "if ($Task.PSObject.Properties[\"testEnv\"]) {"))

os.makedirs(os.path.join(W, 'mut'), exist_ok=True)
results = []
# control: the real file
def run(script, manifest=MAN):
    r = subprocess.run(['pwsh', '-NoProfile', '-File', TEST, '-ScriptPath', script, '-ManifestPath', manifest], capture_output=True, text=True, timeout=300)
    out = r.stdout + r.stderr
    fails = re.findall(r'^FAIL (.*)$', out, re.M)
    return r.returncode, fails, out
rc, fails, out = run(REAL)
print('CONTROL (real files): exit %d, %d FAIL lines' % (rc, len(fails)))
for name, text in M:
    p = os.path.join(W, 'mut', re.sub(r'\W+', '_', name)[:40] + '.ps1')
    open(p, 'wb').write(text.encode('utf-8'))
    rc, fails, out = run(p)
    status = 'caught' if rc != 0 else 'SURVIVED'
    print('%-8s exit %d  %2d FAIL  %s' % (status, rc, len(fails), name))
    for f in fails[:2]: print('           e.g. FAIL', f[:110])
# manifest mutants
man = json.load(open(MAN, encoding='utf-8'))
for name, edit in [('M12 asohav-02 pin dropped', lambda m: [t.pop('testEnv') for t in m['tasks'] if t['id'].startswith('asohav-02')]),
                   ('M13 lfc-02 pin dropped', lambda m: [t.pop('testEnv') for t in m['tasks'] if t['id'].startswith('lfc-02')]),
                   ('M14 a pin without its note', lambda m: [t.pop('testEnvNote') for t in m['tasks'] if t['id'].startswith('asohav-02')]),
                   ('M15 a numeric pin value', lambda m: [t.__setitem__('testEnv', {'DATABASE_URL': 5}) for t in m['tasks'] if t['id'].startswith('asohav-02')]),
                   ('M16 a bad variable name', lambda m: [t.__setitem__('testEnv', {'BAD NAME': None}) for t in m['tasks'] if t['id'].startswith('asohav-02')])]:
    m2 = json.loads(json.dumps(man)); edit(m2)
    p = os.path.join(W, 'mut', 'manifest-%s.json' % name.split()[0])
    json.dump(m2, open(p, 'w'))
    rc, fails, out = run(REAL, p)
    print('%-8s exit %d  %2d FAIL  %s' % ('caught' if rc != 0 else 'SURVIVED', rc, len(fails), name))
    for f in fails[:1]: print('           e.g. FAIL', f[:110])
