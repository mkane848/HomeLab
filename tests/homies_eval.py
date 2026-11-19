#!/usr/bin/env python3
"""Homies small-model eval: which model is the smallest that answers a Homie's questions right? (docs/homies.md ->
"Aiming small").

It sends each question, with the Homie's real tool definitions and prompt, to an OpenAI-compatible endpoint (the
fleet's llama-server), runs every tool call the model makes against the same fake Grocy and fake calendar feeds the
unit tests use (tests/test_openwebui_health_tool.py), and scores the question:

  tool     the model called the expected tool
  args     with the expected arguments
  answer   its final answer holds the facts the tools gave
  private  it named nothing from outside the area (calendar events that are not appointments)
  write    it wrote only after the user's OK, and wrote exactly the expected record

A question passes when all five do. Synthetic data only; the fakes start fresh for every question.

  python3 -I tests/homies_eval.py --url http://localhost:8090 --model qwen3:0.6b --model qwen3:1.7b \\
      --model qwen3:4b --model qwen3:8b --host server
  python3 -I tests/homies_eval.py ... --stop-at-first-pass     # the ladder: stop at the smallest that passes all

Rows are appended to tests/results/homies-eval.tsv (date, host, model, homie, case, rep, pass, the five checks,
seconds, rounds, note). The key for llama-server comes from LLAMACPP_API_KEY or ~/.config/llamacpp/api-key, as in
server/household/openwebui_push.py. Standard library only. Compare models by case, paired (docs/methodology.md).
"""
import argparse
import asyncio
import datetime as dt
import inspect
import json
import os
import re
import sys
import time
import typing
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "server", "household"))

import test_openwebui_health_tool as fx  # noqa: E402  (stubs pydantic if needed, then imports the tool)
import test_openwebui_meals_tool as mfx  # noqa: E402
import openwebui_push  # noqa: E402

health = fx.tool
meals = mfx.tool
DEFAULT_OUT = os.path.join(HERE, "results", "homies-eval.tsv")
COLUMNS = ["date", "host", "model", "homie", "case", "rep", "pass", "tool", "args", "answer", "private", "write",
           "seconds", "rounds", "note"]
MAX_ROUNDS = 6
PRIVATE = ("Dinner", "friends", "Birthday party", "Work trip", "Holiday")  # non-appointment events in the fake feeds
JSON_TYPES = {int: "integer", str: "string", bool: "boolean", float: "number"}


class EvalError(Exception):
    pass


# ---------------------------------------------------------------- tool definitions, from the tool itself

def tool_specs(tools_obj):
    """OpenAI tool definitions for every public async method, as Open WebUI builds them: the docstring above the first
    :param is the description, each :param line describes its parameter, type hints give the types. Parameters with
    two leading underscores are injected by Open WebUI and not shown to the model."""
    specs = []
    for name, fn in inspect.getmembers(type(tools_obj), inspect.iscoroutinefunction):
        if name.startswith("_"):
            continue
        doc = inspect.getdoc(fn) or ""
        desc = doc.split(":param", 1)[0].strip()
        pdocs = dict(re.findall(r":param (\w+): (.+)", doc))
        hints = typing.get_type_hints(fn)
        props, required = {}, []
        for p in list(inspect.signature(fn).parameters.values())[1:]:
            if p.name.startswith("__"):
                continue
            props[p.name] = {"type": JSON_TYPES.get(hints.get(p.name, str), "string"),
                             "description": pdocs.get(p.name, "")}
            if p.default is inspect.Parameter.empty:
                required.append(p.name)
        specs.append({"type": "function", "function": {"name": name, "description": desc, "parameters": {
            "type": "object", "properties": props, "required": required}}})
    return specs


# ---------------------------------------------------------------- the cases (Health)

def d(days):
    return fx.d(days).isoformat()


def same(a, b):
    return str(a or "").strip().lower() == str(b or "").strip().lower()


def has_date(text, iso):
    """The answer names this date: ISO, or month name and day (e.g. 'May 10', '10 May')."""
    day = dt.date.fromisoformat(iso)
    month = day.strftime("%B")
    pats = [re.escape(iso), rf"\b{month[:3]}\w*\.?\s+0?{day.day}(?!\d)",
            rf"(?<!\d)0?{day.day}(st|nd|rd|th)?\s+(of\s+)?{month[:3]}"]
    return any(re.search(p, text, re.I) for p in pats)


