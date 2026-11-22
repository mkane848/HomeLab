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
    "models/server-seats.tsv",
    "models/catalog.tsv",
    "server/llamacpp/models.ini",
    "node3/llamacpp/models.ini",
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

    def append(self, rel, text):
        with open(os.path.join(self.tmp, rel), "a", encoding="utf-8", newline="") as f:
            f.write(text)

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
        self.assertIn("[llamacpp-ctx] server qwen3:8b", out)

    def test_server_section_without_c(self):
        self.edit("server/llamacpp/models.ini", "c = 32768", "# c = 32768")
        code, out = run(self.tmp)
        self.assertEqual(code, 1)
        self.assertIn("[llamacpp-ctx] server", out)
        self.assertIn("no explicit `c`", out)

    def test_node3_limit_mismatch(self):
        # node3's served context against the llamacpp-node3 registration.
        self.edit("node3/llamacpp/models.ini", "c = 32768", "c = 16384")
        code, out = run(self.tmp)
        self.assertEqual(code, 1)
        self.assertIn("[llamacpp-limit] node3 qwen3:8b", out)

    def test_registered_but_not_served(self):
        self.edit("node3/llamacpp/models.ini", "[qwen3.6:35b-a3b-coding]", "[qwen3.6:other]")
        code, out = run(self.tmp)
        self.assertEqual(code, 1)
        self.assertIn("[llamacpp-orphan] node3 qwen3.6:35b-a3b-coding", out)

    def test_seat_nobody_serves(self):
        self.append("models/server-seats.tsv", "\t".join(["zz-gone:8b", "32768", "-", "-", "sha256:" + "c" * 64, "import-server", "test row"]) + "\n")
        code, out = run(self.tmp)
        self.assertEqual(code, 1)
        self.assertIn("[seat-unserved] zz-gone:8b", out)

    def test_catalog_context_mismatch(self):
        self.edit("models/catalog.tsv", "qwen3:8b\t5.2\tfit\t32768", "qwen3:8b\t5.2\tfit\t16384")
        code, out = run(self.tmp)
        self.assertEqual(code, 1)
        self.assertIn("[catalog-ctx] qwen3:8b", out)

    def test_profile_seat_not_registered(self):
        self.edit("profiles/dev-node3.sh", 'OPENCODE_MODEL="llamacpp-node3/qwen3:8b"', 'OPENCODE_MODEL="llamacpp-node3/nope:1b"')
        code, out = run(self.tmp)
        self.assertEqual(code, 1)
        self.assertIn("[profile-seat] dev-node3 OPENCODE_MODEL", out)

    def test_profile_on_a_removed_provider(self):
        self.edit("profiles/dev-node3.sh", 'OPENCODE_MODEL="llamacpp-node3/qwen3:8b"', 'OPENCODE_MODEL="ollama-node3/qwen3:8b"')
        code, out = run(self.tmp)
        self.assertEqual(code, 1)
        self.assertIn("provider 'ollama-node3' is not in opencode.jsonc", out)

    def test_profile_count_in_readme(self):
        self.edit("profiles/README.md", "Live profiles (2)", "Live profiles (3)")
        code, out = run(self.tmp)
        self.assertEqual(code, 1)
        self.assertIn("[profile-count]", out)

    def test_parked_count_in_readme(self):
        self.edit("profiles/README.md", "Parked profiles (1)", "Parked profiles (2)")
        code, out = run(self.tmp)
        self.assertEqual(code, 1)
        self.assertIn("[parked-count]", out)

    def test_stale_allowlist_row(self):
        self.append("tests/config-drift-allow.tsv", "llamacpp-ctx\tnot-a-tag\tleft over\n")
        code, out = run(self.tmp)
        self.assertEqual(code, 1)
        self.assertIn("[stale-allowlist]", out)

    def test_allowlist_hides_a_listed_problem(self):
        self.edit("models/catalog.tsv", "qwen3:8b\t5.2\tfit\t32768", "qwen3:8b\t5.2\tfit\t16384")
        self.append("tests/config-drift-allow.tsv", "catalog-ctx\tqwen3:8b\ta deliberate difference\n")
        code, out = run(self.tmp)
        self.assertEqual(code, 0, out)

    def test_missing_source_is_exit_2(self):
        os.remove(os.path.join(self.tmp, "node3/llamacpp/models.ini"))
        code, _ = run(self.tmp)
        self.assertEqual(code, 2)


if __name__ == "__main__":
    unittest.main()
