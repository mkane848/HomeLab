import subprocess, re, json, sys
REPO='/tmp/claude-0/-home-user-HomeLab/f0484f3b-8cac-50d6-af0c-d45af7ec3928/scratchpad/mine-kane/repo'
def git(*a):
    return subprocess.run(['git','-C',REPO]+list(a),capture_output=True,text=True,check=True).stdout
# non-merge commits with numstat, -M to follow renames
out = git('log','--no-merges','--reverse','--numstat','-M','--format=@@%H|%h|%p|%ad|%s','--date=short')
commits=[]
cur=None
for line in out.splitlines():
    if line.startswith('@@'):
        full,short,parents,date,subj=line[2:].split('|',4)
        cur={'full':full,'sha':short,'parents':parents,'date':date,'subject':subj,'files':[]}
        commits.append(cur)
    elif line.strip():
        parts=line.split('\t')
        if len(parts)==3:
            a,d,p=parts
            cur['files'].append((a,d,p))
json.dump(commits,open('/tmp/claude-0/-home-user-HomeLab/f0484f3b-8cac-50d6-af0c-d45af7ec3928/scratchpad/mine-kane/commits.json','w'))
print(len(commits))
