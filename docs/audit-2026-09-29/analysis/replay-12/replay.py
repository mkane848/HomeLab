"""Replay the edit/write calls of a committed opencode transcript onto a base worktree.

Faithful to what opencode did: an edit is applied from the diff opencode itself recorded
(part.state.metadata.diff), which already reflects its looser matching; if that cannot be applied,
the exact oldString -> newString replacement is tried; if that fails too the edit is reported as a MISS.
Only calls whose state.status == 'completed' are applied (an errored call changed nothing).
"""
import json, os, re, subprocess, sys, tempfile

R = '/home/user/HomeLab/tests/results'
A = '/tmp/claude-0/-home-user-HomeLab/f0484f3b-8cac-50d6-af0c-d45af7ec3928/scratchpad/audit12'


def events(path):
    out = []
    for l in open(path, encoding='utf-8-sig'):
        l = l.strip()
        if l:
            try:
                out.append(json.loads(l))
            except Exception:
                pass
    return out


def rel_path(fp, task_id):
    p = fp.replace('\\', '/')
    m = re.search(r'\.worktrees/' + re.escape(task_id) + r'/(.*)$', p)
    if m:
        return m.group(1)
    # a relative path (older runs, e.g. 'apps/server/src/repo.ts'): opencode resolves it against the worktree root
    if not re.match(r'^([A-Za-z]:|/)', p):
        return re.sub(r'^\./', '', p)
    return None


def read(path):
    return open(path, 'rb').read()


def apply_patch(target, diff_text):
    with tempfile.NamedTemporaryFile('wb', suffix='.diff', delete=False) as f:
        f.write(diff_text.encode('utf-8'))
        dp = f.name
    try:
        r = subprocess.run(['patch', '--batch', '--no-backup-if-mismatch', '-s', target, dp], capture_output=True, text=True)
        return r.returncode == 0, (r.stdout + r.stderr).strip()[:200]
    finally:
        os.unlink(dp)


def replay(transcript, task_id, wt):
    """Apply the transcript's completed edit/write calls to wt (a git worktree at the base).
    Returns a list of per-call records."""
    recs = []
    for e in events(transcript):
        if e.get('type') != 'tool_use':
            continue
        part = e['part']
        tool = part.get('tool')
        if tool not in ('edit', 'write'):
            continue
        st = part['state']
        inp = st.get('input') or {}
        fp = inp.get('filePath', '')
        rp = rel_path(fp, task_id)
        rec = {'tool': tool, 'file': rp or fp, 'status': st.get('status'), 'how': None, 'note': ''}
        if st.get('status') != 'completed':
            rec['how'] = 'skipped (errored call)'
            rec['note'] = (st.get('error') or st.get('output') or '')[:120] if isinstance(st.get('error') or st.get('output'), str) else ''
            recs.append(rec)
            continue
        if rp is None:
            rec['how'] = 'UNMAPPED PATH'
            recs.append(rec)
            continue
        target = os.path.join(wt, rp)
        if tool == 'write':
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, 'wb') as f:
                f.write(inp.get('content', '').encode('utf-8'))
            rec['how'] = 'write'
        else:
            old, new = inp.get('oldString', ''), inp.get('newString', '')
            replace_all = bool(inp.get('replaceAll'))
            before = read(target) if os.path.exists(target) else None
            done = False
            md = st.get('metadata') or {}
            diff = md.get('diff') or (md.get('filediff') or {}).get('patch')
            if before is not None and diff:
                ok, msg = apply_patch(target, diff)
                if ok:
                    rec['how'] = 'opencode diff'
                    done = True
                else:
                    if before is not None:
                        open(target, 'wb').write(before)   # undo a partial patch
                    rec['note'] = 'diff not applicable: ' + msg
            if not done and before is not None:
                txt = before.decode('utf-8')
                cnt = txt.count(old)
                if cnt >= 1 and (replace_all or cnt == 1):
                    open(target, 'wb').write((txt.replace(old, new) if replace_all else txt.replace(old, new, 1)).encode('utf-8'))
                    rec['how'] = 'exact replace'
                    done = True
                elif cnt > 1:
                    rec['note'] += ' oldString matches %d times' % cnt
            if not done:
                rec['how'] = 'MISS'
        recs.append(rec)
    return recs


if __name__ == '__main__':
    print('library module; see run_audit.py')
