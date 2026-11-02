"""Unit tests for desktop/scripts/planner_done.py, experiment 3's confirmation checkpoint (DONE.md version 2:
Gate / Ideal / Out of scope, items with sub-items, a Size line).

Run:  python3 -I tests/test_planner_done.py   (standard library only; also run by tests/test-planner-done.ps1)
"""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "desktop", "scripts"))
import planner_done as pd  # noqa: E402

LIST = """# Done: real-02

Size: 1-minute read

## Gate
- [x] G1: AGENTS.md documents what was added since it was last updated
  - [x] G1.1: HEALTH_PORT and DISCORD_ALERT_WEBHOOK_URL in Environment
  - [x] G1.2: the health server, alerts, audit log, custom IDs and batch operations
- [x] G2: nothing that was there is lost

## Ideal
- [x] I1: the CI description mentions npm audit
- [ ] I2: mentions Dependabot

## Out of scope
- [ ] O1: a CLAUDE.md pointer file
"""

V1 = """# Done: real-02

## Must do
- [x] D1: documents HEALTH_PORT
## Must keep
- [x] K1: keeps the sections
## Could do (not clearly asked)
- [ ] C1: mentions Dependabot
"""


def ids(items, **where):
    return [it.id for it in items if all(getattr(it, k) == v for k, v in where.items())]


class Parse(unittest.TestCase):
    def test_tiers_size_and_parents(self):
        d = pd.parse(LIST)
        self.assertEqual(d.size, "1-minute read")
        self.assertEqual(ids(d.items, tier="gate"), ["G1", "G1.1", "G1.2", "G2"])
        self.assertEqual(ids(d.items, tier="ideal"), ["I1", "I2"])
        self.assertEqual(ids(d.items, tier="out"), ["O1"])
        self.assertEqual(ids(d.items, kept=True), ["G1", "G1.1", "G1.2", "G2", "I1"])

    def test_version_1_sections_map_onto_tiers(self):
        d = pd.parse(V1)
        self.assertEqual([(it.id, it.tier) for it in d.items], [("D1", "gate"), ("K1", "gate"), ("C1", "out")])

    def test_a_struck_parent_strikes_its_sub_items(self):
        d = pd.parse(pd.cmd_set(LIST, ["G1=off"]))
        self.assertEqual(ids(d.items, kept=True), ["G2", "I1"])
        g11 = [it for it in d.items if it.id == "G1.1"][0]
        self.assertTrue(g11.ticked)   # its own tick is left alone ...
        self.assertFalse(g11.kept)    # ... but it is not kept

    def test_a_sub_item_without_its_parent_is_malformed(self):
        with self.assertRaises(pd.Malformed):
            pd.parse("## Gate\n- [x] G3.1: orphan\n")

    def test_a_sub_item_in_another_section_than_its_parent_is_malformed(self):
        with self.assertRaises(pd.Malformed):
            pd.parse("## Gate\n- [x] G1: a\n## Ideal\n- [x] G1.1: b\n")

    def test_a_tick_under_out_of_scope_is_malformed(self):
        with self.assertRaises(pd.Malformed):
            pd.parse(LIST.replace("- [ ] O1:", "- [x] O1:"))
        with self.assertRaises(pd.Malformed):
            pd.cmd_set(LIST, ["O1=on"])

    def test_duplicate_id_is_malformed(self):
        with self.assertRaises(pd.Malformed):
            pd.parse(LIST + "- [ ] I1: again\n")

    def test_a_checklist_line_in_another_shape_is_malformed(self):
        # Not silently ignored: an item the parser skipped would be neither kept nor struck.
        for bad in ("- [x] documents it, no id\n", "* [x] G3: star bullet\n", "- [v] G3: odd mark\n", "- [x] g3: lower case\n"):
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

    def test_confirmed_passes_and_lists_the_kept_ids_by_tier(self):
        ok, msg, kept = pd.verify(pd.cmd_confirm(LIST, "owner", now="2026-11-01T12:00:00-04:00"))
        self.assertTrue(ok, msg)
        self.assertEqual(kept, {"gate": ["G1", "G1.1", "G1.2", "G2"], "ideal": ["I1"]})
        self.assertIn("gate 4, ideal 1 kept, 1 struck", msg)

    def test_a_tick_after_confirming_invalidates_it(self):
        ok, msg, _ = pd.verify(pd.cmd_set(pd.cmd_confirm(LIST, "owner"), ["I2=on"]))
        self.assertFalse(ok)
        self.assertIn("changed since", msg)

    def test_a_reworded_item_after_confirming_invalidates_it(self):
        self.assertFalse(pd.verify(pd.cmd_confirm(LIST, "owner").replace("batch operations", "batch jobs"))[0])

    def test_moving_an_item_between_sections_after_confirming_invalidates_it(self):
        text = pd.cmd_confirm(LIST, "owner")
        moved = text.replace("- [x] I1: the CI description mentions npm audit\n", "").replace(
            "- [x] G2: nothing that was there is lost\n", "- [x] G2: nothing that was there is lost\n- [x] I1: the CI description mentions npm audit\n")
        self.assertEqual(pd.parse(moved).items[4].tier, "gate")
        self.assertFalse(pd.verify(moved)[0])

    def test_reconfirming_after_an_edit_passes(self):
        text = pd.cmd_set(pd.cmd_confirm(LIST, "owner"), ["G1.2=off"])
        ok, _, kept = pd.verify(pd.cmd_confirm(text, "owner"))
        self.assertTrue(ok)
        self.assertEqual(kept["gate"], ["G1", "G1.1", "G2"])

    def test_no_gate_item_kept_fails(self):
        text = pd.cmd_confirm(pd.cmd_set(LIST, ["G1=off", "G2=off"]), "owner")
        ok, msg, _ = pd.verify(text)
        self.assertFalse(ok)
        self.assertIn("no Gate item", msg)

    def test_text_outside_the_items_may_change(self):
        text = pd.cmd_confirm(LIST, "owner").replace("# Done: real-02", "# Done: real-02 (owner reviewed)")
        self.assertTrue(pd.verify(text)[0])


