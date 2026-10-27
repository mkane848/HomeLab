"""List the 12 new DP11 passes (fresh reps on opencode 1.18.33) and survey what each transcript did."""
import csv, glob, json, os, re, collections, sys

R = '/home/user/HomeLab/tests/results'
rows = list(csv.DictReader(open(R + '/tasks-summary.tsv', encoding='utf-8-sig'), delimiter='\t'))
J = {}
for p in glob.glob(R + '/tasks-*.json'):
    try:
        d = json.load(open(p, encoding='utf-8-sig'))
    except Exception:
        continue
    if isinstance(d, dict) and 'taskId' in d:
        J[(d['taskId'], d['model'], d['timestamp'])] = d

SEATS = {'ollama-desktop/qwen3.6:35b-a3b-coding': 'qwen3.6', 'ollama-desktop/qwen3.5:9b': 'qwen3.5'}
TASKS = ['lfc-03-status-transition-guard', 'kane-02-multiword-creature-type', 'asohav-02-changelog-uuid-id', 'kane-04-singleton-up-to-n', 'lfc-02-scryfall-headers']


def gp(r):
    return r['opencodeExit'] == '0' and r['scope'] == 'PASS' and r['suite'] == 'PASS' and r['failsOnOld'] == 'PASS'


passes = []
for r in rows:
    if r['model'] not in SEATS or r['taskId'] not in TASKS or not gp(r):
        continue
    j = J.get((r['taskId'], r['model'], r['timestamp'])) or {}
    if j.get('opencodeVersion') != '1.18.33':
        continue
    passes.append((r['taskId'], SEATS[r['model']], r['timestamp'], j))
passes.sort(key=lambda x: (x[0], x[1], x[2]))


def events(path):
    return [json.loads(l) for l in open(path, encoding='utf-8-sig') if l.strip()]


def survey():
    print('%d passes' % len(passes))
    for task, seat, ts, j in passes:
        p = os.path.join(R, j['transcriptFile'])
        ev = events(p)
        tools = collections.Counter(e['part'].get('tool') for e in ev if e['type'] == 'tool_use')
        print('\n%s | %s | %s | writes=%s | %ss | %s' % (task, seat, ts, j['writes'], j['elapsedSec'], j['transcriptFile'][-40:]))
        print('   tools:', dict(tools))
        for e in ev:
            if e['type'] == 'tool_use' and e['part'].get('tool') == 'bash':
                st = e['part']['state']
                cmd = (st.get('input') or {}).get('command', '')
                print('   bash [%s]: %s' % (st.get('status'), cmd.replace('\n', ' ; ')[:170]))


if __name__ == '__main__':
    survey()