def health_cases():
    """[{id, turns: [user text...], tool, args(call) -> bool, answer(text) -> bool, write: None | (path, body) | ()}]
    write None: no write expected or allowed; a tuple: exactly that write, and only after the last turn's OK;
    () : no write allowed even though the user said OK (the tool must refuse)."""
    return [
        {"id": "due", "turns": ["Which appointments do we need to book in the next 30 days?"],
         "tool": "appointments_due", "args": lambda a: int(a.get("days", 30)) >= 14,
         "answer": lambda t: re.search(r"alex", t, re.I) and re.search(r"sam", t, re.I) and re.search(r"dentist", t, re.I),
         "write": None},
        {"id": "upcoming", "turns": ["What appointments does Alex have coming up?"],
         "tool": "upcoming", "args": lambda a: same(a.get("person"), "alex"),
         "answer": lambda t: re.search(r"dentist", t, re.I) and re.search(r"therapy", t, re.I),
         "write": None},
        {"id": "last_visit", "turns": ["When was Sam last at the dentist?"],
         "tool": "last_visit", "args": lambda a: same(a.get("person"), "sam") and same(a.get("kind"), "dentist"),
         "answer": lambda t: has_date(t, "2026-05-10"),
         "write": None},
        {"id": "clash", "turns": [f"Is {d(5)} free, or is something already on the calendar?"],
         "tool": "check_clash", "args": lambda a: a.get("date") == d(5),
         "answer": lambda t: re.search(r"dentist", t, re.I) and re.search(r"busy|something|other", t, re.I),
         "write": None},
        {"id": "log_visit", "turns": [f"Alex went to the dentist yesterday, {d(-1)}. Please record it.", "Yes, log it."],
         "tool": "log_visit", "args": lambda a: same(a.get("person"), "alex") and same(a.get("kind"), "dentist")
         and a.get("date") == d(-1),
         "answer": lambda t: re.search(r"record|logged|saved|done", t, re.I),
         "write": ("/api/chores/40/execute", {"tracked_time": d(-1) + " 12:00:00"})},
        {"id": "future_refused", "turns": [f"Record Sam's dentist visit on {d(3)}.", "OK"],
         "tool": "log_visit", "args": lambda a: same(a.get("person"), "sam") and a.get("date") == d(3),
         "answer": lambda t: re.search(r"future|not yet|hasn.t|can.t|cannot|after", t, re.I),
         "write": ()},
    ]


def meals_cases():
    """Meals' questions, against the fake Grocy of tests/test_openwebui_meals_tool.py: Tacos can be made now, the
    week holds Chicken and rice and Fried rice, Aldi's shopping is an onion and two tortillas, Tacos was last planned
    seven days ago. Same fields as health_cases; write may also be a list of writes, in order."""
    md = mfx.d
    return [
        {"id": "tonight", "turns": ["What can we make for dinner tonight with what we have?"],
         "tool": "what_can_we_make", "args": lambda a: True,
         "answer": lambda t: re.search(r"tacos", t, re.I),
         "write": None},
        {"id": "week", "turns": ["What's on the meal plan this week?"],
         "tool": "week_plan", "args": lambda a: a.get("start", "") in ("", "today", mfx.TODAY.isoformat()),
         "answer": lambda t: re.search(r"chicken and rice", t, re.I) and re.search(r"fried rice", t, re.I),
         "write": None},
        {"id": "last_had", "turns": ["When did we last have tacos?"],
         "tool": "last_had", "args": lambda a: same(a.get("recipe"), "tacos"),
         "answer": lambda t: has_date(t, md(-7)) or re.search(r"\b7 days\b|a week ago|seven days", t, re.I),
         "write": None},
        {"id": "plan", "turns": ["Put tacos on the meal plan for tomorrow.", "OK, plan it."],
         "tool": "plan_meal", "args": lambda a: same(a.get("recipe"), "tacos")
         and a.get("date") in ("tomorrow", md(1)),
         "answer": lambda t: re.search(r"planned|added|done|scheduled", t, re.I),
         "write": ("/api/objects/meal_plan", {"day": md(1), "type": "recipe", "recipe_id": 10,
                                              "recipe_servings": 4})},
        {"id": "shopping", "turns": ["What do we need from Aldi for this week's meals?", "Yes, add them."],
         "tool": "shopping_for", "args": lambda a: same(a.get("store"), "aldi"),
         "answer": lambda t: re.search(r"onion", t, re.I) and re.search(r"tortilla", t, re.I),
         "write": [("/api/stock/shoppinglist/add-product",
                    {"product_id": 1, "list_id": 1, "product_amount": 1, "note": "Meals: Fried rice"}),
                   ("/api/stock/shoppinglist/add-product",
                    {"product_id": 5, "list_id": 1, "product_amount": 2, "note": "Meals: Fried rice"})]},
    ]


