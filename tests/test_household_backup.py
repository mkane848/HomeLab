"""Unit tests for server/household/backup.sh, run against a stand-in `docker` on PATH.

The real script needs the server's Docker and volumes. The stand-in answers the five docker calls the script makes
(volume inspect, inspect, pause, unpause, run ... tar) and writes a real archive, so what is checked is the script's
own logic: both volumes are backed up, a missing chat volume is not an error, a missing tracker volume is, each
container is unpaused again, and the newest KEEP of EACH kind are kept.

Run:  python3 -m unittest -v tests/test_household_backup.py   (standard library only; needs bash and tar)
"""
import os
import shutil
import stat
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "server", "household", "backup.sh")

STUB = r'''#!/usr/bin/env bash
# Stand-in docker for tests/test_household_backup.py. STUB_VOLUMES: space-separated volumes that exist.
# STUB_LOG: every call is appended. STUB_FAIL_RUN=1: `docker run` fails (after the pause).
echo "$*" >> "$STUB_LOG"
case "$1" in
  volume) for v in $STUB_VOLUMES; do [ "$v" = "$3" ] && exit 0; done; exit 1 ;;
  inspect) echo true ;;
  pause|unpause) exit 0 ;;
  run)
    [ "${STUB_FAIL_RUN:-0}" = 1 ] && exit 9
    dest=""; out=""; prev=""
    for a in "$@"; do
      case "$a" in *:/backup) dest="${a%:/backup}" ;; esac
      [ "$prev" = "-czf" ] && out="${a#/backup/}"
      prev="$a"
    done
    src="$(mktemp -d)"; echo data > "$src/file"
    tar -czf "$dest/$out" -C "$src" .; rm -rf "$src" ;;
  *) exit 2 ;;
esac
'''


@unittest.skipUnless(shutil.which("bash") and shutil.which("tar"), "needs bash and tar")
class Backup(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.bin = os.path.join(self.tmp, "bin")
        self.dest = os.path.join(self.tmp, "backups")
        self.log = os.path.join(self.tmp, "docker.log")
        os.makedirs(self.bin)
        stub = os.path.join(self.bin, "docker")
        with open(stub, "w", encoding="utf-8", newline="\n") as f:
            f.write(STUB)
        os.chmod(stub, os.stat(stub).st_mode | stat.S_IEXEC)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_backup(self, volumes, **extra):
        env = dict(os.environ, PATH=self.bin + os.pathsep + os.environ["PATH"], HOME=self.tmp,
                   HOUSEHOLD_BACKUP_DIR=self.dest, STUB_VOLUMES=volumes, STUB_LOG=self.log, **extra)
        return subprocess.run(["bash", SCRIPT], env=env, capture_output=True, text=True)

    def files(self, prefix):
        return sorted(f for f in os.listdir(self.dest) if f.startswith(prefix + "-") and f.endswith(".tar.gz"))

    def calls(self):
        with open(self.log, encoding="utf-8") as f:
            return f.read().splitlines()

    def test_both_volumes_are_backed_up(self):
        r = self.run_backup("household_grocy_config household_openwebui_data")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(len(self.files("grocy")), 1)
        self.assertEqual(len(self.files("openwebui")), 1)
        self.assertFalse([f for f in os.listdir(self.dest) if f.endswith(".partial")])
        calls = self.calls()
        for c in ("household-grocy", "household-openwebui"):
            self.assertIn("pause " + c, calls)
            self.assertIn("unpause " + c, calls)
        # each archive reads the volume it is named for
        runs = [c for c in calls if c.startswith("run ")]
        self.assertIn("household_grocy_config:/data:ro", runs[0])
        self.assertIn("grocy-", runs[0])
        self.assertIn("household_openwebui_data:/data:ro", runs[1])
        self.assertIn("openwebui-", runs[1])

    def test_no_chat_volume_is_not_an_error(self):
        r = self.run_backup("household_grocy_config")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(len(self.files("grocy")), 1)
        self.assertEqual(self.files("openwebui"), [])
        self.assertIn("the chat is not backed up", r.stdout)
        self.assertNotIn("pause household-openwebui", self.calls())

    def test_no_tracker_volume_is_an_error(self):
        r = self.run_backup("household_openwebui_data")
        self.assertEqual(r.returncode, 1)
        self.assertIn("volume household_grocy_config not found", r.stderr)
        self.assertFalse(os.path.isdir(self.dest) and os.listdir(self.dest))
        self.assertFalse([c for c in self.calls() if c.startswith(("run ", "pause "))])

    def test_a_failed_copy_unpauses_the_container(self):
        r = self.run_backup("household_grocy_config household_openwebui_data", STUB_FAIL_RUN="1")
        self.assertNotEqual(r.returncode, 0)
        calls = self.calls()
        self.assertIn("pause household-grocy", calls)
        self.assertIn("unpause household-grocy", calls)
        self.assertEqual(self.files("grocy"), [])

    def test_keep_applies_to_each_kind(self):
        os.makedirs(self.dest)
        for prefix in ("grocy", "openwebui"):
            for i in range(4):
                p = os.path.join(self.dest, "%s-2026010%dT000000Z.tar.gz" % (prefix, i + 1))
                open(p, "w").close()
                os.utime(p, (1000 + i, 1000 + i))
        r = self.run_backup("household_grocy_config household_openwebui_data", KEEP="2")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        for prefix in ("grocy", "openwebui"):
            kept = self.files(prefix)
            self.assertEqual(len(kept), 2, kept)
            self.assertNotIn("%s-20260101T000000Z.tar.gz" % prefix, kept)   # the oldest went
            self.assertTrue(any("2026010" not in f for f in kept), kept)     # the new one stayed


if __name__ == "__main__":
    unittest.main()
