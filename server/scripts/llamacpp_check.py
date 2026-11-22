#!/usr/bin/env python3
"""llamacpp_check.py - are the llama.cpp trial's contracts kept? (docs/llamacpp-trial.md)

Run through llamacpp-check.sh. Standard library only.

  static (always)   server/llamacpp/models.ini against models/server-seats.tsv:
                    - every section has a row in the seat table;
                    - its weights are a GGUF file under /models whose sha256 the
                      row's `weights` pins (Ollama, whose blobs four seats loaded
                      until 2026-11-21, is removed; those seats load byte copies);
                    - `c` is explicit in the section and equals the row's num_ctx;
                    - one slot (`parallel`/`np` = 1), because `c` is shared across
                      slots and an automatic count would quarter the window;
                    - a row with num_gpu 0 has zero GPU layers;
                    - a quantized V cache has flash attention on;
                    - a `chat-template-file` is a file under /config/templates that
                      exists in server/llamacpp/templates.
  --url U           a running llama-server: /health, the API key (/props without
                    the key must be refused with 401, docs/engine-api-keys.md),
                    the model list, and for each section /props (n_ctx must
                    equal `c`, total_slots must be 1). Asked with autoload=false,
                    so checking never loads a model.
  --key-file F      the API key to send (first line that is not blank or a #
                    comment). Default: $LLAMACPP_API_KEY, else $LLAMACPP_API_KEY_FILE,
                    else ~/.config/llamacpp/api-key. Never printed.
  --weights-container NAME | --weights-dir DIR
                    the weights are really there: each section's GGUF file exists,
                    is not empty and starts with the GGUF magic. Through
                    `docker exec NAME` (the container's own view of /models), or in a
                    local directory holding the same files. A missing file says how
                    to get it.
  --hash            with a weights option: also recompute each file's sha256 and
                    compare it with the seat table's pin (reads every byte: about a
                    minute for the 20 GB seat).

Exit 1 if anything FAILs, 2 on a usage problem. WARN and INFO never fail.
"""
import argparse
import configparser
import json
import os
import hashlib
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_INI = os.path.normpath(os.path.join(HERE, "..", "llamacpp", "models.ini"))
DEFAULT_SEATS = os.path.normpath(os.path.join(HERE, "..", "..", "models", "server-seats.tsv"))
# server/llamacpp/templates, mounted read-only here by docker-compose.llamacpp.yml.
TEMPLATES_DIR = os.path.normpath(os.path.join(HERE, "..", "llamacpp", "templates"))
TEMPLATES_MOUNT = "/config/templates/"

results = []  # (level, subject, message)


def say(level, subject, message):
    results.append((level, subject, message))


def load_ini(path):
    """Sections -> dict of keys. Keys before the first section land in '__global__'."""
    with open(path, encoding="utf-8") as fh:
        text = "[__global__]\n" + fh.read()
    cp = configparser.ConfigParser(interpolation=None, delimiters=("=",), comment_prefixes=("#", ";"),
                                   inline_comment_prefixes=None, strict=False, default_section="__unused__")
    cp.optionxform = str
    cp.read_string(text)
    return {s: dict(cp.items(s)) for s in cp.sections()}


def load_seats(path):
    """tag -> dict(num_ctx, num_gpu, from, weights, source)."""
    seats = {}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            cols = line.split("\t")
            if cols[0] == "tag":
                continue
            while len(cols) < 7:
                cols.append("")
            seats[cols[0]] = {"num_ctx": cols[1], "num_gpu": cols[2], "from": cols[3], "weights": cols[4], "source": cols[5]}
    return seats


def pick(section, glob, *names):
    """First of `names` set in the section, else in [*]."""
    for src in (section, glob):
        for n in names:
            if n in src:
                return src[n]
    return None


API_KEY = None  # set by main() from --key-file / the environment; sent as `Authorization: Bearer`


def read_api_key(path=None):
    """$LLAMACPP_API_KEY, else the first non-blank, non-# line of `path` (default: $LLAMACPP_API_KEY_FILE, else
    ~/.config/llamacpp/api-key). None when there is none."""
    k = os.environ.get("LLAMACPP_API_KEY", "").strip()
    if k:
        return k
    path = path or os.environ.get("LLAMACPP_API_KEY_FILE") or os.path.expanduser("~/.config/llamacpp/api-key")
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    return line
    except OSError:
        pass
    return None


def auth_headers():
    return {"Authorization": "Bearer " + API_KEY} if API_KEY else {}


def http_json(url, data=None, timeout=15):
    headers = dict(auth_headers())
    if data is not None:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=(json.dumps(data).encode() if data is not None else None), headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        body = r.read().decode("utf-8", "replace")
        return r.status, (json.loads(body) if body.strip() else {})


