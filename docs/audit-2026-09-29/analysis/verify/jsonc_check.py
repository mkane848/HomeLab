"""Parse a JSONC file (comments + trailing commas) with a string-aware tokenizer, print a few facts,
and diff the parsed objects of two versions of the file."""
import json, re, subprocess, sys


def strip_jsonc(s):
    out, i, n = [], 0, len(s)
    in_str = False
    while i < n:
        c = s[i]
        if in_str:
            out.append(c)
            if c == '\\' and i + 1 < n:
                out.append(s[i + 1]); i += 2; continue
            if c == '"':
                in_str = False
            i += 1; continue
        if c == '"':
            in_str = True; out.append(c); i += 1; continue
        if c == '/' and i + 1 < n and s[i + 1] == '/':
            while i < n and s[i] != '\n':
                i += 1
            continue
        if c == '/' and i + 1 < n and s[i + 1] == '*':
            i = s.index('*/', i + 2) + 2; continue
        out.append(c); i += 1
    txt = ''.join(out)
    return re.sub(r',(\s*[}\]])', r'\1', txt)   # trailing commas


def load(text):
    return json.loads(strip_jsonc(text))


new = load(open('/home/user/HomeLab/opencode/global/opencode.jsonc', encoding='utf-8').read())
old_text = subprocess.run(['git', '-C', '/home/user/HomeLab', 'show', 'HEAD:opencode/global/opencode.jsonc'], capture_output=True, text=True).stdout
old = load(old_text)
print('parsed OK. top-level keys:', ', '.join(new.keys()))
print('autoupdate: old=%r new=%r' % (old.get('autoupdate'), new.get('autoupdate')))
changed = [k for k in set(old) | set(new) if old.get(k) != new.get(k)]
print('top-level keys that differ between HEAD and the working file:', changed)
