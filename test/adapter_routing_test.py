#!/usr/bin/env python3
"""
Fast, Julia-free tests for the `mcp-julia-adapter` routing logic.

Uses a synthetic registry directory and in-process fake HTTP REPLs, so it runs in
well under a second and needs no Julia. Covers the STATELESS routing model (the
adapter keeps no sticky selection):

  * rank() directory-distance semantics
  * resolution: single shared REPL used silently; >=2 REPLs never auto-picked
    (caller gets a listing + suggestion); explicit repl= honored; an unknown
    repl= errors instead of falling back; no REPLs errors
  * the identity guard: a word-id recycled onto a different project errors once,
    then adopts (a same-project restart rebinds silently)
  * routing a call end-to-end through the real stdin/stdout loop via explicit
    repl=, and the ambiguity listing when repl= is omitted

For the heavier end-to-end test with real Julia servers see
`integration_multiplex.py`.

Run:  python3 test/adapter_routing_test.py
"""

import http.server
import importlib.machinery
import importlib.util
import json
import os
import re
import socketserver
import subprocess
import sys
import tempfile
import threading
import time

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
    return mod


def write_repl(registry_dir, pid, port, word, project_dir, git_root="", pwd=None,
               private=False, spawn_token="", owner_pid=0, tmux_session=""):
    with open(os.path.join(registry_dir, "%d.json" % pid), "w") as fh:
        json.dump({"pid": pid, "port": port, "word": word,
                   "project_dir": project_dir, "pwd": pwd or project_dir,
                   "git_root": git_root,
                   "active_project": project_dir + "/Project.toml",
                   "private": private, "spawn_token": spawn_token,
                   "owner_pid": owner_pid, "tmux_session": tmux_session}, fh)


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

    # single shared REPL, unrelated cwd -> used silently
    r = ad.Router(); r.cwd = "/home/u/projB"
    sel, alt = r.resolve(call())
    assert alt is None and sel["word"] == "otter"

    # a second REPL appears -> NO default is kept: the caller gets a listing and
    # must retry with repl= (we never silently guess among several).
    write_repl(reg, 102, 5002, "badger", "/home/u/projB")
    sel, alt = r.resolve(call(2))
    assert sel is None and alt is not None
    txt = alt["result"]["content"][0]["text"]
    assert "badger" in txt and "otter" in txt
    assert "repl=" in txt
    assert "Suggested (nearest to this session): badger" in txt

    # explicit override is honored regardless of how many REPLs exist
    sel, alt = r.resolve(call(3, {"repl": "otter"}))
    assert alt is None and sel["word"] == "otter"

    # override to a word that is NOT live -> ERROR, never a silent fall-back
    sel, alt = r.resolve(call(4, {"repl": "ghost"}))
    assert sel is None and "error" in alt and "ghost" in alt["error"]["message"]

    # even with a unique strict-nearest, no-override with >=2 REPLs still returns
    # a listing (nearest is only a *suggestion*, never an automatic pick).
    r2 = ad.Router(); r2.cwd = "/home/u/projA/sub"
    sel, alt = r2.resolve(call(5))
    assert sel is None
    assert "Suggested (nearest to this session): otter" in \
        alt["result"]["content"][0]["text"]

    # no REPLs -> clear error
    clear(reg)
    r3 = ad.Router()
    sel, alt = r3.resolve(call(6))
    assert sel is None and "error" in alt and "No Julia REPL" in alt["error"]["message"]
    print("PASS resolution branches (stateless)")


def test_identity_guard(ad, reg):
    clear(reg)
    write_repl(reg, 101, 5001, "otter", "/home/u/projA")
    r = ad.Router(); r.cwd = "/tmp/x"

    # first explicit use binds otter -> projA
    sel, alt = r.resolve(call(1, {"repl": "otter"}))
    assert alt is None and sel["word"] == "otter"

    # same-project restart (new pid+port, SAME project_dir) -> silent rebind
    clear(reg); write_repl(reg, 202, 5999, "otter", "/home/u/projA")
    sel, alt = r.resolve(call(2, {"repl": "otter"}))
    assert alt is None and sel["port"] == 5999

    # otter recycled onto a DIFFERENT project -> one loud error (not a silent
    # hijack)...
    clear(reg); write_repl(reg, 303, 6001, "otter", "/home/u/projZ")
    sel, alt = r.resolve(call(3, {"repl": "otter"}))
    assert sel is None and "DIFFERENT" in alt["error"]["message"]
    # ...then a deliberate retry proceeds (the guard has adopted the new REPL).
    sel, alt = r.resolve(call(4, {"repl": "otter"}))
    assert alt is None and sel["port"] == 6001
    print("PASS identity guard (recycled word-id errors once, then adopts)")


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


