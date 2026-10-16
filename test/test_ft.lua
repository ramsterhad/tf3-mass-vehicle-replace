-- Lokaler Test fuer mass_vehicle_replace.script.lua ohne Spiel (Lua 5.2 wie im Spiel).
-- Bildet api, react, builtin usw. nach, baut das Fenster in mehreren Lagen auf und prueft die Regeln,
-- an denen das Spiel bisher abgestuerzt ist oder falsch gezeichnet hat.
-- Aufruf: lua5.2 test_ft.lua <script.lua> <css.lua> <strings_de.lua>

local SCRIPT, CSS, STRINGS = arg[1], arg[2], arg[3]
local failures, checks = 0, 0
local function fail(msg) failures = failures + 1; print("FEHLER: " .. msg) end
local function check(cond, msg) checks = checks + 1; if not cond then fail(msg) end end

-- Uebersetzungen ---------------------------------------------------------------------------------------
local strings = dofile(STRINGS)
function _(key)
	local s = strings[key]
	if s == nil then fail("Uebersetzung fehlt: " .. tostring(key)); return tostring(key) end
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

-- builtin: jeder Aufruf liefert einen Knoten -----------------------------------------------------------
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

local engine_react_util = { useStepState = function(f) local v = f(); return { old = function() return v end } end }
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
	["::/gui/main/styleutil.tl"] = { makeStyle = function(t) return t end },
	["::/gui/main/gui_react_util.tl"] = gui_react_util,
	["::/gui/main/engine_react_util.tl"] = engine_react_util,
	["::/gui/main/game_react_globals.tl"] = game_react_globals,
	["::/gui/entity_window/entity_window_util.tl"] = entity_window_util,
	["::/gui/entity_window/maintenance_station/maintenance_station.tl"] = MaintenanceStationWindow,
}
function ug_require(path)
	local m = modules[path]
	if m == nil then error("ug_require unbekannt: " .. path) end
	return m
end

-- Spielwelt --------------------------------------------------------------------------------------------
local Carrier = { ROAD = 0, RAIL = 1, TRAM = 2, AIR = 3, WATER = 4 }
local CT = { TRANSPORT_VEHICLE = "TV", GAME_TIME = "GT", VEHICLE_DEPOT = "VD" }

