"""Unit tests for tests/check_config_drift.py: the real tree is clean, and each kind of
drift, planted in a throwaway copy of the files the check reads, is reported.

Run:  python3 -I tests/test_config_drift.py   (standard library only)
"""
import glob
import io
import os
import shutil
import sys
import tempfile
import unittest
from contextlib import redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, ".."))
sys.path.insert(0, HERE)
import check_config_drift as cd  # noqa: E402

FILES = [
    "desktop/scripts/startup.ps1",
    "models/server-seats.tsv",
    "models/catalog.tsv",
    "server/llamacpp/models.ini",
    "opencode/global/opencode.jsonc",
    "profiles/README.md",
    "tests/config-drift-allow.tsv",
]


def copy_tree(dst):
    for rel in FILES:
        os.makedirs(os.path.dirname(os.path.join(dst, rel)), exist_ok=True)
        shutil.copy(os.path.join(REPO, rel), os.path.join(dst, rel))
    for sub in ("profiles", os.path.join("profiles", "parked")):
        os.makedirs(os.path.join(dst, sub), exist_ok=True)
        for f in glob.glob(os.path.join(REPO, sub, "*.sh")):
            shutil.copy(f, os.path.join(dst, sub))


def run(root):
    buf = io.StringIO()
    with redirect_stdout(buf):
        code = cd.main(["--root", root])
    return code, buf.getvalue()


class Drift(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        copy_tree(self.tmp)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def edit(self, rel, old, new):
        p = os.path.join(self.tmp, rel)
        with open(p, encoding="utf-8", newline="") as f:
            s = f.read()
        self.assertIn(old, s, "fixture text moved: %r" % old)
        with open(p, "w", encoding="utf-8", newline="") as f:
            f.write(s.replace(old, new, 1))

    def test_real_tree_is_clean(self):
        code, out = run(REPO)
        self.assertEqual(code, 0, out)

    def test_copy_is_clean(self):
        code, out = run(self.tmp)
        self.assertEqual(code, 0, out)

    def test_seat_context_mismatch(self):
        self.edit("models/server-seats.tsv", "qwen3:8b\t32768", "qwen3:8b\t16384")
        code, out = run(self.tmp)
        self.assertEqual(code, 1)
        self.assertIn("[seat-ctx] qwen3:8b", out)

    def test_server_limit_mismatch(self):
        self.edit("models/server-seats.tsv", "qwen3.6:35b-a3b-coding\t65536", "qwen3.6:35b-a3b-coding\t49152")
        code, out = run(self.tmp)
        self.assertEqual(code, 1)
        self.assertIn("[server-limit] qwen3.6:35b-a3b-coding", out)
        self.assertIn("[llamacpp-ctx] qwen3.6:35b-a3b-coding", out)

    def test_unknown_model_key(self):
        self.edit("opencode/global/opencode.jsonc", '"codestral:22b": {', '"codestral": {')
        code, out = run(self.tmp)
        self.assertEqual(code, 1)
        self.assertIn("[uncatalogued] ollama-server/codestral", out)

    def test_profile_seat_not_registered(self):
        self.edit("profiles/dev-desktop-only.sh", 'OPENCODE_MODEL="ollama-desktop/qwen3:8b"', 'OPENCODE_MODEL="ollama-desktop/nope:1b"')
        code, out = run(self.tmp)
        self.assertEqual(code, 1)
        self.assertIn("[profile-seat]", out)

    def test_profile_count_in_readme(self):
        self.edit("profiles/README.md", "Live profiles (6)", "Live profiles (5)")
        code, out = run(self.tmp)
        self.assertEqual(code, 1)
        self.assertIn("[profile-count]", out)

    def test_stale_allowlist_row(self):
        with open(os.path.join(self.tmp, "tests/config-drift-allow.tsv"), "a", encoding="utf-8", newline="") as f:
            f.write("seat-ctx\tnot-a-tag\tleft over\n")
        code, out = run(self.tmp)
        self.assertEqual(code, 1)
        self.assertIn("[stale-allowlist]", out)

    def test_missing_source_is_exit_2(self):
        os.remove(os.path.join(self.tmp, "models/server-seats.tsv"))
        code, _ = run(self.tmp)
        self.assertEqual(code, 2)


if __name__ == "__main__":
    unittest.main()