def http_status_without_key(url, timeout=15):
    """The HTTP status of a GET that carries no key (the auth check's probe)."""
    try:
        with urllib.request.urlopen(urllib.request.Request(url), timeout=timeout) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code


def auth_check(base):
    """Is the engine closed to a request without the key, and open to ours? docs/engine-api-keys.md.
    Returns False when nothing past this point can be checked (the engine refuses us)."""
    try:
        bare = http_status_without_key(base + "/props")
    except Exception as e:  # noqa: BLE001
        say("WARN", "auth", "could not ask /props without a key: %s" % e)
        return True
    if not API_KEY:
        if bare == 401:
            say("FAIL", "auth", "the server needs an API key and none was found (--key-file, LLAMACPP_API_KEY, "
                "LLAMACPP_API_KEY_FILE or ~/.config/llamacpp/api-key)")
            return False
        say("WARN", "auth", "no API key: /props answered %s without one, so anyone who can reach the port can use it "
            "(docs/engine-api-keys.md)" % bare)
        return True
    if bare != 401:
        say("FAIL", "auth", "/props answered %s without a key (want 401): the server's key did not take, and it is "
            "open to anyone who can reach the port" % bare)
        return True
    try:
        status, _ = http_json(base + "/props")
    except urllib.error.HTTPError as e:
        status = e.code
    except Exception as e:  # noqa: BLE001
        say("WARN", "auth", "/props with the key did not answer: %s" % e)
        return True
    if status == 401:
        say("FAIL", "auth", "refuses requests without a key, but also refuses ours: the key sent is not one of the server's")
        return False
    say("OK", "auth", "refuses requests without a key (401) and accepts ours")
    return True


def static_checks(ini, seats):
    glob = ini.get("*", {})
    models = [s for s in ini if s not in ("*", "__global__")]
    if not models:
        say("FAIL", "preset", "no model sections found")
    flash = (pick({}, glob, "flash-attn", "fa") or "auto").lower()
    for key in ("cache-type-v", "ctv"):
        v = glob.get(key)
        if v and v != "f16" and flash not in ("on", "auto", "1", "true"):
            say("FAIL", "[*]", "quantized V cache (%s) needs flash attention, flash-attn = %s" % (v, flash))
    for tag in models:
        sec = ini[tag]
        seat = seats.get(tag)
        if seat is None:
            say("FAIL", tag, "no row in models/server-seats.tsv")
            continue
        path = sec.get("model", "")
        if GGUF_FILE_RE.search(path) and seat.get("source") in IMPORT_SOURCES and re.fullmatch(r"sha256:[0-9a-f]{64}", seat.get("weights", "")):
            # A GGUF file under the /models mount, pinned by the seat table's sha256, which
            # --weights-container --hash checks against the bytes.
            say("OK", tag, "weights are a GGUF file pinned by server-seats.tsv (%s...)" % seat["weights"][7:19])
        else:
            say("WARN", tag, "weights are not a /models GGUF pinned by server-seats.tsv (%s): unpinned, so this is a different era" % (path or "no model key"))
        c = None
        for key in ("c", "ctx-size"):
            if key in sec:
                c = sec[key]
        if c is None:
            say("FAIL", tag, "no explicit context (c): inheriting one would drift from server-seats.tsv")
        elif c != seat["num_ctx"]:
            say("FAIL", tag, "c = %s but server-seats.tsv num_ctx = %s" % (c, seat["num_ctx"]))
        else:
            say("OK", tag, "context %s equals server-seats.tsv" % c)
        # Router mode reads `name:tag` as a quant tag and rewrites it (qwen3.6:35b-a3b-coding ->
        # qwen3.6:CODING); only an alias keeps the exact tag addressable (trial step 2, 2026-10-13).
        if ":" in tag:
            if sec.get("alias") == tag:
                say("OK", tag, "alias keeps the exact tag addressable")
            else:
                say("FAIL", tag, "a ':' in the section name is rewritten by router mode; add `alias = %s`" % tag)
        # A seat whose weights carry no usable template loads one from the repo, which the
        # compose file mounts read-only at /config/templates (server/llamacpp/templates/README.md).
        tpl = sec.get("chat-template-file")
        if tpl:
            name = tpl[len(TEMPLATES_MOUNT):] if tpl.startswith(TEMPLATES_MOUNT) else None
            if not name or "/" in name:
                say("FAIL", tag, "chat-template-file %s is not a file in %s (the mounted server/llamacpp/templates)" % (tpl, TEMPLATES_MOUNT))
            elif not os.path.isfile(os.path.join(TEMPLATES_DIR, name)):
                say("FAIL", tag, "chat-template-file %s has no server/llamacpp/templates/%s in the repo" % (tpl, name))
            else:
                say("OK", tag, "chat template %s is in the repo" % name)
        par = pick(sec, glob, "parallel", "np")
        if par != "1":
            say("FAIL", tag, "parallel = %s (must be 1: c is shared across slots)" % par)
        ngl = pick(sec, glob, "n-gpu-layers", "ngl", "gpu-layers")
        if seat["num_gpu"] == "0":
            if ngl == "0" or (sec.get("device") or glob.get("device") or "").lower() == "none" or (sec.get("dev") or "").lower() == "none":
                say("OK", tag, "CPU seat (num_gpu 0) has no GPU layers")
            else:
                say("FAIL", tag, "server-seats.tsv says num_gpu 0 but n-gpu-layers = %s" % ngl)
    served = set(models)
    bases = {s["from"] for s in seats.values() if s["from"] not in ("", "-")}
    for tag in seats:
        if tag not in served and tag not in bases:
            say("WARN", tag, "seat in server-seats.tsv has no section in the preset")


