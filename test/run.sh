#!/bin/bash
# Lokaler Test des Fensters von Mass Vehicle Replace (WSL). Aufruf: bash run.sh
set -e
MOD="${MOD:-$(cd "$(dirname "$0")/.." && pwd)/mass_vehicle_replace_1}"
HERE="$(cd "$(dirname "$0")" && pwd)"
LUA="$HOME/.local/lua52/root/usr/bin/lua5.2"
export LD_LIBRARY_PATH="$HOME/.local/lua52/root/usr/lib/x86_64-linux-gnu"
python3 - "$MOD/strings.json" "$HERE/strings_de.lua" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["en"].keys() == d["de"].keys(), "en/de Schluessel ungleich"
for k in d["en"]:
    assert d["en"][k].count("%") == d["de"][k].count("%"), "Platzhalter ungleich: " + k
with open(sys.argv[2], "w", encoding="utf-8") as f:
    f.write("return {\n")
    for k, v in d["de"].items():
        f.write("\t[%s] = %s,\n" % (json.dumps(k), json.dumps(v, ensure_ascii=False)))
    f.write("}\n")
PY
"$HOME/.local/bin/luac52" -p "$MOD/content/gui/mass_vehicle_replace.script.lua" "$MOD/content/gui/mass_vehicle_replace.css.lua"
"$LUA" "$HERE/test_ft.lua" "$MOD/content/gui/mass_vehicle_replace.script.lua" "$MOD/content/gui/mass_vehicle_replace.css.lua" "$HERE/strings_de.lua"
