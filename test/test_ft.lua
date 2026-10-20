-- Local test for mass_vehicle_replace.script.lua without the game (Lua 5.2 like in the game).
-- Mocks api, react, builtin etc., builds the window in several situations and checks the rules
-- the game has crashed on or drawn wrongly so far.
-- Usage: lua5.2 test_ft.lua <script.lua> <css.lua> <strings_de.lua>

local SCRIPT, CSS, STRINGS = arg[1], arg[2], arg[3]
local failures, checks = 0, 0
local function fail(msg) failures = failures + 1; print("FAIL: " .. msg) end
local function check(cond, msg) checks = checks + 1; if not cond then fail(msg) end end
-- per-node rules of every rendered tree (layout gaps, CSS classes, entry shapes): they fail like checks but are not
-- counted one by one, else every render adds ~1000 "checks" and the total says nothing (review 18.10.2026)
local renders = 0
local function invariant(cond, msg) if not cond then fail(msg) end end

-- Translations -----------------------------------------------------------------------------------------
local strings = dofile(STRINGS)
function _(key)
	local s = strings[key]
	if s == nil then fail("translation missing: " .. tostring(key)); return tostring(key) end
	return s
end
local logs = {}
function debugPrint(...)
	local parts = {}
	for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
	logs[#logs + 1] = table.concat(parts, " ")
	print("LOG", ...)
end
local bankBalance = 5000000

-- builtin: every call returns a node -------------------------------------------------------------------
local LAYOUTS = { BoxLayout = true, FloatingLayout = true, GridLayout = true, TableLayout = true }
local builtin = setmetatable({
	type = {
		Orientation = { Horizontal = "H", Vertical = "V" },
		-- builtin.d.tl:10-14, used by the game for the tabs of entity windows (make_entity_window.tl:242)
		TabOrientation = { North = "N", South = "S" },
		ImageViewScaling = { AutoFit = "AutoFit", AutoZoom = "AutoZoom", Stretch = "Stretch" },
	},
}, { __index = function(t, kind)
	local f = function(a, b)
		local props = b or a or {}
		if b ~= nil then props = b end
		return { kind = kind, props = props }
	end
	rawset(t, kind, f)
	return f
end })

-- react ------------------------------------------------------------------------------------------------
local recipes = {}
local currentRecipe
local stateStore = {}
local stateIdx = 0
local react = {}
local function makeRecipe(name, fn)
	recipes[name] = fn
	return setmetatable({ name = name }, { __call = function(self, a, b)
		return { kind = "recipe:" .. name, props = b or a or {} }
	end })
end
react.RegisterRecipe = makeRecipe
react.RegisterWrapperRecipe = function(name, base, fn) return makeRecipe(name, fn) end
react.RegisterPluginRecipe = function(ext, name, fn) return makeRecipe(name, fn) end
react.useState = function(init)
	stateIdx = stateIdx + 1
	local key = currentRecipe .. "#" .. stateIdx
	if stateStore[key] == nil then stateStore[key] = { v = init } end
	local cell = stateStore[key]
	return { old = function() return cell.v end, set = function(_s, v) cell.v = v end }
end
react.useInputAction = function() end
react.iaHandler = function(f) return f end
react.onUnmount = function() end
react.onEvent = function() end
react.getCurrentRecipeName = function() return currentRecipe end
-- step and mount hooks of a recipe (react.d.tl:303-304, 340): collected per render, played by the test (hostFrame
-- below). onStepTimer bodies run as deferred steps with a restricted api in the game (react.lua:525-534); the mock
-- records them apart so a test can tell the two kinds.
-- MOCK: mock state of the queue tests in one table
-- MOCK: a global on purpose: the main chunk of this file is at Lua's limit of 200 locals
MOCK = { hooks = { steps = {}, timers = {}, mounts = {} }, hooksOf = {} }
react.onStep = function(fn) MOCK.hooks.steps[#MOCK.hooks.steps + 1] = fn end
react.onStepTimer = function(fn, interval) MOCK.hooks.timers[#MOCK.hooks.timers + 1] = { fn = fn, interval = interval } end
react.onMount = function(fn) MOCK.hooks.mounts[#MOCK.hooks.mounts + 1] = fn end
-- a ref whose value is computed once (react.d.tl:316); the earnings plugin reads isMapEditor that way
react.useRefLazy = function(fn)
	local v = fn()
	return { get = function() return v end }
end
-- like react.lua: recipes are known by id, a call goes to the replacement if one is set, and
-- CallOriginalRecipe only works with a registered recipe (in the game a plain function fails here)
_react = { recipeReplace = {} }
local recipeIds, originalFns = {}, {}
react.GetRecipeId = function(r) return recipeIds[r] end
local function gameRecipe(name, body)
	originalFns[name] = body
	local f = function(...)
		local rep = _react.recipeReplace[name]
		if rep then return rep(...) end
		return body(...)
	end
	recipeIds[f] = name
	return f
end
react.CallOriginalRecipe = function(r, ...)
	local id = recipeIds[r]
	if id == nil then error("attempt to call field '?' (a nil value)") end
	return originalFns[id](...)
end
local replacementApi = { ReplaceRecipe = function(original, replacement)
	local id = react.GetRecipeId(original)
	if id == nil then error("table index is nil") end
	_react.recipeReplace[id] = replacement
end }

local function render(name, params)
	currentRecipe, stateIdx = name, 0
	MOCK.hooks = { steps = {}, timers = {}, mounts = {} }
	local out = recipes[name](params)
	MOCK.hooksOf[name] = MOCK.hooks
	currentRecipe = nil
	return out
end

-- like the game (engine_react_util.tl:66-98): the function runs every step and the window is redrawn when its
-- value changes; stepStates keeps those of the last render, wouldRedraw() below plays a step
local stepStates = {}
local engine_react_util = { useStepState = function(f)
	local v = f()
	stepStates[#stepStates + 1] = { f = f, v = v }
	return { old = function() return v end }
end }
-- the timed variant (engine_react_util.tl:126-157) runs every interval seconds instead of every step; a step of the
-- mock stands for one tick of it, and the interval must be the game's default or shorter
engine_react_util.useStepStateTimer = function(f, interval)
	assert(interval == nil or interval <= 0.5, "useStepStateTimer interval above 0.5 s")
	local st = engine_react_util.useStepState(f)
	stepStates[#stepStates].timer = true
	return st
end
local spacerOrig = function() return { kind = "Spacer", props = {} } end
local gui_react_util = { makeHorizontalSpacer = spacerOrig }
local windows = {}
local game_react_globals = { getDefaultWindowApi = function() return {
	addWindow = function(recipe, key, params) windows[key] = { recipe = recipe, params = params } end,
	removeWindow = function(recipe, key) windows[key] = nil end,
} end }
local entity_window_util = { ActionButtonBar = gameRecipe("ActionButtonBar", function(ref, p) return { kind = "ActionButtonBar", props = p } end) }
-- the inner panel of the game's windows (entity_window_util.tl:2467-2489): two positional arguments
entity_window_util.ContentWidgetScrollContainer = function(children, first)
	assert(type(children) == "table" and type(first) == "boolean", "ContentWidgetScrollContainer(children, first)")
	return { kind = "ContentWidgetScrollContainer", props = { children = children } }
end
-- the game's text button (button_react_util.tl:6-30): 5th argument = disabled
MOCK.button_react_util = { makeTextButton = function(class, label, onClick, tooltip, disabled)
	assert(type(class) == "string" and type(label) == "string", "makeTextButton(class, text, ...)")
	return { kind = "Button", props = { meta = { class = class, tooltip = tooltip, enabled = disabled == nil and true or not disabled },
		content = { kind = "TextView", props = { meta = { class = "font-scale-body" }, text = label } }, onClick = onClick } }
end }
-- the game's dialog (menu/dialog_react_util.tl, params in dialog_react_util.d.tl:4-26)
MOCK.dialog_react_util = { DialogWindow = makeRecipe("DialogWindow", function(p) return { kind = "Window", props = p } end) }
-- the two extension points the queue uses (main/mod_entry_point.tl:5, game_bar/game_bar_widgets.tl:70)
MOCK.mod_entry_point = { ModEntryPointExtension = { id = "::ModEntryPointExtension" } }
MOCK.game_bar_widgets = { GameBarInfoDisplayExtension = { id = "::GameBarInfoDisplayExtension" } }
local MaintenanceStationWindow = makeRecipe("MaintenanceStationWindow", function() return builtin.BoxLayout{} end)
recipeIds[MaintenanceStationWindow] = "MaintenanceStationWindow"
originalFns.MaintenanceStationWindow = function(params) return { kind = "recipe:MaintenanceStationWindow", props = params } end

-- Minimal fake of the three vehicle_store_util functions the stats card calls (#16), nothing else of the module.
-- makeVehicleData(repId, isMultipleUnit) returns the game's VehicleData, a plain Lua table built by game Lua code
-- (vehicle_store_util.tl:122-391); here only the fields the card reads, per "m<id>" / "u<id>". A model without an
-- entry throws, like the game's code does on a model with missing metadata.
local storeStats, storeCalls = {}, {}
local vehicle_store_util = {
	makeVehicleData = function(repId, mu)
		assert(type(mu) == "boolean", "makeVehicleData: second argument must be a boolean")
		local key = (mu and "u" or "m") .. tostring(repId)
		storeCalls[#storeCalls + 1] = key
		local d = storeStats[key]
		if d == nil then error("attempt to index field 'metadata' (a nil value)") end
		local copy = {}
		for k, v in pairs(d) do copy[k] = v end
		return copy
	end,
	-- the game looks the carrier up in a table keyed by the enum (vehicle_util.tl:210-260); another form fails there
	getRangesFromData = function(d, carrier, year)
		assert(type(d) == "table" and type(year) == "number", "getRangesFromData: bad arguments")
		local known = false
		for _k, v in pairs(api.type.enum.Carrier) do if v == carrier then known = true end end
		if not known then error("bad argument #1 to 'ipairs' (table expected, got nil)") end
		return { noiseScoreRange = { 0, 1 }, pollutionScoreRange = { 0, 1 }, comfortScoreRange = { 0, 1 }, loadSpeedScoreRange = { 0.5, 10 } }
	end,
	-- vehicle_store_util.tl:393-406
	goodnessToTextString = function(v)
		if v < 0 then return "" elseif v < 0.2 then return "Sehr schlecht" elseif v < 0.4 then return "Schlecht"
		elseif v < 0.6 then return "Mittel" elseif v < 0.8 then return "Gut" end
		return "Sehr gut"
	end,
}
-- the game's card (content_card.tl:207-455): renders its collapsible part only while expanded; the mock keeps
-- the params so the test can expand it and render the body itself
local content_card = {
	ContentCard = makeRecipe("ContentCard", function() return builtin.BoxLayout{} end),
	makeRecipeAndParam = function(recipe, param) return { recipe = recipe, param = param } end,
}

local modules = {
	["::/gui/main/react.lua"] = react,
	["::/gui/line_vehicle_mgmt/vehicle_store_util.tl"] = vehicle_store_util,
	["::/gui/main/content_card.tl"] = content_card,
	["::/gui/main/builtin.lua"] = builtin,
	["::/gui/main/gui_react_util.tl"] = gui_react_util,
	["::/gui/main/engine_react_util.tl"] = engine_react_util,
	["::/gui/main/game_react_globals.tl"] = game_react_globals,
	["::/gui/entity_window/entity_window_util.tl"] = entity_window_util,
	["::/gui/main/button_react_util.tl"] = MOCK.button_react_util,
	["::/gui/menu/dialog_react_util.tl"] = MOCK.dialog_react_util,
	["::/gui/main/mod_entry_point.tl"] = MOCK.mod_entry_point,
	["::/gui/game_bar/game_bar_widgets.tl"] = MOCK.game_bar_widgets,
	["::/gui/entity_window/maintenance_station/maintenance_station.tl"] = MaintenanceStationWindow,
	["::/gui/entity_window/maintenance_station/maintenance_station_eow.script.tl"] = {
		MaintenanceStationEowExtensionPoint = { id = "::MaintenanceStationEowExtensionPoint" },
	},
}
function ug_require(path)
	local m = modules[path]
	if m == nil then error("ug_require unknown: " .. path) end
	return m
end

-- Game world -------------------------------------------------------------------------------------------
local Carrier = { ROAD = 0, RAIL = 1, TRAM = 2, AIR = 3, WATER = 4 }
local CT = { TRANSPORT_VEHICLE = "TV", GAME_TIME = "GT", VEHICLE_DEPOT = "VD", PLAYER_OWNED = "PO" }

-- engine types of the game (api/tealdef/api/type.d.tl:1892); the values are made up, only equality counts
local VehicleEngineType = { HORSE = 40, STEAM = 41, ELECTRIC = 42, DIESEL = 43 }
local models = {}
local function model(id, name, carrier, engine, yearFrom, yearTo, price, icons, group, noTags)
	models[id] = { metadata = {
		transportVehicle = { carrier = "meta_" .. carrier, compartments = { {} }, -- deliberately a different form than the enum
			groupFileName = group or "", filterTags = noTags and {} or { "passenger" } },
		landVehicle = (carrier ~= Carrier.WATER and carrier ~= Carrier.AIR) and { engines = engine and { {} } or {} } or nil,
		availability = { yearFrom = yearFrom, yearTo = yearTo },
		cost = { price = price },
		description = { name = name, icon20 = icons ~= false and ("vehicle/" .. id .. "_20.tga") or "", iconSmall = icons ~= false and ("vehicle/" .. id .. "_small.tga") or "" },
	} }
end
model(1, "Ae 4/7", Carrier.RAIL, true, 1927, 0, 900000)
model(2, "Avmz 111.1\nDB (Rot-Elfenbein)", Carrier.RAIL, false, 1970, 0, 300000)
model(3, "Bm 235 (IC)\nDB (Ozeanblau-Elfenbein)", Carrier.RAIL, false, 1975, 0, 280000)
model(4, "BR 103", Carrier.RAIL, true, 1970, 0, 1500000)
model(5, "BR 50", Carrier.RAIL, true, 1939, 0, 700000)
model(6, "Ein sehr sehr langer Wagenname mit Überlänge und noch mehr Text", Carrier.RAIL, false, 1960, 0, 250000, false)
model(10, "Benz Dreitonner Kipper", Carrier.ROAD, true, 1920, 1950, 60000)
model(11, "Benz Dreitonner Kasten", Carrier.ROAD, true, 1920, 0, 61000)
model(12, "Citaro G", Carrier.ROAD, true, 1998, 0, 400000)
-- digit runs beyond the integer range must still sort (Lua 5.2 %d fails on them)
model(13, "Lkw 12345678901234567890123", Carrier.ROAD, true, 1920, 0, 62000)
model(14, "Lkw 9", Carrier.ROAD, true, 1920, 0, 63000)
-- expires at the turn to 1981 (issue #3)
model(15, "Lkw Auslauf", Carrier.ROAD, true, 1920, 1981, 64000)
model(20, "Tram alt", Carrier.TRAM, true, 1900, 0, 100000)
model(30, "Schiff", Carrier.WATER, true, 1900, 0, 500000)
-- group head without tags (the purchase list hides it, in the game without image) and its variant
model(40, "Reihe 1042", Carrier.RAIL, true, 1960, 0, 1300000, false, nil, true)
model(41, "Reihe 1042", Carrier.RAIL, true, 1960, 0, 1300000, nil, "vehicle/40.mdl")
-- decoration copy from another mod (pileouface_rail_vehicle_assets): same data, no tags, no image
model(42, "Reihe 1042", Carrier.RAIL, true, 1960, 0, 1300000, false, nil, true)
-- a multiple unit without tags would not be for sale either
-- multiple unit parts
model(50, "ET 420 Endwagen", Carrier.RAIL, true, 1969, 0, 400000)
model(51, "ET 420 Mittelwagen", Carrier.RAIL, true, 1969, 0, 300000)
model(52, "ET 423 Endwagen", Carrier.RAIL, true, 1975, 0, 600000)
model(53, "ET 423 Mittelwagen", Carrier.RAIL, true, 1975, 0, 500000)
model(54, "ET 999 Zukunft", Carrier.RAIL, true, 2050, 0, 900000)
-- multiple unit with mixed end years: one part ends 1993, the other never (issue #3)
model(56, "ET 404 Endwagen", Carrier.RAIL, true, 1990, 1993, 500000)
model(57, "ET 404 Mittelwagen", Carrier.RAIL, true, 1990, 0, 400000)
-- railcars: engine and passengers (like ACF M-300); locomotives carry only crew without cargo type (like in the game)
model(60, "ACF M-300", Carrier.RAIL, true, 1924, 0, 1582128)
model(61, "Roter Pfeil", Carrier.RAIL, true, 1935, 0, 1200000)
-- engines with a type like landVehicle.engines in the game (VehicleEngine.type, type.d.tl:3980-3984);
-- models without it keep an engine without type, so the older tests never see an engine change
local function engines(id, ...)
	local list = {}
	for k, et in ipairs({ ... }) do list[k] = { type = VehicleEngineType[et] } end
	models[id].metadata.landVehicle.engines = list
end
engines(1, "ELECTRIC") -- Ae 4/7
engines(4, "ELECTRIC") -- BR 103
engines(5, "STEAM") -- BR 50
engines(50, "ELECTRIC"); engines(51, "ELECTRIC") -- ET 420
engines(52, "ELECTRIC"); engines(53, "DIESEL") -- ET 423: one part diesel, to see the types of all parts
local function load(id, classes, cap)
	models[id].metadata.transportVehicle.compartments = { { loadConfigs = { { cargoEntry = { capacity = cap,
		cargoTypeSet = { cargoClassesIncluded = classes, cargoTypesIncluded = {}, cargoClassesExcluded = {}, cargoTypesExcluded = {} } } } } } }
end
load(60, { "PASSENGERS" }, 80)
load(61, { "PASSENGERS" }, 60)
load(1, {}, 4) -- Ae 4/7 with crew
model(7, "Universalwagen", Carrier.RAIL, false, 1960, 0, 200000)
load(7, { "COAL", "IRON_ORE", "GRAIN", "LOGS", "OIL", "STONE" }, 40)
model(8, "Sammelwagen", Carrier.RAIL, false, 1960, 0, 210000)
do
	local classes = { "COAL", "IRON_ORE", "GRAIN", "LOGS", "OIL", "STONE" }
	for k = 8, 20 do classes[#classes + 1] = "C" .. k end
	load(8, classes, 40)
end
load(2, { "PASSENGERS" }, 60)
load(3, { "PASSENGERS" }, 70)
load(51, { "PASSENGERS" }, 100)
load(53, { "PASSENGERS" }, 120)
load(54, { "PASSENGERS" }, 50)
load(57, { "PASSENGERS" }, 110)
model(55, "EMD F A-Einheit", Carrier.RAIL, true, 1949, 0, 3000000)
load(55, {}, 4)
load(6, { "COAL" }, 40)
-- dummy locomotive like in mod 6157450: no engine, only crew without cargo type
model(70, "Fake - BR 246", Carrier.RAIL, false, 2006, 0, 0)
load(70, {}, 4)
local mus = {
	[900] = { name = "ET 420", filterTags = { "default" }, vehicles = { { name = "vehicle/50.mdl", forward = true }, { name = "vehicle/51.mdl", forward = true }, { name = "vehicle/50.mdl", forward = false } } },
	[901] = { name = "ET 423", filterTags = { "default" }, vehicles = { { name = "vehicle/52.mdl", forward = true }, { name = "vehicle/53.mdl", forward = true }, { name = "vehicle/53.mdl", forward = true }, { name = "vehicle/52.mdl", forward = false } } },
	[902] = { name = "ET 999", filterTags = { "default" }, vehicles = { { name = "vehicle/54.mdl", forward = true } } },
	[903] = { name = "EMD F-Serie", filterTags = { "default" }, vehicles = { { name = "vehicle/55.mdl", forward = true }, { name = "vehicle/55.mdl", forward = false } } },
	[904] = { name = "ET 404", filterTags = { "default" }, vehicles = { { name = "vehicle/56.mdl", forward = true }, { name = "vehicle/57.mdl", forward = true }, { name = "vehicle/56.mdl", forward = false } } },
}

-- Engine records are userdata in the game, not tables (tf3-sdk knowledge/api-value-types.md; game test 18.10.2026:
-- a type(r) == "table" check on getRevision passed in a table mock and failed in the game). A file handle with its
-- own metatable is real userdata in Lua 5.2: type() says "userdata", pairs/next/table.* fail like on the engine's.
-- Only declared fields can be set, like "Could not assign value to userdata".
local function engineRecord(name, real, onRead)
	local u = io.tmpfile()
	debug.setmetatable(u, {
		__index = function(_u, k)
			if onRead then onRead(k) end
			return real[k]
		end,
		__newindex = function(_u, k, v)
			if real[k] == nil then error("Could not assign value to userdata '" .. tostring(k) .. "' (" .. name .. ")") end
			real[k] = v
		end,
		__pairs = function() error("pairs on userdata " .. name) end,
		__tostring = function() return "userdata: " .. name end,
	})
	return u
end
local vehicles = {}
local fleetBuildReads = 0 -- carrier reads of vehicles: only a fleet build reads them (#10)
-- groups: nil = each part its own group; otherwise { {size, file name}, ... } like in the game
local function vehicle(id, parts, groups)
	local list = {}
	local carrier = tonumber(models[parts[1]].metadata.transportVehicle.carrier:match("%d+"))
	for i, m in ipairs(parts) do list[i] = { part = { modelId = m, reversed = false, color = "farbe" .. id } } end
	local sizes, paths = {}, {}
	if groups then
		for i, g in ipairs(groups) do sizes[i], paths[i] = g[1], g[2] end
	else
		for i = 1, #parts do sizes[i], paths[i] = 1, "" end
	end
	-- carrier is read when the fleet is built (an entry per model), not by the cheap per-step part check (#10)
	local real = { carrier = carrier, transportVehicleConfig = { vehicles = list, vehicleGroups = sizes, muFileNames = paths } }
	vehicles[id] = engineRecord("TransportVehicle", real, function(k)
		if k == "carrier" then fleetBuildReads = fleetBuildReads + 1 end
	end)
end
vehicle(100, { 1, 2, 2, 2, 3 })
vehicle(101, { 1, 2, 2, 6 })
vehicle(102, { 5, 3, 3 })
-- double traction ET 420 plus a loose wagon 2 behind it
vehicle(103, { 50, 51, 50, 50, 51, 50, 2 }, { { 3, "multiple_unit/et420.mdl" }, { 3, "multiple_unit/et420.mdl" }, { 1, "" } })
vehicle(104, { 50, 51, 50 }, { { 3, "multiple_unit/et420.mdl" } })
vehicle(105, { 4 })
vehicle(106, { 60 })
vehicle(107, { 5, 7, 8 })
vehicle(108, { 5, 70, 7 }) -- train with a dummy locomotive
for v = 110, 117 do vehicle(v, { 10 }) end
vehicle(120, { 20 })
-- owner per vehicle (PLAYER_OWNED.player); the player is 7. Campaign missions hand vehicles to AI
-- players (tf3-sdk knowledge/ownership.md): truck 130 of the same model as 110-117 belongs to one.
local PLAYER = 7
local owners = setmetatable({}, { __index = function() return PLAYER end })
vehicle(130, { 10 })
owners[130] = 99
local currentYear = 1980
local TransportMode = { CAR = 10, BUS = 11, TRUCK = 12, TRAM = 13, ELECTRIC_TRAM = 14, TRAIN = 15, ELECTRIC_TRAIN = 16, SHIP = 17, SMALL_SHIP = 18, AIRCRAFT = 19, SMALL_AIRCRAFT = 20, HELICOPTER = 21, TRAM_TRACK = 22, ELECTRIC_TRAM_TRACK = 23 }
-- as observed in the game: carrier empty, the type is in the transport modes
local depots = {
	[500] = { transportModes = { [TransportMode.TRAIN] = true, [TransportMode.ELECTRIC_TRAIN] = true } },
	[501] = { transportModes = { [TransportMode.BUS] = true, [TransportMode.TRUCK] = true, [TransportMode.CAR] = false } },
	[502] = { carrier = Carrier.TRAM, transportModes = {} },
	[503] = { transportModes = { [TransportMode.BUS] = true, [TransportMode.TRAM] = true } }, -- mixed
}

local CARGO = { PASSENGERS = 1, COAL = 2, IRON_ORE = 3, GRAIN = 4, LOGS = 5, OIL = 6, STONE = 7 }
local CARGO_NAMES = { "Fahrgäste", "Kohle", "Eisenerz", "Getreide", "Holz", "Öl", "Stein" }
for k = 8, 20 do CARGO["C" .. k] = k; CARGO_NAMES[k] = "Fracht " .. k end
local sent = {}
local costPerCommand = 560000
-- commands waiting for the next simulation step; holdSteps keeps them waiting (game paused, slow step)
local queuedCommands = {}
local commandSucceeds, holdSteps = true, false
local refused = {}
local throwAtCommand -- n: sendCommand throws on the n-th command of the current test
local residuals, residualThrows = {}, false -- residual value per vehicle (#26)
local residualReads, deadReads = 0, 0
local gameTimeNow = 123 -- game time of the mock; advancing it means the game runs
-- value per existing part, set with partValue(vehicle, index, value); 0 by default (#26)
local partValues, partValueThrows = {}, false
local function partValue(v, j, value) partValues[vehicles[v].transportVehicleConfig.vehicles[j]] = value end
local function step()
	local q = queuedCommands
	queuedCommands = {}
	for _i, run in ipairs(q) do run() end
end
-- the game's GUI save data per mod id (api/tealdef/api/gui.d.tl:773-781); kept as a copy, like data that goes into
-- a savegame. What the game returns before anything was set is not measured: nil here, the mod handles both.
local guiSaveData = {}
local function copyTable(t)
	if type(t) ~= "table" then return t end
	local c = {}
	for k, v in pairs(t) do c[k] = copyTable(v) end
	return c
end
-- real time of the application in seconds (api/tealdef/api/util.d.tl:176), advanced by the test
MOCK.appClock = 1000
-- revision num[1] per vehicle (tf3-sdk knowledge/gui-change-detection-and-perf.md section 6): the engine's
-- identity slot; a test raises it to stand for an entity id reused for another entity
MOCK.births = {}
MOCK.mapEditor = false
MOCK.ownedReal = { player = PLAYER }
MOCK.owned = engineRecord("PlayerOwned", MOCK.ownedReal)
MOCK.revisionReal = { num = { 1, 5, 0 } }
MOCK.revision = engineRecord("Revision", MOCK.revisionReal)
-- native calls of the game API, for the budget checks of the queue (counted below)
MOCK.apiCalls, MOCK.apiCallsByName = 0, {}
api = {
	gui = { game = {
		getGuiSaveData = function(modId) return copyTable(guiSaveData[modId]) end,
		setGuiSaveData = function(modId, data) assert(type(data) == "table", "setGuiSaveData: table expected"); guiSaveData[modId] = copyTable(data) end,
		isMapEditor = function() return MOCK.mapEditor end,
	} },
	type = {
		ComponentType = CT,
		enum = { Carrier = Carrier, TransportMode = TransportMode, VehicleEngineType = VehicleEngineType },
		TransportVehiclePart = { new = function() return { part = {} } end },
		LoadConfig = { new = function() return {} end },
		TransportVehicleConfig = { new = function(c) return { vehicles = c.vehicles, vehicleGroups = c.vehicleGroups, muFileNames = c.muFileNames } end },
	},
	res = {
		cargoTypeRep = {
			-- like in the game: the cargo classes and single cargo types of the set make up the cargo types
			forEachCargoType = function(set, cb)
				local seen = {}
				for _i, c in ipairs(set.cargoClassesIncluded or {}) do if CARGO[c] and not seen[CARGO[c]] then seen[CARGO[c]] = true; cb(CARGO[c]) end end
				for _i, c in ipairs(set.cargoTypesIncluded or {}) do if CARGO[c] and not seen[CARGO[c]] then seen[CARGO[c]] = true; cb(CARGO[c]) end end
			end,
			-- the game's order deliberately differs from the numbers: oil before coal
			get = function(id) CARGO_GETS = (CARGO_GETS or 0) + 1; return { name = CARGO_NAMES[id], icon = "cargo/" .. id .. ".tga", order = id == 6 and 0 or id } end,
		},
		modelRep = {
			getAll = function() local t = {}; for id in pairs(models) do t[id] = true end; return t end,
			get = function(id) return models[id] end,
			getName = function(id) return "vehicle/" .. id .. ".mdl" end,
			find = function(name) local id = tonumber(name:match("^vehicle/(%d+)%.mdl$")); return (id and models[id]) and id or -1 end,
		},
		multipleUnitRep = {
			getAll = function() local t = {}; for id in pairs(mus) do t[id] = true end; return t end,
			get = function(id) return mus[id] end,
			getName = function(id) return ({ [900] = "multiple_unit/et420.mdl", [901] = "multiple_unit/et423.mdl", [902] = "multiple_unit/et999.mdl", [903] = "multiple_unit/emd_f.mdl", [904] = "multiple_unit/et404.mdl" })[id] end,
		},
	},
	engine = {
		-- filters as in api/tealdef/api/engine.d.tl EntityFilters: requireOwnedByPlayer, filterFn
		getEntitiesWithComponent = function(ct, filters)
			for k in pairs(filters or {}) do assert(k == "requireOwnedByPlayer" or k == "filterFn", "unknown entity filter " .. tostring(k)) end
			local owner = filters and filters.requireOwnedByPlayer
			local t = {}
			if ct == CT.TRANSPORT_VEHICLE then
				for id in pairs(vehicles) do
					if owner == nil or owners[id] == owner then t[#t + 1] = id end
				end
			end
			table.sort(t)
			return t
		end,
		getComponent = function(e, ct)
			if ct == CT.TRANSPORT_VEHICLE then return vehicles[e] end
			if ct == CT.GAME_TIME then return { gameTime = gameTimeNow } end
			if ct == CT.VEHICLE_DEPOT then return depots[e] end
			-- the owner, the way the game's entity windows read it (eow_extension_util.tl:5-17); one shared record
			-- (a file handle each), its field set per call
			if ct == CT.PLAYER_OWNED then
				if not vehicles[e] then return nil end
				MOCK.ownedReal.player = owners[e]
				return MOCK.owned
			end
		end,
		entityExists = function(e) return depots[e] ~= nil or vehicles[e] ~= nil end,
		-- userdata with num = {rev0, rev1, rev2} (api/tealdef/api/engine.d.tl:15-18); what it does for an entity that
		-- does not exist is not measured: the mock throws, so the code must check entityExists first
		getRevision = function(e)
			assert(vehicles[e], "revision of an unknown entity")
			MOCK.revisionReal.num = { MOCK.births[e] or 1, 5, 0 }
			return MOCK.revision
		end,
		util = { getYear = function() return currentYear end, getWorld = function() return 0 end, getPlayer = function() return PLAYER end,
			finance = { getPlayersBalance = function(pl) assert(pl == PLAYER); return bankBalance end },
			-- residual value per whole vehicle (api/tealdef/api/engine/util.d.tl:465-468); 0 unless a test sets it
			vehicle = { getDepreciatedValue = function(v)
				if not vehicles[v] then deadReads = deadReads + 1 end
				assert(vehicles[v], "residual value of an unknown vehicle")
				residualReads = residualReads + 1
				if residualThrows then error("no residual value") end
				return residuals[v] or 0
			end,
			-- value of a part (api/tealdef/api/engine/util.d.tl:469-472); only parts of existing vehicles have one
			getPartPrice = function(part)
				local known = false
				for _v, veh in pairs(vehicles) do
					for _j, p in ipairs(veh.transportVehicleConfig.vehicles) do if p == part then known = true end end
				end
				assert(known, "part value of a part that is not in any vehicle")
				if partValueThrows then error("no part value") end
				return partValues[part] or 0
			end } },
		system = { transportVehicleSystem = { getDepotVehicles = function(d) return d == 503 and { 120 } or {} end } },
	},
	util = { formatMoney = function(v) return "$" .. tostring(v) end,
		-- the game's counters with a thousands separator, as seen in the German game bar ("896.439")
		lang = { formatInt = function(v)
			local s = string.format("%d", v)
			local out = s:reverse():gsub("(%d%d%d)", "%1."):reverse()
			return (out:gsub("^%.", ""))
		end },
		getApplicationTime = function() return MOCK.appClock end,
		-- units as documented in api/tealdef/api/util.d.tl:36-96 (m/s, kW, kN, t)
		formatSpeed = function(v) return string.format("%.0f km/h", v * 3.6) end,
		formatPower = function(v) return string.format("%.0f kW", v) end,
		formatForce = function(v) return string.format("%.0f kN", v) end,
		formatWeight = function(v) return string.format("%.1f t", v) end,
	},
	cmd = {
		makeVehicleReplaceCmd = function(e, conf) return { e = e, conf = conf } end,
		-- like the game in the GUI state (api/tealdef/api/cmd.d.tl:2-10): the command runs in the next
		-- simulation step and its callback comes a frame later; step() below plays that out.
		-- Each executed command books a fixed amount, whatever the balance: measured 19.10.2026, the game carries out
		-- a replace it cannot pay for and lets the balance go negative (tf3-sdk knowledge/vehicles.md).
		-- refused[e]: the game answers this vehicle's command with success == false (cmd.d.tl callback).
		sendCommand = function(c, cb)
			if throwAtCommand and #sent + 1 == throwAtCommand then error("command rejected") end
			sent[#sent + 1] = c
			queuedCommands[#queuedCommands + 1] = function()
				if bankBalance then bankBalance = bankBalance - costPerCommand end
				if cb then cb(c, commandSucceeds and not refused[c.e], {}) end
			end
		end,
	},
}

-- every function of the game API counts as one native call (budget checks of the queue)
do
	local function countCalls(t)
		for k, v in pairs(t) do
			if type(v) == "function" then
				t[k] = function(...)
					MOCK.apiCalls = MOCK.apiCalls + 1
					MOCK.apiCallsByName[k] = (MOCK.apiCallsByName[k] or 0) + 1
					return v(...)
				end
			elseif type(v) == "table" then
				countCalls(v)
			end
		end
	end
	countCalls(api.engine); countCalls(api.util); countCalls(api.gui); countCalls(api.cmd)
end

-- Load the script ---------------------------------------------------------------------------------------
-- the game's GUI Lua has no rawget (crashed at startup in 1.0.1 testing)
rawget = nil
local chunk = assert(loadfile(SCRIPT))
chunk()
local exports = data()
check(type(exports.doReplace) == "function", "doReplace missing in data()")

-- another mod (like Manage Line From Vehicle) replaced the button bar before us and calls the
-- original through the module field
local otherBarCalls = 0
local barRecipe = entity_window_util.ActionButtonBar
_react.recipeReplace.ActionButtonBar = function(ref, p)
	otherBarCalls = otherBarCalls + 1
	return react.CallOriginalRecipe(entity_window_util.ActionButtonBar, ref, p)
end

-- Read the CSS classes ----------------------------------------------------------------------------------
local cssText = io.open(CSS):read("*a")
local cssClasses = {}
for c in cssText:gmatch("!(mvr%-[%w%-]+)") do cssClasses[c] = true end

-- Rules -------------------------------------------------------------------------------------------------
local COMPONENTS = { Component = true, TextView = true, ImageView = true }

local function walk(node, path, visit)
	if type(node) ~= "table" then return end
	visit(node, path)
	local p = node.props or {}
	if p.children then
		local n = 0
		for k in pairs(p.children) do if type(k) == "number" and k > n then n = k end end
		invariant(n == #p.children, path .. ": child list with a gap (nil) in " .. node.kind)
		for i = 1, n do walk(p.children[i], path .. "/" .. node.kind .. "[" .. i .. "]", visit) end
	end
	for _k, key in ipairs({ "child", "content", "layout" }) do
		if p[key] then walk(p[key], path .. "/" .. node.kind .. "." .. key, visit) end
	end
	if p.items then for i, it in ipairs(p.items) do walk(it, path .. "/items[" .. i .. "]", visit) end end
	-- TableLayout rows and their cells
	if p.rows then for i, r in ipairs(p.rows) do walk(r, path .. "/rows[" .. i .. "]", visit) end end
	if p.cells then for i, c in ipairs(p.cells) do walk(c, path .. "/cells[" .. i .. "]", visit) end end
end

local function rules(tree, label)
	renders = renders + 1
	check(tree and tree.kind == "BoxLayout", label .. ": recipe must return a layout, returns " .. tostring(tree and tree.kind))
	walk(tree, label, function(n, path)
		local p = n.props or {}
		local cls = p.meta and p.meta.class
		if cls then
			for c in tostring(cls):gmatch("mvr%-[%w%-]+") do
				invariant(cssClasses[c], path .. ": CSS class missing: " .. c)
			end
		end
		invariant(not (p.meta and p.meta.styleSheet and (p.meta.styleSheet.minSize or p.meta.styleSheet.maxSize or p.meta.styleSheet.gravity or p.meta.styleSheet.padding)),
			path .. ": makeStyle only knows size; minSize/maxSize/gravity/padding have no effect")
		if n.kind == "ComboBoxItem" then
			invariant(p.content and COMPONENTS[p.content.kind], path .. ": ComboBoxItem.content must be a component, is " .. tostring(p.content and p.content.kind))
		elseif n.kind == "ComboBox" then
			invariant(p.items and #p.items > 0, path .. ": ComboBox without entries")
			invariant(p.meta and type(p.meta.localKey) == "string" and p.meta.localKey:find("combo:" .. tostring(p.value) .. "|", 1, true) == 1,
				path .. ": ComboBox without a localKey for its value (the display would not update after changes)")
			local found = false
			for _i, it in ipairs(p.items or {}) do if it.props.value == p.value then found = true end end
			invariant(found, path .. ": ComboBox value " .. tostring(p.value) .. " is not an entry (the display would be empty)")
		elseif n.kind == "Component" and p.layout then
			invariant(LAYOUTS[p.layout.kind], path .. ": Component.layout must be a layout")
		elseif n.kind == "ImageView" then
			invariant(type(p.path) == "string" and p.path ~= "", path .. ": ImageView without path")
		elseif n.kind == "TextView" then
			invariant(type(p.text) == "string", path .. ": TextView without text")
			invariant(not tostring(p.text):find("\n"), path .. ": line break in text: " .. tostring(p.text))
		end
	end)
end

-- Helpers to operate the window -------------------------------------------------------------------------
local function find(tree, pred)
	local hits = {}
	walk(tree, "", function(n) if pred(n) then hits[#hits + 1] = n end end)
	return hits
end
local function combos(tree) return find(tree, function(n) return n.kind == "ComboBox" end) end
local function itemTexts(itemNode)
	local t = {}
	walk(itemNode, "", function(n) if n.kind == "TextView" then t[#t + 1] = n.props.text end end)
	return t
end
local function itemCount(c) return #c.props.items end
-- index of the first model: the placeholder is the first entry only while nothing is selected
local function firstModel(c) return (c.props.items[1] and c.props.items[1].props.value == "none") and 2 or 1 end
-- every list has the same number of lines and identically built entries (fixed height/width)
local function shapeOf(itemNode)
	local s = {}
	-- an image or an empty area count the same if the class is the same
	walk(itemNode, "", function(n)
		local cls = n.props.meta and n.props.meta.class
		local kind = (cls == "mvr-item-image") and "Bild" or (tostring(cls):find("mvr%-cargo%-icon") and "Fracht") or n.kind
		s[#s + 1] = kind == "Fracht" and kind or (kind .. ":" .. tostring(cls))
	end)
	return table.concat(s, ",")
end
local function sameShapes(tree, label)
	local shape
	for _c, c in ipairs(combos(tree)) do
		for _i, it in ipairs(c.props.items) do
			local s = shapeOf(it)
			shape = shape or s
			invariant(s == shape, label .. ": entries built differently:\n  " .. shape .. "\n  " .. s)
		end
	end
end

local lastWindow
local function openAndRender(label, carrier, locked)
	-- close the previous window like the user does (X)
	if lastWindow then lastWindow.params.onClose() end
	windows = {}
	-- like the buttons: open through the window API
	local opened
	if locked then
		-- depot button through the button bar
		exports.doReplace(replacementApi)
		local bar = entity_window_util.ActionButtonBar(nil, { primaryButtons = { { tag = "entityWindow.maintenanceStation.manageVehicle" } }, secondaryButtons = {} })
		check(#bar.props.secondaryButtons == 1, label .. ": depot button missing in the button bar")
		check(exports.depotProbeCondition({ entityId = carrier }) == false, label .. ": depot probe must never show its plugin")
		local bar2 = entity_window_util.ActionButtonBar(nil, { primaryButtons = { { tag = "entityWindow.maintenanceStation.manageVehicle" } }, secondaryButtons = {} })
		bar2.props.secondaryButtons[1].customItem.props.onClick()
		opened = true
	else
		-- the top bar of the vehicle management stays as in the game (the button there was removed)
		exports.doReplace(replacementApi)
		currentRecipe = "LineVehicleManagerTopBar"
		local sp = gui_react_util.makeHorizontalSpacer()
		currentRecipe = nil
		check(sp.kind == "Spacer", label .. ": top bar of the vehicle management was changed")
		-- depot without data: no preselection, all types
		exports.depotProbeCondition({ entityId = 999 })
		local bar = entity_window_util.ActionButtonBar(nil, { primaryButtons = { { tag = "entityWindow.maintenanceStation.manageVehicle" } }, secondaryButtons = {} })
		bar.props.secondaryButtons[1].customItem.props.onClick()
		opened = true
	end
	local w = windows["mass_vehicle_replace.window"]
	check(opened and w, label .. ": window not opened")
	lastWindow = w
	local win = render("MvrWindow", w.params)
	check(win.kind == "Window", label .. ": MvrWindow returns no Window")
	return w
end

local function content(label)
	-- a frame passes before the window is drawn again: commands sent so far have run
	if not holdSteps then step() end
	stepStates = {}
	local t = render("MvrContent", { onClose = function() end })
	rules(t, label)
	sameShapes(t, label)
	return t
end

-- Scenarios ---------------------------------------------------------------------------------------------
print("== Train depot")
openAndRender("train depot", 500, true)
local t = content("train depot")
local on = find(t, function(n) return n.kind == "ToggleButton" and n.props.meta.class == "mvr-filter" and n.props.value == 1 end)
check(#on == 1 and on[1].props.meta.tooltip == "Schiene: Loks und Wagen", "train depot: rail not preselected")
local cs = combos(t)
check(#cs == 2, "two lists expected, found " .. #cs)
-- old models: rail only, powered first, then wagons; natural sort (BR 50 before BR 103)
local names = {}
for i = firstModel(cs[1]), itemCount(cs[1]) do names[#names + 1] = itemTexts(cs[1].props.items[i])[1] end
print("  old: " .. table.concat(names, " | "))
check(names[1] == "ACF M-300" and names[2] == "ET 420" and names[3] == "Ae 4/7" and names[4] == "BR 50" and names[5] == "BR 103", "sort by name: railcar/multiple unit, then locomotives, BR 50 before BR 103")
for _i, n in ipairs(names) do check(not n:find("Endwagen") and not n:find("Mittelwagen"), "multiple unit part listed on its own: " .. n) end
for _i, n in ipairs(names) do check(not n:find("Benz") and not n:find("Tram"), "train depot shows another vehicle type: " .. n) end
for _i, n in ipairs(names) do check(not n:find("Fake"), "dummy locomotive listed on the left: " .. n) end
-- second line of wagons
local secondLines = {}
for i = firstModel(cs[1]), itemCount(cs[1]) do secondLines[#secondLines + 1] = itemTexts(cs[1].props.items[i])[2] end
print("  second lines: " .. table.concat(secondLines, " | "))
-- shortened name
local long = find(t, function(n) return n.kind == "TextView" and n.props.text:find("…") end)
check(#long > 0, "long name is not shortened")
check(long[1] and long[1].props.meta.tooltip ~= nil, "shortened name without tooltip")
-- nothing chosen in the new list: its top model is preselected, no placeholder line (user decision 19.10.2026; until
-- then the placeholder was selected)
check(cs[2].props.value ~= "none" and firstModel(cs[2]) == 1 and cs[2].props.value == cs[2].props.items[1].props.value,
	"new list without a choice should preselect its top model: " .. tostring(cs[2].props.value))

print("== Train depot: choose a wagon, choose a new model")
cs[1].props.onValueChange("m2")
t = content("wagon chosen")
cs = combos(t)
check(cs[1].props.value == "m2", "old selection does not stay")
local neuNames = {}
for i = firstModel(cs[2]), itemCount(cs[2]) do neuNames[#neuNames + 1] = itemTexts(cs[2].props.items[i])[1] end
print("  new: " .. table.concat(neuNames, " | "))
for _i, n in ipairs(neuNames) do check(not n:find("BR ") and n ~= "Ae 4/7", "wagon replacement shows a locomotive: " .. n) end
-- cargo filter: passenger cars only for wagons that carry passengers
local function neuList()
	local c = combos(content("cargo filter"))
	local l = {}
	for i = firstModel(c[2]), itemCount(c[2]) do l[#l + 1] = (itemTexts(c[2].props.items[i])[1]:gsub("\n.*", "")) end
	return table.concat(l, " | "), c
end
local nl = neuList()
check(nl:find("Bm 235") and not nl:find("Universalwagen") and not nl:find("Sammelwagen") and not nl:find("Überlänge"), "cargo filter for passenger car: " .. nl)
cs[1].props.onValueChange("m7")
nl = neuList()
print("  new for Universalwagen: " .. nl)
check(nl == "Sammelwagen", "Universalwagen: only Sammelwagen can load everything: " .. nl)
cs[1].props.onValueChange("m8")
nl = neuList()
print("  new for Sammelwagen: " .. nl)
check(not nl:find("Universalwagen") and not nl:find("Avmz"), "Sammelwagen: no wagon with less cargo: " .. nl)
cs[1].props.onValueChange("m2")
-- "Same cargo" toggle: off shows all wagons, on only matching ones again
local function cargoToggle()
	local tg = find(content("toggle"), function(n) return n.kind == "ToggleButton" and n.props.meta and n.props.meta.class == "mvr-cargo-filter" end)
	check(#tg == 1, "Same cargo toggle missing")
	return tg[1]
end
check(cargoToggle().props.value == 1, "Same cargo toggle should be on at first")
cargoToggle().props.onValueChange(0)
nl = neuList()
print("  new for Avmz without cargo filter: " .. nl)
check(cargoToggle().props.value == 0, "toggle does not stay off")
check(nl:find("Universalwagen") and nl:find("Sammelwagen") and nl:find("Bm 235"), "without cargo filter wagons are missing: " .. nl)
check(not nl:find("Fake"), "without cargo filter the dummy locomotive appears for passenger cars: " .. nl)
cargoToggle().props.onValueChange(1)
nl = neuList()
check(not nl:find("Universalwagen"), "cargo filter switched on again has no effect: " .. nl)
nl, cs = neuList()
cs[2].props.onValueChange("m3")
t = content("new chosen")
local big = find(t, function(n) return n.kind == "ImageView" and n.props.meta and n.props.meta.class == "mvr-big-image" end)
check(#big == 2, "two large images expected, " .. #big)
local summary = find(t, function(n) return n.kind == "TextView" and n.props.text:find("ersetzt") end)
check(#summary == 1, "summary missing")
print("  " .. (summary[1] and summary[1].props.text or "?"))
-- wagon 2: 6 pieces in 3 trains (one runs behind the multiple unit); new model 3 costs 280000
local price = find(t, function(n) return n.kind == "TextView" and n.props.text:find("Kaufpreis") end)
check(price[1] and price[1].props.text == "Kaufpreis: $1680000", "purchase price wrong: " .. tostring(price[1] and price[1].props.text))
check(summary[1] and summary[1].props.text == "3 Fahrzeuge werden ersetzt.", "count wrong")
-- the placeholder must not trigger anything
cs = combos(t)
cs[2].props.onValueChange("none")
t = content("placeholder clicked")
check(combos(t)[2].props.value == "m3", "placeholder cleared the selection")
-- with a selection the open lists have no placeholder line (game test 19.10.2026: an empty or "no vehicles" line on top)
check(firstModel(combos(t)[1]) == 1 and firstModel(combos(t)[2]) == 1, "placeholder listed although a model is selected")

print("== Sort by year")
local sorts = find(t, function(n) return n.kind == "ToggleButton" and n.props.meta.class == "mvr-sort" end)
-- each list has its own sort buttons (user decision 19.10.2026): old Name, old Year, new Name, new Year
check(#sorts == 4, "two sort buttons per list expected: " .. #sorts)
-- both lists start by year, the old oldest first, the new newest first (user decision 20.10.2026): no click needed
t = content("year")
cs = combos(t)
names = {}
for i = firstModel(cs[1]), itemCount(cs[1]) do names[#names + 1] = itemTexts(cs[1].props.items[i])[1] end
print("  old: " .. table.concat(names, " | "))
check(names[1] == "ACF M-300" and names[2] == "ET 420" and names[3] == "Ae 4/7" and names[4] == "BR 50" and names[5] == "BR 103", "year: 1924, 1969, then locomotives 1927, 1939, 1970")

do -- own block: the main chunk is at the 200 local limit
	-- a click on the active button turns the direction round (user decision 19.10.2026); it shows the game's icon
	local function sortButtons(tt) return find(tt, function(n) return n.kind == "ToggleButton" and n.props.meta.class == "mvr-sort" end) end
	local function iconOf(b)
		local ic = find(b, function(n) return n.kind == "ImageView" and n.props.meta and n.props.meta.class == "mvr-sort-icon" end)
		return ic[1] and ic[1].props.path or nil
	end
	local function oldNames(tt)
		local c, list = combos(tt)[1], {}
		for i = firstModel(c), math.min(firstModel(c) + 4, itemCount(c)) do list[#list + 1] = itemTexts(c.props.items[i])[1] end -- the five powered ones
		return table.concat(list, "|")
	end
	local sb = sortButtons(t)
	check(iconOf(sb[2]) and iconOf(sb[2]):find("ascending", 1, true) and iconOf(sb[1]) == nil,
		"sort: the active old Year button must show the ascending icon, the inactive one none")
	check(iconOf(sb[4]) and iconOf(sb[4]):find("descending", 1, true), "sort: new list by year must start descending")
	sb[2].props.onValueChange(0) -- the active button clicked again
	t = content("year old flipped")
	check(oldNames(t) == "ET 420|ACF M-300|BR 103|BR 50|Ae 4/7", "sort: second click must sort the old list newest first: " .. oldNames(t))
	check(iconOf(sortButtons(t)[2]):find("descending", 1, true), "sort: flipped button must show the descending icon")
	check(guiSaveData["mass_vehicle_replace_1"] and guiSaveData["mass_vehicle_replace_1"].sortOldAsc == false,
		"sort: direction not kept in the savegame")
	-- by name, Z to A on a second click
	sortButtons(t)[1].props.onValueChange(1)
	t = content("name old")
	check(oldNames(t) == "ACF M-300|ET 420|Ae 4/7|BR 50|BR 103", "sort: name must start A to Z: " .. oldNames(t))
	sortButtons(t)[1].props.onValueChange(0)
	t = content("name old flipped")
	check(oldNames(t) == "ET 420|ACF M-300|BR 103|BR 50|Ae 4/7", "sort: name second click must be Z to A: " .. oldNames(t))
	-- back to the state the following tests expect: old list by year, oldest first
	sortButtons(t)[2].props.onValueChange(1)
	t = content("year old again")
	check(oldNames(t) == "ACF M-300|ET 420|Ae 4/7|BR 50|BR 103", "sort: switching to year must start oldest first again: " .. oldNames(t))
end

print("== Replace")
sent = {}
local btn = find(t, function(n) return n.kind == "Button" and n.props.meta.class:find("mvr%-replace%-btn") end)[1]
btn.props.onClick()
print("  commands: " .. #sent)
check(#sent == 3, "wagon 2 is in 3 vehicles, commands: " .. #sent)
for _i, c in ipairs(sent) do
	if c.e == 103 then
		-- the multiple units stay, only the loose wagon is swapped
		local ids = {}
		for _j, part in ipairs(c.conf.vehicles) do ids[#ids + 1] = part.part.modelId end
		check(table.concat(ids, ",") == "50,51,50,50,51,50,3", "train 103 wrong: " .. table.concat(ids, ","))
		check(table.concat(c.conf.vehicleGroups, ",") == "3,3,1", "groups 103 wrong")
	end
end
for _i, c in ipairs(sent) do
	for _j, part in ipairs(c.conf.vehicles) do check(part.part.modelId ~= 2, "old model not replaced in " .. c.e) end
end
-- the result appears bottom left as soon as the window is redrawn (the new model is gone then)
sel_reset = true
t = content("after replace")
local res = find(t, function(n) return n.kind == "TextView" and n.props.text:find("Ersetzt:") end)
print("  " .. tostring(res[1] and res[1].props.text))
check(#res == 1, "result of the replacement is not shown")
local ic = find(t, function(n) return n.kind == "ImageView" and n.props.meta and n.props.meta.class == "mvr-btn-icon" end)
check(#ic == 1, "icon in the replace button missing")

print("== Swap a multiple unit as a whole")
openAndRender("train depot 2", 500, true)
t = content("train depot 2")
cs = combos(t)
check(cs[1].props.value == "m60", "railcar is not at the top: " .. tostring(cs[1].props.value))
cs[1].props.onValueChange("u900")
t = content("ET 420 chosen")
cs = combos(t)
check(itemTexts(cs[1].props.items[firstModel(cs[1]) + 1])[2] == "3 Triebzüge in 2 Zügen", "multiple unit second line: " .. tostring(itemTexts(cs[1].props.items[firstModel(cs[1]) + 1])[2]))
local muNeu = {}
for i = firstModel(cs[2]), itemCount(cs[2]) do muNeu[#muNeu + 1] = itemTexts(cs[2].props.items[i])[1] end
print("  new for ET 420: " .. table.concat(muNeu, " | "))
local secondEt423
for i = firstModel(cs[2]), itemCount(cs[2]) do if itemTexts(cs[2].props.items[i])[1] == "ET 423" then secondEt423 = itemTexts(cs[2].props.items[i])[2] end end
check(secondEt423 == "$2200000 · 1975 · 4-teilig", "second line ET 423: " .. tostring(secondEt423))
-- by year the new models come newest first, the old ones oldest first (user decision 19.10.2026)
check(table.concat(muNeu, "|") == "ET 423|Roter Pfeil|ACF M-300", "for ET 420 (by year, newest first, without locomotive pair): railcars and ET 423, no locomotives, no single parts: " .. table.concat(muNeu, "|"))
bankBalance = 10000000
cs[2].props.onValueChange("u901")
t = content("ET 423 chosen")
price = find(t, function(n) return n.kind == "TextView" and n.props.text:find("Kaufpreis") end)
check(price[1] and price[1].props.text == "Kaufpreis: $6600000", "multiple unit price (3 x 2200000): " .. tostring(price[1] and price[1].props.text))
summary = find(t, function(n) return n.kind == "TextView" and n.props.text:find("ersetzt") end)
check(summary[1] and summary[1].props.text == "2 Fahrzeuge werden ersetzt.", "multiple unit count: " .. tostring(summary[1] and summary[1].props.text))
sent = {}
costPerCommand = 3300000
bankBalance = 10000000
find(t, function(n) return n.kind == "Button" and n.props.meta.class:find("mvr%-replace%-btn") end)[1].props.onClick()
check(#sent == 2, "multiple unit: 2 commands expected, " .. #sent)
for _i, c in ipairs(sent) do
	local ids, rev = {}, {}
	for _j, part in ipairs(c.conf.vehicles) do ids[#ids + 1] = part.part.modelId; rev[#rev + 1] = tostring(part.part.reversed) end
	if c.e == 103 then
		check(table.concat(ids, ",") == "52,53,53,52,52,53,53,52,2", "train 103 after multiple unit swap: " .. table.concat(ids, ","))
		check(table.concat(c.conf.vehicleGroups, ",") == "4,4,1", "groups 103: " .. table.concat(c.conf.vehicleGroups, ","))
		check(table.concat(c.conf.muFileNames, ",") == "multiple_unit/et423.mdl,multiple_unit/et423.mdl,", "file names 103: " .. table.concat(c.conf.muFileNames, ","))
		check(rev[4] == "true" and rev[1] == "false", "direction of the end cars wrong")
		check(c.conf.vehicles[1].part.color == "farbe103", "paint not carried over")
	elseif c.e == 104 then
		check(table.concat(ids, ",") == "52,53,53,52", "train 104 after multiple unit swap: " .. table.concat(ids, ","))
	else
		fail("multiple unit swap hits another train " .. tostring(c.e))
	end
end

print("== Reversed multiple unit stays reversed")
-- Train 109: one ET 420 as defined (flags false,false,true) and one ET 420 reversed the way the game
-- stores it: part order reversed and every reversed flag flipped (false,true,true).
vehicle(109, { 50, 51, 50, 50, 51, 50 }, { { 3, "multiple_unit/et420.mdl" }, { 3, "multiple_unit/et420.mdl" } })
do
	local flags = { false, false, true, false, true, true }
	for k, f in ipairs(flags) do vehicles[109].transportVehicleConfig.vehicles[k].part.reversed = f end
end
openAndRender("train depot 2", 500, true)
t = content("reversed unit")
cs = combos(t)
cs[1].props.onValueChange("u900")
t = content("ET 420 selected")
cs = combos(t)
cs[2].props.onValueChange("u901")
t = content("ET 423 selected")
sent = {}
costPerCommand = 3300000
bankBalance = 20000000
find(t, function(n) return n.kind == "Button" and n.props.meta.class:find("mvr%-replace%-btn") end)[1].props.onClick()
local c109
for _i, c in ipairs(sent) do if c.e == 109 then c109 = c end end
check(c109 ~= nil, "no replace command for train 109")
if c109 then
	local ids, rev = {}, {}
	for _j, part in ipairs(c109.conf.vehicles) do ids[#ids + 1] = part.part.modelId; rev[#rev + 1] = part.part.reversed and "r" or "f" end
	print("  train 109 after replace: " .. table.concat(ids, ",") .. " flags " .. table.concat(rev))
	check(table.concat(ids, ",") == "52,53,53,52,52,53,53,52", "train 109 parts: " .. table.concat(ids, ","))
	-- ET 423 as defined is f,f,f,r; the reversed unit must be its mirror image r,f,f,f with flipped flags: f,r,r,r
	check(table.concat(rev) == "fffrfrrr", "train 109 orientation (expected fffrfrrr): " .. table.concat(rev))
	check(table.concat(c109.conf.muFileNames, ",") == "multiple_unit/et423.mdl,multiple_unit/et423.mdl", "train 109 file names")
end
vehicles[109] = nil

print("== Reversed single model stays reversed")
-- in-game test 16.10.2026: Talent 1 is a single model; a reversed one replaced by Talent 2 (a multiple
-- unit) came back facing forward. Train 119: two M-300, the second reversed, replaced by ET 423.
vehicle(119, { 60, 60 })
vehicles[119].transportVehicleConfig.vehicles[2].part.reversed = true
openAndRender("reversed single", 500, true)
t = content("reversed single")
cs = combos(t)
cs[1].props.onValueChange("m60")
t = content("M-300 selected")
cs = combos(t)
cs[2].props.onValueChange("u901")
t = content("ET 423 for M-300")
sent = {}
costPerCommand = 3300000
bankBalance = 20000000
find(t, function(n) return n.kind == "Button" and n.props.meta.class:find("mvr%-replace%-btn") end)[1].props.onClick()
local c119
for _i, c in ipairs(sent) do if c.e == 119 then c119 = c end end
check(c119 ~= nil, "no replace command for train 119")
if c119 then
	local ids, rev = {}, {}
	for _j, part in ipairs(c119.conf.vehicles) do ids[#ids + 1] = part.part.modelId; rev[#rev + 1] = part.part.reversed and "r" or "f" end
	check(table.concat(ids, ",") == "52,53,53,52,52,53,53,52", "train 119 parts: " .. table.concat(ids, ","))
	check(table.concat(rev) == "fffrfrrr", "train 119 orientation (expected fffrfrrr): " .. table.concat(rev))
end
vehicles[119] = nil

print("== Reversed multiple unit replaced by a single model")
-- train 109 again: the second ET 420 is reversed; replaced by Roter Pfeil, the second one faces backwards
vehicle(109, { 50, 51, 50, 50, 51, 50 }, { { 3, "multiple_unit/et420.mdl" }, { 3, "multiple_unit/et420.mdl" } })
do
	local flags = { false, false, true, false, true, true }
	for k, f in ipairs(flags) do vehicles[109].transportVehicleConfig.vehicles[k].part.reversed = f end
end
openAndRender("reversed unit to single", 500, true)
t = content("reversed unit to single")
cs = combos(t)
cs[1].props.onValueChange("u900")
t = content("ET 420 selected")
cs = combos(t)
cs[2].props.onValueChange("m61")
t = content("Roter Pfeil for ET 420")
sent = {}
costPerCommand = 3300000
bankBalance = 20000000
find(t, function(n) return n.kind == "Button" and n.props.meta.class:find("mvr%-replace%-btn") end)[1].props.onClick()
c109 = nil
for _i, c in ipairs(sent) do if c.e == 109 then c109 = c end end
check(c109 ~= nil, "no replace command for train 109 (to single)")
if c109 then
	local ids, rev = {}, {}
	for _j, part in ipairs(c109.conf.vehicles) do ids[#ids + 1] = part.part.modelId; rev[#rev + 1] = part.part.reversed and "r" or "f" end
	check(table.concat(ids, ",") == "61,61", "train 109 to single parts: " .. table.concat(ids, ","))
	check(table.concat(rev) == "fr", "train 109 to single orientation (expected fr): " .. table.concat(rev))
end
vehicles[109] = nil

print("== Group sizes beyond the part list")
-- inconsistent save data: train 118 has one ET 420 (3 parts) but its group sizes claim two units
-- (3 + 3); the window must still open, and replacing must keep the real unit and drop nothing
vehicle(118, { 50, 51, 50 }, { { 3, "multiple_unit/et420.mdl" }, { 3, "multiple_unit/et420.mdl" } })
do
	local okRender, errRender = pcall(function()
		openAndRender("inconsistent groups", 500, true)
		t = content("inconsistent groups")
		combos(t)[1].props.onValueChange("u900")
		t = content("inconsistent groups ET 420")
		combos(t)[2].props.onValueChange("u901")
		t = content("inconsistent groups ET 423")
	end)
	check(okRender, "window breaks with group sizes beyond the part list: " .. tostring(errRender))
	if okRender then
		sent = {}
		costPerCommand = 3300000
		bankBalance = 20000000
		find(t, function(n) return n.kind == "Button" and n.props.meta.class:find("mvr%-replace%-btn") end)[1].props.onClick()
		local c118
		for _i, c in ipairs(sent) do if c.e == 118 then c118 = c end end
		check(c118 ~= nil, "no replace command for train 118")
		if c118 then
			local ids = {}
			for _j, part in ipairs(c118.conf.vehicles) do ids[#ids + 1] = part.part.modelId end
			check(table.concat(ids, ",") == "52,53,53,52", "train 118 parts: " .. table.concat(ids, ","))
			check(table.concat(c118.conf.vehicleGroups, ",") == "4", "train 118 groups: " .. table.concat(c118.conf.vehicleGroups, ","))
		end
	end
end
vehicles[118] = nil

print("== Railcar for multiple unit")
openAndRender("train depot 4", 500, true)
t = content("train depot 4")
cs = combos(t)
check(cs[1].props.value == "m60", "M-300 not preselected")
local rcNeu = {}
for i = firstModel(cs[2]), itemCount(cs[2]) do rcNeu[#rcNeu + 1] = itemTexts(cs[2].props.items[i])[1] end
print("  new for M-300: " .. table.concat(rcNeu, " | "))
check(table.concat(rcNeu, "|") == "ET 423|ET 420|Roter Pfeil", "for M-300 (by year, newest first): multiple units and railcars, no locomotives: " .. table.concat(rcNeu, "|"))
bankBalance = 10000000
cs[2].props.onValueChange("u901")
t = content("M-300 for ET 423")
sent = {}
costPerCommand = 2200000
bankBalance = 10000000
find(t, function(n) return n.kind == "Button" and n.props.meta.class:find("mvr%-replace%-btn") end)[1].props.onClick()
check(#sent == 1 and sent[1].e == 106, "M-300: one command for train 106 expected")
if sent[1] then
	local ids = {}
	for _j, part in ipairs(sent[1].conf.vehicles) do ids[#ids + 1] = part.part.modelId end
	check(table.concat(ids, ",") == "52,53,53,52", "train 106: " .. table.concat(ids, ","))
	check(table.concat(sent[1].conf.vehicleGroups, ",") == "4", "groups 106")
	check(table.concat(sent[1].conf.muFileNames, ",") == "multiple_unit/et423.mdl", "file name 106")
end
print("== Multiple unit for railcar")
openAndRender("train depot 5", 500, true)
t = content("train depot 5")
cs = combos(t)
cs[1].props.onValueChange("u900")
t = content("ET 420")
cs = combos(t)
cs[2].props.onValueChange("m61")
t = content("ET 420 for Roter Pfeil")
sent = {}
find(t, function(n) return n.kind == "Button" and n.props.meta.class:find("mvr%-replace%-btn") end)[1].props.onClick()
check(#sent == 2, "ET 420 for Roter Pfeil: 2 commands")
for _i, c in ipairs(sent) do
	local ids = {}
	for _j, part in ipairs(c.conf.vehicles) do ids[#ids + 1] = part.part.modelId end
	if c.e == 103 then
		check(table.concat(ids, ",") == "61,61,2", "train 103: " .. table.concat(ids, ","))
		check(table.concat(c.conf.vehicleGroups, ",") == "1,1,1", "groups 103: " .. table.concat(c.conf.vehicleGroups, ","))
		check(table.concat(c.conf.muFileNames, ",") == ",,", "file names 103 expected empty")
	elseif c.e == 104 then
		check(table.concat(ids, ",") == "61", "train 104: " .. table.concat(ids, ","))
	end
end

print("== Do not offer a group head without image")
openAndRender("train depot 3", 500, true)
t = content("train depot 3")
cs = combos(t)
cs[1].props.onValueChange("m1")
t = content("Ae 4/7")
cs = combos(t)
local n1042 = 0
for i = firstModel(cs[2]), itemCount(cs[2]) do
	local it = cs[2].props.items[i]
	if itemTexts(it)[1] == "Reihe 1042" then n1042 = n1042 + 1; check(it.props.value == "m41", "wrong 1042 offered: " .. it.props.value) end
end
check(n1042 == 1, "Reihe 1042 should appear exactly once, " .. n1042)
local hasEmd = false
for i = firstModel(cs[2]), itemCount(cs[2]) do if itemTexts(cs[2].props.items[i])[1] == "EMD F-Serie" then hasEmd = true end end
check(hasEmd, "locomotive pair (multiple unit of locomotives only) missing among the locomotives")
for i = firstModel(cs[2]), itemCount(cs[2]) do local n = itemTexts(cs[2].props.items[i])[1]; check(not n:find("ET 4"), "multiple unit part offered on its own: " .. n) end

print("== Cargo icons")
openAndRender("train depot 6", 500, true)
t = content("train depot 6")
cs = combos(t)
local function cargoOf(itemNode)
	local icons, more, tip = {}, nil, nil
	walk(itemNode, "", function(n)
		local cls = n.props.meta and tostring(n.props.meta.class) or ""
		if cls:find("mvr%-cargo%-icon") and n.kind == "ImageView" then icons[#icons + 1] = n.props.path end
		if cls:find("mvr%-cargo%-icon") and n.kind == "TextView" then more = n.props.text end
		if cls == "mvr-cargo" then tip = n.props.meta.tooltip end
	end)
	return icons, more, tip
end
local byName = {}
for i = firstModel(cs[1]), itemCount(cs[1]) do byName[itemTexts(cs[1].props.items[i])[1]] = cs[1].props.items[i] end
local ic, more, tip = cargoOf(byName["ACF M-300"])
check(#ic == 1 and ic[1] == "cargo/1.tga" and more == nil and tip == "Fahrgäste", "M-300: one passenger icon expected: " .. table.concat(ic, ",") .. " " .. tostring(tip))
ic, more, tip = cargoOf(byName["Ae 4/7"])
check(#ic == 0 and more == nil and tip == nil, "locomotive without cargo icon expected")
ic, more, tip = cargoOf(byName["Universalwagen"])
print("  Universalwagen: " .. table.concat(ic, ",") .. " " .. tostring(more) .. " | " .. tostring(tip))
check(#ic == 6 and ic[1] == "cargo/6.tga" and ic[2] == "cargo/2.tga" and more == nil, "Universalwagen: all 6 icons (oil first) expected")
local ic8, more8, tip8 = cargoOf(byName["Sammelwagen"])
print("  Sammelwagen: " .. #ic8 .. " icons, " .. tostring(more8))
check(#ic8 == 15 and more8 == "+4", "Sammelwagen: 15 icons and +4 expected")
check(select(2, tip8:gsub(",", ",")) == 18, "Sammelwagen: all 19 cargo types in the tooltip")
check(tip == "Öl, Kohle, Eisenerz, Getreide, Holz, Stein", "Universalwagen tooltip: " .. tostring(tip))
ic, more, tip = cargoOf(byName["ET 420"])
check(#ic == 1 and tip == "Fahrgäste", "multiple unit: cargo from its parts expected: " .. tostring(tip))
-- the right list shows cargo too
cs[1].props.onValueChange("m2")
t = content("wagon 2 for cargo")
cs = combos(t)
local anyCargo = false
for i = firstModel(cs[2]), itemCount(cs[2]) do local icx = cargoOf(cs[2].props.items[i]); if #icx > 0 then anyCargo = true end end
check(anyCargo, "right list without cargo icons")

print("== Cargo types are looked up only once")
local getsBefore = CARGO_GETS or 0
content("redraw 1"); content("redraw 2")
check((CARGO_GETS or 0) == getsBefore, "cargo types are queried again on every draw: " .. ((CARGO_GETS or 0) - getsBefore))

print("== List is built afresh after replacing")
openAndRender("train depot 7", 500, true)
t = content("before swap")
local keyBefore = combos(t)[1].props.meta.localKey
-- like after a swap in the game's own vehicle window: train 106 now runs with Roter Pfeil instead of M-300.
-- The id stays (issue #10); the window compares the parts of its vehicles in turn and sees it on the next step.
local saved = vehicles[106]
vehicle(106, { 61 })
local redraw = false
for _s = 1, 6 do -- the window checks its vehicles only every few steps (SIG_EVERY in the script)
	for _i, st in ipairs(stepStates) do if st.f() ~= st.v then redraw = true end end
end
check(redraw, "window not redrawn after a vehicle was rebuilt with the same id")
t = content("after swap")
local keyAfter = combos(t)[1].props.meta.localKey
check(keyBefore ~= keyAfter, "localKey of the left list does not change after the swap")
check(combos(t)[1].props.value == "m61", "after the swap Roter Pfeil is at the top: " .. tostring(combos(t)[1].props.value))
vehicles[106] = saved

print("== Road depot")
openAndRender("road depot", 501, true)
t = content("road depot")
on = find(t, function(n) return n.kind == "ToggleButton" and n.props.meta.class == "mvr-filter" and n.props.value == 1 end)
check(#on == 1 and on[1].props.meta.tooltip == "Straße: Busse und Lkw", "road depot: road not preselected")
cs = combos(t)
names = {}
for i = firstModel(cs[1]), itemCount(cs[1]) do names[#names + 1] = itemTexts(cs[1].props.items[i])[1] end
print("  old: " .. table.concat(names, " | "))
check(#names == 1 and names[1] == "Benz Dreitonner Kipper", "road depot: only Kipper in the fleet")
check(cs[1].props.value == "m10", "road depot: first entry preselected")
local roadNew = {}
for i = firstModel(cs[2]), itemCount(cs[2]) do roadNew[#roadNew + 1] = itemTexts(cs[2].props.items[i])[1] end
print("  new: " .. table.concat(roadNew, " | "))
local pos9, posLong
for i, n in ipairs(roadNew) do
	if n == "Lkw 9" then pos9 = i elseif n:find("Lkw 1234", 1, true) then posLong = i end
end
check(pos9 and posLong and pos9 < posLong, "long digit run sorts by value, Lkw 9 first: " .. table.concat(roadNew, "|"))

print("== Tram depot (carrier set) and mixed depot")
local function preselected(depot, label, tooltip)
	openAndRender(label, depot, true)
	local tt = content(label)
	local hit = find(tt, function(n) return n.kind == "ToggleButton" and n.props.meta.class == "mvr-filter" and n.props.value == 1 end)
	check(#hit == 1 and hit[1].props.meta.tooltip == tooltip, label .. ": wrong preselection " .. tostring(hit[1] and hit[1].props.meta.tooltip))
end
preselected(502, "tram depot", "Straßenbahnen")
-- mixed: transport modes ambiguous, vehicle 120 in the depot is a tram
preselected(503, "mixed depot", "Straßenbahnen")

print("== Depot without data, then ships without a fleet")
openAndRender("depot without data", nil, false)
t = content("management all")
local filters = find(t, function(n) return n.kind == "ToggleButton" and n.props.meta.class == "mvr-filter" end)
check(#filters == 5, "five vehicle types expected")
filters[4].props.onValueChange(1)
t = content("ships")
cs = combos(t)
check(itemCount(cs[1]) == 1 and cs[1].props.value == "none", "without ships: placeholder only")
check(itemCount(cs[2]) == 1, "without an old model: new list placeholder only")

print("== Other windows stay unchanged")
local plain = entity_window_util.ActionButtonBar(nil, { primaryButtons = { { tag = "x" } }, secondaryButtons = {} })
check(#plain.props.secondaryButtons == 0, "button appears in another window")

print("== Other mods replacing the button bar")
check(entity_window_util.ActionButtonBar == barRecipe, "ActionButtonBar field was overwritten, CallOriginalRecipe of other mods breaks")
local before = otherBarCalls
local okBar, depotBar = pcall(entity_window_util.ActionButtonBar, nil, { primaryButtons = { { tag = "entityWindow.maintenanceStation.manageVehicle" } }, secondaryButtons = {} })
check(okBar, "button bar fails with another mod's replacement: " .. tostring(depotBar))
check(otherBarCalls == before + 1, "replacement of the other mod is not called")
check(okBar and #depotBar.props.secondaryButtons == 1, "depot button missing when another mod replaces the bar")
local okNoRef, noRef = pcall(entity_window_util.ActionButtonBar, { primaryButtons = { { tag = "x" } } })
check(okNoRef and noRef.kind == "ActionButtonBar", "call without ref does not reach the original: " .. tostring(noRef))

print("== Replacing with balances beyond the integer range")
-- bug report 16.10.2026: "bad argument #2 to 'format' (not a number in proper range)" in the money log
-- nan never covers a price (like the purchase window, funds >= cost is false), so it replaces nothing
for _i, case in ipairs({ { 1e19, 8 }, { math.huge, 8 }, { 0 / 0, 0 } }) do
	local b, expected = case[1], case[2]
	local label = "balance " .. tostring(b)
	openAndRender(label, 501, true)
	t = content(label)
	combos(t)[2].props.onValueChange("m11")
	t = content(label .. " Kasten")
	sent = {}
	costPerCommand = 61000
	bankBalance = b
	t = content(label .. " Kasten")
	local okClick, errClick = pcall(function()
		find(t, function(n) return n.kind == "Button" and n.props.meta.class:find("mvr%-replace%-btn") end)[1].props.onClick()
	end)
	check(okClick, label .. ": replacing fails: " .. tostring(errClick))
	check(#sent == expected, label .. ": " .. expected .. " commands expected, " .. #sent)
end
bankBalance = 5000000

print("== Not enough money")
-- the replace command does not check the balance; the full purchase price must be covered
-- (road depot: 8 Kipper, Kasten costs 61000 each, 488000 in total)
local function replaceButton(tt)
	return find(tt, function(n) return n.kind == "Button" and n.props.meta.class:find("mvr%-replace%-btn") end)[1]
end
local function priceText(tt)
	local pt = find(tt, function(n) return n.kind == "TextView" and n.props.text:find("Kaufpreis") end)
	return pt[1] and pt[1].props.text
end
local function chooseKasten(label, b)
	step() -- commands of an earlier test run first, so they do not book against this balance
	bankBalance = b
	openAndRender(label, 501, true)
	t = content(label)
	combos(t)[2].props.onValueChange("m11")
	return content(label .. " Kasten")
end
costPerCommand = 61000

-- not one truck covered (one truck costs 61000): the red, disabled button; partly covered see issue #23 below
t = chooseKasten("too little money", 60999)
local btnPoor = replaceButton(t)
check(btnPoor.props.meta.enabled == false, "button not disabled without enough money")
check(btnPoor.props.meta.class:find("mvr-no-money", 1, true) ~= nil, "button without mvr-no-money class")
check(btnPoor.props.meta.tooltip == "Nicht genug Geld", "tooltip: " .. tostring(btnPoor.props.meta.tooltip))
check(priceText(t) == "Kaufpreis: $488000", "price line: " .. tostring(priceText(t)))
local function buttonText(btn)
	local tv = find(btn, function(n) return n.kind == "TextView" end)
	return tv[1] and tv[1].props.text
end
-- the money covers the whole replacement: the plain enabled "Ersetzen" (one short: "n von m" or "Nicht genug Geld", #23)
local function fullyCovered(btn)
	return btn.props.meta.enabled == true and buttonText(btn) == "Ersetzen"
end
check(buttonText(btnPoor) == "Nicht genug Geld", "button text without enough money: " .. tostring(buttonText(btnPoor)))
sent = {}
btnPoor.props.onClick() -- the game ignores clicks on disabled buttons; the click itself checks again anyway
check(#sent == 0, "replaced without enough money: " .. #sent)
check(bankBalance == 60999, "balance changed without a replacement")
t = content("too little money, after click")
check(#find(t, function(n) return n.kind == "TextView" and n.props.text == "Nicht genug Geld" end) == 1, "no message after the refused click")

print("== Replace as many as the money covers (issue #23)")
-- not enough for all: the main button itself says "7 von 8 ersetzen", yellow (mvr-partial), enabled
t = chooseKasten("partial, 487999", 487999)
local partBtn = replaceButton(t)
check(buttonText(partBtn) == "7 von 8 ersetzen", "partial: button text " .. tostring(buttonText(partBtn)))
check(partBtn.props.meta.enabled == true, "partial: button disabled")
check(partBtn.props.meta.tooltip == "Nicht genug Geld: Es werden nur 7 von 8 ersetzt (älteste zuerst).", "partial: tooltip " .. tostring(partBtn.props.meta.tooltip))
check(partBtn.props.meta.class:find("mvr-partial", 1, true) and not partBtn.props.meta.class:find("mvr-no-money", 1, true), "partial: class " .. partBtn.props.meta.class)
check(#find(t, function(n) return n.kind == "TextView" and n.props.text == "7 Fahrzeuge werden ersetzt." end) == 1, "partial: count line does not match the button")
check(#find(t, function(n) return n.kind == "TextView" and n.props.text == "Kosten nach Restwert: $427000" end) == 1, "partial: cost line does not match the button")
-- 200000 covers 3 trucks at 61000; truck 115 is the oldest, the rest by id
vehicles[115].transportVehicleConfig.vehicles[1].purchaseTime = 1
t = chooseKasten("partial", 200000)
partBtn = replaceButton(t)
check(buttonText(partBtn) == "3 von 8 ersetzen", "partial: button text " .. tostring(buttonText(partBtn)))
sent = {}
partBtn.props.onClick()
local partialIds = {}
for _i, c in ipairs(sent) do partialIds[#partialIds + 1] = c.e end
table.sort(partialIds)
check(table.concat(partialIds, ",") == "110,111,115", "partial: oldest first expected 110,111,115, got " .. table.concat(partialIds, ","))
t = content("partial, after the click")
check(#find(t, function(n) return n.kind == "TextView" and n.props.text == "Ersetzt: 3 von 8." end) == 1, "partial: result line")
check(bankBalance == 200000 - 3 * 61000, "partial: booked " .. tostring(200000 - bankBalance))
vehicles[115].transportVehicleConfig.vehicles[1].purchaseTime = nil
-- not even one truck: red "Nicht genug Geld" as before; enough for all: plain "Ersetzen"
-- money for exactly one truck: the tooltip uses its singular text
t = chooseKasten("partial, one", 61000)
check(buttonText(replaceButton(t)) == "1 von 8 ersetzen", "partial, one: button text " .. tostring(buttonText(replaceButton(t))))
check(replaceButton(t).props.meta.tooltip == "Nicht genug Geld: Es wird nur 1 von 8 ersetzt (das älteste).", "partial, one: tooltip " .. tostring(replaceButton(t).props.meta.tooltip))
t = chooseKasten("partial, too poor", 60999)
check(buttonText(replaceButton(t)) == "Nicht genug Geld" and replaceButton(t).props.meta.enabled == false, "partial: not one truck covered")
t = chooseKasten("partial, rich", 488000)
check(buttonText(replaceButton(t)) == "Ersetzen", "partial: money covers all")

t = chooseKasten("exactly enough", 488000)
check(replaceButton(t).props.meta.enabled == true, "button disabled with exactly the price")
check(buttonText(replaceButton(t)) == "Ersetzen", "button text with enough money: " .. tostring(buttonText(replaceButton(t))))
check(priceText(t) == "Kaufpreis: $488000", "price line with enough money: " .. tostring(priceText(t)))
sent = {}
replaceButton(t).props.onClick()
check(#sent == 8, "exactly enough: 8 commands expected, " .. #sent)

t = chooseKasten("infinite money", nil)
check(replaceButton(t).props.meta.enabled == true, "button disabled with infinite money")
sent = {}
replaceButton(t).props.onClick()
check(#sent == 8, "infinite money: 8 commands expected, " .. #sent)

t = chooseKasten("money spent meanwhile", 1000000)
check(replaceButton(t).props.meta.enabled == true, "button disabled with enough money")
bankBalance = 1000 -- spent while the window was open
sent = {}
replaceButton(t).props.onClick()
check(#sent == 0, "click does not check the balance again: " .. #sent)
bankBalance = 5000000

local function hasText(tt, s)
	return #find(tt, function(n) return n.kind == "TextView" and n.props.text == s end) > 0
end
local function offered(tt, name)
	local c = combos(tt)[2]
	for i = firstModel(c), itemCount(c) do if itemTexts(c.props.items[i])[1] == name then return true end end
	return false
end

print("== Only the player's vehicles (issue #1)")
-- truck 130 is a Kipper like 110-117 but belongs to an AI player
t = chooseKasten("foreign vehicles", nil)
check(hasText(t, "8 Fahrzeuge werden ersetzt."), "foreign truck counted in the summary")
sent = {}
replaceButton(t).props.onClick()
local foreignSent = false
for _i, c in ipairs(sent) do if c.e == 130 then foreignSent = true end end
check(#sent == 8 and not foreignSent, "foreign truck replaced or commands missing: " .. #sent)

print("== Infinite money: no cost line (issue #20)")
residuals = {}
for v = 110, 117 do residuals[v] = 1000 end
t = chooseKasten("infinite money", nil)
check(hasText(t, "8 Fahrzeuge werden ersetzt."), "infinite money: count missing")
local moneyLines = find(t, function(n) return n.kind == "TextView" and type(n.props.text) == "string" and (n.props.text:find("^Kaufpreis") or n.props.text:find("^Kosten")) end)
-- the price per model in the list stays, like the game's purchase list
check(#moneyLines == 0, "infinite money: cost line shown: " .. tostring(moneyLines[1] and moneyLines[1].props.text))
check(replaceButton(t).props.meta.enabled == true, "infinite money: button disabled")
local readsInfinite = residualReads
gameTimeNow = gameTimeNow + 1
for _i, st in ipairs(stepStates) do st.f() end
check(residualReads == readsInfinite, "infinite money: residual values read although no cost is shown")
residuals = {}

print("== New model expires while the window is open (issue #3)")
bankBalance = nil
openAndRender("expiring model", 501, true)
t = content("expiring model")
check(offered(t, "Lkw Auslauf"), "Lkw Auslauf not offered before it expires")
combos(t)[2].props.onValueChange("m15")
t = content("expiring model chosen")
local expiringBtn = replaceButton(t)
check(expiringBtn.props.meta.enabled == true, "button disabled for an available model")
currentYear = 1981 -- the year changes while the window is open
sent = {}
expiringBtn.props.onClick()
check(#sent == 0, "expired model still replaced: " .. #sent .. " commands")
t = content("expiring model after the click")
check(hasText(t, "Das neue Modell ist nicht mehr erhältlich"), "no message for the expired model")
check(not offered(t, "Lkw Auslauf"), "expired model still offered")
combos(t)[2].props.onValueChange("m15") -- a stale selection must not come back either
t = content("expired model selected again")
check(not priceText(t), "expired model selected, price line shown: " .. tostring(priceText(t)))
currentYear = 1980
bankBalance = 5000000

print("== Multiple unit with mixed end years follows the game (issue #3)")
-- ET 404: one part ends 1993, the other never; the game's store keeps the unit for sale (yearTo 0 wins)
currentYear = 1995
openAndRender("mixed end years", 500, true)
t = content("mixed end years")
combos(t)[1].props.onValueChange("u900")
t = content("mixed end years, ET 420")
check(offered(t, "ET 404"), "ET 404 not offered in 1995 although the game still sells it")
currentYear = 1980

print("== No second batch while the first is still running (issue #9)")
-- the vehicles only change in the next simulation step; until then a second batch would replace them again
holdSteps = true
t = chooseKasten("double click", nil)
sent = {}
local firstBtn = replaceButton(t)
firstBtn.props.onClick()
check(#sent == 8, "first click: 8 commands expected, " .. #sent)
firstBtn.props.onClick() -- fast double click on the same button
check(#sent == 8, "second click on the same button sent again: " .. #sent)
t = content("double click, redrawn")
check(replaceButton(t).props.meta.enabled == false, "button enabled while the batch is running")
check(buttonText(replaceButton(t)) == "Wird ersetzt …", "button text while running: " .. tostring(buttonText(replaceButton(t))))
-- no half-counted result while the game has not answered yet: the line shows once, at the end
check(#find(t, function(n) return n.kind == "TextView" and n.props.text:find("Ersetzt:", 1, true) end) == 0, "result line shown before the game answered")
combos(t)[2].props.onValueChange("m11") -- the user picks the new model again
t = content("double click, chosen again")
replaceButton(t).props.onClick()
check(#sent == 8, "second batch sent while the first was running: " .. #sent)
holdSteps = false
t = content("double click, step done")
check(replaceButton(t).props.meta.enabled == true, "button stays disabled after the batch finished")
check(buttonText(replaceButton(t)) == "Ersetzen", "button text after the batch: " .. tostring(buttonText(replaceButton(t))))

print("== Failed commands also end the batch (issue #9)")
holdSteps, commandSucceeds = true, false
t = chooseKasten("failing commands", nil)
sent = {}
replaceButton(t).props.onClick()
check(#sent == 8, "failing commands: 8 sent expected, " .. #sent)
holdSteps = false
t = content("failing commands, step done")
check(hasText(t, "Ersetzt: 0 von 8 (8 geplante Fahrzeuge wurden vom Spiel abgelehnt)."), "failure count not shown")
check(replaceButton(t).props.meta.enabled == true, "button stays disabled after failed commands")
commandSucceeds = true

print("== Refused commands are told apart from the vehicles skipped for money")
step()
refused[113] = true
t = chooseKasten("one refused", nil)
replaceButton(t).props.onClick()
t = content("one refused, done")
check(hasText(t, "Ersetzt: 7 von 8 (1 geplantes Fahrzeug wurde vom Spiel abgelehnt)."), "one refused: result line")
-- partial: 3 trucks planned (200000 covers 3 x 61000), one of them refused
refused[113], refused[110] = nil, true
t = chooseKasten("partial, one refused", 200000)
replaceButton(t).props.onClick()
t = content("partial, one refused, done")
check(hasText(t, "Ersetzt: 2 von 8 (1 geplantes Fahrzeug wurde vom Spiel abgelehnt)."), "partial, one refused: result line")
refused = {}
bankBalance = nil

print("== A command that throws does not leave the button stuck (issue #9)")
-- review finding on #28: counted before sending, a throwing command never got its callback
holdSteps = true
t = chooseKasten("throwing command", nil)
sent, throwAtCommand = {}, 3
replaceButton(t).props.onClick()
throwAtCommand = nil
check(#sent == 2, "throwing command: 2 commands sent before the error, " .. #sent)
holdSteps = false
t = content("throwing command, step done")
check(replaceButton(t).props.meta.enabled == true, "button stuck after a command threw")

print("== Callbacks of a closed window do not count (issue #9)")
-- like the game's counter, which lives with its UI component (engine_react_util.tl:36-55)
holdSteps = true
t = chooseKasten("reopen", nil)
sent = {}
replaceButton(t).props.onClick()
t = chooseKasten("reopen, new window", nil)
check(replaceButton(t).props.meta.enabled == true, "new window blocked by the batch of the closed one")
sent = {}
replaceButton(t).props.onClick()
check(#sent == 8, "new window: 8 commands expected, " .. #sent)
step() -- the callbacks of the closed window and of the new one arrive in the same step
t = content("reopen, done")
check(hasText(t, "Ersetzt: 8 von 8."), "old callbacks mixed into the new batch")
holdSteps = false
bankBalance = 5000000

print("== Residual value of whole vehicles counts, like the game (issue #26)")
-- the game's purchase window: cost = price - residual value (vehicle_store_window.tl:2995-3005, 3525-3547)
for v = 110, 117 do residuals[v] = 1000 end
residuals[130] = 1000000 -- the foreign truck is not replaced, its value must not count
t = chooseKasten("residual, exactly enough", 480000) -- 8 x 61000 - 8 x 1000
check(replaceButton(t).props.meta.enabled == true, "residual value not counted: button disabled with price minus residual")
check(hasText(t, "Kosten nach Restwert: $480000"), "cost line with residual value missing")
sent = {}
replaceButton(t).props.onClick()
check(#sent == 8, "price minus residual covered: 8 commands expected, " .. #sent)
t = chooseKasten("residual, one short", 479999)
check(not fullyCovered(replaceButton(t)), "button enabled one short of price minus residual")
sent = {}
replaceButton(t).props.onClick()
check(#sent < 8, "replaced all one short of price minus residual: " .. #sent)

print("== The cost follows the residual value while the game runs (issue #26)")
-- in-game 17.10.2026: the line was read, the game ran on, the charge was 5120 higher
-- several steps: the window checks its vehicles only every few steps (#10, SIG_EVERY in the script)
local STEPS_PER_CHECK = 6
local function wouldRedraw()
	for _s = 1, STEPS_PER_CHECK do
		for _i, st in ipairs(stepStates) do if st.f() ~= st.v then return true end end
	end
	return false
end
residuals = {}
for v = 110, 117 do residuals[v] = 1000 end
t = chooseKasten("live cost", 5000000)
check(hasText(t, "Kosten nach Restwert: $480000"), "live cost: cost line")
check(not wouldRedraw(), "live cost: redraw without any change")
-- reading every residual value is heavy (1450 trucks in a game test): only timed step states may do it
do
	gameTimeNow = gameTimeNow + 1
	for _i, st in ipairs(stepStates) do
		local before = residualReads
		st.f()
		check(residualReads == before or st.timer, "live cost: an every-step state reads residual values")
	end
end
for v = 110, 117 do residuals[v] = 900 end -- the trucks aged
local reads = residualReads
check(not wouldRedraw(), "live cost: redraw while paused")
check(residualReads == reads, "live cost: residual values read while paused, " .. (residualReads - reads))
gameTimeNow = gameTimeNow + 1 -- the game runs
check(wouldRedraw(), "live cost: window not redrawn when the residual value dropped")
t = content("live cost, aged")
check(hasText(t, "Kosten nach Restwert: $480800"), "live cost: cost line after aging")
-- a truck is sold while the window is open: the next step must not value the vanished vehicle (review finding)
local soldTruck = vehicles[117]
vehicles[117] = nil
gameTimeNow = gameTimeNow + 1
check(wouldRedraw(), "live cost: a sold truck's credit did not go")
check(deadReads == 0, "live cost: residual value read for a vehicle that no longer exists")
vehicles[117] = soldTruck
residuals = {}
step()
bankBalance = 5000000

print("== Partly replaced vehicles: the kept parts are charged, like the game's Modify window (issue #26)")
-- the Modify window charges kept parts at getPartPrice and subtracts the residual value of the whole vehicle
-- (vehicle_store_window.tl:3758-3768). BR 50 pulls wagons in trains 102, 107 and 108; replacing it by BR 103
-- (3 x 1500000) credits per train its residual value minus the value of the wagons that stay.
local function chooseBr103(label, b)
	step()
	bankBalance = b
	openAndRender(label, 500, true)
	local tt = content(label)
	combos(tt)[1].props.onValueChange("m5")
	tt = content(label .. ", BR 50")
	combos(tt)[2].props.onValueChange("m4")
	return content(label .. ", BR 103")
end
local function partlyReplacedValues()
	residuals, partValues = {}, {}
	residuals[102], residuals[107], residuals[108] = 1000000, 1000000, 500000
	partValue(102, 2, 300000); partValue(102, 3, 300000) -- credits 400000
	partValue(107, 2, 400000); partValue(107, 3, 450000) -- credits 150000
	partValue(108, 2, 200000); partValue(108, 3, 200000) -- credits 100000 (dummy locomotive and wagon stay)
	-- the replaced locomotives carry a value too: charging a replaced part as kept must show (review finding)
	for _i, v in ipairs({ 102, 107, 108 }) do partValue(v, 1, 9000000) end
end
partlyReplacedValues()
t = chooseBr103("partly replaced, exactly enough", 3850000) -- 4500000 - 650000
check(hasText(t, "Kosten nach Restwert: $3850000"), "partly replaced trains: cost line " .. tostring(priceText(t)))
check(replaceButton(t).props.meta.enabled == true, "partly replaced trains: residual value of the removed locomotives not counted")
sent = {}
replaceButton(t).props.onClick()
check(#sent == 3, "partly replaced trains, exactly enough: 3 commands expected, " .. #sent)
t = chooseBr103("partly replaced, one short", 3849999)
check(not fullyCovered(replaceButton(t)), "partly replaced trains: button enabled one short")
sent = {}
replaceButton(t).props.onClick()
check(#sent < 3, "partly replaced trains: all replaced one short: " .. #sent)

print("== Kept parts worth more than the vehicle's residual value cost extra, like the game (issue #26)")
residuals, partValues = {}, {}
residuals[102] = 100000
partValue(102, 2, 300000); partValue(102, 3, 300000) -- credits -500000
t = chooseBr103("kept parts worth more", 5000000)
check(hasText(t, "Kosten nach Restwert: $5000000"), "kept parts worth more: cost line")
check(replaceButton(t).props.meta.enabled == true, "kept parts worth more: button disabled with enough money")
t = chooseBr103("kept parts worth more, one short", 4999999)
check(not fullyCovered(replaceButton(t)), "kept parts worth more: button enabled below the game's cost")

print("== Part value unreadable: that vehicle counts at the full price (issue #26)")
partlyReplacedValues()
partValueThrows = true
t = chooseBr103("part value unreadable", 4500000)
check(priceText(t) == "Kaufpreis: $4500000", "part value unreadable: price line " .. tostring(priceText(t)))
t = chooseBr103("part value unreadable, one short", 4499999)
check(not fullyCovered(replaceButton(t)), "part value unreadable: credited although the kept parts are unknown")
-- vehicles without kept parts do not need a part value: the trucks still get their residual value
for v = 110, 117 do residuals[v] = 1000 end
t = chooseKasten("part value unreadable, whole trucks", 480000)
check(replaceButton(t).props.meta.enabled == true, "part value unreadable: whole trucks lost their residual value")
partValueThrows = false
partlyReplacedValues()
partValue(102, 2, 0 / 0) -- nan: train 102 counts at the full price, 107 and 108 still credit 250000
t = chooseBr103("part value nan", 4250000)
check(replaceButton(t).props.meta.enabled == true, "part value nan: the other trains lost their credit")
t = chooseBr103("part value nan, one short", 4249999)
check(not fullyCovered(replaceButton(t)), "part value nan: train 102 credited anyway")
partlyReplacedValues()
partValue(107, 2, -1); partValue(108, 2, math.huge) -- 107 and 108 count at the full price, 102 credits 400000
t = chooseBr103("part value negative and infinite", 4100000)
check(replaceButton(t).props.meta.enabled == true, "part value negative/infinite: train 102 lost its credit")
t = chooseBr103("part value negative and infinite, one short", 4099999)
check(not fullyCovered(replaceButton(t)), "part value negative/infinite: trains 107 or 108 credited anyway")

print("== A train with an unknown multiple unit: its parts stay and are charged (issue #26)")
-- the multiple unit's mod is missing: rebuild keeps the group, so it counts as kept like any other part
vehicle(140, { 5, 50, 51, 50 }, { { 1, "" }, { 3, "multiple_unit/unknown.mdl" } })
partlyReplacedValues()
residuals[140] = 2000000
partValue(140, 1, 9000000)
for j = 2, 4 do partValue(140, j, 500000) end -- credits 500000
t = chooseBr103("unknown multiple unit, exactly enough", 4850000) -- 4 x 1500000 - 650000 - 500000
check(hasText(t, "Kosten nach Restwert: $4850000"), "unknown multiple unit: cost line")
sent = {}
replaceButton(t).props.onClick()
check(#sent == 4, "unknown multiple unit: 4 commands expected, " .. #sent)
t = chooseBr103("unknown multiple unit, one short", 4849999)
check(not fullyCovered(replaceButton(t)), "unknown multiple unit: its parts were not charged")
vehicles[140] = nil

print("== Multiple units: whole and partly replaced trains (issue #26)")
-- train 104 is one ET 420 alone, train 103 has two ET 420 and a wagon that stays
residuals, partValues = {}, {}
residuals[103], residuals[104] = 1000000, 1000000
partValue(103, 7, 300000)
-- the replaced multiple unit parts carry a value too: charging them as kept must show (review finding)
for j = 1, 6 do partValue(103, j, 9000000) end
for j = 1, 3 do partValue(104, j, 9000000) end
local function chooseEt423(label, b)
	step()
	bankBalance = b
	openAndRender(label, 500, true)
	local tt = content(label)
	combos(tt)[1].props.onValueChange("u900")
	tt = content(label .. ", ET 420")
	combos(tt)[2].props.onValueChange("u901")
	return content(label .. ", ET 423")
end
t = chooseEt423("multiple units, enough", 4900000) -- 3 units x 2200000 - 1000000 (104) - 700000 (103)
check(hasText(t, "Kosten nach Restwert: $4900000"), "multiple units: cost line missing")
check(replaceButton(t).props.meta.enabled == true, "multiple units: residual value not counted")
t = chooseEt423("multiple units, one short", 4899999)
check(not fullyCovered(replaceButton(t)), "multiple units: the kept wagon was not charged")
-- an ET 420 end car standing alone is a single model, not the multiple unit: not replaced, not credited
vehicle(141, { 50 })
residuals[141] = 5000000
t = chooseEt423("loose multiple unit car", 4900000)
check(hasText(t, "Kosten nach Restwert: $4900000"), "loose multiple unit car credited")
sent = {}
replaceButton(t).props.onClick()
check(#sent == 2, "loose multiple unit car: 2 commands expected, " .. #sent)
vehicles[141] = nil
residuals, partValues = {}, {}

print("== Residual value above the price: proceeds, not a negative cost")
-- 8 trucks worth 100000 each, replaced for 61000 each: the player gets 312000 back
for v = 110, 117 do residuals[v] = 100000 end
t = chooseKasten("proceeds", 0)
check(hasText(t, "Erlös nach Restwert: $312000"), "proceeds: line missing")
check(#find(t, function(n) return n.kind == "TextView" and n.props.text:find("$-", 1, true) end) == 0, "proceeds: negative amount shown")
check(replaceButton(t).props.meta.enabled == true, "proceeds: button disabled with a balance of 0")
residuals = {}

print("== Residual value unreadable counts as none (issue #26)")
residualThrows = true
t = chooseKasten("residual unreadable, full price", 488000)
check(replaceButton(t).props.meta.enabled == true, "residual unreadable: button disabled with the full price")
check(priceText(t) == "Kaufpreis: $488000", "residual unreadable: price line " .. tostring(priceText(t)))
t = chooseKasten("residual unreadable, one short", 487999)
check(not fullyCovered(replaceButton(t)), "residual unreadable: button enabled below the full price")
residualThrows = false
-- nan, negative and infinite values count as none (review finding: only the error path was tested)
for v = 110, 117 do residuals[v] = 1000 end
residuals[110], residuals[111], residuals[112] = 0 / 0, -1, math.huge
t = chooseKasten("odd residual values", 483000) -- 488000 - 5 x 1000
check(replaceButton(t).props.meta.enabled == true, "odd residual values: button disabled with price minus the valid residual")
check(hasText(t, "Kosten nach Restwert: $483000"), "odd residual values: cost line")
t = chooseKasten("odd residual values, one short", 482999)
check(not fullyCovered(replaceButton(t)), "odd residual values: button enabled one short")
residuals = {}
step()
bankBalance = 5000000

print("== Warning when the engine type changes (issue #50)")
local ARROW = "\226\134\146"
local function engineLine(tt)
	local w = find(tt, function(n) return n.kind == "TextView" and n.props.meta.class == "font-scale-body, warning" end)
	check(#w == 1, "engine warning line missing or doubled: " .. #w)
	return w[1] and w[1].props or { meta = {} }
end
local function chooseRail(label, altKey, neuKey)
	step()
	openAndRender(label, 500, true)
	local tt = content(label)
	combos(tt)[1].props.onValueChange(altKey)
	tt = content(label .. ", old")
	if neuKey then combos(tt)[2].props.onValueChange(neuKey); tt = content(label .. ", new") end
	return tt
end
local wl = engineLine(chooseRail("steam to electric", "m5", "m4"))
check(wl.text == "Antrieb wechselt: Dampf " .. ARROW .. " Elektrisch", "steam to electric: " .. tostring(wl.text))
check(wl.meta.tooltip ~= nil and wl.meta.tooltip:find("Oberleitung", 1, true) ~= nil, "steam to electric: tooltip " .. tostring(wl.meta.tooltip))
wl = engineLine(chooseRail("electric to electric", "m1", "m4"))
check(wl.text == " " and wl.meta.tooltip == nil, "same engine type warns: " .. tostring(wl.text))
wl = engineLine(chooseRail("wagon to wagon", "m2", "m3"))
check(wl.text == " " and wl.meta.tooltip == nil, "wagons warn: " .. tostring(wl.text))
-- no new model chosen: the top one is preselected (user decision 19.10.2026), and the warning follows it like a chosen one
-- (until then: no new model, no warning)
wl = engineLine(chooseRail("no new model chosen", "m5", nil))
check(wl.text == "Antrieb wechselt: Dampf " .. ARROW .. " Elektrisch", "warning for the preselected new model: " .. tostring(wl.text))
wl = engineLine(chooseRail("multiple units", "u900", "u901"))
check(wl.text == "Antrieb wechselt: Elektrisch " .. ARROW .. " Diesel/Elektrisch", "multiple units: " .. tostring(wl.text))
-- an engine without a known type (like the older models here) gives no warning
wl = engineLine(chooseRail("untyped engine", "m4", "m41"))
check(wl.text == " ", "untyped engine warns: " .. tostring(wl.text))
if windows["mass_vehicle_replace.window"] then windows["mass_vehicle_replace.window"].params.onClose() end

print("== Depot window is not replaced, depot comes from the plugin condition")
check(_react.recipeReplace.MaintenanceStationWindow == nil, "MaintenanceStationWindow is replaced although the plugin condition gives the depot")
check(type(exports.depotProbe) == "table" or type(exports.depotProbe) == "function", "depot probe plugin recipe missing in data()")
-- two depot windows render one after the other: each button opens its own depot (issue #4)
local manage = { primaryButtons = { { tag = "entityWindow.maintenanceStation.manageVehicle" } }, secondaryButtons = {} }
exports.depotProbeCondition({ entityId = 500 })
local barA = entity_window_util.ActionButtonBar(nil, manage)
exports.depotProbeCondition({ entityId = 501 })
local barB = entity_window_util.ActionButtonBar(nil, manage)
-- the window opens with the vehicle type of its own depot: 500 rail, 501 road
local function preselectedAfterClick(bar, label)
	bar.props.secondaryButtons[1].customItem.props.onClick()
	local w = windows["mass_vehicle_replace.window"]
	check(w ~= nil, label .. ": window not opened")
	if w then lastWindow = w; render("MvrWindow", w.params) end
	local hit = find(content(label), function(n) return n.kind == "ToggleButton" and n.props.meta.class == "mvr-filter" and n.props.value == 1 end)
	return hit[1] and hit[1].props.meta.tooltip
end
local typeA = preselectedAfterClick(barA, "first depot window")
check(typeA == "Schiene: Loks und Wagen", "button of the first depot window opens another depot: " .. tostring(typeA))
local typeB = preselectedAfterClick(barB, "second depot window")
check(typeB == "Straße: Busse und Lkw", "button of the second depot window opens another depot: " .. tostring(typeB))
if windows["mass_vehicle_replace.window"] then windows["mass_vehicle_replace.window"].params.onClose() end

print("== Fleet changes while the window is open (issue #10)")
-- seen in the game: a vehicle bought or handed to another player while the window was open left the count stale
t = chooseKasten("fleet change", 5000000)
check(hasText(t, "8 Fahrzeuge werden ersetzt."), "fleet change: start count")
check(not wouldRedraw(), "fleet change: redraw without any change")
local readsBefore = fleetBuildReads
t = content("fleet change, unchanged")
check(fleetBuildReads == readsBefore, "fleet change: fleet rebuilt on a redraw without changes")
vehicle(118, { 10 }) -- bought
check(wouldRedraw(), "fleet change: window not redrawn after a purchase")
t = content("fleet change, bought")
check(hasText(t, "9 Fahrzeuge werden ersetzt."), "fleet change: count after a purchase")
owners[118] = 99 -- handed to another player (makeEntitySetPlayerCmd)
check(wouldRedraw(), "fleet change: window not redrawn after a handover")
t = content("fleet change, handed over")
check(hasText(t, "8 Fahrzeuge werden ersetzt."), "fleet change: count after a handover")
owners[118] = nil
vehicles[118] = nil
-- reopened right after a change, before the throttled vehicle check ran: the new window must not show the old fleet
t = chooseKasten("fleet change, reopen 1", 5000000)
vehicle(118, { 10 })
t = chooseKasten("fleet change, reopen 2", 5000000)
check(hasText(t, "9 Fahrzeuge werden ersetzt."), "fleet change: reopened window shows the fleet of the last one")
vehicles[118] = nil
t = chooseKasten("fleet change, reopen 3", 5000000)
-- our own batch: the vehicles keep their ids, the callbacks make the window read the fleet again
t = content("fleet change, before replacing")
replaceButton(t).props.onClick() -- the click itself reads the vehicles; count only the redraw after it
step() -- the commands run, their callbacks arrive
readsBefore = fleetBuildReads
check(wouldRedraw(), "fleet change: window not redrawn after the callbacks of our own batch")
t = content("fleet change, replaced")
check(fleetBuildReads > readsBefore, "fleet change: fleet not read again after our own batch")
step()

print("== Vehicle stats of old and new model (issue #16)")
storeStats.m10 = { totalCapacity = 10, speed = 60 / 3.6, loadingSpeed = 1, power = 50, tractiveEffort = 20, thrust = 0,
	weight = 3, runningCosts = 5000, noise = 0.6, pollution = 0.6, comfortFactor = 0 }
-- tractive effort and pollution differ only below what is shown ("20 kN", "Mittel" on both sides): game test
-- 19.10.2026, equal rating words were colored
storeStats.m11 = { totalCapacity = 12, speed = 70 / 3.6, loadingSpeed = 1, power = 60, tractiveEffort = 20.3, thrust = 0,
	weight = 3.5, runningCosts = 6000, noise = 0.4, pollution = 0.55, comfortFactor = 0 }
storeCalls = {}
local function detailsCardOf(tt)
	local cards = find(tt, function(n) return n.kind == "recipe:ContentCard" end)
	return cards[1] and cards[1].props, #cards
end
-- the body the game renders inside the card while it is expanded
local function detailsBody(card, label)
	local rp = card and card.recipeAndParamCollapsible
	check(rp and rp.recipe and rp.recipe.name == "MvrStats", label .. ": card without the stats body")
	if not (rp and rp.recipe) then return { kind = "BoxLayout", props = {} } end
	local body = render(rp.recipe.name, rp.param)
	rules(body, label .. " body")
	return body
end
-- the cells of every table row, as text lists
local function statLines(body)
	local lines = {}
	for _i, tl in ipairs(find(body, function(n) return n.kind == "TableLayout" end)) do
		for _j, r in ipairs(tl.props.rows) do
			local cells = {}
			for k, c in ipairs(r.props.cells) do cells[k] = c end
			lines[#lines + 1] = cells
		end
	end
	return lines
end
-- a row's cells as { label, old, new, change }, found by the header texts, so the checks do not depend on the
-- column order (that one is checked on its own below)
local function lineOf(body, label)
	local lines = statLines(body)
	local col = {}
	for k, c in ipairs(lines[1] or {}) do col[c.props.text] = k end
	for _i, cells in ipairs(lines) do
		if cells[1].props.text == label then
			return { cells[1], cells[col["Alt"] or 2], cells[col["Neu"] or 3], cells[col["Änderung"] or 4] }
		end
	end
	return nil
end
local function classOf(cell) return tostring(cell and cell.props.meta and cell.props.meta.class) end

do -- own block: the main chunk is at the 200 local limit
	t = chooseKasten("stats", 5000000)
	local card, nCards = detailsCardOf(t)
	check(nCards == 1, "stats: one details card expected, found " .. nCards)
	check(card and card.title == "Details", "stats: card title")
	-- expanded by default (user decision 19.10.2026; was collapsed until then)
	check(card and card.collapsibleExpanded == true, "stats: card must be expanded by default")
	-- collapse like the game's arrow button does: stays collapsed, and collapsed reads nothing
	card.setCollapsibleExpanded(false)
	card = detailsCardOf(content("stats collapsed"))
	check(card and card.collapsibleExpanded == false, "stats: card does not stay collapsed")
	check(#storeCalls == 0, "stats: collapsed card read vehicle data: " .. table.concat(storeCalls, ","))
	local stepStatesCollapsed = #stepStates
	-- and expand again
	card.setCollapsibleExpanded(true)
	t = content("stats expanded")
	card = detailsCardOf(t)
	check(card and card.collapsibleExpanded == true, "stats: card does not stay expanded")
	check(#stepStates == stepStatesCollapsed, "stats: the card added step states (stats only change with the selection)")
	local body = detailsBody(card, "stats expanded")
	check(#find(body, function(n) return n.kind == "TableLayout" end) == 2, "stats: two halves expected")
	-- the change right after the label, as the most important column (user decision 19.10.2026)
	local header = statLines(body)[1] or {}
	local headerText = {}
	for k, c in ipairs(header) do headerText[k] = c.props.text end
	check(table.concat(headerText, "|") == " |Änderung|Alt|Neu", "stats: column order " .. table.concat(headerText, "|"))
	local speedLine = lineOf(body, "Höchsttempo")
	check(speedLine and speedLine[2].props.text == "60 km/h" and speedLine[3].props.text == "70 km/h", "stats: old and new top speed")
	check(speedLine and speedLine[4].props.text == "+10 km/h" and classOf(speedLine[4]):find("positive", 1, true), "stats: faster must read +10 km/h in the better color")
	-- old and new each marked as the worse or the better one (user decision 19.10.2026)
	check(speedLine and classOf(speedLine[2]):find("negative", 1, true) and classOf(speedLine[3]):find("positive", 1, true),
		"stats: slower old value must be marked worse, faster new one better")
	local weightLine = lineOf(body, "Gewicht")
	check(weightLine and weightLine[4].props.text == "+0.5 t" and classOf(weightLine[4]):find("negative", 1, true), "stats: heavier must read +0.5 t in the worse color")
	local costLine = lineOf(body, "Betriebskosten/Jahr")
	check(costLine and costLine[2].props.text == "$5000" and costLine[4].props.text == "+$1000" and classOf(costLine[4]):find("negative", 1, true), "stats: running costs")
	local tractiveLine = lineOf(body, "Zugkraft")
	-- equal as shown: the change column lists the value itself, without color (user decision 19.10.2026, like the store)
	check(tractiveLine and tractiveLine[4].props.text == "20 kN" and not classOf(tractiveLine[4]):find("positive") and not classOf(tractiveLine[4]):find("negative")
		and not classOf(tractiveLine[2]):find("positive") and not classOf(tractiveLine[2]):find("negative"), "stats: equal values must list the value without color")
	local noiseLine = lineOf(body, "Lärm")
	-- emissions are inverted: less noise is better, shown as the game's rating words
	check(noiseLine and noiseLine[2].props.text == "Mittel" and noiseLine[3].props.text == "Gut" and classOf(noiseLine[3]):find("positive", 1, true), "stats: quieter must be rated better")
	check(noiseLine and classOf(noiseLine[2]):find("negative", 1, true), "stats: the louder old rating must be marked worse")
	local pollutionLine = lineOf(body, "Verschmutzung")
	check(pollutionLine and pollutionLine[2].props.text == "Mittel" and pollutionLine[3].props.text == "Mittel"
		and not classOf(pollutionLine[3]):find("positive") and not classOf(pollutionLine[3]):find("negative")
		and not classOf(pollutionLine[2]):find("positive") and not classOf(pollutionLine[2]):find("negative"),
		"stats: the same rating word must not be colored")
	check(lineOf(body, "Schub") == nil and lineOf(body, "Komfort") == nil, "stats: rows without a value on either side must be hidden")
	check(lineOf(body, "Kapazität") ~= nil and lineOf(body, "Leistung") ~= nil and lineOf(body, "Ladetempo") ~= nil, "stats: capacity, power, loading speed missing")
	local readsExpanded = #storeCalls
	check(readsExpanded == 2, "stats: each model read once: " .. table.concat(storeCalls, ","))
	detailsBody(detailsCardOf(content("stats again")), "stats again")
	check(#storeCalls == readsExpanded, "stats: redraw read the vehicle data again")
	check(not wouldRedraw(), "stats: expanded card makes the window redraw on its own")

	-- new model without data (the game's code throws): old values stay, no crash, no difference
	combos(content("stats missing"))[2].props.onValueChange("m13")
	t = content("stats missing new")
	body = detailsBody(detailsCardOf(t), "stats missing new")
	speedLine = lineOf(body, "Höchsttempo")
	check(speedLine and speedLine[2].props.text == "60 km/h" and speedLine[3].props.text == "-" and speedLine[4].props.text == "", "stats: missing new data must show a dash")

	-- a vehicle type without any data and no new model: the card says so
	openAndRender("stats tram", 502, true)
	t = content("stats tram")
	card = detailsCardOf(t)
	check(card and card.collapsibleExpanded == true, "stats: expanded card does not stay expanded for the session")
	body = detailsBody(card, "stats tram")
	check(hasText(body, "Keine Daten zu diesen Modellen."), "stats: no data text missing")

	-- multiple units are read as the whole unit, like the store (makeVehicleData(id, true))
	storeStats.u900 = { totalCapacity = 100, speed = 120 / 3.6, power = 2000, weight = 150, runningCosts = 90000 }
	storeStats.u901 = { totalCapacity = 240, speed = 140 / 3.6, power = 2400, weight = 170, runningCosts = 110000 }
	bankBalance = 10000000
	openAndRender("stats mu", 500, true)
	combos(content("stats mu"))[1].props.onValueChange("u900")
	combos(content("stats mu old"))[2].props.onValueChange("u901")
	body = detailsBody(detailsCardOf(content("stats mu new")), "stats mu")
	local capLine = lineOf(body, "Kapazität")
	check(capLine and capLine[2].props.text == "100" and capLine[3].props.text == "240" and capLine[4].props.text == "+140", "stats: multiple unit capacity per unit")
	-- collapsing again hides the body
	card = detailsCardOf(content("stats mu collapse"))
	card.setCollapsibleExpanded(false)
	check(detailsCardOf(content("stats mu collapsed")).collapsibleExpanded == false, "stats: card does not collapse")
	if windows["mass_vehicle_replace.window"] then windows["mass_vehicle_replace.window"].params.onClose() end
end

print("== Sorting, Same cargo and details kept in the savegame")
do -- own block: the main chunk is at the 200 local limit
	local MOD = "mass_vehicle_replace_1"
	openAndRender("kept settings", 500, true)
	t = content("kept settings")
	find(t, function(n) return n.kind == "ToggleButton" and n.props.meta.class == "mvr-sort" end)[2].props.onValueChange(1)
	cargoToggle().props.onValueChange(0)
	detailsCardOf(content("kept details")).setCollapsibleExpanded(false)
	local kept = guiSaveData[MOD] or {}
	check(kept.sortOld == "year" and kept.sameCargo == false and kept.details == false,
		"kept: changes not written: sortOld " .. tostring(kept.sortOld) .. ", sameCargo " .. tostring(kept.sameCargo) .. ", details " .. tostring(kept.details))
	-- another savegame with other values: the next opening takes them
	guiSaveData[MOD] = { sortOld = "name", sortNew = "year", sameCargo = true, details = true }
	openAndRender("kept other savegame", 500, true)
	t = content("kept other savegame")
	local sortOn = find(t, function(n) return n.kind == "ToggleButton" and n.props.meta.class == "mvr-sort" end)
	check(sortOn[1].props.value == 1 and sortOn[4].props.value == 1 and cargoToggle().props.value == 1 and detailsCardOf(t).collapsibleExpanded == true,
		"kept: saved values not read on opening")
	-- odd values (another version, a broken savegame) keep what is there
	guiSaveData[MOD] = { sortOld = "speed", sortNew = 2, sameCargo = "no", details = 1 }
	openAndRender("kept odd values", 500, true)
	t = content("kept odd values")
	sortOn = find(t, function(n) return n.kind == "ToggleButton" and n.props.meta.class == "mvr-sort" end)
	check(sortOn[1].props.value == 1 and sortOn[4].props.value == 1 and cargoToggle().props.value == 1 and detailsCardOf(t).collapsibleExpanded == true,
		"kept: odd saved values must be ignored")
	-- the game's save data unreachable: the window still opens and works
	local savedGame = api.gui.game
	api.gui.game = nil
	openAndRender("kept unreachable", 500, true)
	find(content("kept unreachable"), function(n) return n.kind == "ToggleButton" and n.props.meta.class == "mvr-sort" end)[2].props.onValueChange(1)
	check(find(content("kept unreachable after"), function(n) return n.kind == "ToggleButton" and n.props.meta.class == "mvr-sort" end)[2].props.value == 1,
		"kept: without save data the sorting must still switch")
	api.gui.game = savedGame
end

print("== Replacement queue (#23 stage 2)")
do -- own block: the main chunk is at the 200 local limit
	local MOD = "mass_vehicle_replace_1"
	-- every scenario in a pcall: against a script without the queue the recipes are missing, and the counter-check
	-- (new tests against the old code) must count failures instead of stopping at the first error
	local function section(name, fn)
		print("== queue: " .. name)
		local ok, err = pcall(fn)
		if not ok then fail("queue: " .. name .. ": " .. tostring(err)) end
	end
	-- the host: an invisible plugin at the mod entry point; mounting reads the queue from the savegame, every
	-- frame runs its step hooks, a tick is one second of application time
	local function mountHost()
		local tree = render("MvrQueueHost", {})
		rules(tree, "queue host")
		for _i, fn in ipairs(MOCK.hooksOf.MvrQueueHost.mounts) do fn() end
	end
	local function frame()
		for _i, fn in ipairs(MOCK.hooksOf.MvrQueueHost.steps) do fn() end
	end
	local function hostTick(n)
		for _i = 1, n or 1 do
			MOCK.appClock = MOCK.appClock + 1
			frame()
		end
	end
	local function saved() return guiSaveData[MOD] or {} end
	local function openEntries()
		local n = 0
		for _e in tostring(saved().queue or ""):gmatch("%d+/%d+") do n = n + 1 end
		return n
	end
	local function sentIds()
		local ids = {}
		for _i, c in ipairs(sent) do ids[#ids + 1] = c.e end
		return table.concat(ids, ",")
	end
	local function queueBox(tt)
		return find(tt, function(n) return n.kind == "CheckBox" and tostring(n.props.label):find("nachbestellen", 1, true) ~= nil end)[1]
	end
	-- the replace window with its two tabs in the header (user decision 20.10.2026: no second window)
	local function mainWindow()
		local w = render("MvrWindow", { onClose = function() end })
		-- the tabs sit at the top of the content (game test 20.10.2026: as header they cut the title), the tab's
		-- content follows them; header and shown content are put where the checks look for them
		local kids = w.props.content and w.props.content.props.children or {}
		check(w.props.header == nil, "tabs must not sit in the window header")
		w.props.header, w.props.content = kids[1], kids[2]
		return w
	end
	-- MOCK: a field, not a local (the main chunk is at Lua's limit of 200 locals)
	function MOCK.tabLabels(w)
		local out = {}
		local h = w.props.header
		for _i, t in ipairs(h and h.props.tabs or {}) do out[#out + 1] = t.props.indicator.props.text end
		return table.concat(out, "|")
	end
	local function buttonIn(tree, label)
		return find(tree, function(n) return n.kind == "Button" and buttonText(n) == label end)[1]
	end
	-- the orders tab: its content and the body of every card, rendered like the game's card does it
	local function queueWindow(label)
		local win = mainWindow()
		local h = win.props.header
		check(h and h.kind == "TabWidget" and h.props.meta.class == "no-content" and h.props.value == 1, label .. ": orders tab not selected")
		check(win.props.content and win.props.content.kind == "recipe:MvrQueueContent", label .. ": window does not show the orders")
		if not (h and h.props.value == 1) then return { cards = {}, bodies = {}, titles = {}, settings = { kind = "none", props = {} } } end
		if not holdSteps then step() end
		stepStates = {}
		local tt = render("MvrQueueContent", { onClose = function() end })
		rules(tt, label)
		local cards = find(tt, function(n) return n.kind == "recipe:ContentCard" end)
		-- the settings: plain rows above the cards (user decision 20.10.2026), rendered like the content does
		local settings = render("MvrQueueSettings", {})
		rules(settings, label .. " settings")
		local out = { tree = tt, cards = cards, bodies = {}, titles = {}, settings = settings }
		for k, c in ipairs(cards) do
			local rp = c.props.recipeAndParamPermanent
			check(rp and rp.recipe and rp.param, label .. ": card " .. k .. " without a permanent body")
			local body = render(rp.recipe.name, rp.param)
			rules(body, label .. " card " .. k)
			out.bodies[k] = body
			out.titles[k] = c.props.title
		end
		return out
	end
	local function openQueue(_tt, label)
		local h = mainWindow().props.header
		check(h ~= nil, label .. ": tabs missing in the window header")
		if h then h.props.onValueChange(1) end
		return queueWindow(label)
	end
	local function closeQueue()
		local h = mainWindow().props.header
		if h then h.props.onValueChange(0) end
	end
	-- "cancel all" through the window and the game's dialog, like the player
	local function clearQueue(tt)
		local q = openQueue(tt, "clear")
		local b = buttonIn(q.settings, "Alle abbrechen")
		check(b ~= nil, "clear: cancel all button missing")
		if b and b.props.meta.enabled ~= false then
			b.props.onClick()
			local d = windows["mass_vehicle_replace.confirm"]
			check(d ~= nil, "clear: confirmation dialog not opened with its own key")
			if d then d.params.choices[1].onClick() end
			check(windows["mass_vehicle_replace.confirm"] == nil, "clear: dialog not closed")
		end
		closeQueue()
		check(openEntries() == 0, "clear: entries left: " .. tostring(saved().queue))
	end
	local function queueTrucks(label, b)
		local tt = chooseKasten(label, b)
		local box = queueBox(tt)
		if box and box.props.value == 0 then box.props.onValueChange(1); tt = content(label .. ", box on") end
		sent = {}
		replaceButton(tt).props.onClick()
		return content(label .. ", queued")
	end
	local function lineOf(body, prefix)
		local hit = find(body, function(n) return n.kind == "TextView" and tostring(n.props.text):find(prefix, 1, true) == 1 end)[1]
		return hit and hit.props.text or nil, hit
	end
	local function newSession()
		-- a new game session: the script loads again (fresh memory), the savegame data stays
		_react.recipeReplace.ActionButtonBar = nil
		chunk()
		exports = data()
		MOCK.appClock = MOCK.appClock + 100
	end
	local PRICE = 61000

	residuals, partValues, refused = {}, {}, {}
	commandSucceeds, holdSteps, throwAtCommand = true, false, nil
	costPerCommand = PRICE
	vehicles[115].transportVehicleConfig.vehicles[1].purchaseTime = 1 -- the oldest truck
	guiSaveData[MOD] = {}

	section("the box shows only while the money does not cover all", function()
		local tt = chooseKasten("box, one short", 487999)
		local box = queueBox(tt)
		check(box ~= nil and box.props.label == "Übriges nachbestellen", "box, one short: " .. tostring(box and box.props.label))
		check(box and box.props.value == 0, "box must be off at first")
		check(MOCK.tabLabels(mainWindow()) == "Ersetzen|Nachbestellungen", "tabs: " .. MOCK.tabLabels(mainWindow()))
		check(queueBox(chooseKasten("box, enough", 488000)) == nil, "box shown although the money covers all")
		check(queueBox(chooseKasten("box, infinite", nil)) == nil, "box shown with infinite money")
		box = queueBox(chooseKasten("box, nothing", 60999))
		check(box ~= nil and box.props.label == "Übrige 8 nachbestellen", "box, nothing affordable: " .. tostring(box and box.props.label))
	end)

	section("nothing affordable: the box turns the button into Queue 8", function()
		local tt = chooseKasten("queue all", 60999)
		queueBox(tt).props.onValueChange(1)
		check(saved().queueRest == true, "box state not kept in the savegame")
		tt = content("queue all, box on")
		local b = replaceButton(tt)
		check(buttonText(b) == "8 nachbestellen", "button text: " .. tostring(buttonText(b)))
		check(b.props.meta.enabled == true and b.props.meta.class:find("mvr-partial", 1, true) ~= nil, "button must be enabled and yellow")
		sent = {}
		b.props.onClick()
		check(#sent == 0, "queue all sent commands: " .. #sent)
		check(saved().queueFormat == "1", "queueFormat: " .. tostring(saved().queueFormat))
		check(saved().queue == "1,m10,m11,0,0,0,0,0:115/1,110/1,111/1,112/1,113/1,114/1,116/1,117/1", "queue, oldest first: " .. tostring(saved().queue))
		check(saved().queueNextId == "2" and saved().queueReserve == "0" and saved().queuePaused == false, "queue fields")
		tt = content("queue all, after")
		check(hasText(tt, "Ersetzt: 0 von 8. 8 nachbestellt."), "result line after queueing")
		-- a second click: the new order takes the vehicles over, the old job that did nothing yet goes
		tt = chooseKasten("queue all again", 60999)
		replaceButton(tt).props.onClick()
		tt = content("queue all again, after")
		check(hasText(tt, "Ersetzt: 0 von 8. 8 nachbestellt."), "second click must order all 8 again")
		check(saved().queue == "2,m10,m11,0,0,0,0,0:115/1,110/1,111/1,112/1,113/1,114/1,116/1,117/1", "second click: one job, the new one: " .. tostring(saved().queue))
		clearQueue(tt)
	end)

	section("box off: replacing as before, nothing queued (regression, passes on 1.1.0 too)", function()
		local tt = chooseKasten("box off", 200000)
		local box = queueBox(tt)
		if box and box.props.value == 1 then box.props.onValueChange(0); tt = content("box off, off") end
		sent = {}
		replaceButton(tt).props.onClick()
		check(#sent == 3, "box off: 3 commands expected, " .. #sent)
		check(openEntries() == 0, "box off: vehicles queued")
		check(hasText(content("box off, after"), "Ersetzt: 3 von 8."), "box off: result line")
	end)

	section("orders tab: the count in its label, the box under the replace button", function()
		local tt = queueTrucks("tab count", 0)
		check(MOCK.tabLabels(mainWindow()) == "Ersetzen|Nachbestellungen (8)", "tab with 8 open: " .. MOCK.tabLabels(mainWindow()))
		check(mainWindow().props.content.kind == "recipe:MvrContent", "the window must open on the replace tab")
		clearQueue(tt)
		check(MOCK.tabLabels(mainWindow()) == "Ersetzen|Nachbestellungen", "tab when empty: " .. MOCK.tabLabels(mainWindow()))
		tt = chooseKasten("box place", 200000)
		local col = find(tt, function(n)
			local c = n.kind == "BoxLayout" and n.props.children
			return c and #c == 2 and c[2].kind == "CheckBox" and c[1].kind == "Button"
		end)[1]
		check(col ~= nil and col.props.orientation == "V" and col.props.children[1].kind == "Button", "the box must sit under the replace button")
	end)

	section("partial click queues the rest, oldest first", function()
		local tt = queueTrucks("partial queue", 200000)
		local ids = {}
		for _i, c in ipairs(sent) do ids[#ids + 1] = c.e end
		table.sort(ids)
		check(#sent == 3 and table.concat(ids, ",") == "110,111,115", "partial queue: oldest three sent: " .. sentIds())
		check(tostring(saved().queue):match("^%d+,m10,m11,0,0,0,0,0:112/1,113/1,114/1,116/1,117/1$") ~= nil, "partial queue: " .. tostring(saved().queue))
		check(hasText(tt, "Ersetzt: 3 von 8. 5 nachbestellt."), "partial queue: result line")
	end)

	section("host: a tick sends what the balance covers, the next tick waits for the answers", function()
		mountHost()
		bankBalance, sent = 0, {}
		hostTick(3)
		check(#sent == 0, "sent without money")
		bankBalance = PRICE - 1
		hostTick()
		check(#sent == 0, "sent one short")
		bankBalance = 2 * PRICE - 1
		holdSteps = true
		hostTick()
		check(#sent == 1 and sent[1].e == 112, "money for one: one command for the head expected: " .. sentIds())
		hostTick(2)
		check(#sent == 1, "commands while the last tick's are in flight")
		holdSteps = false
		step()
		check(bankBalance == PRICE - 1, "balance after the command: " .. tostring(bankBalance))
		check(tostring(saved().queue):match("^%d+,m10,m11,1,0,0,0,0:113/1,114/1,116/1,117/1$") ~= nil, "after the callback: " .. tostring(saved().queue))
		bankBalance = 0
		-- the head is checked only when the money could cover it (its net cost only rises): one balance read per tick
		MOCK.apiCalls, MOCK.apiCallsByName = 0, {}
		hostTick(10)
		-- one validation reads three components (owner, vehicle, game time)
		check((MOCK.apiCallsByName.getComponent or 0) == 3, "head validated more than once while the money stays short: " .. tostring(MOCK.apiCallsByName.getComponent))
		check((MOCK.apiCallsByName.getPlayersBalance or 0) == 10, "balance reads: " .. tostring(MOCK.apiCallsByName.getPlayersBalance))
	end)

	section("queue window: cards, counters, the next vehicle and what is short", function()
		local tt = content("window")
		local q = openQueue(tt, "window")
		-- one card per order, without a title: number, both models with their images, price, counters
		check(#q.cards == 1 and q.titles[1] == nil, "order cards: " .. #q.cards .. ", title " .. tostring(q.titles[1]))
		local b = q.bodies[1]
		check(#find(b, function(n) return n.kind == "TextView" and n.props.text == "1" and n.props.meta.class:find("font-scale-title-2", 1, true) ~= nil end) == 1, "order number missing")
		check(#find(b, function(n) return n.kind == "Component" and n.props.meta and n.props.meta.class == "mvr-divider" end) == 2, "lines around the order missing")
		check(lineOf(b, "Benz Dreitonner Kipper") ~= nil and lineOf(b, "Benz Dreitonner Kasten") ~= nil and lineOf(b, "→") ~= nil, "models in the head")
		check(#find(b, function(n) return n.kind == "ImageView" and n.props.meta.class == "mvr-item-image" end) == 2, "model images in the head")
		check(lineOf(b, "Nächstes $61000 | Gesamt $244000") ~= nil, "price of one and of all open vehicles")
		-- number | order | cancel (user decision 20.10.2026): the models centered, open left and prices right below
		local card = find(b, function(n) return n.kind == "BoxLayout" and n.props.meta and n.props.meta.class == "mvr-row" end)[1]
		local kinds = {}
		for _i, c in ipairs(card and card.props.children or {}) do kinds[#kinds + 1] = c.kind == "Component" and c.props.meta.class or c.kind end
		check(table.concat(kinds, "|") == "TextView|mvr-divider|BoxLayout|mvr-divider|Button", "card parts: " .. table.concat(kinds, "|"))
		local rowsBox = card and card.props.children[3]
		local head, row2 = rowsBox.props.children[1], rowsBox.props.children[2]
		check(head.props.children[1].kind == "Spacer" and head.props.children[#head.props.children].kind == "Spacer", "models must be centered")
		check(row2.props.children[2].kind == "Spacer", "open left, prices right")
		local texts = {}
		for _i, c in ipairs(row2 and row2.props.children or {}) do texts[#texts + 1] = c.kind == "TextView" and c.props.text or c.kind end
		check(#rowsBox.props.children == 2 and texts[1] == "Offen 4 (übersprungen 0)" and texts[3] == "Nächstes $61000 | Gesamt $244000"
			and #texts == 3, "second row: " .. table.concat(texts, "|"))
		check(lineOf(b, "Offen 4 (übersprungen 0)") ~= nil and lineOf(b, "Ersetzt") == nil, "counters in one row, no replaced count (user decision 20.10.2026)")
		check(lineOf(q.settings, "4 Fahrzeuge") == nil and lineOf(q.settings, "Pausiert") == nil, "settings without a count or status line")
		check(buttonIn(q.bodies[1], "Abbrechen") ~= nil, "cancel button of the job")
		-- a plain tree, no own classes without a rule (rules() checked that), and the game's spacing classes on the rows
		check(#find(q.settings, function(n) return n.kind == "BoxLayout" and n.props.meta and n.props.meta.class == "mvr-rows" end) == 1, "settings rows without the spacing class")
		closeQueue()
	end)

	section("reserve stays on the account", function()
		local q = openQueue(content("reserve"), "reserve")
		local spin = find(q.settings, function(n) return n.kind == "DoubleSpinBox" end)[1]
		check(spin ~= nil and spin.props.min == 0 and spin.props.value == 0, "reserve spin box")
		check(hasText(q.settings, "Reserve") and hasText(q.settings, "$"), "reserve: currency sign in front of the field")
		spin.props.onValueChange(100000)
		check(saved().queueReserve == "100000", "reserve not kept: " .. tostring(saved().queueReserve))
		q = queueWindow("reserve set")
		check(find(q.settings, function(n) return n.kind == "DoubleSpinBox" end)[1].props.value == 100000, "spin box does not show the reserve")
		closeQueue()
		bankBalance, sent = PRICE + 99999, {}
		hostTick()
		check(#sent == 0, "sent into the reserve")
		bankBalance = PRICE + 100000
		hostTick()
		check(#sent == 1 and sent[1].e == 113, "reserve covered: " .. sentIds())
		step()
		openQueue(content("reserve back"), "reserve back")
		find(queueWindow("reserve back").settings, function(n) return n.kind == "DoubleSpinBox" end)[1].props.onValueChange(0)
		closeQueue()
	end)

	section("a sold vehicle is dropped and the next one checked in the same tick", function()
		local truck = vehicles[114]
		vehicles[114] = nil
		bankBalance, sent = PRICE, {}
		hostTick()
		check(#sent == 1 and sent[1].e == 116, "next vehicle not sent in the same tick: " .. sentIds())
		step()
		local q = openQueue(content("sold"), "sold")
		check(lineOf(q.bodies[1], "Offen 1 (übersprungen 1)") ~= nil, "counts after a sold vehicle")
		local _t, node = lineOf(q.bodies[1], "Offen")
		check(node and node.props.meta.tooltip == "1 verkauft, 0 schon ersetzt, 0 vom Spiel abgelehnt", "skipped tooltip: " .. tostring(node and node.props.meta.tooltip))
		closeQueue()
		vehicles[114] = truck
	end)

	section("an entity id reused for another entity is dropped", function()
		MOCK.births[117] = 2
		bankBalance, sent = PRICE, {}
		hostTick()
		check(#sent == 0, "reused id replaced: " .. sentIds())
		local q = openQueue(content("reused"), "reused")
		-- the last open vehicle went: the finished job leaves the window by itself (user decision 20.10.2026)
		check(#q.cards == 0 and tostring(saved().queue) == "", "finished job not removed by itself: " .. tostring(saved().queue))
		closeQueue()
		MOCK.births[117] = nil
	end)

	section("a vehicle replaced by hand is dropped, the next one goes on", function()
		local tt = queueTrucks("by hand", 0)
		check(openEntries() == 8, "by hand: 8 queued")
		vehicle(115, { 11 }) -- the oldest got the new model in the game's own window; the id stays
		bankBalance, sent = PRICE, {}
		hostTick()
		check(#sent == 1 and sent[1].e == 110, "by hand: 110 expected after dropping 115: " .. sentIds())
		step()
		local q = openQueue(content("by hand, window"), "by hand")
		check(lineOf(q.bodies[1], "Offen 6") ~= nil, "by hand: counts")
		local _t, node = lineOf(q.bodies[1], "Offen 6 (übersprungen 1)")
		check(node and node.props.meta.tooltip == "0 verkauft, 1 schon ersetzt, 0 vom Spiel abgelehnt", "by hand: tooltip " .. tostring(node and node.props.meta.tooltip))
		closeQueue()
		clearQueue(tt)
		vehicle(115, { 10 })
		vehicles[115].transportVehicleConfig.vehicles[1].purchaseTime = 1
	end)

	section("a train rebuilt by hand keeps the new locomotive, the queue swaps only the wagons", function()
		-- Bm 235 (3) in trains 100 and 102; the player swaps the locomotive of 102 meanwhile
		step()
		bankBalance = 0
		openAndRender("train queue", 500, true)
		local tt = content("train queue")
		combos(tt)[1].props.onValueChange("m3")
		tt = content("train queue, Bm 235")
		combos(tt)[2].props.onValueChange("m2")
		tt = content("train queue, Avmz")
		local box = queueBox(tt)
		check(box ~= nil, "train queue: box missing")
		if box and box.props.value == 0 then box.props.onValueChange(1); tt = content("train queue, box on") end
		check(buttonText(replaceButton(tt)) == "2 nachbestellen", "train queue: button " .. tostring(buttonText(replaceButton(tt))))
		sent = {}
		replaceButton(tt).props.onClick()
		check(openEntries() == 2, "train queue: 2 trains expected: " .. tostring(saved().queue))
		local saved102 = vehicles[102]
		vehicle(102, { 4, 3, 3 })
		bankBalance = nil
		hostTick()
		step()
		hostTick()
		check(#sent == 2 and sentIds() == "100,102", "train queue: both trains in order: " .. sentIds())
		local ids = {}
		for _j, part in ipairs(sent[2] and sent[2].conf.vehicles or {}) do ids[#ids + 1] = part.part.modelId end
		check(table.concat(ids, ",") == "4,2,2", "train queue: new locomotive kept, wagons swapped: " .. table.concat(ids, ","))
		step()
		vehicles[102] = saved102
		clearQueue(content("train queue, clear"))
	end)

	section("new model expires: the job waits, blocked, and goes on when it is back", function()
		step()
		bankBalance = 0
		openAndRender("expiring queue", 501, true)
		local tt = content("expiring queue")
		combos(tt)[2].props.onValueChange("m15")
		tt = content("expiring queue, Auslauf")
		if queueBox(tt).props.value == 0 then queueBox(tt).props.onValueChange(1); tt = content("expiring queue, box on") end
		sent = {}
		replaceButton(tt).props.onClick()
		check(openEntries() == 8, "expiring queue: 8 queued")
		currentYear = 1981
		bankBalance = nil
		hostTick(2)
		check(#sent == 0, "expired model still replaced: " .. #sent)
		local q = openQueue(content("expiring queue, window"), "expiring")
		local _t, node = lineOf(q.bodies[1], "Modell nicht mehr erhältlich")
		check(node ~= nil and node.props.meta.class:find("error", 1, true) ~= nil, "blocked job must say why, in the error colour")
		check(buttonIn(q.bodies[1], "Abbrechen") ~= nil, "blocked job must offer Cancel")
		-- the red line is the third row of the order; cancel stays in its own part on the right (user decision 20.10.2026)
		local rowsBox = find(q.bodies[1], function(n) return n.kind == "BoxLayout" and n.props.meta and n.props.meta.class == "mvr-order-body" end)[1]
		check(rowsBox and #rowsBox.props.children == 3 and #find(rowsBox, function(n) return n.kind == "Button" end) == 0, "blocked: red line as third row, cancel outside")
		closeQueue()
		currentYear = 1980
		hostTick()
		check(#sent == 8, "model back: not resumed: " .. #sent)
		step()
		clearQueue(content("expiring queue, clear"))
	end)

	section("a blocked job is removed with its button", function()
		step()
		bankBalance = 0
		openAndRender("blocked remove", 501, true)
		local tt = content("blocked remove")
		combos(tt)[2].props.onValueChange("m15")
		tt = content("blocked remove, Auslauf")
		if queueBox(tt).props.value == 0 then queueBox(tt).props.onValueChange(1); tt = content("blocked remove, box on") end
		replaceButton(tt).props.onClick()
		currentYear = 1981
		hostTick()
		local q = openQueue(content("blocked remove, window"), "blocked remove")
		buttonIn(q.bodies[1], "Abbrechen").props.onClick()
		q = queueWindow("blocked removed")
		check(#q.cards == 0 and tostring(saved().queue) == "", "blocked job not removed: " .. tostring(saved().queue))
		closeQueue()
		currentYear = 1980
	end)

	section("reserve: hidden with infinite money, capped at a trillion", function()
		local tt = queueTrucks("reserve rules", 0)
		bankBalance = nil
		local q = openQueue(content("reserve rules, infinite"), "reserve infinite")
		check(find(q.settings, function(n) return n.kind == "DoubleSpinBox" end)[1] == nil, "reserve shown with infinite money")
		closeQueue()
		bankBalance = 0
		q = openQueue(content("reserve rules, money"), "reserve money")
		local spin = find(q.settings, function(n) return n.kind == "DoubleSpinBox" end)[1]
		check(spin ~= nil and spin.props.max == 1e12, "reserve field without its upper bound")
		if spin then spin.props.onValueChange(5e12) end
		check(saved().queueReserve == "1000000000000", "reserve not capped: " .. tostring(saved().queueReserve))
		if spin then spin.props.onValueChange(0) end
		closeQueue()
		clearQueue(tt)
	end)

	section("orders tab: prices follow the residual value while the game runs", function()
		local tt = queueTrucks("revalue", 0)
		bankBalance = 0
		hostTick()
		local q = openQueue(content("revalue"), "revalue")
		check(lineOf(q.bodies[1], "Nächstes $61000 | Gesamt $488000") ~= nil, "revalue: first prices")
		residuals[115] = 1000 -- the oldest truck is worth something after all
		q = queueWindow("revalue, paused")
		check(lineOf(q.bodies[1], "Nächstes $61000 | Gesamt $488000") ~= nil, "revalue: read again although the game stood still")
		gameTimeNow = gameTimeNow + 1 -- the game runs: the prices follow at once (user decision 20.10.2026: live)
		q = queueWindow("revalue, game runs")
		check(lineOf(q.bodies[1], "Nächstes $60000 | Gesamt $487000") ~= nil, "revalue: prices do not follow the residual value")
		residuals[115] = nil
		closeQueue()
		clearQueue(tt)
	end)

	section("infinite money: the whole queue in one tick", function()
		local tt = queueTrucks("infinite queue", 0)
		bankBalance, sent = nil, {}
		hostTick()
		check(sentIds() == "115,110,111,112,113,114,116,117", "one tick, oldest first: " .. sentIds())
		step()
		hostTick(2)
		check(#sent == 8 and openEntries() == 0, "queue not empty after one tick: " .. tostring(saved().queue))
		clearQueue(tt)
	end)

	section("money for three of eight: three in one tick, the rest waits", function()
		local tt = queueTrucks("three", 0)
		bankBalance, sent = 3 * PRICE + 500, {}
		hostTick()
		check(sentIds() == "115,110,111", "three oldest in one tick: " .. sentIds())
		step()
		check(bankBalance == 500 and openEntries() == 5, "after three: balance " .. tostring(bankBalance) .. ", " .. tostring(saved().queue))
		hostTick(3)
		check(#sent == 3, "sent without money: " .. sentIds())
		clearQueue(tt)
		bankBalance = 0
	end)

	section("a newer order takes queued vehicles over; the older job keeps what it did", function()
		local tt = queueTrucks("older order", 0)
		bankBalance, sent = PRICE, {}
		hostTick()
		step()
		check(sentIds() == "115", "older order: one replaced")
		-- a newer model came out: the player orders the remaining trucks again, now with another new model
		bankBalance = 0
		tt = chooseKasten("newer order", 0)
		combos(tt)[2].props.onValueChange("m15")
		tt = content("newer order, model")
		if queueBox(tt).props.value == 0 then queueBox(tt).props.onValueChange(1); tt = content("newer order, box on") end
		replaceButton(tt).props.onClick()
		check(tostring(saved().queue):match("^%d+,m10,m15,0,0,0,0,0:115/1,110/1,111/1,112/1,113/1,114/1,116/1,117/1$") ~= nil,
			"newer order: vehicles moved, the emptied older job gone: " .. tostring(saved().queue))
		local q = openQueue(content("newer order, window"), "newer order")
		check(#q.cards == 1 and lineOf(q.bodies[1], "Offen 8") ~= nil,
			"newer order: cards " .. table.concat(q.titles, "|"))
		closeQueue()
		clearQueue(content("newer order, clear"))
	end)

	section("replacing at once takes the vehicles out of the queue", function()
		local tt = queueTrucks("direct", 0)
		check(openEntries() == 8, "direct: 8 queued")
		bankBalance = nil
		tt = chooseKasten("direct, money", nil)
		sent = {}
		replaceButton(tt).props.onClick()
		check(#sent == 8 and openEntries() == 0 and tostring(saved().queue) == "", "direct: queue must be empty: " .. tostring(saved().queue))
		step()
		bankBalance = 0
	end)

	section("negative balance: nothing", function()
		local tt = queueTrucks("negative", 0)
		bankBalance, sent = -5, {}
		hostTick(3)
		check(#sent == 0, "sent with a negative balance")
		clearQueue(tt)
		bankBalance = 0
	end)

	section("two jobs run one after the other", function()
		step()
		queueTrucks("fifo trucks", 0)
		openAndRender("fifo trains", 500, true)
		local tt = content("fifo trains")
		combos(tt)[1].props.onValueChange("m3")
		tt = content("fifo trains, Bm 235")
		combos(tt)[2].props.onValueChange("m2")
		tt = content("fifo trains, Avmz")
		if queueBox(tt).props.value == 0 then queueBox(tt).props.onValueChange(1); tt = content("fifo, box on") end
		sent = {}
		replaceButton(tt).props.onClick()
		check(openEntries() == 10, "fifo: 10 queued: " .. tostring(saved().queue))
		local q = openQueue(tt, "fifo")
		check(#q.cards == 2 and #find(q.bodies[2], function(n) return n.kind == "TextView" and n.props.text == "2" end) == 1, "second order must carry number 2")
		closeQueue()
		bankBalance = nil
		for _k = 1, 10 do hostTick(); step() end
		check(sentIds() == "115,110,111,112,113,114,116,117,100,102", "fifo: order " .. sentIds())
		check(openEntries() == 0, "fifo: entries left")
		clearQueue(content("fifo, clear"))
	end)

	section("cancelling a job while its command is in flight", function()
		local tt = queueTrucks("cancel", 0)
		holdSteps, bankBalance, sent = true, PRICE, {}
		hostTick()
		check(#sent == 1, "cancel: one in flight")
		local q = openQueue(tt, "cancel")
		buttonIn(q.bodies[1], "Abbrechen").props.onClick()
		q = queueWindow("cancelled")
		check(#q.cards == 0 and openEntries() == 0, "cancel: job not removed")
		closeQueue()
		holdSteps = false
		step() -- the callback of the cancelled job arrives
		hostTick()
		check(#sent == 1 and openEntries() == 0 and tostring(saved().queue) == "", "cancel: the late callback revived something: " .. tostring(saved().queue))
	end)

	section("paused: nothing until the box is cleared", function()
		local tt = queueTrucks("paused", 0)
		local q = openQueue(tt, "paused")
		local box = find(q.settings, function(n) return n.kind == "CheckBox" end)[1]
		-- name on the left, the box in the right column of the settings, like the reserve field
		check(box and box.props.label == "Nachbestellungen anhalten", "hold box label: " .. tostring(box and box.props.label))
		-- the settings are the footer below the orders (variant D, user decision 20.10.2026)
		local kids = find(q.tree, function(n) return n.kind == "Component" and n.props.meta and n.props.meta.class == "mvr-orders" end)[1].props.layout.props.children
		check(kids[#kids].kind == "recipe:MvrQueueSettings", "settings must be the last part of the tab")
		check(#find(q.settings, function(n) return n.kind == "BoxLayout" and n.props.meta and n.props.meta.class == "mvr-row" end) == 1, "settings must be one row")
		check(box ~= nil and box.props.value == 0, "paused box")
		box.props.onValueChange(1)
		check(saved().queuePaused == true, "paused not kept")
		q = queueWindow("paused on")
		check(find(q.settings, function(n) return n.kind == "CheckBox" end)[1].props.value == 1, "hold box must show it is on")
		closeQueue()
		bankBalance, sent = nil, {}
		hostTick(3)
		check(#sent == 0, "sent while paused")
		openQueue(content("paused off"), "paused off")
		find(queueWindow("paused off").settings, function(n) return n.kind == "CheckBox" end)[1].props.onValueChange(0)
		closeQueue()
		hostTick()
		check(#sent == 8, "not resumed: " .. #sent)
		step()
		clearQueue(content("paused, clear"))
	end)

	section("refused three times: dropped as rejected", function()
		local tt = queueTrucks("refused", 0)
		refused[115] = true
		sent = {}
		for _k = 1, 3 do bankBalance = PRICE; hostTick(); step() end
		check(sentIds() == "115,115,115", "refused: three tries expected: " .. sentIds())
		bankBalance = PRICE
		hostTick()
		check(sentIds() == "115,115,115,110", "refused: next vehicle after three tries: " .. sentIds())
		step()
		local q = openQueue(content("refused, window"), "refused")
		local _t, node = lineOf(q.bodies[1], "Offen")
		check(node and node.props.meta.tooltip == "0 verkauft, 0 schon ersetzt, 1 vom Spiel abgelehnt", "refused: tooltip " .. tostring(node and node.props.meta.tooltip))
		closeQueue()
		refused = {}
		clearQueue(tt)
	end)

	section("no callback: the vehicle tells whether it was replaced", function()
		local tt = queueTrucks("no callback", 0)
		holdSteps, bankBalance, sent = true, PRICE, {}
		hostTick()
		check(#sent == 1 and sent[1].e == 115, "no callback: first command")
		hostTick(5)
		check(#sent == 1, "resent before the timeout")
		MOCK.appClock = MOCK.appClock + 11
		frame() -- the timeout: parts unchanged, so the vehicle stays at the head
		hostTick()
		check(#sent == 2 and sent[2].e == 115, "no callback, unchanged: not sent again: " .. sentIds())
		-- this time the vehicle changed meanwhile: done, the next one is sent
		vehicle(115, { 11 })
		MOCK.appClock = MOCK.appClock + 11
		frame()
		hostTick()
		check(#sent == 3 and sent[3].e == 110, "no callback, changed: next vehicle expected: " .. sentIds())
		queuedCommands = {}
		holdSteps = false
		local q = openQueue(content("no callback, window"), "no callback")
		check(lineOf(q.bodies[1], "Offen 7") ~= nil, "no callback: counts")
		closeQueue()
		vehicle(115, { 10 })
		vehicles[115].transportVehicleConfig.vehicles[1].purchaseTime = 1
		clearQueue(tt)
	end)

	section("budget: an empty queue costs no native call, a waiting one only the clock", function()
		MOCK.apiCalls = 0
		for _k = 1, 100 do frame() end
		hostTick(5)
		check(MOCK.apiCalls == 0, "empty queue: " .. MOCK.apiCalls .. " native calls")
		local tt = queueTrucks("budget", 0)
		bankBalance = 0
		hostTick() -- the first tick validates the head
		MOCK.apiCalls, MOCK.apiCallsByName = 0, {}
		for _k = 1, 100 do frame() end
		check(MOCK.apiCalls == 100 and MOCK.apiCallsByName.getApplicationTime == 100, "frames between ticks: " .. MOCK.apiCalls .. " calls")
		MOCK.apiCalls, MOCK.apiCallsByName = 0, {}
		hostTick(10)
		check((MOCK.apiCallsByName.getComponent or 0) == 0 and (MOCK.apiCallsByName.getEntitiesWithComponent or 0) == 0, "waiting for money: the fleet or the head read again")
		clearQueue(tt)
	end)

	section("1000 stale vehicles: at most 20 dropped per tick", function()
		for id = 2000, 2999 do
			vehicle(id, { 10 })
			vehicles[id].transportVehicleConfig.vehicles[1].purchaseTime = 0 -- older than the eight
		end
		local tt = queueTrucks("stale", 0)
		check(openEntries() == 1008, "stale: 1008 queued, " .. openEntries())
		-- numbers carry the game's thousands separator (user decision 20.10.2026)
		check(MOCK.tabLabels(mainWindow()) == "Ersetzen|Nachbestellungen (1.008)", "thousands separator in the tab: " .. MOCK.tabLabels(mainWindow()))
		check(hasText(tt, "Ersetzt: 0 von 1.008. 1.008 nachbestellt."), "thousands separator in the result line")
		for id = 2000, 2999 do vehicles[id] = nil end
		bankBalance, sent = nil, {}
		hostTick()
		check(openEntries() == 988 and #sent == 0, "stale: 20 dropped expected, " .. (1008 - openEntries()) .. " dropped, " .. #sent .. " sent")
		hostTick()
		check(openEntries() == 968, "stale: second tick, " .. openEntries() .. " left")
		clearQueue(tt)
	end)

	section("the window's own batch and the queue never hit the same vehicle", function()
		local tt = queueTrucks("race", 0)
		holdSteps, bankBalance, sent = true, PRICE, {}
		hostTick()
		check(#sent == 1 and sent[1].e == 115, "race: queue sent the oldest")
		bankBalance = nil
		-- the player picks the new model again in the open window (no step passes: the queue's command is still
		-- waiting) and replaces everything with infinite money
		combos(tt)[2].props.onValueChange("m11")
		tt = content("race, window")
		check(buttonText(replaceButton(tt)) == "Ersetzen", "race: button " .. tostring(buttonText(replaceButton(tt))))
		replaceButton(tt).props.onClick()
		check(#sent == 8 and not sentIds():find(",115", 1, true), "race: the window must leave the queue's vehicle out: " .. sentIds())
		hostTick(3)
		check(#sent == 8, "race: queue sent while the window's batch is pending")
		holdSteps = false
		step()
		clearQueue(content("race, clear"))
	end)

	section("no counter in the game bar: everything stays in the depot window (user decision 20.10.2026)", function()
		local ok = pcall(render, "MvrQueueBar", {})
		check(not ok, "a game bar counter is still registered")
	end)

	section("an error in the tick never reaches the UI; five in a row pause the queue", function()
		local tt = queueTrucks("error", 0)
		bankBalance, sent = nil, {}
		local realGet = api.engine.getComponent
		api.engine.getComponent = function(e, ct) if ct == CT.TRANSPORT_VEHICLE then error("component unreadable") end return realGet(e, ct) end
		local okFrame = true
		for _k = 1, 5 do
			MOCK.appClock = MOCK.appClock + 11
			okFrame = okFrame and pcall(frame)
		end
		api.engine.getComponent = realGet
		check(okFrame, "error: the step hook threw")
		check(#sent == 0 and saved().queuePaused == true, "error: queue not paused after five errors")
		local q = openQueue(content("error, window"), "error")
		check(lineOf(q.tree, "Fehler, Nachbestellungen angehalten: ") ~= nil, "error: window does not show it")
		find(q.settings, function(n) return n.kind == "CheckBox" end)[1].props.onValueChange(0)
		closeQueue()
		MOCK.appClock = MOCK.appClock + 11
		hostTick()
		check(#sent == 8, "error: not resumed after unpausing: " .. #sent)
		step()
		clearQueue(tt)
	end)

	section("savegame: a new session continues the queue, garbage is left alone", function()
		local tt = queueTrucks("session", 0)
		local before = saved().queue
		newSession()
		mountHost()
		bankBalance, sent = PRICE, {}
		hostTick()
		check(#sent == 1 and sent[1].e == 115, "session: queue not continued after loading: " .. sentIds())
		step()
		check(saved().queue ~= before and openEntries() == 7, "session: progress not written")
		-- another version wrote the queue: not processed, not overwritten, said in the window
		guiSaveData[MOD] = { sortOld = "name", queueFormat = "2", queue = "whatever", queueReserve = "5" }
		newSession()
		mountHost()
		sent = {}
		hostTick(3)
		check(#sent == 0, "foreign format processed")
		local hit = false
		for _i, l in ipairs(logs) do if l:find("another version", 1, true) then hit = true end end
		check(hit, "foreign format: no log line")
		tt = chooseKasten("foreign, sort", 60999)
		find(tt, function(n) return n.kind == "ToggleButton" and n.props.meta.class == "mvr-sort" end)[2].props.onValueChange(1)
		check(saved().sortOld == "year" and saved().queueFormat == "2" and saved().queue == "whatever" and saved().queueReserve == "5", "foreign format overwritten by a settings change")
		tt = content("foreign, queue")
		if queueBox(tt).props.value == 0 then queueBox(tt).props.onValueChange(1); tt = content("foreign, box on") end
		replaceButton(tt).props.onClick()
		tt = content("foreign, clicked")
		check(hasText(tt, "Die Nachbestellungen in diesem Spielstand stammen von einer anderen Version von Mass Vehicle Replace und bleiben unangetastet."), "foreign format: click must say why nothing was queued")
		check(saved().queue == "whatever", "foreign format overwritten by a click")
		local q = openQueue(tt, "foreign")
		check(lineOf(q.tree, "Die Nachbestellungen in diesem Spielstand") ~= nil, "foreign format: window does not say so")
		closeQueue()
		-- damaged string of our own format: the same
		guiSaveData[MOD] = { queueFormat = "1", queue = "1,m10,m11,0,0,0,0,0:115/x" }
		newSession()
		mountHost()
		hostTick(2)
		check(#sent == 0 and saved().queue == "1,m10,m11,0,0,0,0,0:115/x", "damaged queue processed or overwritten")
		-- an old savegame without a queue, and none at all
		guiSaveData[MOD] = { sortOld = "year" }
		newSession()
		mountHost()
		hostTick(2)
		guiSaveData[MOD] = nil
		newSession()
		mountHost()
		hostTick(2)
		check(#sent == 0, "old savegame: commands from nowhere")
		tt = queueTrucks("old savegame, queue", 0)
		check(openEntries() == 8 and saved().queueFormat == "1", "old savegame: queueing must start a queue")
		clearQueue(tt)
	end)

	section("map editor: the host does nothing", function()
		MOCK.mapEditor = true
		local tt = queueTrucks("editor", 0)
		newSession()
		mountHost()
		bankBalance, sent = nil, {}
		hostTick(3)
		check(#sent == 0, "editor: commands sent")
		MOCK.mapEditor = false
		newSession()
		mountHost()
		clearQueue(chooseKasten("editor, clear", 0))
	end)

	-- back to the state the following tests expect
	bankBalance, holdSteps, refused, residuals = 5000000, false, {}, {}
	vehicles[115].transportVehicleConfig.vehicles[1].purchaseTime = nil
	if windows["mass_vehicle_replace.window"] then windows["mass_vehicle_replace.window"].params.onClose() end
end

print("== Robust against mods that overwrite the module field")
-- fresh copy of the mod without the other mod's replacement in front of it
local savedReplace, savedField = _react.recipeReplace.ActionButtonBar, entity_window_util.ActionButtonBar
_react.recipeReplace.ActionButtonBar = nil
chunk()
local fresh = data()
fresh.doReplace(replacementApi)
-- a careless mod swaps the field with a plain function after we loaded
entity_window_util.ActionButtonBar = function(ref, p) return { kind = "Swapped", props = p } end
local okSwap, swapped = pcall(barRecipe, nil, manage)
check(okSwap, "our replacement breaks when another mod swaps the module field: " .. tostring(swapped))
check(okSwap and swapped.kind == "ActionButtonBar" and #swapped.props.secondaryButtons == 1, "captured recipe not used after the field was swapped")
-- the field is already swapped when the mod loads: no crash, no replacement
_react.recipeReplace.ActionButtonBar = nil
chunk()
local okLoad = pcall(function() data().doReplace(replacementApi) end)
check(okLoad, "doReplace fails when ActionButtonBar is not a recipe")
check(_react.recipeReplace.ActionButtonBar == nil, "a plain function was passed to ReplaceRecipe")
_react.recipeReplace.ActionButtonBar, entity_window_util.ActionButtonBar = savedReplace, savedField

print(string.format("\n%d checks, %d errors (plus the per-node rules on %d rendered trees)", checks, failures, renders))
os.exit(failures == 0 and 0 or 1)