class Set(unittest.TestCase):
    def test_toggles_only_the_named_items(self):
        d = pd.parse(pd.cmd_set(LIST, ["G2=off", "I2=on"]))
        self.assertEqual([it.ticked for it in d.items], [True, True, True, False, True, True, False])

    def test_unknown_id_and_bad_state(self):
        with self.assertRaises(pd.Malformed):
            pd.cmd_set(LIST, ["Z9=on"])
        with self.assertRaises(pd.Malformed):
            pd.cmd_set(LIST, ["G1=yes"])

    def test_sub_item_indentation_survives(self):
        self.assertIn("  - [ ] G1.1:", pd.cmd_set(LIST, ["G1.1=off"]))

    def test_crlf_survives(self):
        crlf = LIST.replace("\n", "\r\n")
        out = pd.cmd_confirm(pd.cmd_set(crlf, ["I2=on"]), "owner")
        self.assertNotIn("\r\r", out)
        self.assertEqual(out.count("\n"), out.count("\r\n"))
        self.assertTrue(pd.verify(out)[0])


class Show(unittest.TestCase):
    def test_groups_by_tier_and_marks_a_ticked_child_of_a_struck_parent(self):
        out = pd.show(pd.cmd_set(LIST, ["G1=off"]))
        self.assertIn("Size: 1-minute read", out)
        self.assertLess(out.index("Gate"), out.index("Ideal"))
        self.assertIn("[-] G1.1", out)


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
            self.assertFalse(pd.parse(pd.read(p)).confirmations)


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
        self.put(pd.cmd_set(pd.cmd_confirm(LIST, "owner"), ["I2=on"]))
        with self.assertRaises(SystemExit):
            self.mpp.copy_confirmed(self.src, self.out, "t-1")
        self.assertFalse(self.copied())

    def test_no_list_at_all_is_refused(self):
        with self.assertRaises(SystemExit):
            self.mpp.copy_confirmed(self.src, self.out, "t-2")


if __name__ == "__main__":
    unittest.main(verbosity=2)
