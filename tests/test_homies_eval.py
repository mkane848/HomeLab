"""Unit tests for tests/homies_eval.py (docs/homies.md -> "Aiming small"): its scoring, against scripted stand-in
models instead of a real one. A model that does everything right must pass every case; each kind of wrong behaviour
must fail the check meant to catch it, and only that one. Synthetic data only.

Run:  python3 -m unittest -v tests/test_homies_eval.py   (standard library only)
"""
import io
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import homies_eval as ev  # noqa: E402

d = ev.d


def plan_for(text):
    """The tool call a careful model makes for each user turn (None: answer without a tool)."""
    t = text.lower()
    if "need to book" in t:
        return "appointments_due", {"days": 30}
    if "coming up" in t:
        return "upcoming", {"person": "Alex"}
    if "last at the dentist" in t:
        return "last_visit", {"person": "Sam", "kind": "dentist"}
    if "free" in t:
        return "check_clash", {"date": d(5)}
    if "alex went to the dentist" in t:
        return "log_visit", {"person": "Alex", "kind": "dentist", "date": d(-1), "confirm": False}
    if "record sam" in t:
        return "log_visit", {"person": "Sam", "kind": "dentist", "date": d(3), "confirm": False}
    if "what can we make" in t:
        return "what_can_we_make", {}
    if "meal plan this week" in t:
        return "week_plan", {}
    if "last have tacos" in t:
        return "last_had", {"recipe": "Tacos"}
    if "put tacos" in t:
        return "plan_meal", {"recipe": "Tacos", "date": "tomorrow", "confirm": False}
    if "from aldi" in t:
        return "shopping_for", {"store": STORE["aldi"], "confirm": False}
    return None


STORE = {"aldi": "Aldi"}  # a test can point the careful model at the wrong store


class Scripted:
    """A stand-in model. good: calls the right tool, confirms only on the user's OK, answers with the tool's words.
    The flags each break one behaviour."""

    def __init__(self, wrong_tool=False, wrong_args=False, leak=False, confirm_early=False, no_answer=False,
                 bad_json=False):
        self.f = dict(wrong_tool=wrong_tool, wrong_args=wrong_args, leak=leak, confirm_early=confirm_early,
                      no_answer=no_answer, bad_json=bad_json)
        self.n = 0

    def __call__(self, model, messages, tools):
        self.n += 1
        last = messages[-1]
        if last["role"] == "tool":
            text = last["content"]
            if self.f["leak"]:
                text += " Also: Dinner with friends at 18:00."
            return {"content": "" if self.f["no_answer"] else text}
        users = [m["content"] for m in messages if m["role"] == "user"]
        plan = plan_for(users[0])
        if plan is None:
            return {"content": "I do not know."}
        name, args = plan[0], dict(plan[1])
        if len(users) > 1 or self.f["confirm_early"]:
            args["confirm"] = True
        if self.f["wrong_tool"]:
            name = "upcoming" if name != "upcoming" else "appointments_due"
        if self.f["wrong_args"]:
            args = {k: ("Nobody" if k == "person" else "1999-01-01" if k == "date" else v) for k, v in args.items()}
        raw = "{not json" if self.f["bad_json"] else json.dumps(args)
        return {"content": "", "tool_calls": [{"id": f"c{self.n}", "type": "function",
                                               "function": {"name": name, "arguments": raw}}]}


PROMPT = "You are Health."
CASES = {c["id"]: c for c in ev.health_cases()}


def score(model, case_id):
    return ev.run_case(model, "stand-in", CASES[case_id], PROMPT)


class ToolSpecs(unittest.TestCase):
    def test_specs_from_the_real_tool(self):
        specs = {s["function"]["name"]: s["function"] for s in ev.tool_specs(ev.health.Tools())}
        self.assertEqual(set(specs), {"appointments_due", "upcoming", "last_visit", "log_visit", "check_clash",
                                      "add_kind"})
        lv = specs["log_visit"]["parameters"]
        self.assertNotIn("__messages__", lv["properties"])
        self.assertEqual(lv["required"], ["person", "kind", "date"])
        self.assertEqual(lv["properties"]["confirm"]["type"], "boolean")
        self.assertEqual(specs["appointments_due"]["parameters"]["properties"]["days"]["type"], "integer")
        self.assertIn("YYYY-MM-DD", specs["check_clash"]["parameters"]["properties"]["date"]["description"])
        self.assertNotIn(":param", specs["upcoming"]["description"])


class GoodModel(unittest.TestCase):
    def test_every_case_passes(self):
        for cid in CASES:
            with self.subTest(case=cid):
                row = score(Scripted(), cid)
                self.assertTrue(row["pass"], row)

    def test_the_write_lands_once_after_the_ok(self):
        row = score(Scripted(), "log_visit")
        self.assertTrue(row["write"])
        self.assertEqual(row["rounds"], 4)


