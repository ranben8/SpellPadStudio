"""Static checks for SpellPad Studio; no game needed.

Run from anywhere:  python tools/check.py
Needs the lupa package (pip install lupa) for a real Lua 5.1 compile.
Exit code 1 when an error is found; warnings never fail the run.
"""
import os
import re
import sys

try:
    import lupa.lua51 as lupa
except ImportError:
    sys.exit("lupa is missing: pip install lupa")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
errors, warnings = [], []


def err(msg):
    errors.append(msg)


def warn(msg):
    warnings.append(msg)


def read(name):
    with open(os.path.join(ROOT, name), "rb") as f:
        return f.read()


# --- .toc ---------------------------------------------------------------
toc = read("SpellPadStudio.toc")
if b"\r" in toc:
    err("SpellPadStudio.toc must use LF line endings")
toc_lines = toc.decode("utf-8").split("\n")

interface = next((l for l in toc_lines if l.startswith("## Interface:")), "")
nums = re.findall(r"\d+", interface)
if len(nums) < 2:
    err("toc: '## Interface:' needs a retail number and 16001 (Forever): %r" % interface)
elif "16001" not in nums:
    err("toc: Interface line lacks 16001 (Forever)")
elif not any(len(n) == 6 for n in nums):
    err("toc: Interface line lacks a six-digit retail number")

listed = [l.strip() for l in toc_lines if l.strip() and not l.startswith("#")]
for entry in listed:
    path = entry.replace("\\", "/")
    folder = os.path.join(ROOT, os.path.dirname(path))
    # Exact-case match: the game is case-insensitive on Windows, the packager is not.
    if os.path.basename(path) not in os.listdir(folder if os.path.isdir(folder) else ROOT):
        err("toc lists '%s' but no file with exactly that name exists" % entry)
if len(set(listed)) != len(listed):
    err("toc lists a file twice")

top_lua = sorted(f for f in os.listdir(ROOT) if f.endswith(".lua"))
for f in top_lua:
    if f not in listed:
        err("%s is not listed in the toc" % f)

# --- Lua files ----------------------------------------------------------
lua = lupa.LuaRuntime()
compile_lua = lua.eval("function(s, n) local f, e = loadstring(s, n) return f ~= nil, e end")
for f in top_lua:
    data = read(f)
    ok, msg = compile_lua(data.decode("utf-8", "replace"), "@" + f)
    if not ok:
        err("%s does not compile: %s" % (f, msg))
    bare_lf = len(re.findall(rb"(?<!\r)\n", data))
    if bare_lf:
        err("%s has %d line(s) without CR (must be pure CRLF)" % (f, bare_lf))
    text = data.decode("utf-8", "replace")
    for n, line in enumerate(text.split("\r\n"), 1):
        if line.startswith("\t") or re.match(r" *\t", line):
            err("%s:%d tab indentation" % (f, n))
        elif line != line.rstrip():
            err("%s:%d trailing whitespace" % (f, n))
        if re.search(r'"[^"\n]*/sdb[^"\n]*"', line) and "SLASH_" not in line:
            warn("%s:%d visible text mentions /sdb (use /sps)" % (f, n))

# --- client tags --------------------------------------------------------
for f in top_lua:
    text = read(f).decode("utf-8", "replace")
    for n, line in enumerate(text.split("\r\n"), 1):
        for tag in re.findall(r'\bclient\s*=\s*"([^"]*)"', line):
            if tag not in ("retail", "forever"):
                err("%s:%d client tag '%s' is not retail or forever" % (f, n, tag))

# --- addon texture paths ------------------------------------------------
# A path like Interface\AddOns\SpellPadStudio\textures\icon.tga must exist with exactly that case (the
# packager runs on Linux), and a .tga must be an uncompressed 32-bit image (what the game reads without trouble).
path_re = re.compile(r'Interface[\\]+AddOns[\\]+SpellPadStudio[\\]+([A-Za-z0-9_ .\\-]+?[.](?:tga|blp))')
for f in ["SpellPadStudio.toc"] + top_lua:
    text = read(f).decode("utf-8", "replace")
    for m in path_re.finditer(text):
        rel = re.sub(r'[\\]+', '/', m.group(1))
        full = os.path.join(ROOT, *rel.split('/'))
        folder = os.path.dirname(full)
        names = os.listdir(folder) if os.path.isdir(folder) else []
        if os.path.basename(full) not in names:
            err('%s refers to a texture that is not there: %s' % (f, rel))
        elif rel.lower().endswith('.tga'):
            head = read(rel)[:18]
            if len(head) < 18 or head[2] != 2 or head[16] != 32:
                err('%s is not an uncompressed 32-bit TGA' % rel)

# --- report -------------------------------------------------------------
for w in warnings:
    print("warning:", w)
for e in errors:
    print("ERROR:", e)
print("%d Lua files, %d toc entries, %d errors, %d warnings" % (
    len(top_lua), len(listed), len(errors), len(warnings)))
sys.exit(1 if errors else 0)