GGUF_MAGIC = b"GGUF"
GGUF_FILE_RE = re.compile(r"^/models/([\w.-]+\.gguf)$")


class LocalBlobs:
    """GGUF files in a local directory (tests, or a copy of ~/models)."""

    def __init__(self, directory):
        self.dir = directory

    def stat(self, name):
        """(size, first 4 bytes), or None when the file is not there."""
        p = os.path.join(self.dir, name)
        if not os.path.isfile(p):
            return None
        with open(p, "rb") as fh:
            return os.path.getsize(p), fh.read(4)

    def sha256(self, name):
        h = hashlib.sha256()
        with open(os.path.join(self.dir, name), "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                h.update(chunk)
        return h.hexdigest()


class ContainerBlobs:
    """GGUF files read through `docker exec`, at the path the preset gives (the container's own view)."""

    def __init__(self, container, run=subprocess.run):
        self.container, self.run = container, run
        self.paths = {}

    def _exec(self, *cmd, timeout=60):
        r = self.run(["docker", "exec", self.container] + list(cmd), capture_output=True, timeout=timeout)
        return r.returncode, r.stdout

    def stat(self, name):
        path = self.paths[name]
        code, out = self._exec("sh", "-c", 'test -f "$1" && stat -c %s "$1" && head -c 4 "$1"', "_", path)
        if code != 0 or b"\n" not in out:
            return None
        size, magic = out.split(b"\n", 1)
        return int(size), magic[:4]

    def sha256(self, name):
        code, out = self._exec("sha256sum", self.paths[name], timeout=1800)
        if code != 0:
            raise OSError("sha256sum failed in %s" % self.container)
        return out.split()[0].decode()


# Seats whose weights are a GGUF file under /models, pinned by the seat table's sha256. "import-server" is served by
# the server's llama.cpp only (every seat since 2026-11-21); "import" is the older name, kept readable.
IMPORT_SOURCES = ("import", "import-server")


def how_to_get(tag, seat):
    """The fix for a missing GGUF file."""
    return "put its GGUF back in ~/models (the seat row's note names the file; --hash checks it against the pin)"


def weights_checks(ini, seats, blobs, rehash=False):
    for tag in [s for s in ini if s not in ("*", "__global__")]:
        path = ini[tag].get("model", "")
        g = GGUF_FILE_RE.search(path)
        pinned = (seats.get(tag) or {}).get("weights", "")
        if g and (seats.get(tag) or {}).get("source") in IMPORT_SOURCES and re.fullmatch(r"sha256:[0-9a-f]{64}", pinned):
            name, want = g.group(1), pinned[7:]   # a GGUF under /models: the seat table pins its bytes
        else:
            continue  # static_checks already WARNs that it is unpinned
        if isinstance(blobs, ContainerBlobs):
            blobs.paths[name] = ini[tag]["model"]
        try:
            st = blobs.stat(name)
        except Exception as e:  # noqa: BLE001 - docker missing, container down: the same finding
            say("FAIL", tag, "could not read the weights: %s" % e)
            continue
        if st is None:
            say("FAIL", tag, "weights %s are not there; %s" % (name, how_to_get(tag, seats.get(tag))))
            continue
        size, magic = st
        if size == 0 or magic != GGUF_MAGIC:
            say("FAIL", tag, "%s is not a GGUF file (%d bytes, starts %r): fetch it again" % (name, size, magic))
            continue
        if not rehash:
            say("OK", tag, "weights present (%.1f GB, GGUF)" % (size / 1e9))
            continue
        try:
            got = blobs.sha256(name)
        except Exception as e:  # noqa: BLE001
            say("FAIL", tag, "could not hash the weights: %s" % e)
            continue
        if got == want:
            say("OK", tag, "weights present (%.1f GB) and their sha256 matches the pin" % (size / 1e9))
        else:
            say("FAIL", tag, "%s hashes to %s...: the bytes are not the pinned weights (%s...); fetch it again" % (name[:19], got[:12], want[:12]))


def live_checks(ini, url, check_auth=False):
    base = url.rstrip("/")
    try:
        status, _ = http_json(base + "/health")
        say("OK" if status == 200 else "FAIL", "server", "/health answered %s" % status)
    except Exception as e:  # noqa: BLE001
        say("FAIL", "server", "/health did not answer: %s" % e)
        return
    if check_auth and not auth_check(base):
        return
    ids = set()
    for path in ("/v1/models", "/models"):
        try:
            _, body = http_json(base + path)
            # Router mode rewrites a section name with a ':' (qwen3:8b -> qwen3:8B, read as a
            # quant tag), so a seat is listed when its tag is the id or one of its aliases
            # (the preset's `alias` key; trial step 2, 2026-10-13).
            ids = set()
            for m in body.get("data", []):
                if isinstance(m, dict):
                    ids.add(m.get("id") or m.get("name"))
                    ids.update(a for a in (m.get("aliases") or []) if isinstance(a, str))
            if ids:
                break
        except Exception:  # noqa: BLE001
            continue
    for tag in [s for s in ini if s not in ("*", "__global__")]:
        if ids and tag not in ids:
            say("WARN", tag, "not in the server's model list")
        want = ini[tag].get("c") or ini[tag].get("ctx-size")
        try:
            _, props = http_json(base + "/props?model=%s&autoload=false" % urllib.parse.quote(tag, safe=""))
        except Exception:  # noqa: BLE001
            say("INFO", tag, "not loaded, so /props has nothing to say (checking never loads a model)")
            continue
        dgs = props.get("default_generation_settings") or {}
        n_ctx = dgs.get("n_ctx", props.get("n_ctx"))
        slots = props.get("total_slots")
        if n_ctx is None:
            say("WARN", tag, "/props reports no n_ctx")
        elif str(n_ctx) == str(want):
            say("OK", tag, "serving n_ctx %s, as the preset says" % n_ctx)
        else:
            say("FAIL", tag, "serving n_ctx %s but the preset says c = %s" % (n_ctx, want))
        if slots is not None and int(slots) != 1:
            say("FAIL", tag, "total_slots = %s (must be 1: the context is shared across slots)" % slots)


def main(argv):
    ap = argparse.ArgumentParser(description="Check the llama.cpp trial's preset contracts.")
    ap.add_argument("--ini", default=DEFAULT_INI)
    ap.add_argument("--seats", default=DEFAULT_SEATS)
    ap.add_argument("--url", help="check a running llama-server (e.g. http://localhost:8090)")
    ap.add_argument("--key-file", help="the API key file to send with --url (default: see the module docstring)")
    where = ap.add_mutually_exclusive_group()
    where.add_argument("--weights-container", metavar="NAME", help="check the GGUF files through docker exec (e.g. llamacpp-server)")
    where.add_argument("--weights-dir", metavar="DIR", help="check the GGUF files in a local directory")
    ap.add_argument("--hash", action="store_true", help="with a weights option: recompute each file's sha256 (slow)")
    args = ap.parse_args(argv)
    if args.hash and not (args.weights_container or args.weights_dir):
        print("llamacpp-check: --hash needs --weights-container or --weights-dir", file=sys.stderr)
        return 2
    for p in (args.ini, args.seats):
        if not os.path.isfile(p):
            print("llamacpp-check: no such file: %s" % p, file=sys.stderr)
            return 2
    ini, seats = load_ini(args.ini), load_seats(args.seats)
    static_checks(ini, seats)
    if args.url:
        global API_KEY
        API_KEY = read_api_key(args.key_file)
        live_checks(ini, args.url, check_auth=True)
    if args.weights_container:
        weights_checks(ini, seats, ContainerBlobs(args.weights_container), args.hash)
    elif args.weights_dir:
        weights_checks(ini, seats, LocalBlobs(args.weights_dir), args.hash)
    width = max([len(s) for _, s, _ in results] + [8])
    for level, subject, message in results:
        print("[%-4s] %-*s  %s" % (level, width, subject, message))
    fails = sum(1 for lvl, _, _ in results if lvl == "FAIL")
    print("\n%d FAIL, %d WARN, %d OK" % (fails, sum(1 for lvl, _, _ in results if lvl == "WARN"), sum(1 for lvl, _, _ in results if lvl == "OK")))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