class BadModels(unittest.TestCase):
    def failed(self, model, cid):
        row = score(model, cid)
        self.assertFalse(row["pass"], row)
        return {k for k in ("tool", "args", "answer", "private", "write") if not row[k]}, row

    def test_wrong_tool(self):
        bad, _ = self.failed(Scripted(wrong_tool=True), "last_visit")
        self.assertIn("tool", bad)

    def test_wrong_args(self):
        bad, _ = self.failed(Scripted(wrong_args=True), "last_visit")
        self.assertEqual(bad, {"args", "answer"})  # the tool asks which person is meant; the date never comes back

    def test_naming_a_private_event(self):
        bad, _ = self.failed(Scripted(leak=True), "clash")
        self.assertEqual(bad, {"private"})

    def test_no_final_answer(self):
        bad, _ = self.failed(Scripted(no_answer=True), "due")
        self.assertEqual(bad, {"answer"})

    def test_bad_json_arguments(self):
        bad, row = self.failed(Scripted(bad_json=True), "due")
        self.assertIn("args", bad)
        self.assertIn("bad arguments", row["note"])

    def test_a_write_before_the_users_ok_fails_the_write_check(self):
        case = dict(CASES["log_visit"], turns=[f"OK, log that Alex went to the dentist yesterday, {d(-1)}.",
                                               "Thanks."])
        orig = plan_for
        try:
            globals()["plan_for"] = lambda t: ("log_visit", {"person": "Alex", "kind": "dentist", "date": d(-1)}) \
                if "alex" in t.lower() else orig(t)
            row = ev.run_case(Scripted(confirm_early=True), "stand-in", case, PROMPT)
        finally:
            globals()["plan_for"] = orig
        self.assertFalse(row["write"], row)

    def test_no_write_when_none_is_expected(self):
        row = score(Scripted(), "future_refused")  # the tool refuses even after "OK"
        self.assertTrue(row["write"], row)


MEALS = {c["id"]: c for c in ev.meals_cases()}
MEALS_PROMPT = "You are Meals."


class MealsCases(unittest.TestCase):
    def test_a_careful_model_passes_every_meals_case(self):
        for cid, case in MEALS.items():
            with self.subTest(case=cid):
                row = ev.run_case(Scripted(), "stand-in", case, MEALS_PROMPT, homie="meals")
                self.assertTrue(row["pass"], row)

    def test_the_wrong_store_fails_args_answer_and_write(self):
        STORE["aldi"] = "Costco"
        try:
            row = ev.run_case(Scripted(), "stand-in", MEALS["shopping"], MEALS_PROMPT, homie="meals")
        finally:
            STORE["aldi"] = "Aldi"
        self.assertFalse(row["pass"])
        self.assertEqual({k for k in ("tool", "args", "answer", "private", "write") if not row[k]},
                         {"args", "answer", "write"})

    def test_every_expected_write_must_happen(self):
        extra = ("/api/stock/shoppinglist/add-product",
                 {"product_id": 6, "list_id": 1, "product_amount": 1, "note": "Meals: Fried rice"})
        case = dict(MEALS["shopping"], write=MEALS["shopping"]["write"] + [extra])
        row = ev.run_case(Scripted(), "stand-in", case, MEALS_PROMPT, homie="meals")
        self.assertFalse(row["write"], row)  # two of the three expected writes happened: not enough

    def test_meals_tools_seen_by_the_model(self):
        specs = {s["function"]["name"] for s in ev.tool_specs(ev.meals.Tools())}
        self.assertEqual(specs, {"what_can_we_make", "week_plan", "plan_meal", "shopping_for", "last_had",
                                 "add_recipe"})


class AnswerChecks(unittest.TestCase):
    def test_dates_in_words_or_iso(self):
        for text in ("2026-05-10", "on May 10", "May 10th, 2026", "10 May", "the 10th of May"):
            with self.subTest(text=text):
                self.assertTrue(ev.has_date(text, "2026-05-10"))
        for text in ("May 1", "2026-05-01", "June 10", "May 100"):
            with self.subTest(text=text):
                self.assertFalse(ev.has_date(text, "2026-05-10"))


class Runner(unittest.TestCase):
    def test_tsv_rows_and_stop_at_first_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "r", "homies-eval.tsv")
            models = {"small": Scripted(wrong_tool=True), "medium": Scripted(), "large": Scripted()}

            def chat(model, messages, tools):
                return models[model](model, messages, tools)

            log = io.StringIO()
            summary = ev.run(chat, ["small", "medium", "large"], "health", "testhost", stop_at_first_pass=True,
                             out=out, log=lambda s: log.write(s + "\n"))
            self.assertEqual([m for m, _, _ in summary], ["small", "medium"])
            self.assertEqual(summary[1][1:], (len(CASES), len(CASES)))
            with open(out, encoding="utf-8") as f:
                rows = [line.rstrip("\n").split("\t") for line in f]
            self.assertEqual(rows[0], ev.COLUMNS)
            self.assertEqual(len(rows), 1 + 2 * len(CASES))
            self.assertTrue(all(r[1] == "testhost" and r[3] == "health" for r in rows[1:]))
            self.assertIn("stopping: medium", log.getvalue())

    def test_http_chat_sends_tools_and_key(self):
        seen = {}

        class R:
            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

            def read(self):
                return b'{"choices": [{"message": {"content": "hi"}}]}'

        def opener(req, timeout):
            seen["url"], seen["auth"], seen["body"] = req.full_url, req.get_header("Authorization"), json.loads(req.data)
            return R()

        chat = ev.make_chat("http://e:8090/", "synthetic-key", opener=opener)
        self.assertEqual(chat("m", [{"role": "user", "content": "x"}], [{"t": 1}]), {"content": "hi"})
        self.assertEqual(seen["url"], "http://e:8090/v1/chat/completions")
        self.assertEqual(seen["auth"], "Bearer synthetic-key")
        self.assertEqual((seen["body"]["model"], seen["body"]["tools"], seen["body"]["temperature"]), ("m", [{"t": 1}], 0))


if __name__ == "__main__":
    unittest.main()
