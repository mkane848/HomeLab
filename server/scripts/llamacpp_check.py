#!/usr/bin/env python3
"""llamacpp_check.py - are the llama.cpp trial's contracts kept? (docs/llamacpp-trial.md)

Run through llamacpp-check.sh. Standard library only.

  static (always)   server/llamacpp/models.ini against models/server-seats.tsv:
                    - every section has a row in the seat table;
                    - its weights are an Ollama blob whose sha256 equals the row's
                      `weights` (same bytes as the other engines' results);
                    - `c` is explicit in the section and equals the row's num_ctx;
                    - one slot (`parallel`/`np` = 1), because `c` is shared across
                      slots and an automatic count would quarter the window;
                    - a row with num_gpu 0 has zero GPU layers;
                    - a quantized V cache has flash attention on;
                    - a `chat-template-file` is a file under /config/templates that
                      exists in server/llamacpp/templates.
  --ollama-url U    sampling: for each section, ask Ollama's /api/show for the same
                    tag's parameters and compare them with the section. A parameter
                    Ollama applies that the section does not set means llama-server
                    uses ITS default for it - a difference the engine comparison
                    would otherwise hide.
  --url U           a running llama-server: /health, the model list, and for each
                    section /props (n_ctx must equal `c`, total_slots must be 1).
                    Asked with autoload=false, so checking never loads a model.
  --weights-container NAME | --weights-dir DIR
                    the weights are really there (the job bake-models.sh did under
                    Ollama, "Replacing Ollama" Phase 3): each section's blob exists,
                    is not empty and starts with the GGUF magic. Through
                    `docker exec NAME` (the container sees Ollama's volume at
                    /ollama; the host cannot read it without sudo), or in a local
                    copy of the blobs directory. A missing blob says how to get it.
  --hash            with a weights option: also recompute each blob's sha256 and
                    compare it with its name (reads every byte: about a minute for
                    the 20 GB seat).

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

# Ollama parameter -> the llama-server keys that set the same thing.
SAMPLING = {
    "temperature": ("temp", "temperature"),
    "top_k": ("top-k",),
    "top_p": ("top-p",),
    "min_p": ("min-p",),
    "repeat_penalty": ("repeat-penalty",),
    "presence_penalty": ("presence-penalty",),
    "frequency_penalty": ("frequency-penalty",),
    "repeat_last_n": ("repeat-last-n",),
    "seed": ("seed", "s"),
    # Not sampling, but applied the same way: Ollama 0.34.3 serves a tag with this
    # parameter through its bundled llama-server with `--spec-type draft-mtp
    # --spec-draft-n-max N` (its own log, trial step 5, 2026-10-13). Speculative
    # decoding changes speed, not output, so leaving it out skews only the speed row.
    "draft_num_predict": ("spec-draft-n-max",),
}

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


def http_json(url, data=None, timeout=15):
    req = urllib.request.Request(url, data=(json.dumps(data).encode() if data is not None else None),
                                 headers={"Content-Type": "application/json"} if data is not None else {})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        body = r.read().decode("utf-8", "replace")
        return r.status, (json.loads(body) if body.strip() else {})


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
        m = re.search(r"/blobs/sha256-([0-9a-f]{64})$", path)
        if not m:
            say("WARN", tag, "weights are not an Ollama blob (%s): unpinned, so this is a different era" % (path or "no model key"))
        elif "sha256:" + m.group(1) == seat["weights"]:
            say("OK", tag, "weights are the pinned blob (%s...)" % m.group(1)[:12])
        else:
            say("FAIL", tag, "blob sha256 %s... != server-seats.tsv weights %s" % (m.group(1)[:12], seat["weights"][:19] + "..."))
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
        # qwen3.6:CODING); only an alias keeps the Ollama tag addressable (trial step 2, 2026-10-13).
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


def parse_ollama_parameters(text):
    out = {}
    for line in (text or "").splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[0] in SAMPLING:
            out[parts[0]] = parts[1].strip().strip('"')
    return out


def same_number(a, b):
    try:
        return abs(float(a) - float(b)) < 1e-9
    except (TypeError, ValueError):
        return str(a) == str(b)


def sampling_checks(ini, ollama_url):
    glob = ini.get("*", {})
    for tag in [s for s in ini if s not in ("*", "__global__")]:
        try:
            _, show = http_json(ollama_url.rstrip("/") + "/api/show", {"model": tag})
        except Exception as e:  # noqa: BLE001 - any failure is the same finding
            say("WARN", tag, "could not read Ollama's parameters: %s" % e)
            continue
        params = parse_ollama_parameters(show.get("parameters", ""))
        if not params:
            say("INFO", tag, "Ollama applies no sampling parameters to this tag; llama-server defaults are not compared")
            continue
        for oname, value in sorted(params.items()):
            have = pick(ini[tag], glob, *SAMPLING[oname])
            if have is None:
                say("FAIL", tag, "Ollama applies %s = %s; the preset does not set %s, so llama-server's own default is used" % (oname, value, SAMPLING[oname][0]))
            elif same_number(have, value):
                say("OK", tag, "%s = %s matches Ollama" % (SAMPLING[oname][0], have))
            else:
                say("FAIL", tag, "%s = %s but Ollama applies %s = %s" % (SAMPLING[oname][0], have, oname, value))
            if oname == "draft_num_predict":
                kinds = (pick(ini[tag], glob, "spec-type") or "").split(",")
                if "draft-mtp" in kinds:
                    say("OK", tag, "spec-type includes draft-mtp, as Ollama serves it")
                else:
                    say("FAIL", tag, "Ollama drafts with MTP (draft_num_predict = %s); the preset needs spec-type = draft-mtp" % value)


GGUF_MAGIC = b"GGUF"
BLOB_RE = re.compile(r"/blobs/(sha256-[0-9a-f]{64})$")


class LocalBlobs:
    """Blobs in a local directory (tests, or a copy of the volume)."""

    def __init__(self, directory):
        self.dir = directory

    def stat(self, name):
        """(size, first 4 bytes), or None when the blob is not there."""
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
    """Blobs read through `docker exec`, at the path the preset gives (the container's own view)."""

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


def how_to_get(tag, seat):
    """The fix for a missing blob. Ollama's volume is where the weights live until Phase 6."""
    src = (seat or {}).get("source")
    pull = (seat or {}).get("from") if src == "derived" else tag
    if src == "import":
        return "an import seat: copy the desktop's GGUF and 'ollama create %s' from it" % tag
    return ("pull it into Ollama's volume: docker start ollama-server && docker exec ollama-server ollama pull %s "
            "&& docker stop ollama-server (no model loads, so it does not fight llama.cpp for the GPU)" % pull)


def weights_checks(ini, seats, blobs, rehash=False):
    for tag in [s for s in ini if s not in ("*", "__global__")]:
        m = BLOB_RE.search(ini[tag].get("model", ""))
        if not m:
            continue  # static_checks already WARNs that it is unpinned
        name = m.group(1)
        if isinstance(blobs, ContainerBlobs):
            blobs.paths[name] = ini[tag]["model"]
        try:
            st = blobs.stat(name)
        except Exception as e:  # noqa: BLE001 - docker missing, container down: the same finding
            say("FAIL", tag, "could not read the weights: %s" % e)
            continue
        if st is None:
            say("FAIL", tag, "weights blob %s... is not there; %s" % (name[7:19], how_to_get(tag, seats.get(tag))))
            continue
        size, magic = st
        if size == 0 or magic != GGUF_MAGIC:
            say("FAIL", tag, "blob %s... is not a GGUF file (%d bytes, starts %r): re-pull it" % (name[7:19], size, magic))
            continue
        if not rehash:
            say("OK", tag, "weights present (%.1f GB, GGUF)" % (size / 1e9))
            continue
        try:
            got = blobs.sha256(name)
        except Exception as e:  # noqa: BLE001
            say("FAIL", tag, "could not hash the weights: %s" % e)
            continue
        if got == name[7:]:
            say("OK", tag, "weights present (%.1f GB) and their sha256 matches the name" % (size / 1e9))
        else:
            say("FAIL", tag, "blob %s... hashes to %s...: the bytes are not the pinned weights; re-pull it" % (name[7:19], got[:12]))


def live_checks(ini, url):
    base = url.rstrip("/")
    try:
        status, _ = http_json(base + "/health")
        say("OK" if status == 200 else "FAIL", "server", "/health answered %s" % status)
    except Exception as e:  # noqa: BLE001
        say("FAIL", "server", "/health did not answer: %s" % e)
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
    ap.add_argument("--ollama-url", help="compare sampling parameters with this Ollama (e.g. http://localhost:11434)")
    ap.add_argument("--url", help="check a running llama-server (e.g. http://localhost:8090)")
    where = ap.add_mutually_exclusive_group()
    where.add_argument("--weights-container", metavar="NAME", help="check the weights blobs through docker exec (e.g. llamacpp-server)")
    where.add_argument("--weights-dir", metavar="DIR", help="check the weights blobs in a local blobs directory")
    ap.add_argument("--hash", action="store_true", help="with a weights option: recompute each blob's sha256 (slow)")
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
    if args.ollama_url:
        sampling_checks(ini, args.ollama_url)
    if args.url:
        live_checks(ini, args.url)
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