local models = {}
local function model(id, name, carrier, engine, yearFrom, yearTo, price, icons, group, noTags)
	models[id] = { metadata = {
		transportVehicle = { carrier = "meta_" .. carrier, compartments = { {} }, -- bewusst andere Form als das Enum
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
model(20, "Tram alt", Carrier.TRAM, true, 1900, 0, 100000)
model(30, "Schiff", Carrier.WATER, true, 1900, 0, 500000)
-- Gruppenkopf ohne Tags (Kaufliste blendet ihn aus, im Spiel ohne Bild) und seine Variante
model(40, "Reihe 1042", Carrier.RAIL, true, 1960, 0, 1300000, false, nil, true)
model(41, "Reihe 1042", Carrier.RAIL, true, 1960, 0, 1300000, nil, "vehicle/40.mdl")
-- Deko-Kopie einer anderen Mod (pileouface_rail_vehicle_assets): gleiche Daten, keine Tags, kein Bild
model(42, "Reihe 1042", Carrier.RAIL, true, 1960, 0, 1300000, false, nil, true)
-- Triebzug ohne Tags waere ebenso nicht kaufbar
-- Triebzugteile
model(50, "ET 420 Endwagen", Carrier.RAIL, true, 1969, 0, 400000)
model(51, "ET 420 Mittelwagen", Carrier.RAIL, true, 1969, 0, 300000)
model(52, "ET 423 Endwagen", Carrier.RAIL, true, 1975, 0, 600000)
model(53, "ET 423 Mittelwagen", Carrier.RAIL, true, 1975, 0, 500000)
model(54, "ET 999 Zukunft", Carrier.RAIL, true, 2050, 0, 900000)
-- Triebwagen: Motor und Fahrgaeste (wie ACF M-300); Loks tragen nur Personal ohne Frachtart (wie im Spiel)
model(60, "ACF M-300", Carrier.RAIL, true, 1924, 0, 1582128)
model(61, "Roter Pfeil", Carrier.RAIL, true, 1935, 0, 1200000)
local function load(id, classes, cap)
	models[id].metadata.transportVehicle.compartments = { { loadConfigs = { { cargoEntry = { capacity = cap,
		cargoTypeSet = { cargoClassesIncluded = classes, cargoTypesIncluded = {}, cargoClassesExcluded = {}, cargoTypesExcluded = {} } } } } } }
end
load(60, { "PASSENGERS" }, 80)
load(61, { "PASSENGERS" }, 60)
load(1, {}, 4) -- Ae 4/7 mit Personal
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
model(55, "EMD F A-Einheit", Carrier.RAIL, true, 1949, 0, 3000000)
load(55, {}, 4)
load(6, { "COAL" }, 40)
-- Lok-Attrappe wie in Mod 6157450: kein Motor, nur Personal ohne Frachtart
model(70, "Fake - BR 246", Carrier.RAIL, false, 2006, 0, 0)
load(70, {}, 4)
local mus = {
	[900] = { name = "ET 420", filterTags = { "default" }, vehicles = { { name = "vehicle/50.mdl", forward = true }, { name = "vehicle/51.mdl", forward = true }, { name = "vehicle/50.mdl", forward = false } } },
	[901] = { name = "ET 423", filterTags = { "default" }, vehicles = { { name = "vehicle/52.mdl", forward = true }, { name = "vehicle/53.mdl", forward = true }, { name = "vehicle/53.mdl", forward = true }, { name = "vehicle/52.mdl", forward = false } } },
	[902] = { name = "ET 999", filterTags = { "default" }, vehicles = { { name = "vehicle/54.mdl", forward = true } } },
	[903] = { name = "EMD F-Serie", filterTags = { "default" }, vehicles = { { name = "vehicle/55.mdl", forward = true }, { name = "vehicle/55.mdl", forward = false } } },
}

local vehicles = {}
-- groups: nil = jedes Teil eine Gruppe; sonst { {Groesse, Dateiname}, ... } wie im Spiel
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
	vehicles[id] = { carrier = carrier, transportVehicleConfig = { vehicles = list, vehicleGroups = sizes, muFileNames = paths } }
end
vehicle(100, { 1, 2, 2, 2, 3 })
vehicle(101, { 1, 2, 2, 6 })
vehicle(102, { 5, 3, 3 })
-- Doppeltraktion ET 420 plus ein loser Wagen 2 dahinter
vehicle(103, { 50, 51, 50, 50, 51, 50, 2 }, { { 3, "multiple_unit/et420.mdl" }, { 3, "multiple_unit/et420.mdl" }, { 1, "" } })
vehicle(104, { 50, 51, 50 }, { { 3, "multiple_unit/et420.mdl" } })
vehicle(105, { 4 })
vehicle(106, { 60 })
vehicle(107, { 5, 7, 8 })
vehicle(108, { 5, 70, 7 }) -- Zug mit Lok-Attrappe
for v = 110, 117 do vehicle(v, { 10 }) end
vehicle(120, { 20 })
local TransportMode = { CAR = 10, BUS = 11, TRUCK = 12, TRAM = 13, ELECTRIC_TRAM = 14, TRAIN = 15, ELECTRIC_TRAIN = 16, SHIP = 17, SMALL_SHIP = 18, AIRCRAFT = 19, SMALL_AIRCRAFT = 20, HELICOPTER = 21, TRAM_TRACK = 22, ELECTRIC_TRAM_TRACK = 23 }
-- wie im Spiel beobachtet: carrier leer, die Art steckt in den Verkehrsarten
local depots = {
	[500] = { transportModes = { [TransportMode.TRAIN] = true, [TransportMode.ELECTRIC_TRAIN] = true } },
	[501] = { transportModes = { [TransportMode.BUS] = true, [TransportMode.TRUCK] = true, [TransportMode.CAR] = false } },
	[502] = { carrier = Carrier.TRAM, transportModes = {} },
	[503] = { transportModes = { [TransportMode.BUS] = true, [TransportMode.TRAM] = true } }, -- gemischt
}

local CARGO = { PASSENGERS = 1, COAL = 2, IRON_ORE = 3, GRAIN = 4, LOGS = 5, OIL = 6, STONE = 7 }
local CARGO_NAMES = { "Fahrgäste", "Kohle", "Eisenerz", "Getreide", "Holz", "Öl", "Stein" }
for k = 8, 20 do CARGO["C" .. k] = k; CARGO_NAMES[k] = "Fracht " .. k end
local sent = {}
local costPerCommand = 560000
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
			-- wie im Spiel: Frachtklassen und einzelne Frachtarten des Sets ergeben die Frachtarten
			forEachCargoType = function(set, cb)
				local seen = {}
				for _i, c in ipairs(set.cargoClassesIncluded or {}) do if CARGO[c] and not seen[CARGO[c]] then seen[CARGO[c]] = true; cb(CARGO[c]) end end
				for _i, c in ipairs(set.cargoTypesIncluded or {}) do if CARGO[c] and not seen[CARGO[c]] then seen[CARGO[c]] = true; cb(CARGO[c]) end end
			end,
			-- Reihenfolge des Spiels absichtlich anders als die Nummern: Oel vor Kohle
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
			getName = function(id) return ({ [900] = "multiple_unit/et420.mdl", [901] = "multiple_unit/et423.mdl", [902] = "multiple_unit/et999.mdl", [903] = "multiple_unit/emd_f.mdl" })[id] end,
		},
	},
	engine = {
		getEntitiesWithComponent = function(ct)
			local t = {}
			if ct == CT.TRANSPORT_VEHICLE then for id in pairs(vehicles) do t[#t + 1] = id end end
			table.sort(t)
			return t
		end,
		getComponent = function(e, ct)
			if ct == CT.TRANSPORT_VEHICLE then return vehicles[e] end
			if ct == CT.GAME_TIME then return { gameTime = 123 } end
			if ct == CT.VEHICLE_DEPOT then return depots[e] end
		end,
		entityExists = function(e) return depots[e] ~= nil or vehicles[e] ~= nil end,
		util = { getYear = function() return 1980 end, getWorld = function() return 0 end, getPlayer = function() return 7 end,
			finance = { getPlayersBalance = function(pl) assert(pl == 7); return bankBalance end },
			vehicle = { getDepreciatedValue = function(v) assert(vehicles[v], "Restwert fuer unbekanntes Fahrzeug"); return 100000 end } },
		system = { transportVehicleSystem = { getDepotVehicles = function(d) return d == 503 and { 120 } or {} end } },
	},
	util = { formatMoney = function(v) return "$" .. tostring(v) end },
	cmd = {
		makeVehicleReplaceCmd = function(e, conf) return { e = e, conf = conf } end,
		-- jeder Tausch bucht hier pro Befehl einen festen Betrag ab; geprueft wird nur die Rechnung im Protokoll
		sendCommand = function(c, cb) sent[#sent + 1] = c; bankBalance = bankBalance - costPerCommand; if cb then cb(nil, true) end end,
	},
}

-- Skript laden ------------------------------------------------------------------------------------------
-- the game's GUI Lua has no rawget (crashed at startup in 1.0.1 testing)
rawget = nil
local chunk = assert(loadfile(SCRIPT))
chunk()
local exports = data()
check(type(exports.doReplace) == "function", "doReplace fehlt in data()")

-- another mod (like Manage Line From Vehicle) replaced the button bar before us and calls the
-- original through the module field
local otherBarCalls = 0
local barRecipe = entity_window_util.ActionButtonBar
_react.recipeReplace.ActionButtonBar = function(ref, p)
	otherBarCalls = otherBarCalls + 1
	return react.CallOriginalRecipe(entity_window_util.ActionButtonBar, ref, p)
end

-- CSS-Klassen einlesen ----------------------------------------------------------------------------------
local cssText = io.open(CSS):read("*a")
local cssClasses = {}
for c in cssText:gmatch("!(ft%-[%w%-]+)") do cssClasses[c] = true end

-- Regeln ------------------------------------------------------------------------------------------------
local COMPONENTS = { Component = true, TextView = true, ImageView = true }

local function walk(node, path, visit)
	if type(node) ~= "table" then return end
	visit(node, path)
	local p = node.props or {}
	if p.children then
		local n = 0
		for k in pairs(p.children) do if type(k) == "number" and k > n then n = k end end
		check(n == #p.children, path .. ": Kinderliste mit Luecke (nil) in " .. node.kind)
		for i = 1, n do walk(p.children[i], path .. "/" .. node.kind .. "[" .. i .. "]", visit) end
	end
	for _k, key in ipairs({ "child", "content", "layout" }) do
		if p[key] then walk(p[key], path .. "/" .. node.kind .. "." .. key, visit) end
	end
	if p.items then for i, it in ipairs(p.items) do walk(it, path .. "/items[" .. i .. "]", visit) end end
end

local function rules(tree, label)
	check(tree and tree.kind == "BoxLayout", label .. ": Rezept muss ein Layout liefern, liefert " .. tostring(tree and tree.kind))
	walk(tree, label, function(n, path)
		local p = n.props or {}
		local cls = p.meta and p.meta.class
		if cls then
			for c in tostring(cls):gmatch("ft%-[%w%-]+") do
				check(cssClasses[c], path .. ": CSS-Klasse fehlt: " .. c)
			end
		end
		check(not (p.meta and p.meta.styleSheet and (p.meta.styleSheet.minSize or p.meta.styleSheet.maxSize or p.meta.styleSheet.gravity or p.meta.styleSheet.padding)),
			path .. ": makeStyle kennt nur size; minSize/maxSize/gravity/padding wirken nicht")
		if n.kind == "ComboBoxItem" then
			check(p.content and COMPONENTS[p.content.kind], path .. ": ComboBoxItem.content muss Komponente sein, ist " .. tostring(p.content and p.content.kind))
		elseif n.kind == "ComboBox" then
			check(p.items and #p.items > 0, path .. ": ComboBox ohne Eintraege")
			check(p.meta and type(p.meta.localKey) == "string" and p.meta.localKey:find("combo:" .. tostring(p.value) .. "|", 1, true) == 1,
				path .. ": ComboBox ohne localKey zu ihrem Wert (Anzeige bliebe nach Aenderungen stehen)")
			local found = false
			for _i, it in ipairs(p.items or {}) do if it.props.value == p.value then found = true end end
			check(found, path .. ": ComboBox-Wert " .. tostring(p.value) .. " ist kein Eintrag (Anzeige waere leer)")
		elseif n.kind == "Component" and p.layout then
			check(LAYOUTS[p.layout.kind], path .. ": Component.layout muss ein Layout sein")
		elseif n.kind == "ImageView" then
			check(type(p.path) == "string" and p.path ~= "", path .. ": ImageView ohne Pfad")
		elseif n.kind == "TextView" then
			check(type(p.text) == "string", path .. ": TextView ohne Text")
			check(not tostring(p.text):find("\n"), path .. ": Zeilenumbruch im Text: " .. tostring(p.text))
		end
	end)
end

-- Hilfen zum Bedienen -----------------------------------------------------------------------------------
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
-- jede Liste hat gleich viele Zeilen und gleich aufgebaute Eintraege (feste Hoehe/Breite)
local function shapeOf(itemNode)
	local s = {}
	-- Bild oder leere Flaeche zaehlen gleich, wenn die Klasse gleich ist
	walk(itemNode, "", function(n)
		local cls = n.props.meta and n.props.meta.class
		local kind = (cls == "ft-item-image") and "Bild" or (tostring(cls):find("ft%-cargo%-icon") and "Fracht") or n.kind
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
			check(s == shape, label .. ": Eintraege unterschiedlich aufgebaut:\n  " .. shape .. "\n  " .. s)
		end
	end
end

local lastWindow
local function openAndRender(label, carrier, locked)
	-- vorheriges Fenster schliessen wie der Nutzer (X)
	if lastWindow then lastWindow.params.onClose() end
	windows = {}
	-- wie die Knoepfe: oeffnen ueber die Fenster-API
	local opened
	if locked then
		-- Depotknopf ueber die Knopfleiste
		exports.doReplace(replacementApi)
		local bar = entity_window_util.ActionButtonBar(nil, { primaryButtons = { { tag = "entityWindow.maintenanceStation.manageVehicle" } }, secondaryButtons = {} })
		check(#bar.props.secondaryButtons == 1, label .. ": Depotknopf fehlt in der Knopfleiste")
		render("FtMaintenanceStationWindow", { keyEntity = carrier })
		local bar2 = entity_window_util.ActionButtonBar(nil, { primaryButtons = { { tag = "entityWindow.maintenanceStation.manageVehicle" } }, secondaryButtons = {} })
		bar2.props.secondaryButtons[1].customItem.props.onClick()
		opened = true
	else
		-- Kopfleiste der Fahrzeugverwaltung bleibt wie im Spiel (Knopf dort ausgebaut)
		exports.doReplace(replacementApi)
		currentRecipe = "LineVehicleManagerTopBar"
		local sp = gui_react_util.makeHorizontalSpacer()
		currentRecipe = nil
		check(sp.kind == "Spacer", label .. ": Kopfleiste der Verwaltung wurde veraendert")
		-- Depot ohne Daten: keine Vorauswahl, alle Arten
		render("FtMaintenanceStationWindow", { keyEntity = 999 })
		local bar = entity_window_util.ActionButtonBar(nil, { primaryButtons = { { tag = "entityWindow.maintenanceStation.manageVehicle" } }, secondaryButtons = {} })
		bar.props.secondaryButtons[1].customItem.props.onClick()
		opened = true
	end
	local w = windows["mass_vehicle_replace.window"]
	check(opened and w, label .. ": Fenster nicht geoeffnet")
	lastWindow = w
	local win = render("FtWindow", w.params)
	check(win.kind == "Window", label .. ": FtWindow liefert kein Window")
	return w
end

local function content(label)
	local t = render("FtContent", { onClose = function() end })
	rules(t, label)
	sameShapes(t, label)
	return t
end

-- Lagen -------------------------------------------------------------------------------------------------
print("== Zugdepot")
openAndRender("Zugdepot", 500, true)
local t = content("Zugdepot")
local on = find(t, function(n) return n.kind == "ToggleButton" and n.props.meta.class == "ft-filter" and n.props.value == 1 end)
check(#on == 1 and on[1].props.meta.tooltip == "Schiene: Loks und Wagen", "Zugdepot: Schiene nicht vorausgewaehlt")
local cs = combos(t)
check(#cs == 2, "zwei Listen erwartet, gefunden " .. #cs)
-- alte Modelle: nur Schiene, Antrieb zuerst, dann Wagen; natuerlich sortiert (BR 50 vor BR 103)
local names = {}
for i = 2, itemCount(cs[1]) do names[#names + 1] = itemTexts(cs[1].props.items[i])[1] end
print("  alt: " .. table.concat(names, " | "))
check(names[1] == "ACF M-300" and names[2] == "ET 420" and names[3] == "Ae 4/7" and names[4] == "BR 50" and names[5] == "BR 103", "Sortierung Name: Triebwagen/Triebzug, dann Loks, BR 50 vor BR 103")
for _i, n in ipairs(names) do check(not n:find("Endwagen") and not n:find("Mittelwagen"), "Triebzugteil einzeln gelistet: " .. n) end
for _i, n in ipairs(names) do check(not n:find("Benz") and not n:find("Tram"), "Zugdepot zeigt fremde Art: " .. n) end
for _i, n in ipairs(names) do check(not n:find("Fake"), "Lok-Attrappe links gelistet: " .. n) end
-- zweite Zeile Wagen
local secondLines = {}
for i = 2, itemCount(cs[1]) do secondLines[#secondLines + 1] = itemTexts(cs[1].props.items[i])[2] end
print("  zweite Zeilen: " .. table.concat(secondLines, " | "))
-- gekuerzter Name
local long = find(t, function(n) return n.kind == "TextView" and n.props.text:find("…") end)
check(#long > 0, "langer Name wird nicht gekuerzt")
check(long[1] and long[1].props.meta.tooltip ~= nil, "gekuerzter Name ohne Tooltip")
-- Platzhalter in der neuen Liste ausgewaehlt
check(cs[2].props.value == "none", "neue Liste ohne Auswahl soll Platzhalter zeigen")

print("== Zugdepot: Wagen waehlen, neues Modell waehlen")
cs[1].props.onValueChange("m2")
t = content("Wagen gewaehlt")
cs = combos(t)
check(cs[1].props.value == "m2", "Auswahl alt bleibt nicht")
local neuNames = {}
for i = 2, itemCount(cs[2]) do neuNames[#neuNames + 1] = itemTexts(cs[2].props.items[i])[1] end
print("  neu: " .. table.concat(neuNames, " | "))
for _i, n in ipairs(neuNames) do check(not n:find("BR ") and n ~= "Ae 4/7", "Wagen-Ersatz zeigt Lok: " .. n) end
-- Frachtfilter: Personenwagen nur gegen Wagen, die Fahrgaeste laden
local function neuList()
	local c = combos(content("Frachtfilter"))
	local l = {}
	for i = 2, itemCount(c[2]) do l[#l + 1] = (itemTexts(c[2].props.items[i])[1]:gsub("\n.*", "")) end
	return table.concat(l, " | "), c
end
local nl = neuList()
check(nl:find("Bm 235") and not nl:find("Universalwagen") and not nl:find("Sammelwagen") and not nl:find("Überlänge"), "Frachtfilter Personenwagen: " .. nl)
cs[1].props.onValueChange("m7")
nl = neuList()
print("  neu fuer Universalwagen: " .. nl)
check(nl == "Sammelwagen", "Universalwagen: nur Sammelwagen kann alles laden: " .. nl)
cs[1].props.onValueChange("m8")
nl = neuList()
print("  neu fuer Sammelwagen: " .. nl)
check(not nl:find("Universalwagen") and not nl:find("Avmz"), "Sammelwagen: kein Wagen mit weniger Fracht: " .. nl)
cs[1].props.onValueChange("m2")
-- Schalter "Gleiche Fracht": aus zeigt alle Wagen, an wieder nur passende
local function cargoToggle()
	local tg = find(content("Schalter"), function(n) return n.kind == "ToggleButton" and n.props.meta and n.props.meta.class == "ft-cargo-filter" end)
	check(#tg == 1, "Schalter Gleiche Fracht fehlt")
	return tg[1]
end
check(cargoToggle().props.value == 1, "Schalter Gleiche Fracht soll anfangs an sein")
cargoToggle().props.onValueChange(0)
nl = neuList()
print("  neu fuer Avmz ohne Frachtfilter: " .. nl)
check(cargoToggle().props.value == 0, "Schalter bleibt nicht aus")
check(nl:find("Universalwagen") and nl:find("Sammelwagen") and nl:find("Bm 235"), "ohne Frachtfilter fehlen Wagen: " .. nl)
check(not nl:find("Fake"), "ohne Frachtfilter erscheint Lok-Attrappe bei Personenwagen: " .. nl)
cargoToggle().props.onValueChange(1)
nl = neuList()
check(not nl:find("Universalwagen"), "Frachtfilter wieder an wirkt nicht: " .. nl)
nl, cs = neuList()
cs[2].props.onValueChange("m3")
t = content("neu gewaehlt")
local big = find(t, function(n) return n.kind == "ImageView" and n.props.meta and n.props.meta.class == "ft-big-image" end)
check(#big == 2, "zwei grosse Bilder erwartet, " .. #big)
local summary = find(t, function(n) return n.kind == "TextView" and n.props.text:find("ersetzt") end)
check(#summary == 1, "Zusammenfassung fehlt")
print("  " .. (summary[1] and summary[1].props.text or "?"))
-- Wagen 2: 6 Stueck in 3 Zuegen (einer haengt hinter dem Triebzug); neues Modell 3 kostet 280000
local price = find(t, function(n) return n.kind == "TextView" and n.props.text:find("Kaufpreis") end)
check(price[1] and price[1].props.text == "Kaufpreis: $1680000", "Kaufpreis falsch: " .. tostring(price[1] and price[1].props.text))
check(summary[1] and summary[1].props.text == "3 Fahrzeuge werden ersetzt.", "Anzahl falsch")
-- Platzhalter darf nichts ausloesen
cs = combos(t)
cs[2].props.onValueChange("none")
t = content("Platzhalter geklickt")
check(combos(t)[2].props.value == "m3", "Platzhalter hat Auswahl geloescht")

print("== Sortierung nach Jahr")
local sorts = find(t, function(n) return n.kind == "ToggleButton" and n.props.meta.class == "ft-sort" end)
check(#sorts == 2, "zwei Sortierknoepfe erwartet")
sorts[2].props.onValueChange(1)
t = content("Jahr")
cs = combos(t)
names = {}
for i = 2, itemCount(cs[1]) do names[#names + 1] = itemTexts(cs[1].props.items[i])[1] end
print("  alt: " .. table.concat(names, " | "))
check(names[1] == "ACF M-300" and names[2] == "ET 420" and names[3] == "Ae 4/7" and names[4] == "BR 50" and names[5] == "BR 103", "Jahr: 1924, 1969, dann Loks 1927, 1939, 1970")

print("== Ersetzen")
sent = {}
local btn = find(t, function(n) return n.kind == "Button" and n.props.meta.class:find("ft%-replace%-btn") end)[1]
btn.props.onClick()
print("  Befehle: " .. #sent)
check(#sent == 3, "Wagen 2 steckt in 3 Fahrzeugen, Befehle: " .. #sent)
for _i, c in ipairs(sent) do
	if c.e == 103 then
		-- Triebzuege bleiben, nur der lose Wagen wird getauscht
		local ids = {}
		for _j, part in ipairs(c.conf.vehicles) do ids[#ids + 1] = part.part.modelId end
		check(table.concat(ids, ",") == "50,51,50,50,51,50,3", "Zug 103 falsch: " .. table.concat(ids, ","))
		check(table.concat(c.conf.vehicleGroups, ",") == "3,3,1", "Gruppen 103 falsch")
	end
end
for _i, c in ipairs(sent) do
	for _j, part in ipairs(c.conf.vehicles) do check(part.part.modelId ~= 2, "altes Modell nicht ersetzt in " .. c.e) end
end
-- Ergebnis erscheint unten links, sobald das Fenster neu gezeichnet wird (neues Modell ist dann weg)
sel_reset = true
t = content("nach Ersetzen")
local res = find(t, function(n) return n.kind == "TextView" and n.props.text:find("Ersetzt:") end)
print("  " .. tostring(res[1] and res[1].props.text))
check(#res == 1, "Ergebnis des Ersetzens wird nicht angezeigt")
local ic = find(t, function(n) return n.kind == "ImageView" and n.props.meta and n.props.meta.class == "ft-btn-icon" end)
check(#ic == 1, "Symbol im Ersetzen-Knopf fehlt")

print("== Triebzug als Ganzes tauschen")
openAndRender("Zugdepot 2", 500, true)
t = content("Zugdepot 2")
cs = combos(t)
check(cs[1].props.value == "m60", "Triebwagen steht nicht oben: " .. tostring(cs[1].props.value))
cs[1].props.onValueChange("u900")
t = content("ET 420 gewaehlt")
cs = combos(t)
check(itemTexts(cs[1].props.items[3])[2] == "3 Triebzüge in 2 Zügen", "Triebzug zweite Zeile: " .. tostring(itemTexts(cs[1].props.items[3])[2]))
local muNeu = {}
for i = 2, itemCount(cs[2]) do muNeu[#muNeu + 1] = itemTexts(cs[2].props.items[i])[1] end
print("  neu fuer ET 420: " .. table.concat(muNeu, " | "))
local secondEt423
for i = 2, itemCount(cs[2]) do if itemTexts(cs[2].props.items[i])[1] == "ET 423" then secondEt423 = itemTexts(cs[2].props.items[i])[2] end end
check(secondEt423 == "$2200000 · 1975 · 4-teilig", "zweite Zeile ET 423: " .. tostring(secondEt423))
check(table.concat(muNeu, "|") == "ACF M-300|Roter Pfeil|ET 423", "fuer ET 420 (nach Jahr, ohne Lok-Paar): Triebwagen und ET 423, keine Loks, keine Einzelteile: " .. table.concat(muNeu, "|"))
cs[2].props.onValueChange("u901")
t = content("ET 423 gewaehlt")
price = find(t, function(n) return n.kind == "TextView" and n.props.text:find("Kaufpreis") end)
check(price[1] and price[1].props.text == "Kaufpreis: $6600000", "Triebzug-Preis (3 x 2200000): " .. tostring(price[1] and price[1].props.text))
summary = find(t, function(n) return n.kind == "TextView" and n.props.text:find("ersetzt") end)
check(summary[1] and summary[1].props.text == "2 Fahrzeuge werden ersetzt.", "Triebzug-Anzahl: " .. tostring(summary[1] and summary[1].props.text))
sent = {}
costPerCommand = 3300000
bankBalance = 10000000
find(t, function(n) return n.kind == "Button" and n.props.meta.class:find("ft%-replace%-btn") end)[1].props.onClick()
check(#sent == 2, "Triebzug: 2 Befehle erwartet, " .. #sent)
for _i, c in ipairs(sent) do
	local ids, rev = {}, {}
	for _j, part in ipairs(c.conf.vehicles) do ids[#ids + 1] = part.part.modelId; rev[#rev + 1] = tostring(part.part.reversed) end
	if c.e == 103 then
		check(table.concat(ids, ",") == "52,53,53,52,52,53,53,52,2", "Zug 103 nach Triebzugtausch: " .. table.concat(ids, ","))
		check(table.concat(c.conf.vehicleGroups, ",") == "4,4,1", "Gruppen 103: " .. table.concat(c.conf.vehicleGroups, ","))
		check(table.concat(c.conf.muFileNames, ",") == "multiple_unit/et423.mdl,multiple_unit/et423.mdl,", "Dateinamen 103: " .. table.concat(c.conf.muFileNames, ","))
		check(rev[4] == "true" and rev[1] == "false", "Richtung der Endwagen falsch")
		check(c.conf.vehicles[1].part.color == "farbe103", "Lackierung nicht uebernommen")
	elseif c.e == 104 then
		check(table.concat(ids, ",") == "52,53,53,52", "Zug 104 nach Triebzugtausch: " .. table.concat(ids, ","))
	else
		fail("Triebzugtausch trifft fremden Zug " .. tostring(c.e))
	end
end

print("== Triebwagen gegen Triebzug")
openAndRender("Zugdepot 4", 500, true)
t = content("Zugdepot 4")
cs = combos(t)
check(cs[1].props.value == "m60", "M-300 nicht vorgewaehlt")
local rcNeu = {}
for i = 2, itemCount(cs[2]) do rcNeu[#rcNeu + 1] = itemTexts(cs[2].props.items[i])[1] end
print("  neu fuer M-300: " .. table.concat(rcNeu, " | "))
check(table.concat(rcNeu, "|") == "Roter Pfeil|ET 420|ET 423", "fuer M-300 (nach Jahr): Triebzuege und Triebwagen, keine Loks: " .. table.concat(rcNeu, "|"))
cs[2].props.onValueChange("u901")
t = content("M-300 gegen ET 423")
sent = {}
costPerCommand = 2200000
bankBalance = 10000000
find(t, function(n) return n.kind == "Button" and n.props.meta.class:find("ft%-replace%-btn") end)[1].props.onClick()
check(#sent == 1 and sent[1].e == 106, "M-300: ein Befehl fuer Zug 106 erwartet")
if sent[1] then
	local ids = {}
	for _j, part in ipairs(sent[1].conf.vehicles) do ids[#ids + 1] = part.part.modelId end
	check(table.concat(ids, ",") == "52,53,53,52", "Zug 106: " .. table.concat(ids, ","))
	check(table.concat(sent[1].conf.vehicleGroups, ",") == "4", "Gruppen 106")
	check(table.concat(sent[1].conf.muFileNames, ",") == "multiple_unit/et423.mdl", "Dateiname 106")
end
print("== Triebzug gegen Triebwagen")
openAndRender("Zugdepot 5", 500, true)
t = content("Zugdepot 5")
cs = combos(t)
cs[1].props.onValueChange("u900")
t = content("ET 420")
cs = combos(t)
cs[2].props.onValueChange("m61")
t = content("ET 420 gegen Roter Pfeil")
sent = {}
find(t, function(n) return n.kind == "Button" and n.props.meta.class:find("ft%-replace%-btn") end)[1].props.onClick()
check(#sent == 2, "ET 420 gegen Roter Pfeil: 2 Befehle")
for _i, c in ipairs(sent) do
	local ids = {}
	for _j, part in ipairs(c.conf.vehicles) do ids[#ids + 1] = part.part.modelId end
	if c.e == 103 then
		check(table.concat(ids, ",") == "61,61,2", "Zug 103: " .. table.concat(ids, ","))
		check(table.concat(c.conf.vehicleGroups, ",") == "1,1,1", "Gruppen 103: " .. table.concat(c.conf.vehicleGroups, ","))
		check(table.concat(c.conf.muFileNames, ",") == ",,", "Dateinamen 103 leer erwartet")
	elseif c.e == 104 then
		check(table.concat(ids, ",") == "61", "Zug 104: " .. table.concat(ids, ","))
	end
end

print("== Gruppenkopf ohne Bild nicht anbieten")
openAndRender("Zugdepot 3", 500, true)
t = content("Zugdepot 3")
cs = combos(t)
cs[1].props.onValueChange("m1")
t = content("Ae 4/7")
cs = combos(t)
local n1042 = 0
for i = 2, itemCount(cs[2]) do
	local it = cs[2].props.items[i]
	if itemTexts(it)[1] == "Reihe 1042" then n1042 = n1042 + 1; check(it.props.value == "m41", "falsche 1042 angeboten: " .. it.props.value) end
end
check(n1042 == 1, "Reihe 1042 soll genau einmal erscheinen, " .. n1042)
local hasEmd = false
for i = 2, itemCount(cs[2]) do if itemTexts(cs[2].props.items[i])[1] == "EMD F-Serie" then hasEmd = true end end
check(hasEmd, "Lok-Paar (Triebzug nur aus Loks) fehlt bei den Loks")
for i = 2, itemCount(cs[2]) do local n = itemTexts(cs[2].props.items[i])[1]; check(not n:find("ET 4"), "Triebzugteil einzeln angeboten: " .. n) end

print("== Frachtsymbole")
openAndRender("Zugdepot 6", 500, true)
t = content("Zugdepot 6")
cs = combos(t)
local function cargoOf(itemNode)
	local icons, more, tip = {}, nil, nil
	walk(itemNode, "", function(n)
		local cls = n.props.meta and tostring(n.props.meta.class) or ""
		if cls:find("ft%-cargo%-icon") and n.kind == "ImageView" then icons[#icons + 1] = n.props.path end
		if cls:find("ft%-cargo%-icon") and n.kind == "TextView" then more = n.props.text end
		if cls == "ft-cargo" then tip = n.props.meta.tooltip end
	end)
	return icons, more, tip
end
local byName = {}
for i = 2, itemCount(cs[1]) do byName[itemTexts(cs[1].props.items[i])[1]] = cs[1].props.items[i] end
local ic, more, tip = cargoOf(byName["ACF M-300"])
check(#ic == 1 and ic[1] == "cargo/1.tga" and more == nil and tip == "Fahrgäste", "M-300: ein Fahrgastsymbol erwartet: " .. table.concat(ic, ",") .. " " .. tostring(tip))
ic, more, tip = cargoOf(byName["Ae 4/7"])
check(#ic == 0 and more == nil and tip == nil, "Lok ohne Frachtsymbol erwartet")
ic, more, tip = cargoOf(byName["Universalwagen"])
print("  Universalwagen: " .. table.concat(ic, ",") .. " " .. tostring(more) .. " | " .. tostring(tip))
check(#ic == 6 and ic[1] == "cargo/6.tga" and ic[2] == "cargo/2.tga" and more == nil, "Universalwagen: alle 6 Symbole (Oel zuerst) erwartet")
local ic8, more8, tip8 = cargoOf(byName["Sammelwagen"])
print("  Sammelwagen: " .. #ic8 .. " Symbole, " .. tostring(more8))
check(#ic8 == 15 and more8 == "+4", "Sammelwagen: 15 Symbole und +4 erwartet")
check(select(2, tip8:gsub(",", ",")) == 18, "Sammelwagen: alle 19 Frachten im Tooltip")
check(tip == "Öl, Kohle, Eisenerz, Getreide, Holz, Stein", "Universalwagen Tooltip: " .. tostring(tip))
ic, more, tip = cargoOf(byName["ET 420"])
check(#ic == 1 and tip == "Fahrgäste", "Triebzug: Frachten aus seinen Teilen erwartet: " .. tostring(tip))
-- rechte Liste zeigt ebenfalls Frachten
cs[1].props.onValueChange("m2")
t = content("Wagen 2 fuer Frachten")
cs = combos(t)
local anyCargo = false
for i = 2, itemCount(cs[2]) do local icx = cargoOf(cs[2].props.items[i]); if #icx > 0 then anyCargo = true end end
check(anyCargo, "rechte Liste ohne Frachtsymbole")

print("== Frachtarten werden nur einmal nachgeschlagen")
local getsBefore = CARGO_GETS or 0
content("erneut zeichnen 1"); content("erneut zeichnen 2")
check((CARGO_GETS or 0) == getsBefore, "Frachtarten werden bei jedem Zeichnen neu abgefragt: " .. ((CARGO_GETS or 0) - getsBefore))

print("== Liste wird nach dem Ersetzen frisch aufgebaut")
openAndRender("Zugdepot 7", 500, true)
t = content("vor Tausch")
local keyBefore = combos(t)[1].props.meta.localKey
-- wie nach einem Tausch: Zug 106 faehrt nun mit Roter Pfeil statt M-300
local saved = vehicles[106]
vehicle(106, { 61 })
t = content("nach Tausch")
local keyAfter = combos(t)[1].props.meta.localKey
check(keyBefore ~= keyAfter, "localKey der linken Liste aendert sich nach dem Tausch nicht")
check(combos(t)[1].props.value == "m61", "nach dem Tausch steht oben der Rote Pfeil: " .. tostring(combos(t)[1].props.value))
vehicles[106] = saved

print("== Strassendepot")
openAndRender("Strassendepot", 501, true)
t = content("Strassendepot")
on = find(t, function(n) return n.kind == "ToggleButton" and n.props.meta.class == "ft-filter" and n.props.value == 1 end)
check(#on == 1 and on[1].props.meta.tooltip == "Straße: Busse und Lkw", "Strassendepot: Strasse nicht vorausgewaehlt")
cs = combos(t)
names = {}
for i = 2, itemCount(cs[1]) do names[#names + 1] = itemTexts(cs[1].props.items[i])[1] end
print("  alt: " .. table.concat(names, " | "))
check(#names == 1 and names[1] == "Benz Dreitonner Kipper", "Strassendepot: nur Kipper im Bestand")
check(cs[1].props.value == "m10", "Strassendepot: erster Eintrag vorgewaehlt")
local roadNew = {}
for i = 2, itemCount(cs[2]) do roadNew[#roadNew + 1] = itemTexts(cs[2].props.items[i])[1] end
print("  neu: " .. table.concat(roadNew, " | "))
local pos9, posLong
for i, n in ipairs(roadNew) do
	if n == "Lkw 9" then pos9 = i elseif n:find("Lkw 1234", 1, true) then posLong = i end
end
check(pos9 and posLong and pos9 < posLong, "long digit run sorts by value, Lkw 9 first: " .. table.concat(roadNew, "|"))

print("== Strassenbahndepot (carrier gesetzt) und gemischtes Depot")
local function preselected(depot, label, tooltip)
	openAndRender(label, depot, true)
	local tt = content(label)
	local hit = find(tt, function(n) return n.kind == "ToggleButton" and n.props.meta.class == "ft-filter" and n.props.value == 1 end)
	check(#hit == 1 and hit[1].props.meta.tooltip == tooltip, label .. ": falsche Vorauswahl " .. tostring(hit[1] and hit[1].props.meta.tooltip))
end
preselected(502, "Strassenbahndepot", "Straßenbahnen")
-- gemischt: Verkehrsarten uneindeutig, Fahrzeug 120 im Depot ist eine Strassenbahn
preselected(503, "gemischtes Depot", "Straßenbahnen")

print("== Depot ohne Daten, dann Schiffe ohne Bestand")
openAndRender("Depot ohne Daten", nil, false)
t = content("Verwaltung alle")
local filters = find(t, function(n) return n.kind == "ToggleButton" and n.props.meta.class == "ft-filter" end)
check(#filters == 5, "fuenf Fahrzeugarten erwartet")
filters[4].props.onValueChange(1)
t = content("Schiffe")
cs = combos(t)
check(itemCount(cs[1]) == 1 and cs[1].props.value == "none", "ohne Schiffe: nur Platzhalter")
check(itemCount(cs[2]) == 1, "ohne altes Modell: neue Liste nur Platzhalter")

print("== Andere Fenster bleiben unveraendert")
local plain = entity_window_util.ActionButtonBar(nil, { primaryButtons = { { tag = "x" } }, secondaryButtons = {} })
check(#plain.props.secondaryButtons == 0, "Knopf taucht in fremdem Fenster auf")

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
for _i, b in ipairs({ 1e19, math.huge, 0 / 0 }) do
	local label = "balance " .. tostring(b)
	openAndRender(label, 501, true)
	t = content(label)
	combos(t)[2].props.onValueChange("m11")
	t = content(label .. " Kasten")
	sent = {}
	costPerCommand = 61000
	bankBalance = b
	local okClick, errClick = pcall(function()
		find(t, function(n) return n.kind == "Button" and n.props.meta.class:find("ft%-replace%-btn") end)[1].props.onClick()
	end)
	check(okClick, label .. ": replacing fails: " .. tostring(errClick))
	check(#sent == 8, label .. ": 8 commands expected, " .. #sent)
end
bankBalance = 5000000

print(string.format("\n%d Pruefungen, %d Fehler", checks, failures))
os.exit(failures == 0 and 0 or 1)
