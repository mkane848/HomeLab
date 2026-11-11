#!/usr/bin/env python3
"""Push the household chat's tool code and system prompt from this repo into Open WebUI.

Runbook: docs/household/phase2-chat.md -> "Updating the tool and prompt". Replaces pasting both by hand after every
merge. Run it on the server after `git pull`:

  python3 -I server/household/openwebui_push.py            # dry run: says what differs, writes nothing
  python3 -I server/household/openwebui_push.py --apply    # writes

It changes exactly two things, through Open WebUI's own API (the same calls its editor makes):
  - the tool's code (POST /api/v1/tools/id/<tool>/update). Its Valves, the Grocy key among them, are kept;
  - the workspace model's system prompt (POST /api/v1/models/model/update). Every other model setting is sent back
    as Open WebUI returned it: base model, tools, capabilities, access.
Nothing else is touched, and each is written only when it differs from the repo's file.

The API key is an Open WebUI key the owner made (Settings > Account > API keys), kept in a file readable only by them
(default ~/.config/household/openwebui-api-key) or in OPENWEBUI_API_KEY. It is never printed.
Standard library only.
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_KEY_FILE = os.path.expanduser("~/.config/household/openwebui-api-key")
DEFAULT_TOOL = "grocy_household_tracker"
DEFAULT_MODEL = "household"


class PushError(Exception):
    pass


def read_key(path):
    key = os.environ.get("OPENWEBUI_API_KEY", "").strip()
    if key:
        return key
    try:
        with open(path, encoding="utf-8") as f:
            key = f.read().strip()
    except OSError:
        raise PushError(f"no API key: set OPENWEBUI_API_KEY or put it in {path} (see the runbook)")
    if not key:
        raise PushError(f"the key file {path} is empty")
    return key


def make_call(base, key, opener=urllib.request.urlopen):
    def call(method, path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(base.rstrip("/") + "/api/v1" + path, data=data, method=method)
        req.add_header("Authorization", "Bearer " + key)
        req.add_header("Accept", "application/json")
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with opener(req, timeout=60) as r:
                return json.loads(r.read() or b"null")
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", "replace")[:300]
            raise PushError(f"{method} {path}: HTTP {e.code} {detail}")
        except urllib.error.URLError as e:
            raise PushError(f"{method} {path}: {e.reason}")
    return call


def version_of(code):
    for line in code.splitlines()[:12]:
        if line.strip().startswith("version:"):
            return line.split(":", 1)[1].strip()
    return "?"


def push(call, tool_id, model_id, tool_code, prompt, apply):
    """Returns the lines to print. Writes only with apply, and only what differs."""
    out = []
    tool = call("GET", f"/tools/id/{tool_id}")
    if not tool:
        raise PushError(f"Open WebUI has no tool '{tool_id}'")
    have, want = version_of(tool.get("content", "")), version_of(tool_code)
    if tool.get("content") == tool_code:
        out.append(f"tool {tool_id}: up to date ({have})")
    elif not apply:
        out.append(f"tool {tool_id}: would update {have} -> {want}")
    else:
        call("POST", f"/tools/id/{tool_id}/update",
             {"id": tool_id, "name": tool["name"], "meta": tool.get("meta") or {}, "content": tool_code})
        now = version_of((call("GET", f"/tools/id/{tool_id}") or {}).get("content", ""))
        if now != want:
            raise PushError(f"tool {tool_id}: wrote {want} but Open WebUI now reports {now}")
        out.append(f"tool {tool_id}: updated {have} -> {now}")

    model = call("GET", f"/models/model?id={model_id}")
    if not model:
        raise PushError(f"Open WebUI has no model '{model_id}'")
    params = dict(model.get("params") or {})
    if (params.get("system") or "").strip() == prompt.strip():
        out.append(f"model {model_id}: prompt up to date")
    elif not apply:
        out.append(f"model {model_id}: would replace the system prompt")
    else:
        params["system"] = prompt
        body = {k: model[k] for k in ("id", "base_model_id", "name", "meta", "access_grants", "is_active") if k in model}
        body["params"] = params
        call("POST", "/models/model/update", body)
        after = call("GET", f"/models/model?id={model_id}") or {}
        if ((after.get("params") or {}).get("system") or "").strip() != prompt.strip():
            raise PushError(f"model {model_id}: the prompt did not take")
        if after.get("base_model_id") != model.get("base_model_id"):
            raise PushError(f"model {model_id}: its base model changed; fix it in Workspace > Models")
        out.append(f"model {model_id}: prompt replaced")
    if not apply:
        out.append("Dry run: nothing written. Run again with --apply.")
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--url", default="http://localhost:3000")
    ap.add_argument("--key-file", default=DEFAULT_KEY_FILE)
    ap.add_argument("--tool", default=DEFAULT_TOOL)
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--apply", action="store_true")
    a = ap.parse_args(argv)
    try:
        with open(os.path.join(HERE, "openwebui_grocy_tool.py"), encoding="utf-8") as f:
            code = f.read()
        with open(os.path.join(HERE, "openwebui-household-prompt.md"), encoding="utf-8") as f:
            prompt = f.read()
        for line in push(make_call(a.url, read_key(a.key_file)), a.tool, a.model, code, prompt, a.apply):
            print(line)
    except PushError as e:
        print(f"openwebui_push: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
