#!/usr/bin/env python3
"""
Fast, Julia-free tests for the `mcp-julia-adapter` routing logic.

Uses a synthetic registry directory and in-process fake HTTP REPLs, so it runs in
well under a second and needs no Julia. Covers:

  * rank() directory-distance semantics
  * resolution: single REPL, nearest-ancestor, same-project restart (silent
    rebind), a nearer REPL appearing (reprompt), ambiguous tie, no REPLs
  * the elicitation round-trip (adapter emits elicitation/create, consumes the
    user's pick from stdin, routes to the chosen REPL)
  * the no-elicitation fallback (returns a "pick a REPL, retry with repl=<word>"
    text result) and honoring an explicit `repl` argument

For the heavier end-to-end test with real Julia servers see
`integration_multiplex.py`.

Run:  python3 test/adapter_routing_test.py
"""

import http.server
import importlib.machinery
import importlib.util
import json
import os
import socketserver
import subprocess
import sys
import tempfile
import threading

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADAPTER = os.path.join(REPO, "mcp-julia-adapter")


def load_adapter(registry_dir):
    loader = importlib.machinery.SourceFileLoader("adapter", ADAPTER)
    spec = importlib.util.spec_from_loader("adapter", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    mod.REGISTRY_DIR = registry_dir
    mod.TOOLS_CACHE = os.path.join(registry_dir, "tools_cache.json")
    mod.pid_alive = lambda pid: True       # every synthetic REPL is "alive"
    mod.repl_reachable = lambda port: False  # force a rescan each resolve()
    return mod


def write_repl(registry_dir, pid, port, word, project_dir, git_root="", pwd=None):
    with open(os.path.join(registry_dir, "%d.json" % pid), "w") as fh:
        json.dump({"pid": pid, "port": port, "word": word,
                   "project_dir": project_dir, "pwd": pwd or project_dir,
                   "git_root": git_root,
                   "active_project": project_dir + "/Project.toml"}, fh)


def clear(registry_dir):
    for f in os.listdir(registry_dir):
        if f.endswith(".json"):
            os.remove(os.path.join(registry_dir, f))


def call(cid=1, args=None):
    return {"jsonrpc": "2.0", "id": cid, "method": "tools/call",
            "params": {"name": "exec_repl", "arguments": args or {}}}


# --- rank() -----------------------------------------------------------------

def test_rank(ad):
    assert ad.dir_rank("/a/b", "/a/b") == 0
    assert ad.dir_rank("/a/b", "/a/b/c") == 1
    assert ad.dir_rank("/a", "/a/b/c") == 2
    assert ad.dir_rank("/x/y", "/a/b") == ad.INF
    print("PASS dir_rank()")


def test_git_rank(ad):
    # A REPL in the same git project as our cwd ranks 0 even when it is a
    # *sibling* subfolder (not an ancestor of cwd).
    r = ad.Router()
    r.cwd = "/repo/frontend"
    r.git_root = "/repo"
    same = {"word": "otter", "port": 1, "project_dir": "/repo/backend",
            "pwd": "/repo/backend", "git_root": "/repo"}
    other = {"word": "badger", "port": 2, "project_dir": "/elsewhere",
             "pwd": "/elsewhere", "git_root": "/elsewhere"}
    assert r.repl_rank(same) == 0
    assert r.repl_rank(other) == ad.INF
    assert r.nearest([same, other])["word"] == "otter"
    print("PASS git-project rank (sibling subfolder scores 0)")


# --- resolution branches ----------------------------------------------------

def test_resolution(ad, reg):
    clear(reg)
    write_repl(reg, 101, 5001, "otter", "/home/u/projA")

    # single REPL, unrelated cwd -> silent
    r = ad.Router(); r.cwd = "/home/u/projB"
    sel, alt = r.resolve(call())
    assert alt is None and sel["word"] == "otter"

    # a nearer REPL appears -> reprompt (no elicitation cap -> fallback text)
    r.client_supports_elicitation = False
    write_repl(reg, 102, 5002, "badger", "/home/u/projB")
    sel, alt = r.resolve(call(2))
    assert sel is None and alt is not None
    txt = alt["result"]["content"][0]["text"]
    assert "badger" in txt and "otter" in txt
    assert "Suggested (nearest to this session): badger" in txt

    # explicit override argument is honored
    sel, alt = r.resolve(call(3, {"repl": "otter"}))
    assert alt is None and sel["word"] == "otter"

    # a NEW equally-near REPL (same git project as cwd) appears while one is
    # already selected -> reprompt (this is the sibling-subfolder case).
    r5 = ad.Router(); r5.cwd = "/repo/frontend"; r5.git_root = "/repo"
    r5.client_supports_elicitation = False
    clear(reg)
    write_repl(reg, 501, 7001, "otter", "/repo/a", git_root="/repo", pwd="/repo/a")
    sel, alt = r5.resolve(call(7))          # first sight -> single, silent
    assert alt is None and sel["word"] == "otter"
    write_repl(reg, 502, 7002, "badger", "/repo/b", git_root="/repo", pwd="/repo/b")
    sel, alt = r5.resolve(call(8))          # equally-near newcomer -> prompt
    assert sel is None and alt is not None

    # same-project restart -> silent rebind to the new port (word already known,
    # so the restart is not treated as a newcomer).
    r2 = ad.Router(); r2.cwd = "/home/u/projA"
    r2.selected = {"project_dir": "/home/u/projA", "port": 5001, "word": "otter"}
    r2.known_words = {"otter"}
    clear(reg); write_repl(reg, 201, 5999, "otter", "/home/u/projA")
    sel, alt = r2.resolve(call(4))
    assert alt is None and sel["port"] == 5999

    # a farther newcomer does NOT disturb the current selection
    r6 = ad.Router(); r6.cwd = "/home/u/projA"
    r6.selected = {"project_dir": "/home/u/projA", "port": 8001, "word": "otter"}
    r6.known_words = {"otter"}
    clear(reg)
    write_repl(reg, 601, 8001, "otter", "/home/u/projA")   # ancestor of cwd
    write_repl(reg, 602, 8002, "badger", "/home/u/elsewhere")  # unrelated (INF)
    sel, alt = r6.resolve(call(9))
    assert alt is None and sel["word"] == "otter"

    # ambiguous tie (two unrelated INF) -> prompt
    r3 = ad.Router(); r3.cwd = "/home/u/projC"; r3.client_supports_elicitation = False
    clear(reg)
    write_repl(reg, 301, 6001, "otter", "/home/u/projA")
    write_repl(reg, 302, 6002, "badger", "/home/u/projB")
    sel, alt = r3.resolve(call(5))
    assert sel is None and alt is not None

    # no REPLs -> clear error
    clear(reg)
    r4 = ad.Router(); r4.last_mtime = None
    sel, alt = r4.resolve(call(6))
    assert sel is None and "error" in alt and "No Julia REPL" in alt["error"]["message"]
    print("PASS resolution branches")


# --- elicitation round-trip (subprocess drives the real stdin/stdout loop) ---

class _Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        req = json.loads(self.rfile.read(n))
        if req.get("method") == "tools/call":
            res = {"jsonrpc": "2.0", "id": req["id"],
                   "result": {"content": [{"type": "text",
                              "text": "ran on %s" % self.server.word}]}}
        else:
            res = {"jsonrpc": "2.0", "id": req.get("id"), "result": {}}
        body = json.dumps(res).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def _fake_repl(word):
    srv = socketserver.TCPServer(("127.0.0.1", 0), _Handler)
    srv.word = word
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, srv.server_address[1]


def test_elicitation_roundtrip(reg):
    sA, pA = _fake_repl("otter")
    sB, pB = _fake_repl("badger")
    try:
        clear(reg)
        write_repl(reg, 1, pA, "otter", "/tmp/projA")
        write_repl(reg, 2, pB, "badger", "/tmp/projB")

        wrapper = os.path.join(reg, "_run.py")
        with open(wrapper, "w") as fh:
            fh.write(
                "import importlib.util, importlib.machinery, os\n"
                "l=importlib.machinery.SourceFileLoader('a', %r)\n"
                "s=importlib.util.spec_from_loader('a', l); a=importlib.util.module_from_spec(s); l.exec_module(a)\n"
                "a.REGISTRY_DIR=%r; a.TOOLS_CACHE=%r; a.pid_alive=lambda p: True; os.chdir('/tmp')\n"
                "a.main()\n" % (ADAPTER, reg, os.path.join(reg, "tc.json")))

        msgs = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": {"capabilities": {"elicitation": {}}}},
            call(2),
            # The user's answer to the first elicitation (id is deterministic).
            {"jsonrpc": "2.0", "id": "mcprepl-elicit-1",
             "result": {"action": "accept", "content": {"repl": "badger"}}},
        ]
        inp = "\n".join(json.dumps(m) for m in msgs) + "\n"
        p = subprocess.run([sys.executable, wrapper], input=inp,
                           capture_output=True, text=True, timeout=30)
        out = [json.loads(l) for l in p.stdout.splitlines() if l.strip()]

        elicit = [o for o in out if o.get("method") == "elicitation/create"]
        assert elicit, "adapter should emit elicitation/create"
        enum = elicit[0]["params"]["requestedSchema"]["properties"]["repl"]["enum"]
        assert set(enum) == {"otter", "badger"}
        result = [o for o in out if o.get("id") == 2 and "result" in o]
        assert result and "ran on badger" in result[0]["result"]["content"][0]["text"]
        print("PASS elicitation round-trip")
    finally:
        sA.shutdown()
        sB.shutdown()


