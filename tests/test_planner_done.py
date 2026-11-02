"""Unit tests for desktop/scripts/planner_done.py, experiment 3's confirmation checkpoint.

Run:  python3 -I tests/test_planner_done.py   (standard library only; also run by tests/test-planner-done.ps1)
"""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "desktop", "scripts"))
import planner_done as pd  # noqa: E402

LIST = """# Done list: real-02, planner run 1

## Must add
- [x] D1: documents HEALTH_PORT and DISCORD_ALERT_WEBHOOK_URL
- [x] D2: documents the health server, alerts, audit log, custom IDs and batch operations

## Not asked
- [ ] N1: mentions Dependabot
"""


class Parse(unittest.TestCase):
    def test_items_and_states(self):
        items, confs = pd.parse(LIST)
        self.assertEqual([(k, i) for k, i, _ in items], [(True, "D1"), (True, "D2"), (False, "N1")])
        self.assertEqual(confs, [])

    def test_duplicate_id_is_malformed(self):
        with self.assertRaises(pd.Malformed):
            pd.parse(LIST + "- [x] D1: again\n")

    def test_a_checklist_line_in_another_shape_is_malformed(self):
        # Not silently ignored: an item the parser skipped would be neither kept nor struck.
        for bad in ("- [x] documents it, no id\n", "* [x] D3: star bullet\n", "- [v] D3: odd mark\n"):
            with self.assertRaises(pd.Malformed, msg=bad):
                pd.parse(LIST + bad)

    def test_no_items_is_malformed(self):
        with self.assertRaises(pd.Malformed):
            pd.parse("# empty\n")


class Verify(unittest.TestCase):
    def test_unconfirmed_fails(self):
        ok, msg, _ = pd.verify(LIST)
        self.assertFalse(ok)
        self.assertIn("not confirmed", msg)

    def test_confirmed_passes_and_lists_the_kept_ids(self):
        ok, msg, kept = pd.verify(pd.cmd_confirm(LIST, "owner", now="2026-11-01T12:00:00-04:00"))
        self.assertTrue(ok, msg)
        self.assertEqual(kept, ["D1", "D2"])
        self.assertIn("2 kept, 1 struck", msg)

    def test_a_tick_after_confirming_invalidates_it(self):
        text = pd.cmd_set(pd.cmd_confirm(LIST, "owner"), ["N1=on"])
        ok, msg, _ = pd.verify(text)
        self.assertFalse(ok)
        self.assertIn("changed since", msg)

    def test_a_reworded_item_after_confirming_invalidates_it(self):
        text = pd.cmd_confirm(LIST, "owner").replace("batch operations", "batch jobs")
        self.assertFalse(pd.verify(text)[0])

    def test_reconfirming_after_an_edit_passes(self):
        text = pd.cmd_set(pd.cmd_confirm(LIST, "owner"), ["D2=off"])
        ok, _, kept = pd.verify(pd.cmd_confirm(text, "owner"))
        self.assertTrue(ok)
        self.assertEqual(kept, ["D1"])

    def test_everything_struck_fails(self):
        text = pd.cmd_confirm(pd.cmd_set(LIST, ["D1=off", "D2=off"]), "owner")
        ok, msg, _ = pd.verify(text)
        self.assertFalse(ok)
        self.assertIn("nothing to test", msg)

    def test_text_outside_the_items_may_change(self):
        text = pd.cmd_confirm(LIST, "owner").replace("## Not asked", "## Not asked (the planner's reading)")
        self.assertTrue(pd.verify(text)[0])


class Set(unittest.TestCase):
    def test_toggles_only_the_named_items(self):
        out = pd.cmd_set(LIST, ["D1=off", "N1=on"])
        items, _ = pd.parse(out)
        self.assertEqual([k for k, _, _ in items], [False, True, True])

    def test_unknown_id_and_bad_state(self):
        with self.assertRaises(pd.Malformed):
            pd.cmd_set(LIST, ["Z9=on"])
        with self.assertRaises(pd.Malformed):
            pd.cmd_set(LIST, ["D1=yes"])

    def test_crlf_survives(self):
        crlf = LIST.replace("\n", "\r\n")
        out = pd.cmd_confirm(pd.cmd_set(crlf, ["N1=on"]), "owner")
        self.assertNotIn("\r\r", out)
        self.assertEqual(out.count("\n"), out.count("\r\n"))
        self.assertTrue(pd.verify(out)[0])


class CommandLine(unittest.TestCase):
    def test_verify_exit_codes(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "DONE.md")
            pd.write(p, LIST)
            self.assertEqual(pd.main(["verify", p]), 1)
            self.assertEqual(pd.main(["confirm", p, "--by", "owner"]), 0)
            self.assertEqual(pd.main(["verify", p]), 0)
            pd.write(p, "# nothing\n")
            self.assertEqual(pd.main(["verify", p]), 2)

    def test_confirm_rejects_an_odd_name(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "DONE.md")
            pd.write(p, LIST)
            self.assertEqual(pd.main(["confirm", p, "--by", "a b <!--"]), 2)
            self.assertFalse(pd.parse(pd.read(p))[1])


class PackBuilder(unittest.TestCase):
    """make-planner-packs.py --confirmed: only a confirmed, unchanged list reaches the pack."""

    def setUp(self):
        import importlib.util
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "desktop", "scripts", "make-planner-packs.py")
        spec = importlib.util.spec_from_file_location("make_planner_packs", path)
        self.mpp = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.mpp)
        self.tmp = tempfile.TemporaryDirectory()
        self.src = os.path.join(self.tmp.name, "src")
        self.out = os.path.join(self.tmp.name, "pack")
        os.makedirs(os.path.join(self.src, "t-1", "1"))

    def tearDown(self):
        self.tmp.cleanup()

    def put(self, text):
        pd.write(os.path.join(self.src, "t-1", "1", "DONE.md"), text)

    def copied(self):
        return os.path.isfile(os.path.join(self.out, "planner", "t-1", "1", "DONE.md"))

    def test_a_confirmed_list_is_copied(self):
        self.put(pd.cmd_confirm(LIST, "owner"))
        self.mpp.copy_confirmed(self.src, self.out, "t-1")
        self.assertTrue(self.copied())

    def test_an_unconfirmed_list_is_refused(self):
        self.put(LIST)
        with self.assertRaises(SystemExit):
            self.mpp.copy_confirmed(self.src, self.out, "t-1")
        self.assertFalse(self.copied())

    def test_a_list_changed_after_confirming_is_refused(self):
        self.put(pd.cmd_set(pd.cmd_confirm(LIST, "owner"), ["N1=on"]))
        with self.assertRaises(SystemExit):
            self.mpp.copy_confirmed(self.src, self.out, "t-1")
        self.assertFalse(self.copied())

    def test_no_list_at_all_is_refused(self):
        with self.assertRaises(SystemExit):
            self.mpp.copy_confirmed(self.src, self.out, "t-2")


if __name__ == "__main__":
    unittest.main(verbosity=2)
