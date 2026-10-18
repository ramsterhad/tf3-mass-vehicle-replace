-- Local test for mass_vehicle_replace.script.lua without the game (Lua 5.2 like in the game).
-- Mocks api, react, builtin etc., builds the window in several situations and checks the rules
-- the game has crashed on or drawn wrongly so far.
-- Usage: lua5.2 test_ft.lua <script.lua> <css.lua> <strings_de.lua>

local SCRIPT, CSS, STRINGS = arg[1], arg[2], arg[3]
local failures, checks = 0, 0
local function fail(msg) failures = failures + 1; print("FAIL: " .. msg) end
local function check(cond, msg) checks = checks + 1; if not cond then fail(msg) end end

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
local LAYOUTS = { BoxLayout = true, FloatingLayout = true, GridLayout = true }
local builtin = setmetatable({
	type = {
		Orientation = { Horizontal = "H", Vertical = "V" },
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
	local out = recipes[name](params)
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
local spacerOrig = function() return { kind = "Spacer", props = {} } end
local gui_react_util = { makeHorizontalSpacer = spacerOrig }
local windows = {}
local game_react_globals = { getDefaultWindowApi = function() return {
	addWindow = function(recipe, key, params) windows[key] = { recipe = recipe, params = params } end,
	removeWindow = function(recipe, key) windows[key] = nil end,
} end }
local entity_window_util = { ActionButtonBar = gameRecipe("ActionButtonBar", function(ref, p) return { kind = "ActionButtonBar", props = p } end) }
local MaintenanceStationWindow = makeRecipe("MaintenanceStationWindow", function() return builtin.BoxLayout{} end)
recipeIds[MaintenanceStationWindow] = "MaintenanceStationWindow"
originalFns.MaintenanceStationWindow = function(params) return { kind = "recipe:MaintenanceStationWindow", props = params } end

local modules = {
	["::/gui/main/react.lua"] = react,
	["::/gui/main/builtin.lua"] = builtin,
	["::/gui/main/gui_react_util.tl"] = gui_react_util,
	["::/gui/main/engine_react_util.tl"] = engine_react_util,
	["::/gui/main/game_react_globals.tl"] = game_react_globals,
	["::/gui/entity_window/entity_window_util.tl"] = entity_window_util,
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
local CT = { TRANSPORT_VEHICLE = "TV", GAME_TIME = "GT", VEHICLE_DEPOT = "VD" }

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
	vehicles[id] = setmetatable({}, { __index = function(_t, k)
		if k == "carrier" then fleetBuildReads = fleetBuildReads + 1 end
		return real[k]
	end, __newindex = real })
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
api = {
	type = {
		ComponentType = CT,
		enum = { Carrier = Carrier, TransportMode = TransportMode },
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
		end,
		entityExists = function(e) return depots[e] ~= nil or vehicles[e] ~= nil end,
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
	util = { formatMoney = function(v) return "$" .. tostring(v) end },
	cmd = {
		makeVehicleReplaceCmd = function(e, conf) return { e = e, conf = conf } end,
		-- like the game in the GUI state (api/tealdef/api/cmd.d.tl:2-10): the command runs in the next
		-- simulation step and its callback comes a frame later; step() below plays that out.
		-- Each executed command books a fixed amount.
		sendCommand = function(c, cb)
			if throwAtCommand and #sent + 1 == throwAtCommand then error("command rejected") end
			sent[#sent + 1] = c
			queuedCommands[#queuedCommands + 1] = function()
				if bankBalance then bankBalance = bankBalance - costPerCommand end
				if cb then cb(c, commandSucceeds, {}) end
			end
		end,
	},
}

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
		check(n == #p.children, path .. ": child list with a gap (nil) in " .. node.kind)
		for i = 1, n do walk(p.children[i], path .. "/" .. node.kind .. "[" .. i .. "]", visit) end
	end
	for _k, key in ipairs({ "child", "content", "layout" }) do
		if p[key] then walk(p[key], path .. "/" .. node.kind .. "." .. key, visit) end
	end
	if p.items then for i, it in ipairs(p.items) do walk(it, path .. "/items[" .. i .. "]", visit) end end
end

local function rules(tree, label)
	check(tree and tree.kind == "BoxLayout", label .. ": recipe must return a layout, returns " .. tostring(tree and tree.kind))
	walk(tree, label, function(n, path)
		local p = n.props or {}
		local cls = p.meta and p.meta.class
		if cls then
			for c in tostring(cls):gmatch("mvr%-[%w%-]+") do
				check(cssClasses[c], path .. ": CSS class missing: " .. c)
			end
		end
		check(not (p.meta and p.meta.styleSheet and (p.meta.styleSheet.minSize or p.meta.styleSheet.maxSize or p.meta.styleSheet.gravity or p.meta.styleSheet.padding)),
			path .. ": makeStyle only knows size; minSize/maxSize/gravity/padding have no effect")
		if n.kind == "ComboBoxItem" then
			check(p.content and COMPONENTS[p.content.kind], path .. ": ComboBoxItem.content must be a component, is " .. tostring(p.content and p.content.kind))
		elseif n.kind == "ComboBox" then
			check(p.items and #p.items > 0, path .. ": ComboBox without entries")
			check(p.meta and type(p.meta.localKey) == "string" and p.meta.localKey:find("combo:" .. tostring(p.value) .. "|", 1, true) == 1,
				path .. ": ComboBox without a localKey for its value (the display would not update after changes)")
			local found = false
			for _i, it in ipairs(p.items or {}) do if it.props.value == p.value then found = true end end
			check(found, path .. ": ComboBox value " .. tostring(p.value) .. " is not an entry (the display would be empty)")
		elseif n.kind == "Component" and p.layout then
			check(LAYOUTS[p.layout.kind], path .. ": Component.layout must be a layout")
		elseif n.kind == "ImageView" then
			check(type(p.path) == "string" and p.path ~= "", path .. ": ImageView without path")
		elseif n.kind == "TextView" then
			check(type(p.text) == "string", path .. ": TextView without text")
			check(not tostring(p.text):find("\n"), path .. ": line break in text: " .. tostring(p.text))
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
			check(s == shape, label .. ": entries built differently:\n  " .. shape .. "\n  " .. s)
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
for i = 2, itemCount(cs[1]) do names[#names + 1] = itemTexts(cs[1].props.items[i])[1] end
print("  old: " .. table.concat(names, " | "))
check(names[1] == "ACF M-300" and names[2] == "ET 420" and names[3] == "Ae 4/7" and names[4] == "BR 50" and names[5] == "BR 103", "sort by name: railcar/multiple unit, then locomotives, BR 50 before BR 103")
for _i, n in ipairs(names) do check(not n:find("Endwagen") and not n:find("Mittelwagen"), "multiple unit part listed on its own: " .. n) end
for _i, n in ipairs(names) do check(not n:find("Benz") and not n:find("Tram"), "train depot shows another vehicle type: " .. n) end
for _i, n in ipairs(names) do check(not n:find("Fake"), "dummy locomotive listed on the left: " .. n) end
-- second line of wagons
local secondLines = {}
for i = 2, itemCount(cs[1]) do secondLines[#secondLines + 1] = itemTexts(cs[1].props.items[i])[2] end
print("  second lines: " .. table.concat(secondLines, " | "))
-- shortened name
local long = find(t, function(n) return n.kind == "TextView" and n.props.text:find("…") end)
check(#long > 0, "long name is not shortened")
check(long[1] and long[1].props.meta.tooltip ~= nil, "shortened name without tooltip")
-- placeholder selected in the new list
check(cs[2].props.value == "none", "new list without selection should show the placeholder")

print("== Train depot: choose a wagon, choose a new model")
cs[1].props.onValueChange("m2")
t = content("wagon chosen")
cs = combos(t)
check(cs[1].props.value == "m2", "old selection does not stay")
local neuNames = {}
for i = 2, itemCount(cs[2]) do neuNames[#neuNames + 1] = itemTexts(cs[2].props.items[i])[1] end
print("  new: " .. table.concat(neuNames, " | "))
for _i, n in ipairs(neuNames) do check(not n:find("BR ") and n ~= "Ae 4/7", "wagon replacement shows a locomotive: " .. n) end
-- cargo filter: passenger cars only for wagons that carry passengers
local function neuList()
	local c = combos(content("cargo filter"))
	local l = {}
	for i = 2, itemCount(c[2]) do l[#l + 1] = (itemTexts(c[2].props.items[i])[1]:gsub("\n.*", "")) end
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

print("== Sort by year")
local sorts = find(t, function(n) return n.kind == "ToggleButton" and n.props.meta.class == "mvr-sort" end)
check(#sorts == 2, "two sort buttons expected")
sorts[2].props.onValueChange(1)
t = content("year")
cs = combos(t)
names = {}
for i = 2, itemCount(cs[1]) do names[#names + 1] = itemTexts(cs[1].props.items[i])[1] end
print("  old: " .. table.concat(names, " | "))
check(names[1] == "ACF M-300" and names[2] == "ET 420" and names[3] == "Ae 4/7" and names[4] == "BR 50" and names[5] == "BR 103", "year: 1924, 1969, then locomotives 1927, 1939, 1970")

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
check(itemTexts(cs[1].props.items[3])[2] == "3 Triebzüge in 2 Zügen", "multiple unit second line: " .. tostring(itemTexts(cs[1].props.items[3])[2]))
local muNeu = {}
for i = 2, itemCount(cs[2]) do muNeu[#muNeu + 1] = itemTexts(cs[2].props.items[i])[1] end
print("  new for ET 420: " .. table.concat(muNeu, " | "))
local secondEt423
for i = 2, itemCount(cs[2]) do if itemTexts(cs[2].props.items[i])[1] == "ET 423" then secondEt423 = itemTexts(cs[2].props.items[i])[2] end end
check(secondEt423 == "$2200000 · 1975 · 4-teilig", "second line ET 423: " .. tostring(secondEt423))
check(table.concat(muNeu, "|") == "ACF M-300|Roter Pfeil|ET 423", "for ET 420 (by year, without locomotive pair): railcars and ET 423, no locomotives, no single parts: " .. table.concat(muNeu, "|"))
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
for i = 2, itemCount(cs[2]) do rcNeu[#rcNeu + 1] = itemTexts(cs[2].props.items[i])[1] end
print("  new for M-300: " .. table.concat(rcNeu, " | "))
check(table.concat(rcNeu, "|") == "Roter Pfeil|ET 420|ET 423", "for M-300 (by year): multiple units and railcars, no locomotives: " .. table.concat(rcNeu, "|"))
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
for i = 2, itemCount(cs[2]) do
	local it = cs[2].props.items[i]
	if itemTexts(it)[1] == "Reihe 1042" then n1042 = n1042 + 1; check(it.props.value == "m41", "wrong 1042 offered: " .. it.props.value) end
end
check(n1042 == 1, "Reihe 1042 should appear exactly once, " .. n1042)
local hasEmd = false
for i = 2, itemCount(cs[2]) do if itemTexts(cs[2].props.items[i])[1] == "EMD F-Serie" then hasEmd = true end end
check(hasEmd, "locomotive pair (multiple unit of locomotives only) missing among the locomotives")
for i = 2, itemCount(cs[2]) do local n = itemTexts(cs[2].props.items[i])[1]; check(not n:find("ET 4"), "multiple unit part offered on its own: " .. n) end

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
for i = 2, itemCount(cs[1]) do byName[itemTexts(cs[1].props.items[i])[1]] = cs[1].props.items[i] end
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
for i = 2, itemCount(cs[2]) do local icx = cargoOf(cs[2].props.items[i]); if #icx > 0 then anyCargo = true end end
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
for i = 2, itemCount(cs[1]) do names[#names + 1] = itemTexts(cs[1].props.items[i])[1] end
print("  old: " .. table.concat(names, " | "))
check(#names == 1 and names[1] == "Benz Dreitonner Kipper", "road depot: only Kipper in the fleet")
check(cs[1].props.value == "m10", "road depot: first entry preselected")
local roadNew = {}
for i = 2, itemCount(cs[2]) do roadNew[#roadNew + 1] = itemTexts(cs[2].props.items[i])[1] end
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

t = chooseKasten("too little money", 487999)
local btnPoor = replaceButton(t)
check(btnPoor.props.meta.enabled == false, "button not disabled without enough money")
check(btnPoor.props.meta.class:find("mvr-no-money", 1, true) ~= nil, "button without mvr-no-money class")
check(btnPoor.props.meta.tooltip == "Nicht genug Geld", "tooltip: " .. tostring(btnPoor.props.meta.tooltip))
check(priceText(t) == "Kaufpreis: $488000", "price line: " .. tostring(priceText(t)))
local function buttonText(btn)
	local tv = find(btn, function(n) return n.kind == "TextView" end)
	return tv[1] and tv[1].props.text
end
check(buttonText(btnPoor) == "Nicht genug Geld", "button text without enough money: " .. tostring(buttonText(btnPoor)))
sent = {}
btnPoor.props.onClick() -- the game ignores clicks on disabled buttons; the click itself checks again anyway
check(#sent == 0, "replaced without enough money: " .. #sent)
check(bankBalance == 487999, "balance changed without a replacement")
t = content("too little money, after click")
check(#find(t, function(n) return n.kind == "TextView" and n.props.text == "Nicht genug Geld" end) == 1, "no message after the refused click")

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
	for i = 2, itemCount(c) do if itemTexts(c.props.items[i])[1] == name then return true end end
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
check(hasText(t, "Ersetzt: 0 von 8, Fehler: 8"), "failure count not shown")
check(replaceButton(t).props.meta.enabled == true, "button stays disabled after failed commands")
commandSucceeds = true

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
check(hasText(t, "Ersetzt: 8 von 8"), "old callbacks mixed into the new batch")
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
check(replaceButton(t).props.meta.enabled == false, "button enabled one short of price minus residual")
sent = {}
replaceButton(t).props.onClick()
check(#sent == 0, "replaced one short of price minus residual: " .. #sent)

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
check(replaceButton(t).props.meta.enabled == false, "partly replaced trains: button enabled one short")
sent = {}
replaceButton(t).props.onClick()
check(#sent == 0, "partly replaced trains replaced one short: " .. #sent)

print("== Kept parts worth more than the vehicle's residual value cost extra, like the game (issue #26)")
residuals, partValues = {}, {}
residuals[102] = 100000
partValue(102, 2, 300000); partValue(102, 3, 300000) -- credits -500000
t = chooseBr103("kept parts worth more", 5000000)
check(hasText(t, "Kosten nach Restwert: $5000000"), "kept parts worth more: cost line")
check(replaceButton(t).props.meta.enabled == true, "kept parts worth more: button disabled with enough money")
t = chooseBr103("kept parts worth more, one short", 4999999)
check(replaceButton(t).props.meta.enabled == false, "kept parts worth more: button enabled below the game's cost")

print("== Part value unreadable: that vehicle counts at the full price (issue #26)")
partlyReplacedValues()
partValueThrows = true
t = chooseBr103("part value unreadable", 4500000)
check(priceText(t) == "Kaufpreis: $4500000", "part value unreadable: price line " .. tostring(priceText(t)))
t = chooseBr103("part value unreadable, one short", 4499999)
check(replaceButton(t).props.meta.enabled == false, "part value unreadable: credited although the kept parts are unknown")
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
check(replaceButton(t).props.meta.enabled == false, "part value nan: train 102 credited anyway")
partlyReplacedValues()
partValue(107, 2, -1); partValue(108, 2, math.huge) -- 107 and 108 count at the full price, 102 credits 400000
t = chooseBr103("part value negative and infinite", 4100000)
check(replaceButton(t).props.meta.enabled == true, "part value negative/infinite: train 102 lost its credit")
t = chooseBr103("part value negative and infinite, one short", 4099999)
check(replaceButton(t).props.meta.enabled == false, "part value negative/infinite: trains 107 or 108 credited anyway")

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
check(replaceButton(t).props.meta.enabled == false, "unknown multiple unit: its parts were not charged")
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
check(replaceButton(t).props.meta.enabled == false, "multiple units: the kept wagon was not charged")
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

print("== Residual value unreadable counts as none (issue #26)")
residualThrows = true
t = chooseKasten("residual unreadable, full price", 488000)
check(replaceButton(t).props.meta.enabled == true, "residual unreadable: button disabled with the full price")
check(priceText(t) == "Kaufpreis: $488000", "residual unreadable: price line " .. tostring(priceText(t)))
t = chooseKasten("residual unreadable, one short", 487999)
check(replaceButton(t).props.meta.enabled == false, "residual unreadable: button enabled below the full price")
residualThrows = false
-- nan, negative and infinite values count as none (review finding: only the error path was tested)
for v = 110, 117 do residuals[v] = 1000 end
residuals[110], residuals[111], residuals[112] = 0 / 0, -1, math.huge
t = chooseKasten("odd residual values", 483000) -- 488000 - 5 x 1000
check(replaceButton(t).props.meta.enabled == true, "odd residual values: button disabled with price minus the valid residual")
check(hasText(t, "Kosten nach Restwert: $483000"), "odd residual values: cost line")
t = chooseKasten("odd residual values, one short", 482999)
check(replaceButton(t).props.meta.enabled == false, "odd residual values: button enabled one short")
residuals = {}
step()
bankBalance = 5000000

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

print(string.format("\n%d checks, %d errors", checks, failures))
os.exit(failures == 0 and 0 or 1)
