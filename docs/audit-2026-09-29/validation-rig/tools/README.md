# Validation rig (item 5, 2026-10-03)

Runs the REAL `tests/test-tasks.ps1` (copied from /home/user/HomeLab at make_rig time) against local clones of the upstream repos, with a
stand-in `opencode` that "makes the model's change" by applying reference patches. Nothing here touches /home/user/HomeLab.

    # once per agent: your own clones (cheap, hardlinked)
    mkdir -p $G/repos && for r in KaneEnabler lfc-bot ASoHaVCompanionApp; do git clone --local -q $RIG/repos/$r $G/repos/$r; done
    # every time you change your entries file:
    python3 $RIG/tools/make_rig.py --out $G/rig --fragment $G/entries.<group>.json --repos $G/repos
    # reference patches (src and test halves) for a task whose fix commit can be used as is:
    $RIG/tools/mkpatch.sh $G/repos/<Repo> <parent> <fix> $G/rig/ref <taskId> "<src files>" "<test files>"
    # runs
    cd $G/rig
    ./run.sh <taskId> ref dry        # worktree + install + baseline (+ acceptance must FAIL on the untouched base)
    ./run.sh <taskId> ref            # stand-in applies src+test patches        -> every gate PASS (+ acceptance PASS)
    ./run.sh <taskId> srconly        # stand-in applies the source fix only      -> failsOnOld FAIL (test never modified / still green on old code)
    ./run.sh <taskId> testsonly      # stand-in applies the tests only           -> scope FAIL + suite FAIL
    python3 $RIG/tools/summarize.py . [taskId...]    # one line per latest run, with acceptance detail
    # logs: out/<id>.<tag>.log ; result JSON: tests/results/tasks-<id>-<tag>_<stamp>.json
    # env variants: RIG_UNSET="MANAPOOL_API_KEY DATABASE_URL" RIG_TAG=unset ./run.sh <id> ref
    #               RIG_ENV="DATABASE_URL=postgres://u:p@127.0.0.1:9/x MANAPOOL_API_KEY=dummy" RIG_TAG=dummy ./run.sh <id> ref