def health_setup():
    fake = fx.Fake()
    t = health.Tools()
    v = t.valves
    v.grocy_url, v.api_key = fake.url, fx.KEY
    v.feed_1_person, v.feed_1_url = "Alex", fake.url + "/feed/a.ics"
    v.feed_2_person, v.feed_2_url = "Sam", fake.url + "/feed/b.ics"
    return t, fake


def meals_setup():
    fake = mfx.Fake()
    t = meals.Tools()
    t.valves.grocy_url, t.valves.api_key = fake.url, mfx.KEY
    return t, fake


HOUSEHOLD = os.path.join(ROOT, "server", "household")
HOMIES = {
    "health": {"cases": health_cases, "setup": health_setup, "private": PRIVATE,
               "prompt": os.path.join(HOUSEHOLD, "openwebui-health-prompt.md")},
    "meals": {"cases": meals_cases, "setup": meals_setup, "private": (),
              "prompt": os.path.join(HOUSEHOLD, "openwebui-meals-prompt.md")},
}


# ---------------------------------------------------------------- the model

def make_chat(url, key, opener=urllib.request.urlopen, timeout=600):
    def chat(model, messages, tools):
        body = json.dumps({"model": model, "messages": messages, "tools": tools, "tool_choice": "auto",
                           "temperature": 0}).encode()
        req = urllib.request.Request(url.rstrip("/") + "/v1/chat/completions", data=body, method="POST",
                                     headers={"Content-Type": "application/json"})
        if key:
            req.add_header("Authorization", "Bearer " + key)
        try:
            with opener(req, timeout=timeout) as r:
                return json.loads(r.read())["choices"][0]["message"]
        except urllib.error.HTTPError as e:
            raise EvalError(f"HTTP {e.code} from {url}" + (" (no or wrong API key)" if e.code == 401 else ""))
        except (urllib.error.URLError, OSError) as e:
            raise EvalError(f"cannot reach {url}: {getattr(e, 'reason', e)}")
    return chat


# ---------------------------------------------------------------- one case

