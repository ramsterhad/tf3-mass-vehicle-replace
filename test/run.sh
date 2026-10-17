#!/bin/bash
# Offline test of Mass Vehicle Replace: mocks the game API, renders the window as a tree and checks
# layout rules and the replace logic. Usage: bash test/run.sh
# Environment: MOD (mod folder), LUA and LUAC (Lua 5.2 binaries); defaults below.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
MOD="${MOD:-$(cd "$HERE/.." && pwd)/mass_vehicle_replace_1}"
LUA="${LUA:-$HOME/.local/lua52/root/usr/bin/lua5.2}"
LUAC="${LUAC:-$HOME/.local/bin/luac52}"
LUACHECK="${LUACHECK:-$HOME/.local/bin/luacheck}"
# a Lua unpacked into ~/.local needs its shared library
if [ -d "$HOME/.local/lua52/root/usr/lib/x86_64-linux-gnu" ]; then
	export LD_LIBRARY_PATH="$HOME/.local/lua52/root/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

# mod metadata: valid JSON, limits from the modding wiki (name 32 and summary 100 characters)
python3 - "$MOD" <<'PY'
import json, sys
mod = sys.argv[1]
info = json.load(open(mod + "/_metadata/modinfo.json", encoding="utf-8"))
assert len(info["name"]) <= 32, "name longer than 32 characters"
assert len(info["summary"]) <= 100, "summary longer than 100 characters: %d" % len(info["summary"])
assert "\n" not in info["name"] and "\n" not in info["summary"], "name or summary contains a line break"
conf = json.load(open(mod + "/mod.json", encoding="utf-8"))
assert isinstance(conf["revision"], int) and conf["revision"] > 0, "mod.json revision must be a positive integer"
print("metadata ok: revision %d, summary %d characters" % (conf["revision"], len(info["summary"])))
PY
# compatibility rules (tf3-mod-compat): no overwritten game modules, chained replacements, mod prefix
python3 "$HERE/lint.py" "$MOD" mvr
# static analysis: undefined or misspelt globals, unused variables, shadowing (config in .luacheckrc)
"$LUACHECK" --config "$HERE/../.luacheckrc" --no-color -q "$MOD"

# translations: same keys and placeholders in both languages; the German strings feed the test
python3 - "$MOD/strings.json" "$HERE/strings_de.lua" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["en"].keys() == d["de"].keys(), "en/de keys differ"
for k in d["en"]:
    assert d["en"][k].count("%") == d["de"][k].count("%"), "placeholders differ: " + k
with open(sys.argv[2], "w", encoding="utf-8") as f:
    f.write("return {\n")
    for k, v in d["de"].items():
        f.write("\t[%s] = %s,\n" % (json.dumps(k), json.dumps(v, ensure_ascii=False)))
    f.write("}\n")
PY

# text hygiene of the whole repo: no broken encoding, Lua comments in ASCII
python3 "$HERE/textcheck.py" "$HERE/.."

# syntax of every Lua file of the mod, with the game's Lua version (5.2)
find "$MOD" -name '*.lua' -print0 | xargs -0 "$LUAC" -p
"$LUA" "$HERE/test_ft.lua" "$MOD/content/gui/mass_vehicle_replace.script.lua" "$MOD/content/gui/mass_vehicle_replace.css.lua" "$HERE/strings_de.lua"