def test_routing_subprocess(reg):
    """Drive the real stdin/stdout loop: explicit repl= routes end-to-end to the
    named fake REPL; omitting it with >=2 REPLs yields a listing, not a route."""
    sA, pA = _fake_repl("otter")
    sB, pB = _fake_repl("badger")
    try:
        clear(reg)
        write_repl(reg, 1, pA, "otter", "/tmp/projA")
        write_repl(reg, 2, pB, "badger", "/tmp/projB")

        # explicit repl= -> the call is forwarded to badger and its reply returns
        out = _drive(reg, "/tmp", [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": {"capabilities": {}}},
            call(2, {"repl": "badger"}),
        ])
        result = [o for o in out if o.get("id") == 2 and "result" in o]
        assert result and "ran on badger" in result[0]["result"]["content"][0]["text"]

        # no repl= with two REPLs -> a listing telling the caller to pass repl=,
        # NOT a silent route to either REPL.
        out2 = _drive(reg, "/tmp", [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": {"capabilities": {}}},
            call(2),
        ])
        r2 = [o for o in out2 if o.get("id") == 2 and "result" in o]
        txt = r2[0]["result"]["content"][0]["text"]
        assert "repl=" in txt and "ran on" not in txt
        print("PASS routing via explicit repl= (subprocess) + ambiguity listing")
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


def test_route_arg_schema(ad):
    """Every REPL-bound tool must advertise the optional `repl` routing arg, so a
    strict MCP client won't drop it — else an agent can't route past one REPL."""
    reply = {"jsonrpc": "2.0", "id": 1, "result": {"tools": [
        {"name": "exec_repl", "inputSchema": {"type": "object",
            "properties": {"expression": {"type": "string"}}}},
        {"name": "remove-trailing-whitespace", "inputSchema": {"type": "object",
            "properties": {"file_path": {"type": "string"}}}},
    ]}}
    out = ad.inject_adapter_tools(reply)
    tools = {t["name"]: t for t in out["result"]["tools"]}
    for name in ("exec_repl", "remove-trailing-whitespace"):
        props = tools[name]["inputSchema"]["properties"]
        assert "repl" in props and props["repl"]["type"] == "string", name
        # optional: NOT added to required (single-REPL fast path needs no arg)
        assert "repl" not in tools[name]["inputSchema"].get("required", []), name
    # adapter-owned tools are still appended, and are NOT given a spurious repl arg
    assert "list_repls" in tools and "spawn_repl" in tools
    assert "repl" not in tools["list_repls"]["inputSchema"].get("properties", {})
    print("PASS routable tools advertise optional repl= arg")


def test_manual_tools(reg):
    clear(reg)
    write_repl(reg, 1, 5001, "otter", "/tmp/projA")
    write_repl(reg, 2, 5002, "badger", "/tmp/projB")

    # list_repls is exposed and answered by the adapter itself; select_repl is
    # gone (routing is explicit via repl=, so there is nothing to "select").
    out = _drive(reg, "/tmp", [
        {"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
         "params": {"name": "list_repls", "arguments": {}}},
    ])
    by_id = {o["id"]: o for o in out if "id" in o}
    names = [t["name"] for t in by_id[1].get("result", {}).get("tools", [])]
    assert "list_repls" in names, names
    assert "select_repl" not in names, names
    txt = by_id[2]["result"]["content"][0]["text"]
    assert "otter" in txt and "badger" in txt
    assert "repl=" in txt   # tells the caller how to route
    print("PASS list_repls tool (explicit routing, no select_repl)")


