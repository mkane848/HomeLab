"""Unit tests for server/scripts/model-ports-firewall.sh, run against a stand-in `iptables`.

The real script needs root, Docker and the server's network. The stand-in keeps chains and rules in a JSON file and
answers the calls the script makes (-nL, -N, -F, -X, -A, -I, -C, -D, -S) the way iptables does where it matters here:
-N fails when the chain exists, -C exits 1 when the rule is absent, -X fails while a chain is referenced. So what is
checked is the script's own logic: which rules it writes, that a second run changes nothing, that it never leaves
the model ports closed to everyone, and that `remove` puts everything back.

It cannot show that the kernel filters as intended; the runbook's checks on the server are for that
(docs/network-topology.md -> "Limit the model ports to named hosts").

Run:  python3 -m unittest -v tests/test_model_ports_firewall.py   (standard library only; needs bash)
"""
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "server", "scripts", "model-ports-firewall.sh")

STUB = r'''#!/usr/bin/env python3
import json, os, sys
path = os.environ["STUB_STATE"]
state = json.load(open(path))
chains = state["chains"]            # name -> list of rule specs (each a list of words)
state["calls"].append(sys.argv[1:])
def save(code=0):
    json.dump(state, open(path, "w")); sys.exit(code)
a = sys.argv[1:]
op, chain, spec = a[0], (a[1] if len(a) > 1 else None), a[2:]
if op == "-nL":
    save(0 if chain in chains else 1)
if op == "-S":
    if chain not in chains: save(1)
    print("-N " + chain)
    for r in chains[chain]: print("-A %s %s" % (chain, " ".join(r)))
    save()
if op == "-N":
    if chain in chains: save(1)
    chains[chain] = []; save()
if chain not in chains: save(1)
if op == "-F": chains[chain] = []; save()
if op == "-X":
    used = any(r[-2:] == ["-j", chain] for rules in chains.values() for r in rules)
    if used or chains[chain]: save(1)
    del chains[chain]; save()
if op == "-A": chains[chain].append(spec); save()
if op == "-I": chains[chain].insert(0, spec); save()
if op == "-C": save(0 if spec in chains[chain] else 1)
if op == "-D":
    if spec not in chains[chain]: save(1)
    chains[chain].remove(spec); save()
save(2)
'''


def jump(port, iface="eth9"):
    return ["-i", iface, "-p", "tcp", "-m", "conntrack", "--ctorigdstport", str(port), "--ctdir", "ORIGINAL", "-j", "HOMELAB-MODELS"]


