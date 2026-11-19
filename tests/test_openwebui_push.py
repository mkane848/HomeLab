"""Unit tests for server/household/openwebui_push.py against a fake Open WebUI (an in-memory call function that
records every request). Synthetic data only.

Run:  python3 -m unittest -v tests/test_openwebui_push.py   (standard library only)
"""
import copy
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "server", "household"))
import openwebui_push as push  # noqa: E402

OLD = '"""\ntitle: T\nversion: 0.1.0\n"""\nclass Tools: pass\n'
NEW = '"""\ntitle: T\nversion: 0.2.0\n"""\nclass Tools: pass\n'


class FakeWebUI:
    def __init__(self, content=OLD, system="old prompt", drop_base=False):
        self.tool = {"id": "t", "name": "T", "meta": {"description": "d"}, "content": content, "valves": {"k": "v"}}
        self.model = {"id": "m", "base_model_id": "vision:8B", "name": "M", "is_active": True,
                      "meta": {"toolIds": ["t"], "capabilities": {"vision": True}},
                      "params": {"system": system, "temperature": 0.7}, "access_grants": [{"group": "g"}]}
        self.calls, self.drop_base = [], drop_base

    def __call__(self, method, path, body=None):
        self.calls.append((method, path, copy.deepcopy(body)))
        if (method, path) == ("GET", "/tools/id/t"):
            return copy.deepcopy(self.tool)
        if (method, path) == ("POST", "/tools/id/t/update"):
            self.tool.update(body)
            return self.tool
        if (method, path) == ("GET", "/models/model?id=m"):
            return copy.deepcopy(self.model)
        if (method, path) == ("POST", "/models/model/update"):
            self.model = copy.deepcopy(body)
            if self.drop_base:
                self.model["base_model_id"] = None
            return self.model
        return None

    def posts(self):
        return [c for c in self.calls if c[0] == "POST"]


def run(fake, apply):
    return push.push(fake, "t", "m", NEW, "new prompt\n", apply)


class PushTest(unittest.TestCase):
    def test_dry_run_reports_and_writes_nothing(self):
        f = FakeWebUI()
        out = run(f, apply=False)
        self.assertEqual(out, ["tool t: would update 0.1.0 -> 0.2.0", "model m: would replace the system prompt",
                               "Dry run: nothing written. Run again with --apply."])
        self.assertEqual(f.posts(), [])

    def test_apply_updates_code_and_prompt_and_keeps_the_rest(self):
        f = FakeWebUI()
        out = run(f, apply=True)
        self.assertEqual(out, ["tool t: updated 0.1.0 -> 0.2.0", "model m: prompt replaced"])
        self.assertEqual(f.tool["content"], NEW)
        self.assertEqual(f.tool["valves"], {"k": "v"})  # the Grocy key lives in Valves; never sent, never lost
        self.assertNotIn("valves", f.posts()[0][2])
        self.assertEqual(f.model["params"], {"system": "new prompt\n", "temperature": 0.7})
        self.assertEqual(f.model["base_model_id"], "vision:8B")
        self.assertEqual(f.model["meta"], {"toolIds": ["t"], "capabilities": {"vision": True}})
        self.assertEqual(f.model["access_grants"], [{"group": "g"}])

    def test_up_to_date_writes_nothing(self):
        f = FakeWebUI(content=NEW, system="new prompt")
        self.assertEqual(run(f, apply=True), ["tool t: up to date (0.2.0)", "model m: prompt up to date"])
        self.assertEqual(f.posts(), [])

    def test_a_lost_base_model_is_an_error(self):
        with self.assertRaisesRegex(push.PushError, "base model changed"):
            run(FakeWebUI(drop_base=True), apply=True)

    def test_missing_tool_is_an_error(self):
        with self.assertRaisesRegex(push.PushError, "no tool 'x'"):
            push.push(FakeWebUI(), "x", "m", NEW, "p", False)

    def test_key_from_env_or_file_never_printed(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "key")
            with self.assertRaisesRegex(push.PushError, "no API key"):
                push.read_key(p)
            with open(p, "w") as fh:
                fh.write("  synthetic-key\n")
            os.environ.pop("OPENWEBUI_API_KEY", None)
            self.assertEqual(push.read_key(p), "synthetic-key")
            os.environ["OPENWEBUI_API_KEY"] = "from-env"
            try:
                self.assertEqual(push.read_key(p), "from-env")
            finally:
                del os.environ["OPENWEBUI_API_KEY"]

    def test_local_base_passes_and_is_reported(self):
        f = FakeWebUI()
        out = push.push(f, "t", "m", NEW, "new prompt\n", True, local={"vision:8B", "other"})
        self.assertEqual(out[0], "model m: base model vision:8B is local")
        self.assertEqual(f.tool["content"], NEW)

    def test_a_base_not_served_locally_is_refused_before_any_write(self):
        for apply in (False, True):
            with self.subTest(apply=apply):
                f = FakeWebUI()
                f.model["base_model_id"] = "gpt-4o"
                with self.assertRaisesRegex(push.PushError, "'gpt-4o' is not served by the server's llama-server"):
                    push.push(f, "t", "m", NEW, "new prompt\n", apply, local={"vision:8B"})
                self.assertEqual(f.posts(), [])

    def test_no_local_check_for_the_house_agent(self):
        f = FakeWebUI()
        f.model["base_model_id"] = "anything"
        self.assertEqual(run(f, apply=False)[0], "tool t: would update 0.1.0 -> 0.2.0")

    def test_served_models_reads_ids_and_aliases_and_sends_the_key(self):
        seen = {}

        class R:
            def __init__(self, body):
                self.body = body

            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

            def read(self):
                return self.body

        def opener(req, timeout):
            seen["url"], seen["auth"] = req.full_url, req.get_header("Authorization")
            return R(b'{"data": [{"id": "qwen3-vl:8b", "aliases": ["vision:8B"]}, {"id": "qwen3:8b"}]}')

        ids = push.served_models("http://e:8090/", "synthetic-fleet-key", opener=opener)
        self.assertEqual(ids, {"qwen3-vl:8b", "vision:8B", "qwen3:8b"})
        self.assertEqual(seen, {"url": "http://e:8090/v1/models", "auth": "Bearer synthetic-fleet-key"})
        with self.assertRaisesRegex(push.PushError, "lists no models"):
            push.served_models("http://e", None, opener=lambda req, timeout: R(b'{"data": []}'))

    def test_engine_key_first_key_line(self):
        os.environ.pop("LLAMACPP_API_KEY", None)
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "api-key")
            self.assertIsNone(push.engine_key(p))
            with open(p, "w") as fh:
                fh.write("# fleet\n\n  synthetic-fleet  \nsecond-client\n")
            self.assertEqual(push.engine_key(p), "synthetic-fleet")

    def test_agents_point_at_real_files(self):
        here = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "server", "household")
        for name, (tool_file, prompt_file, _, _, _) in push.AGENTS.items():
            with self.subTest(agent=name):
                self.assertTrue(os.path.isfile(os.path.join(here, tool_file)))
                self.assertTrue(os.path.isfile(os.path.join(here, prompt_file)))
        self.assertTrue(push.AGENTS["health"][4], "Health must require a local base model")

    def test_version_of(self):
        self.assertEqual(push.version_of(NEW), "0.2.0")
        self.assertEqual(push.version_of("no header"), "?")


if __name__ == "__main__":
    unittest.main()