# --- private REPLs: filtering, discoverability, spawn/kill, auto-kill --------

def _capture(ad):
    """Redirect the adapter's emit() into a list; returns (list, restore_fn)."""
    out = []
    saved = ad.emit
    ad.emit = lambda obj: out.append(obj)
    return out, (lambda: setattr(ad, "emit", saved))


def test_private_filtering(ad, reg):
    clear(reg)
    write_repl(reg, 700, 9000, "beaver", "/tmp/privP", private=True,
               spawn_token="tok-beaver", owner_pid=os.getpid())

    # Only a private REPL exists: automatic (no-override) resolution ignores the
    # pool and errors — but the message points the agent at its own private REPL.
    r = ad.Router(); r.cwd = "/tmp/x"
    sel, alt = r.resolve(call())
    assert sel is None and "beaver" in alt["error"]["message"]

    # ...but an explicit override reaches the private REPL even as the only one.
    r2 = ad.Router(); r2.cwd = "/tmp/x"
    sel, alt = r2.resolve(call(2, {"repl": "beaver"}))
    assert alt is None and sel and sel["word"] == "beaver"

    # A shared REPL alongside it: a no-override call routes to the SHARED one; the
    # private REPL is out of the pool and never becomes a silent default. This is
    # the crux of the stateless model.
    write_repl(reg, 701, 9001, "otter", "/tmp/x")
    r3 = ad.Router(); r3.cwd = "/tmp/x"
    sel, alt = r3.resolve(call(3))
    assert alt is None and sel["word"] == "otter"
    # The private REPL is still reachable by naming it — on every call.
    sel, alt = r3.resolve(call(4, {"repl": "beaver"}))
    assert alt is None and sel["word"] == "beaver"
    # Drop the override again -> back to the shared REPL (no stickiness).
    sel, alt = r3.resolve(call(5))
    assert alt is None and sel["word"] == "otter", (sel, alt)

    # list_repls shows this session's OWN private REPL (tagged), plus the shared
    # pool, but hides private REPLs owned by *other* live adapters.
    clear(reg)
    write_repl(reg, 700, 9000, "beaver", "/tmp/privP", private=True,
               spawn_token="tok-beaver", owner_pid=os.getpid())   # mine
    write_repl(reg, 701, 9001, "otter", "/tmp/x")                 # shared
    write_repl(reg, 1, 9002, "lynx", "/tmp/peer", private=True,
               spawn_token="tok-lynx", owner_pid=1)               # another live adapter
    out, restore = _capture(ad)
    try:
        ad._handle_list_repls(ad.Router(), {"id": 9, "params": {}})
    finally:
        restore()
    txt = out[-1]["result"]["content"][0]["text"]
    assert "otter" in txt, txt
    assert "beaver" in txt and "(private, yours)" in txt, txt
    assert "lynx" not in txt, txt
    print("PASS private REPL filtering (own private discoverable, peers' hidden)")


def test_usage_instructions(ad, reg):
    clear(reg)  # zero REPLs: must still work
    out, restore = _capture(ad)
    try:
        ad._handle_usage_instructions({"id": 1})
    finally:
        restore()
    txt = out[-1]["result"]["content"][0]["text"]
    assert "spawn_repl" in txt and "private" in txt.lower()
    print("PASS usage_instructions (adapter-owned, zero-REPL-safe)")


def test_initialize_instructions(ad, reg):
    clear(reg)  # no REPL -> the adapter answers initialize statically
    out, restore = _capture(ad)
    try:
        ad.handle_message(ad.Router(), {
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"capabilities": {}}})
    finally:
        restore()
    result = out[-1]["result"]
    assert "instructions" in result and "spawn_repl" in result["instructions"]
    print("PASS initialize teaser (instructions advertised)")


def _fake_tmux(reg, calls, word):
    """A run_tmux stub that records calls and, on new-session, registers the REPL."""
    def _run(args):
        calls.append(list(args))
        if args and args[0] == "new-session":
            # The launch command is a single shell-quoted string; dig the token out.
            # The real REPL records the adapter-chosen session name (passed via
            # MCPREPL_TMUX_SESSION / the -s arg); mirror that so kill/reap target it.
            m = re.search(r"MCPREPL_SPAWN_TOKEN=(\S+)", " ".join(args))
            sess = args[args.index("-s") + 1] if "-s" in args else ""
            if m:
                write_repl(reg, 90001, 6000, word, "/tmp/spawnP", private=True,
                           spawn_token=m.group(1), owner_pid=os.getpid(),
                           tmux_session=sess)
        return (0, "", "")
    return _run