@unittest.skipUnless(shutil.which("bash"), "needs bash")
class Firewall(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.bin = os.path.join(self.tmp, "bin")
        os.makedirs(self.bin)
        self.stub = os.path.join(self.bin, "iptables")
        with open(self.stub, "w", encoding="utf-8", newline="\n") as f:
            f.write(STUB.replace("#!/usr/bin/env python3", "#!" + sys.executable, 1))
        os.chmod(self.stub, os.stat(self.stub).st_mode | stat.S_IEXEC)
        self.state = os.path.join(self.tmp, "state.json")
        self.env = os.path.join(self.tmp, "fleet.env")
        self.reset({"DOCKER-USER": []})

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def reset(self, chains):
        with open(self.state, "w") as f:
            json.dump({"chains": chains, "calls": []}, f)

    def chains(self):
        with open(self.state) as f:
            return json.load(f)["chains"]

    def calls(self):
        with open(self.state) as f:
            return json.load(f)["calls"]

    def run_fw(self, *args, iface=True):
        extra = ["--iface", "eth9"] if iface else []
        env = dict(os.environ, IPTABLES=self.stub, STUB_STATE=self.state)
        return subprocess.run(["bash", SCRIPT, *args, *extra, "--env-file", self.env], env=env, capture_output=True, text=True)

    def test_apply_writes_the_chain_and_one_jump_per_port(self):
        r = self.run_fw("apply", "--allow", "192.0.2.10,192.0.2.11")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        c = self.chains()
        self.assertEqual(c["HOMELAB-MODELS"], [["-s", "192.0.2.10", "-j", "RETURN"], ["-s", "192.0.2.11", "-j", "RETURN"], ["-j", "DROP"]])
        self.assertCountEqual(c["DOCKER-USER"], [jump(8090), jump(11434)])

    def test_the_drop_is_last_and_only_inside_the_chain(self):
        self.run_fw("apply", "--allow", "192.0.2.10")
        c = self.chains()
        self.assertEqual(c["HOMELAB-MODELS"][-1], ["-j", "DROP"])
        self.assertEqual([r for r in c["HOMELAB-MODELS"][:-1] if "DROP" in r], [])
        # DOCKER-USER itself never drops: only the two port-scoped jumps were added, so no other port is affected.
        self.assertEqual([r for r in c["DOCKER-USER"] if "DROP" in r], [])
        for r in c["DOCKER-USER"]:
            self.assertIn("--ctorigdstport", r)
            self.assertEqual(r[:2], ["-i", "eth9"])
            self.assertEqual(r[r.index("--ctdir") + 1], "ORIGINAL")

    def test_a_second_apply_changes_nothing(self):
        self.run_fw("apply", "--allow", "192.0.2.10,192.0.2.11")
        first = self.chains()
        r = self.run_fw("apply", "--allow", "192.0.2.10,192.0.2.11")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.chains(), first)

    def test_a_new_allow_list_replaces_the_old_one(self):
        self.run_fw("apply", "--allow", "192.0.2.10,192.0.2.11")
        self.run_fw("apply", "--allow", "192.0.2.20")
        c = self.chains()
        self.assertEqual(c["HOMELAB-MODELS"], [["-s", "192.0.2.20", "-j", "RETURN"], ["-j", "DROP"]])
        self.assertEqual(len(c["DOCKER-USER"]), 2)

    def test_rules_that_were_already_in_docker_user_are_kept(self):
        mine = ["-s", "198.51.100.0/24", "-j", "ACCEPT"]
        self.reset({"DOCKER-USER": [mine]})
        self.run_fw("apply", "--allow", "192.0.2.10")
        self.assertIn(mine, self.chains()["DOCKER-USER"])
        self.run_fw("remove")
        self.assertEqual(self.chains(), {"DOCKER-USER": [mine]})

    def test_remove_puts_everything_back(self):
        self.run_fw("apply", "--allow", "192.0.2.10")
        r = self.run_fw("remove")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.chains(), {"DOCKER-USER": []})
        self.assertIn("open to the LAN again", r.stdout)
        r = self.run_fw("remove")      # nothing to remove: still fine
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_remove_clears_duplicate_jumps(self):
        self.reset({"DOCKER-USER": [jump(8090), jump(8090)], "HOMELAB-MODELS": [["-j", "DROP"]]})
        r = self.run_fw("remove")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.chains(), {"DOCKER-USER": []})

    def test_no_allowed_host_is_refused_before_anything_changes(self):
        r = self.run_fw("apply")       # no --allow, and the env file does not exist
        self.assertEqual(r.returncode, 3)
        self.assertIn("no allowed hosts", r.stderr)
        self.assertEqual(self.chains(), {"DOCKER-USER": []})
        self.assertEqual(self.calls(), [])

    def test_a_bad_address_port_or_action_is_refused(self):
        for args, msg in ((("apply", "--allow", "192.0.2.300"), "not an IPv4 address"),
                          (("apply", "--allow", "192.0.2.10,desktop"), "not an IPv4 address"),
                          (("apply", "--allow", "192.0.2.10", "--ports", "8090,x"), "not a port"),
                          (("apply", "--allow", "192.0.2.10", "--ports", "70000"), "not a port"),
                          (("open",), "usage:")):
            r = self.run_fw(*args)
            self.assertEqual(r.returncode, 3, args)
            self.assertIn(msg, r.stderr, args)
        self.assertEqual(self.calls(), [])

    def test_the_allow_list_defaults_to_the_env_file(self):
        with open(self.env, "w", encoding="utf-8") as f:
            f.write('SERVER_IP=192.0.2.1\nDESKTOP_IP="192.0.2.10"   # the desk\nNODE3_IP=192.0.2.11\n')
        r = self.run_fw("apply")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.chains()["HOMELAB-MODELS"], [["-s", "192.0.2.10", "-j", "RETURN"], ["-s", "192.0.2.11", "-j", "RETURN"], ["-j", "DROP"]])
        # the server's own address is not an allowed SOURCE: it never arrives on the LAN interface
        self.assertNotIn(["-s", "192.0.2.1", "-j", "RETURN"], self.chains()["HOMELAB-MODELS"])
        with open(self.env, "w", encoding="utf-8") as f:
            f.write("DESKTOP_IP=\nNODE3_IP=192.0.2.11\n")
        self.run_fw("apply")
        self.assertEqual(self.chains()["HOMELAB-MODELS"], [["-s", "192.0.2.11", "-j", "RETURN"], ["-j", "DROP"]])

    def test_no_docker_user_chain_stops_with_exit_1(self):
        self.reset({})
        r = self.run_fw("apply", "--allow", "192.0.2.10")
        self.assertEqual(r.returncode, 1)
        self.assertIn("no DOCKER-USER chain", r.stderr)
        self.assertEqual(self.chains(), {})

    def test_a_dry_run_prints_the_commands_and_changes_nothing(self):
        r = self.run_fw("apply", "--allow", "192.0.2.10", "--dry-run")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("-A HOMELAB-MODELS -s 192.0.2.10 -j RETURN", r.stdout)
        self.assertIn("-A HOMELAB-MODELS -j DROP", r.stdout)
        self.assertIn("-I DOCKER-USER -i eth9 -p tcp -m conntrack --ctorigdstport 8090 --ctdir ORIGINAL -j HOMELAB-MODELS", r.stdout)
        self.assertEqual(self.chains(), {"DOCKER-USER": []})
        self.assertEqual(self.calls(), [])

    def test_status_shows_both_states(self):
        r = self.run_fw("status", iface=False)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("open to the LAN", r.stdout)
        self.run_fw("apply", "--allow", "192.0.2.10")
        r = self.run_fw("status", iface=False)
        self.assertIn("-A HOMELAB-MODELS -s 192.0.2.10 -j RETURN", r.stdout)
        self.assertIn("--ctorigdstport 8090", r.stdout)


if __name__ == "__main__":
    unittest.main()
