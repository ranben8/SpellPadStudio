"""Read-only scope scanner: finds writes to undeclared (global) names and functions
with many active locals in the addon's top-level Lua files.

Run:  python -I tools/scan_globals.py [addon dir]
Needs the luaparser package (pip install luaparser). Expected writes are the addon's
own globals (SLASH_*, BINDING_NAME_*, GalleonBridgeDB, StreamDeckBridge_* functions);
anything else is a leak. Line numbers are not available from the parser.
"""
import os
import sys
import collections
from luaparser import ast, astnodes as N

root = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
files = sorted(f for f in os.listdir(root) if f.endswith(".lua"))

writes = collections.defaultdict(list)
parse_fail = []
heavy = []


class Scan:
    def __init__(self, fname):
        self.f = fname
        self.scopes = [set()]
        self.fns = []
        self.marks = []

    def declared(self, name):
        return any(name in s for s in self.scopes)

    def declare(self, name):
        self.scopes[-1].add(name)
        if self.fns:
            self.fns[-1]["cur"] += 1
            self.fns[-1]["max"] = max(self.fns[-1]["max"], self.fns[-1]["cur"])

    def push(self):
        self.scopes.append(set())
        self.marks.append(self.fns[-1]["cur"] if self.fns else 0)

    def pop(self):
        self.scopes.pop()
        m = self.marks.pop()
        if self.fns:
            self.fns[-1]["cur"] = m

    def func(self, params, body, selfparam=False):
        self.fns.append({"cur": 0, "max": 0})
        self.push()
        if selfparam:
            self.declare("self")
        for p in params:
            if isinstance(p, N.Name):
                self.declare(p.id)
        self.visit(body)
        self.pop()
        info = self.fns.pop()
        if info["max"] >= 100:
            heavy.append((self.f, info["max"]))

    def visit(self, n):
        if n is None:
            return
        if isinstance(n, list):
            for x in n:
                self.visit(x)
            return
        if not isinstance(n, N.Node):
            return
        if isinstance(n, N.Chunk):
            return self.visit(n.body)
        if isinstance(n, N.Block):
            self.push()
            self.visit(n.body)
            self.pop()
            return
        if isinstance(n, N.LocalAssign):
            self.visit(n.values)
            for tg in n.targets:
                self.declare(tg.id)
            return
        if isinstance(n, N.Assign):
            self.visit(n.values)
            for tg in n.targets:
                if isinstance(tg, N.Name):
                    if not self.declared(tg.id):
                        writes[tg.id].append(self.f)
                else:
                    self.visit(tg)
            return
        if isinstance(n, N.LocalFunction):
            self.declare(n.name.id)
            return self.func(n.args, n.body)
        if isinstance(n, N.Function):
            if isinstance(n.name, N.Name):
                if not self.declared(n.name.id):
                    writes[n.name.id].append(self.f)
            else:
                self.visit(n.name)
            return self.func(n.args, n.body)
        if isinstance(n, N.Method):
            self.visit(n.source)
            return self.func(n.args, n.body, selfparam=True)
        if isinstance(n, N.AnonymousFunction):
            return self.func(n.args, n.body)
        if isinstance(n, N.Fornum):
            self.visit(n.start)
            self.visit(n.stop)
            self.visit(n.step)
            self.push()
            self.declare(n.target.id)
            self.visit(n.body)
            self.pop()
            return
        if isinstance(n, N.Forin):
            self.visit(n.iter)
            self.push()
            for tg in n.targets:
                self.declare(tg.id)
            self.visit(n.body)
            self.pop()
            return
        if isinstance(n, N.Repeat):
            self.push()
            self.visit(n.body.body if isinstance(n.body, N.Block) else n.body)
            self.visit(n.test)
            self.pop()
            return
        if isinstance(n, N.Index):
            self.visit(n.value)
            if str(getattr(n, "notation", "")).endswith("SQUARE"):
                self.visit(n.idx)
            return
        if isinstance(n, N.Invoke):
            self.visit(n.source)
            self.visit(n.args)
            return
        if isinstance(n, (N.String, N.Number, N.Name)):
            return
        for k, v in n.__dict__.items():
            if k in ("line", "first_token", "last_token", "comments", "start_char", "stop_char", "source_name"):
                continue
            if isinstance(v, (N.Node, list)):
                self.visit(v)


for f in files:
    src = open(os.path.join(root, f), "rb").read().decode("utf-8", "replace")
    try:
        tree = ast.parse(src)
    except Exception as e:
        parse_fail.append((f, str(e)[:120]))
        continue
    Scan(f).visit(tree)

print("files scanned:", len(files), " parse failures:", len(parse_fail))
for f, e in parse_fail:
    print("  PARSE FAIL", f, e)
print("writes to undeclared names:")
for k in sorted(writes):
    print("  %s: %d (%s)" % (k, len(writes[k]), ", ".join(sorted(set(writes[k])))))
print("functions with 100+ active locals:", heavy if heavy else "none")