def test_spawn_kill(ad, reg):
    clear(reg)
    ad.SPAWNED_SESSIONS.clear()
    calls = []
    saved = (ad.run_tmux, ad.shutil.which, ad.SPAWN_TIMEOUT, ad.SPAWN_POLL)
    ad.run_tmux = _fake_tmux(reg, calls, "beaver")
    ad.shutil.which = lambda name: "/usr/bin/tmux"
    ad.SPAWN_TIMEOUT, ad.SPAWN_POLL = 5.0, 0.01
    try:
        out, restore = _capture(ad)
        try:
            ad._handle_spawn_repl(ad.Router(), {
                "id": 1, "params": {"name": "spawn_repl",
                                    "arguments": {"project": reg}}})
        finally:
            restore()
        txt = out[-1]["result"]["content"][0]["text"]
        assert "beaver" in txt, txt
        new = [c for c in calls if c and c[0] == "new-session"]
        assert new and "MCPREPL_OWNER_PID=" in " ".join(new[0])
        assert any(s.startswith(ad.SESSION_PREFIX) for s in ad.SPAWNED_SESSIONS)
        # The REPL activates the requested project AND starts in it, so relative
        # paths resolve there rather than in the adapter's cwd.
        real = os.path.realpath(reg)
        assert "--project=" + real in " ".join(new[0]), new[0]
        assert new[0][new[0].index("-c") + 1] == real, new[0]

        # kill_repl refuses a shared (non-private) REPL...
        write_repl(reg, 90002, 6001, "otter", "/tmp/shared")
        out, restore = _capture(ad)
        try:
            ad._handle_kill_repl(ad.Router(), {
                "id": 2, "params": {"arguments": {"repl": "otter"}}})
        finally:
            restore()
        assert "Refusing" in out[-1]["result"]["content"][0]["text"]

        # ...and refuses another *live* adapter's private REPL (pid 1 is always
        # alive and is not us), without leaking its word-id as a suggestion.
        write_repl(reg, 90003, 6002, "lynx", "/tmp/peer", private=True,
                   spawn_token="tok-lynx", owner_pid=1)
        out, restore = _capture(ad)
        try:
            ad._handle_kill_repl(ad.Router(), {
                "id": 5, "params": {"arguments": {"repl": "lynx"}}})
        finally:
            restore()
        assert "another live session" in out[-1]["result"]["content"][0]["text"]
        out, restore = _capture(ad)
        try:
            ad._handle_kill_repl(ad.Router(), {
                "id": 6, "params": {"arguments": {"repl": "nosuch"}}})
        finally:
            restore()
        assert "lynx" not in out[-1]["result"]["content"][0]["text"]

        # ...but kills the private one and untracks its session.
        calls.clear()
        out, restore = _capture(ad)
        try:
            ad._handle_kill_repl(ad.Router(), {
                "id": 3, "params": {"arguments": {"repl": "beaver"}}})
        finally:
            restore()
        assert "Killed" in out[-1]["result"]["content"][0]["text"]
        assert any(c and c[0] == "kill-session" for c in calls)
        assert not any(s.startswith(ad.SESSION_PREFIX) for s in ad.SPAWNED_SESSIONS)

        # Naming a Project.toml (not a directory) puts the REPL in its folder.
        calls.clear()
        toml = os.path.join(reg, "Project.toml")
        open(toml, "w").close()
        out, restore = _capture(ad)
        try:
            ad._handle_spawn_repl(ad.Router(), {
                "id": 4, "params": {"name": "spawn_repl",
                                    "arguments": {"project": toml}}})
        finally:
            restore()
        os.remove(toml)
        new = [c for c in calls if c and c[0] == "new-session"]
        assert new and new[0][new[0].index("-c") + 1] == real, new[0]
        print("PASS spawn_repl / kill_repl (tracked, private-only kill, cwd)")
    finally:
        (ad.run_tmux, ad.shutil.which, ad.SPAWN_TIMEOUT, ad.SPAWN_POLL) = saved
        ad.SPAWNED_SESSIONS.clear()


