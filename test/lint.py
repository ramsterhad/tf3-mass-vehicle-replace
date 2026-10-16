#!/usr/bin/env python3
"""Compatibility lint for Transport Fever 3 GUI mods.

Enforces the mechanical part of the tf3-mod-compat rules, so that the mod never
overwrites game code other mods rely on. Usage: lint.py <mod folder> <prefix>
(prefix in lower case, e.g. "mvr": recipes "Mvr...", CSS classes "mvr-...",
translation keys "mvr_...").
"""
import json
import os
import re
import sys

mod, prefix = sys.argv[1], sys.argv[2]
Prefix = prefix[:1].upper() + prefix[1:]
errors = []


def error(path, line, msg):
    errors.append("%s:%d: %s" % (os.path.relpath(path, mod), line, msg))


def strip_comments(src):
    # good enough for our code: drops "--" comments outside of strings, keeps line numbers
    out = []
    for line in src.split("\n"):
        in_str = None
        cut = len(line)
        i = 0
        while i < len(line):
            c = line[i]
            if in_str:
                if c == "\\":
                    i += 1
                elif c == in_str:
                    in_str = None
            elif c in "\"'":
                in_str = c
            elif line.startswith("--", i):
                cut = i
                break
            i += 1
        out.append(line[:cut])
    return "\n".join(out)


# allowed file types in the mod folder; the game's mod validation rejects others (e.g. .orig from patch)
ALLOWED = (".lua", ".json", ".png", ".tga", ".dds")
for root, _dirs, files in os.walk(mod):
    for f in files:
        p = os.path.join(root, f)
        rel = os.path.relpath(p, mod).replace("\\", "/")
        if rel == "_metadata/mod.io_fileid.txt":
            continue
        if not f.endswith(ALLOWED):
            error(p, 0, "file type not allowed in a mod (game validation fails): " + f)

lua_files = []
for root, _dirs, files in os.walk(os.path.join(mod, "content")):
    for f in files:
        if f.endswith(".lua"):
            lua_files.append(os.path.join(root, f))

for p in lua_files:
    raw = open(p, encoding="utf-8").read()
    src = strip_comments(raw)
    lines = src.split("\n")

    def lineno(pos):
        return src.count("\n", 0, pos) + 1

    # rule: game modules are read-only; overwriting their fields breaks other mods
    # (CallOriginalRecipe, GetRecipeId and anyone reading the field)
    modules = set(re.findall(r"local\s+(\w+)\s*=\s*ug_require\b", src))
    modules |= set(re.findall(r"local\s+\w+\s*,\s*(\w+)\s*=\s*pcall\(\s*ug_require\b", src))
    for name in modules:
        for m in re.finditer(r"(?m)^\s*%s\s*(?:\.\s*\w+|\[[^\]]+\])\s*=(?!=)" % re.escape(name), src):
            error(p, lineno(m.start()), "assignment to a field of game module '%s'; use an extension point or a chained ReplaceRecipe" % name)

    # rule: functions missing or unsafe in the game's GUI Lua
    for fn in ("rawget", "rawset", "setfenv", "getfenv", "debug."):
        for m in re.finditer(r"(?<![\w.])%s" % re.escape(fn), src):
            error(p, lineno(m.start()), "'%s' is missing or unsafe in the game's GUI Lua" % fn.rstrip("."))

    # rule: every recipe replacement keeps an earlier replacement of another mod in the chain
    for m in re.finditer(r"ReplaceRecipe\(\s*([\w.]+)\s*,", src):
        target = m.group(1)
        if not re.search(r"currentReplacement\(\s*%s\s*\)" % re.escape(target), src):
            error(p, lineno(m.start()), "ReplaceRecipe(%s) without currentReplacement(%s): an earlier replacement would be lost" % (target, target))

    # rule: CallOriginalRecipe gets a recipe captured at load, never a module field read at call time
    for m in re.finditer(r"CallOriginalRecipe\(\s*([\w.]+)", src):
        if "." in m.group(1):
            error(p, lineno(m.start()), "CallOriginalRecipe(%s): capture the recipe in a local at load, other mods may swap the field" % m.group(1))

    # rule: names in shared namespaces carry the mod prefix
    for m in re.finditer(r"Register(?:Plugin|Wrapper)?Recipe\((?:[^,()]+,\s*)?\"(\w+)\"", src):
        if not m.group(1).startswith(Prefix):
            error(p, lineno(m.start()), "recipe name '%s' without prefix '%s' (recipe names are shared by all mods)" % (m.group(1), Prefix))
    if p.endswith(".css.lua"):
        for m in re.finditer(r"!([A-Za-z][\w-]*)", src):
            if not m.group(1).startswith(prefix + "-"):
                error(p, lineno(m.start()), "CSS class '%s' without prefix '%s-'" % (m.group(1), prefix))
    for m in re.finditer(r"_\(\s*\"([^\"]+)\"\s*\)", src):
        if not m.group(1).startswith(prefix + "_"):
            error(p, lineno(m.start()), "translation key '%s' without prefix '%s_'" % (m.group(1), prefix))

    # rule: replacement configs state their order explicitly
    if p.endswith(".res.lua") and "react-replacement-config" in src and not re.search(r"\border\s*=", src):
        error(p, 0, "react-replacement-config without explicit order")

strings = os.path.join(mod, "strings.json")
if os.path.exists(strings):
    data = json.load(open(strings, encoding="utf-8"))
    for lang, table in data.items():
        for key in table:
            if not key.startswith(prefix + "_"):
                error(strings, 0, "translation key '%s' (%s) without prefix '%s_'" % (key, lang, prefix))

for e in errors:
    print("LINT: " + e)
print("lint: %d files, %d problems" % (len(lua_files), len(errors)))
sys.exit(1 if errors else 0)