def _drive(reg, cwd, messages):
    """Run the real adapter as a subprocess in cwd; return emitted messages."""
    wrapper = os.path.join(reg, "_run.py")
    with open(wrapper, "w") as fh:
        fh.write(
            "import importlib.util, importlib.machinery, os\n"
            "l=importlib.machinery.SourceFileLoader('a', %r)\n"
            "s=importlib.util.spec_from_loader('a', l); a=importlib.util.module_from_spec(s); l.exec_module(a)\n"
            "a.REGISTRY_DIR=%r; a.TOOLS_CACHE=%r; a.pid_alive=lambda p: True; os.chdir(%r)\n"
            "a.main()\n" % (ADAPTER, reg, os.path.join(reg, "tc.json"), cwd))
    inp = "\n".join(json.dumps(m) for m in messages) + "\n"
    p = subprocess.run([sys.executable, wrapper], input=inp,
                       capture_output=True, text=True, timeout=30)
    return [json.loads(l) for l in p.stdout.splitlines() if l.strip()]


def test_manual_tools(reg):
    clear(reg)
    write_repl(reg, 1, 5001, "otter", "/tmp/projA")
    write_repl(reg, 2, 5002, "badger", "/tmp/projB")

    # list_repls and select_repl are exposed and answered by the adapter itself.
    out = _drive(reg, "/tmp", [
        {"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
         "params": {"name": "list_repls", "arguments": {}}},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
         "params": {"name": "select_repl", "arguments": {"repl": "badger"}}},
        {"jsonrpc": "2.0", "id": 4, "method": "tools/call",
         "params": {"name": "select_repl", "arguments": {"repl": "nope"}}},
    ])
    by_id = {o["id"]: o for o in out if "id" in o}
    names = [t["name"] for t in by_id[1].get("result", {}).get("tools", [])]
    assert "list_repls" in names and "select_repl" in names, names
    assert "otter" in by_id[2]["result"]["content"][0]["text"]
    assert "badger" in by_id[2]["result"]["content"][0]["text"]
    assert "Routing this session to 'badger'" in by_id[3]["result"]["content"][0]["text"]
    assert "No running REPL with word-id 'nope'" in by_id[4]["result"]["content"][0]["text"]
    print("PASS list_repls / select_repl tools")