def test_spawn_failure_output(ad, reg):
    # Julia dies while loading MCPRepl: the error names the pane's last output,
    # returns without waiting out SPAWN_TIMEOUT, and cleans up the session.
    clear(reg)
    calls = []

    def _run(args):
        calls.append(list(args))
        if args[0] == "list-panes":
            return (0, "1\n", "")
        if args[0] == "capture-pane":
            return (0, "ERROR: Package MCPRepl not found\n\n", "")
        return (0, "", "")

    saved = (ad.run_tmux, ad.shutil.which, ad.SPAWN_TIMEOUT)
    ad.run_tmux = _run
    ad.shutil.which = lambda name: "/usr/bin/tmux"
    ad.SPAWN_TIMEOUT = 30.0
    out, restore = _capture(ad)
    try:
        t0 = time.time()
        ad._handle_spawn_repl(ad.Router(), {
            "id": 1, "params": {"arguments": {"project": reg}}})
        assert time.time() - t0 < 5, "a dead pane must end the wait early"
        txt = out[-1]["result"]["content"][0]["text"]
        assert "Package MCPRepl not found" in txt, txt
        assert any(c[0] == "kill-session" for c in calls)
        print("PASS spawn_repl failure shows the REPL's output")
    finally:
        restore()
        (ad.run_tmux, ad.shutil.which, ad.SPAWN_TIMEOUT) = saved


def test_autokill_and_reap(ad, reg):
    calls = []
    saved = (ad.run_tmux, ad.pid_alive)
    ad.run_tmux = lambda args: (calls.append(list(args)), (0, "", ""))[1]
    try:
        # reap_spawned_sessions kills exactly the sessions we spawned.
        ad.SPAWNED_SESSIONS.clear()
        ad.SPAWNED_SESSIONS.add("mcprepl-abc")
        ad.reap_spawned_sessions()
        assert ["kill-session", "-t", "mcprepl-abc"] in calls
        assert not ad.SPAWNED_SESSIONS

        # orphan reap: kill private w/ dead owner; spare live-owner / persist / shared.
        clear(reg)
        LIVE_OWNER, DEAD_OWNER = 111, 222
        # record pids (1..4) stay "alive" so read_registry keeps them; only the
        # dead owner distinguishes an orphan.
        alive = {1, 2, 3, 4, LIVE_OWNER}
        ad.pid_alive = lambda pid: pid in alive
        write_repl(reg, 1, 5000, "dead", "/tmp/a", private=True,
                   spawn_token="tok-dead", owner_pid=DEAD_OWNER)
        write_repl(reg, 2, 5001, "live", "/tmp/b", private=True,
                   spawn_token="tok-live", owner_pid=LIVE_OWNER)
        write_repl(reg, 3, 5002, "keep", "/tmp/c", private=True,
                   spawn_token="tok-keep", owner_pid=0)   # persist
        write_repl(reg, 4, 5003, "shared", "/tmp/d")       # not private
        calls.clear()
        ad.reap_orphan_private_sessions()
        killed = [c[2] for c in calls if c and c[0] == "kill-session"]
        assert killed == ["mcprepl-tok-dead"], killed
        print("PASS auto-kill on exit + orphan reap")
    finally:
        (ad.run_tmux, ad.pid_alive) = saved
        ad.SPAWNED_SESSIONS.clear()


# --- cancellation: notifications/cancelled -> interrupt the serving REPL ------

