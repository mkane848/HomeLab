"""Unit tests for server/scripts/llamacpp_check.py: the sampling comparison and the
live-server checks, with the HTTP layer replaced (no server needed). The static
checks and the command line are covered end to end by tests/test-llamacpp-stack.ps1.

Run:  python3 -I tests/test_llamacpp_check.py   (standard library only)
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "server", "scripts"))
import llamacpp_check as lc  # noqa: E402


def levels():
    return [(lvl, subj) for lvl, subj, _ in lc.results]


def messages(level):
    return [msg for lvl, _, msg in lc.results if lvl == level]


class Base(unittest.TestCase):
    def setUp(self):
        lc.results.clear()
        self.real = lc.http_json

    def tearDown(self):
        lc.http_json = self.real


class ParseParameters(Base):
    def test_only_sampling_parameters_are_read(self):
        text = 'temperature                    0.6\ntop_k                          20\nstop                           "<|im_end|>"\nnum_ctx                        65536\n'
        self.assertEqual(lc.parse_ollama_parameters(text), {"temperature": "0.6", "top_k": "20"})

    def test_empty_and_none(self):
        self.assertEqual(lc.parse_ollama_parameters(""), {})
        self.assertEqual(lc.parse_ollama_parameters(None), {})

    def test_numbers_compare_as_numbers(self):
        self.assertTrue(lc.same_number("0.6", "0.60"))
        self.assertTrue(lc.same_number("20", "20.0"))
        self.assertFalse(lc.same_number("0.6", "0.7"))


class Sampling(Base):
    INI = {"*": {}, "t": {"temp": "0.6", "top-k": "20"}}

    def run_with(self, ini, show):
        lc.http_json = lambda url, data=None, timeout=15: (200, show)
        lc.sampling_checks(ini, "http://ollama.invalid:11434")

    def test_matching_parameters_pass(self):
        self.run_with(self.INI, {"parameters": "temperature 0.6\ntop_k 20\n"})
        self.assertEqual(sorted(l for l, _ in levels()), ["OK", "OK"])

    def test_a_parameter_the_preset_does_not_set_fails(self):
        self.run_with(self.INI, {"parameters": "temperature 0.6\ntop_k 20\nrepeat_penalty 1.05\n"})
        self.assertEqual(sorted(l for l, _ in levels()), ["FAIL", "OK", "OK"])
        self.assertIn("llama-server's own default is used", messages("FAIL")[0])

    def test_a_different_value_fails(self):
        self.run_with(self.INI, {"parameters": "temperature 0.7\n"})
        self.assertEqual(levels(), [("FAIL", "t")])
        self.assertIn("temp = 0.6 but Ollama applies temperature = 0.7", messages("FAIL")[0])

    def test_the_long_key_name_is_accepted(self):
        self.run_with({"*": {}, "t": {"temperature": "0.6"}}, {"parameters": "temperature 0.6\n"})
        self.assertEqual(levels(), [("OK", "t")])

    def test_a_global_value_counts(self):
        self.run_with({"*": {"top-p": "0.95"}, "t": {}}, {"parameters": "top_p 0.95\n"})
        self.assertEqual(levels(), [("OK", "t")])

    def test_no_ollama_parameters_is_information_not_a_failure(self):
        self.run_with(self.INI, {"parameters": "num_ctx 65536\n"})
        self.assertEqual(levels(), [("INFO", "t")])

    def test_mtp_drafting_must_be_copied(self):
        # Ollama 0.34.3 serves draft_num_predict as --spec-type draft-mtp --spec-draft-n-max N (2026-10-13).
        self.run_with({"*": {}, "t": {}}, {"parameters": "draft_num_predict 2\n"})
        self.assertEqual(sorted(l for l, _ in levels()), ["FAIL", "FAIL"])
        self.assertTrue(any("spec-type = draft-mtp" in m for m in messages("FAIL")))
        lc.results.clear()
        self.run_with({"*": {}, "t": {"spec-type": "draft-mtp", "spec-draft-n-max": "2"}}, {"parameters": "draft_num_predict 2\n"})
        self.assertEqual(levels(), [("OK", "t"), ("OK", "t")])

    def test_unreachable_ollama_is_a_warning(self):
        def boom(*a, **k):
            raise OSError("connection refused")
        lc.http_json = boom
        lc.sampling_checks(self.INI, "http://ollama.invalid:11434")
        self.assertEqual(levels(), [("WARN", "t")])


class Live(Base):
    INI = {"*": {}, "t": {"c": "65536"}}

    def fake(self, health=200, models=("t",), props=None, props_error=False, health_error=False):
        calls = []

        def f(url, data=None, timeout=15):
            calls.append(url)
            if url.endswith("/health"):
                if health_error:
                    raise OSError("connection refused")
                return health, {"status": "ok"}
            if "/models" in url:
                return 200, {"data": [{"id": m} for m in models]}
            if "/props" in url:
                if props_error:
                    raise OSError("404")
                return 200, props
            raise AssertionError(url)
        lc.http_json = f
        return calls

    def test_matching_context_and_one_slot_pass(self):
        self.fake(props={"default_generation_settings": {"n_ctx": 65536}, "total_slots": 1})
        lc.live_checks(self.INI, "http://llama.invalid:8090")
        self.assertEqual([l for l, _ in levels()], ["OK", "OK"])

    def test_a_quartered_context_fails(self):
        self.fake(props={"default_generation_settings": {"n_ctx": 16384}, "total_slots": 4})
        lc.live_checks(self.INI, "http://llama.invalid:8090")
        self.assertEqual(sorted(l for l, _ in levels()), ["FAIL", "FAIL", "OK"])
        self.assertTrue(any("serving n_ctx 16384 but the preset says c = 65536" in m for m in messages("FAIL")))
        self.assertTrue(any("total_slots = 4" in m for m in messages("FAIL")))

    def test_props_is_asked_without_autoload_and_with_the_tag_escaped(self):
        calls = self.fake(props={"default_generation_settings": {"n_ctx": 65536}, "total_slots": 1})
        lc.live_checks({"*": {}, "qwen3.6:35b-a3b-coding": {"c": "65536"}}, "http://llama.invalid:8090/")
        props = [c for c in calls if "/props" in c]
        self.assertEqual(props, ["http://llama.invalid:8090/props?model=qwen3.6%3A35b-a3b-coding&autoload=false"])

    def test_a_model_that_is_not_loaded_is_information(self):
        self.fake(props_error=True)
        lc.live_checks(self.INI, "http://llama.invalid:8090")
        self.assertEqual([l for l, _ in levels()], ["OK", "INFO"])

    def test_a_server_that_is_down_fails_and_stops(self):
        calls = self.fake(health_error=True)
        lc.live_checks(self.INI, "http://llama.invalid:8090")
        self.assertEqual(levels(), [("FAIL", "server")])
        self.assertEqual(len(calls), 1)

    def test_a_section_missing_from_the_server_is_a_warning(self):
        self.fake(models=("other",), props={"default_generation_settings": {"n_ctx": 65536}, "total_slots": 1})
        lc.live_checks(self.INI, "http://llama.invalid:8090")
        self.assertIn("WARN", [l for l, _ in levels()])

    def test_a_tag_listed_only_as_an_alias_is_present(self):
        # Router mode lists [qwen3:8b] as id "qwen3:8B"; the preset's alias keeps the tag (2026-10-13).
        def f(url, data=None, timeout=15):
            if url.endswith("/health"):
                return 200, {"status": "ok"}
            if "/models" in url:
                return 200, {"data": [{"id": "qwen3:8B", "aliases": ["qwen3:8b"]}]}
            return 200, {"default_generation_settings": {"n_ctx": 32768}, "total_slots": 1}
        lc.http_json = f
        lc.live_checks({"*": {}, "qwen3:8b": {"c": "32768"}}, "http://llama.invalid:8090")
        self.assertEqual([l for l, _ in levels()], ["OK", "OK"])


class ChatTemplate(Base):
    # gpt-oss's Ollama blob has no usable template; its seat loads one from the repo (2026-10-23).
    SEATS = {"g:1": {"num_ctx": "65536", "num_gpu": "-", "from": "-", "weights": "sha256:" + "a" * 64}}

    def run_with(self, tpl):
        sec = {"model": "/ollama/models/blobs/sha256-" + "a" * 64, "c": "65536", "alias": "g:1", "parallel": "1"}
        if tpl is not None:
            sec["chat-template-file"] = tpl
        lc.static_checks({"*": {}, "g:1": sec}, self.SEATS)

    def test_the_repo_template_passes(self):
        self.run_with("/config/templates/openai-gpt-oss-120b.jinja")
        self.assertIn("chat template openai-gpt-oss-120b.jinja is in the repo", messages("OK"))
        self.assertEqual(messages("FAIL"), [])

    def test_a_template_missing_from_the_repo_fails(self):
        self.run_with("/config/templates/no-such.jinja")
        self.assertEqual(len(messages("FAIL")), 1)

    def test_a_path_outside_the_mounted_folder_fails(self):
        self.run_with("/models/some.jinja")
        self.assertEqual(len(messages("FAIL")), 1)

    def test_no_template_key_is_not_checked(self):
        self.run_with(None)
        self.assertFalse(any("chat template" in m for m in messages("OK")))
        self.assertEqual(messages("FAIL"), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