def test_prompt_picker(reg):
    """The user-triggered `select-repl` prompt shows a picker and sets routing."""
    clear(reg)
    write_repl(reg, 1, 5001, "otter", "/tmp/projA")
    write_repl(reg, 2, 5002, "badger", "/tmp/projB")

    out = _drive(reg, "/tmp", [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize",
         "params": {"capabilities": {"elicitation": {}}}},
        {"jsonrpc": "2.0", "id": 2, "method": "prompts/list"},
        {"jsonrpc": "2.0", "id": 3, "method": "prompts/get",
         "params": {"name": "select-repl"}},
        # The user's answer to the picker (deterministic elicit id).
        {"jsonrpc": "2.0", "id": "mcprepl-elicit-1",
         "result": {"action": "accept", "content": {"repl": "badger"}}},
    ])
    by_id = {o["id"]: o for o in out if "id" in o}
    # initialize advertises the prompts capability
    assert "prompts" in by_id[1]["result"]["capabilities"]
    # prompts/list exposes select-repl
    assert by_id[2]["result"]["prompts"][0]["name"] == "select-repl"
    # a picker was shown
    assert any(o.get("method") == "elicitation/create" for o in out)
    # prompts/get returns a confirmation naming the chosen REPL
    assert "badger" in by_id[3]["result"]["messages"][0]["content"]["text"]
    print("PASS select-repl prompt (user-triggered picker)")


def main():
    reg = tempfile.mkdtemp(prefix="mcprepl-adapter-test-")
    try:
        ad = load_adapter(reg)
        test_rank(ad)
        test_git_rank(ad)
        test_resolution(ad, reg)
        test_manual_tools(reg)
        test_prompt_picker(reg)
        test_elicitation_roundtrip(reg)
        print("\nALL ADAPTER ROUTING TESTS PASSED")
        return 0
    finally:
        import shutil
        shutil.rmtree(reg, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