class _SlowInterruptibleHandler(http.server.BaseHTTPRequestHandler):
    """A fake REPL: `tools/call` blocks until an `interrupt` arrives (or times
    out), mimicking Julia serving a second request while an eval is in flight."""

    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        req = json.loads(self.rfile.read(n))
        m = req.get("method")
        if m == "interrupt":
            self.server.interrupts.append(req)
            res = {"jsonrpc": "2.0", "id": req.get("id"),
                   "result": {"interrupted": True}}
        elif m == "tools/call":
            for _ in range(300):                 # up to ~3s, cut short on interrupt
                if self.server.interrupts:
                    break
                time.sleep(0.01)
            res = {"jsonrpc": "2.0", "id": req["id"],
                   "result": {"content": [{"type": "text", "text": "eval-finished"}]}}
        else:
            res = {"jsonrpc": "2.0", "id": req.get("id"), "result": {}}
        body = json.dumps(res).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def test_cancellation(reg):
    # ThreadingHTTPServer so the interrupt POST is served concurrently with the
    # still-blocked tools/call — exactly how Julia's HTTP.serve! behaves.
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _SlowInterruptibleHandler)
    srv.interrupts = []
    port = srv.server_address[1]
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        clear(reg)
        write_repl(reg, 1, port, "otter", "/tmp/projA")
        out = _drive(reg, "/tmp", [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": {"capabilities": {}}},
            call(2),   # exec_repl -> routed to the slow fake REPL (blocks)
            # ...and while it blocks, the client cancels it (a notification).
            {"jsonrpc": "2.0", "method": "notifications/cancelled",
             "params": {"requestId": 2, "reason": "test"}},
        ])
        assert srv.interrupts, "adapter must post an interrupt on cancellation"
        assert srv.interrupts[0].get("method") == "interrupt"
        # The routed reply still comes back (its id is the caller's to ignore).
        assert any(o.get("id") == 2 and "result" in o for o in out)
        print("PASS cancellation -> interrupt posted to the serving REPL")
    finally:
        srv.shutdown()


# --- progress heartbeat while a routed call is open --------------------------

class _SlowHandler(http.server.BaseHTTPRequestHandler):
    """A fake REPL whose `tools/call` takes `server.delay` seconds."""

    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        req = json.loads(self.rfile.read(n))
        time.sleep(self.server.delay)
        res = {"jsonrpc": "2.0", "id": req.get("id"),
               "result": {"content": [{"type": "text", "text": "done"}]}}
        body = json.dumps(res).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def test_progress_heartbeat(ad):
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _SlowHandler)
    srv.delay = 0.6
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    saved_interval = ad.PROGRESS_INTERVAL
    ad.PROGRESS_INTERVAL = 0.1
    out, restore = _capture(ad)
    try:
        sel = {"port": srv.server_address[1], "word": "otter"}
        req = call(7)
        req["params"]["_meta"] = {"progressToken": "tok"}
        ad._forward_worker(None, sel, req)
        time.sleep(0.3)   # a stopped heartbeat must stay silent
        progress = [o for o in out if o.get("method") == "notifications/progress"]
        assert len(progress) >= 3, out
        assert all(o["params"]["progressToken"] == "tok" for o in progress)
        steps = [o["params"]["progress"] for o in progress]
        assert steps == sorted(set(steps)), "progress must increase"
        assert out[-1].get("id") == 7 and "result" in out[-1], "reply comes last"

        # Without a progressToken the client can't receive progress: send none.
        out.clear()
        ad._forward_worker(None, sel, call(8))
        assert [o.get("id") for o in out] == [8], out
        print("PASS progress heartbeat while a routed call is open")
    finally:
        restore()
        ad.PROGRESS_INTERVAL = saved_interval
        srv.shutdown()


def main():
    reg = tempfile.mkdtemp(prefix="mcprepl-adapter-test-")
    try:
        ad = load_adapter(reg)
        test_rank(ad)
        test_git_rank(ad)
        test_resolution(ad, reg)
        test_identity_guard(ad, reg)
        test_route_arg_schema(ad)
        test_manual_tools(reg)
        test_routing_subprocess(reg)
        test_private_filtering(ad, reg)
        test_usage_instructions(ad, reg)
        test_initialize_instructions(ad, reg)
        test_spawn_kill(ad, reg)
        test_spawn_failure_output(ad, reg)
        test_autokill_and_reap(ad, reg)
        test_cancellation(reg)
        test_progress_heartbeat(ad)
        print("\nALL ADAPTER ROUTING TESTS PASSED")
        return 0
    finally:
        import shutil
        shutil.rmtree(reg, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