def run_case(chat, model, case, prompt, homie="health"):
    """Runs one case against fresh fakes. Returns the scored row (without date/host/model/rep)."""
    spec = HOMIES[homie]
    t, fake = spec["setup"]()
    try:
        tools = tool_specs(t)
        messages = [{"role": "system", "content": prompt}]
        calls, notes, rounds, final = [], [], 0, ""
        writes_before_last = None
        start = time.monotonic()
        for i, turn in enumerate(case["turns"]):
            if i == len(case["turns"]) - 1:
                writes_before_last = len(fake.writes())
            messages.append({"role": "user", "content": turn})
            for _ in range(MAX_ROUNDS):
                rounds += 1
                msg = chat(model, messages, tools)
                tcs = msg.get("tool_calls") or []
                messages.append({"role": "assistant", "content": msg.get("content") or "",
                                 **({"tool_calls": tcs} if tcs else {})})
                if not tcs:
                    final = msg.get("content") or ""
                    break
                for tc in tcs:
                    name = tc.get("function", {}).get("name", "")
                    try:
                        args = json.loads(tc.get("function", {}).get("arguments") or "{}")
                        if not isinstance(args, dict):
                            raise ValueError("not an object")
                    except ValueError:
                        args, result = None, "Could not do that: the arguments were not valid JSON."
                        notes.append(f"bad arguments for {name}")
                    if args is not None:
                        fn = getattr(t, name, None)
                        if name.startswith("_") or not inspect.iscoroutinefunction(fn):
                            result = f"Could not do that: there is no tool '{name}'."
                            notes.append(f"unknown tool {name}")
                        else:
                            if "__messages__" in inspect.signature(fn).parameters:
                                args["__messages__"] = [m for m in messages if m["role"] in ("user", "assistant")]
                            try:
                                result = asyncio.run(fn(**args))
                            except TypeError as e:
                                result = f"Could not do that: {e}"
                                notes.append(f"wrong parameters for {name}")
                            args.pop("__messages__", None)
                    calls.append((name, args))
                    messages.append({"role": "tool", "tool_call_id": tc.get("id", ""), "content": str(result)})
            else:
                notes.append(f"no final answer after {MAX_ROUNDS} rounds")
        seconds = time.monotonic() - start
        writes = [(p, b) for (_, p, b) in fake.writes()]
    finally:
        fake.close()

    named = [a for n, a in calls if n == case["tool"]]
    tool_ok = bool(named)
    args_ok = any(a is not None and bool(case["args"](a)) for a in named)
    answer_ok = bool(final) and bool(case["answer"](final))
    private_ok = not any(p.lower() in final.lower() for p in spec["private"])
    want = case["write"]
    if want is None or want == ():
        write_ok = writes == []
    else:
        write_ok = writes == (want if isinstance(want, list) else [want]) and writes_before_last == 0
    checks = [tool_ok, args_ok, answer_ok, private_ok, write_ok]
    return {"case": case["id"], "pass": all(checks), "tool": tool_ok, "args": args_ok, "answer": answer_ok,
            "private": private_ok, "write": write_ok, "seconds": f"{seconds:.1f}", "rounds": rounds,
            "note": "; ".join(notes)[:200]}


def run(chat, models, homie, host, reps=1, stop_at_first_pass=False, out=DEFAULT_OUT, log=print, today=None):
    spec = HOMIES[homie]
    with open(spec["prompt"], encoding="utf-8") as f:
        prompt = f.read()
    cases = spec["cases"]()
    date = (today or dt.date.today()).isoformat()
    summary = []
    new_file = not os.path.exists(out)
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    with open(out, "a", encoding="utf-8", newline="") as fh:
        if new_file:
            fh.write("\t".join(COLUMNS) + "\n")
        for model in models:
            passed = 0
            for rep in range(1, reps + 1):
                for case in cases:
                    row = {"date": date, "host": host, "model": model, "homie": homie, "rep": rep,
                           **run_case(chat, model, case, prompt, homie)}
                    passed += row["pass"]
                    fh.write("\t".join(str(row[c]).replace("\t", " ").replace("\n", " ") for c in COLUMNS) + "\n")
                    fh.flush()
                    log(f"{model}  {case['id']:<15} {'PASS' if row['pass'] else 'FAIL'}  "
                        + " ".join(f"{c}={'ok' if row[c] else 'NO'}" for c in ("tool", "args", "answer", "private", "write"))
                        + f"  {row['seconds']}s  {row['note']}")
            total = reps * len(cases)
            summary.append((model, passed, total))
            log(f"{model}: {passed}/{total} passed")
            if stop_at_first_pass and passed == total:
                log(f"stopping: {model} is the smallest that passed every case")
                break
    return summary


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--url", default="http://localhost:8090", help="OpenAI-compatible server (llama-server)")
    ap.add_argument("--model", action="append", required=True, help="model id; repeat, smallest first")
    ap.add_argument("--homie", choices=sorted(HOMIES), default="health", help="which Homie's questions")
    ap.add_argument("--host", default="", help="name of the machine serving the model, for the results")
    ap.add_argument("--reps", type=int, default=1)
    ap.add_argument("--stop-at-first-pass", action="store_true")
    ap.add_argument("--out", default=DEFAULT_OUT)
    a = ap.parse_args(argv)
    try:
        summary = run(make_chat(a.url, openwebui_push.engine_key()), a.model, a.homie, a.host or a.url, a.reps,
                      a.stop_at_first_pass, a.out)
    except EvalError as e:
        print(f"homies_eval: {e}", file=sys.stderr)
        return 1
    return 0 if summary and summary[-1][1] == summary[-1][2] else 2


if __name__ == "__main__":
    sys.exit(main())
