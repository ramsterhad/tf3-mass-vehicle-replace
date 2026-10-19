-- luacheck config for the mod (run by test/run.sh and CI)
std = "lua52" -- the game's GUI Lua

-- globals the game provides
read_globals = {
	"api", -- game API
	"_", -- translation function; loop variables use "__" instead
	"ug_require", -- the game's module loader
	"debugPrint",
	"_react", -- the game's react registry, read under pcall (currentReplacement)
	"getOwningModId", -- mod id of the calling file (api/tealdef/main.d.tl), read under pcall
}
-- .script.lua resources export through a global data()
globals = { "data" }

-- "__" marks a value that is not used (loop keys, callback arguments), like "_" elsewhere
ignore = { "21[123]/__", "4[23]3/__" }

-- long lines are part of the style (UI trees, messages)
max_line_length = false

