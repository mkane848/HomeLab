#!/usr/bin/env python3
"""Push a household chat agent's tool code and system prompt from this repo into Open WebUI.

Runbooks: docs/household/phase2-chat.md -> "Updating the tool and prompt" (the house agent) and
docs/household/health-agent.md (Health). Replaces pasting both by hand after every merge. Run it on the server after
`git pull`:

  python3 -I server/household/openwebui_push.py                         # dry run: says what differs, writes nothing
  python3 -I server/household/openwebui_push.py --apply                 # writes
  python3 -I server/household/openwebui_push.py --agent health --apply  # the same for Health

--agent picks the tool file, prompt file, tool id and model id (AGENTS below). For Health the workspace model's base
model must be one the server's own llama-server serves (--engine-url, default http://localhost:8090; its /v1/models,
with the fleet key from ~/.config/llamacpp/api-key when that file exists). Anything else, a cloud model among them, is
refused before anything is written: health stays on the household's own hardware.

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
DEFAULT_ENGINE = "http://localhost:8090"
ENGINE_KEY_FILE = os.path.expanduser("~/.config/llamacpp/api-key")
# agent -> tool file, prompt file, Open WebUI tool id, workspace model id, base model must be local
AGENTS = {
    "household": ("openwebui_grocy_tool.py", "openwebui-household-prompt.md", "grocy_household_tracker", "household",
                  False),
    "health": ("openwebui_health_tool.py", "openwebui-health-prompt.md", "health_appointments", "health", True),
}
DEFAULT_TOOL = AGENTS["household"][2]
DEFAULT_MODEL = AGENTS["household"][3]


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


def engine_key(path=ENGINE_KEY_FILE):
    """The fleet's llama-server key: the first line of the key file that is not blank or a # comment (as
    server/scripts/llamacpp-auth.sh reads it). None when there is no file or no key."""
    key = os.environ.get("LLAMACPP_API_KEY", "").strip()
    if key:
        return key
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    return line
    except OSError:
        pass
    return None


def served_models(engine_url, key=None, opener=urllib.request.urlopen):
    """The ids (and aliases) the llama-server at engine_url serves, from its /v1/models."""
    req = urllib.request.Request(engine_url.rstrip("/") + "/v1/models", headers={"Accept": "application/json"})
    if key:
        req.add_header("Authorization", "Bearer " + key)
    try:
        with opener(req, timeout=30) as r:
            data = json.loads(r.read() or b"null") or {}
    except urllib.error.HTTPError as e:
        hint = " (no or wrong API key: see docs/engine-api-keys.md)" if e.code == 401 else ""
        raise PushError(f"cannot list the local models at {engine_url}: HTTP {e.code}{hint}")
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise PushError(f"cannot list the local models at {engine_url}: {getattr(e, 'reason', e)}")
    ids = set()
    for m in data.get("data") or data.get("models") or []:
        for k in ("id", "model", "name"):
            if m.get(k):
                ids.add(m[k])
        ids.update(a for a in m.get("aliases") or [] if a)
    if not ids:
        raise PushError(f"the llama-server at {engine_url} lists no models")
    return ids


def version_of(code):
    for line in code.splitlines()[:12]:
        if line.strip().startswith("version:"):
            return line.split(":", 1)[1].strip()
    return "?"


def push(call, tool_id, model_id, tool_code, prompt, apply, local=None):
    """Returns the lines to print. Writes only with apply, and only what differs.
    local: None, or the set of model ids the server's llama-server serves; then the model's base model must be one of
    them, checked before anything is written."""
    out = []
    if local is not None:
        model = call("GET", f"/models/model?id={model_id}")
        if not model:
            raise PushError(f"Open WebUI has no model '{model_id}'")
        base = model.get("base_model_id")
        if base not in local:
            raise PushError(f"model {model_id}: its base model '{base}' is not served by the server's llama-server; "
                            "pick a local one in Workspace > Models. Nothing written.")
        out.append(f"model {model_id}: base model {base} is local")
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
        if local is not None and after.get("base_model_id") not in local:
            raise PushError(f"model {model_id}: its base model is no longer local; fix it in Workspace > Models")
        out.append(f"model {model_id}: prompt replaced")
    if not apply:
        out.append("Dry run: nothing written. Run again with --apply.")
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--url", default="http://localhost:3000")
    ap.add_argument("--key-file", default=DEFAULT_KEY_FILE)
    ap.add_argument("--agent", choices=sorted(AGENTS), default="household")
    ap.add_argument("--tool", help="Open WebUI tool id (default: the agent's)")
    ap.add_argument("--model", help="workspace model id (default: the agent's)")
    ap.add_argument("--engine-url", default=DEFAULT_ENGINE, help="the server's llama-server, for the local-base check")
    ap.add_argument("--apply", action="store_true")
    a = ap.parse_args(argv)
    tool_file, prompt_file, tool_id, model_id, must_be_local = AGENTS[a.agent]
    try:
        with open(os.path.join(HERE, tool_file), encoding="utf-8") as f:
            code = f.read()
        with open(os.path.join(HERE, prompt_file), encoding="utf-8") as f:
            prompt = f.read()
        local = served_models(a.engine_url, engine_key()) if must_be_local else None
        for line in push(make_call(a.url, read_key(a.key_file)), a.tool or tool_id, a.model or model_id, code, prompt,
                         a.apply, local=local):
            print(line)
    except PushError as e:
        print(f"openwebui_push: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
