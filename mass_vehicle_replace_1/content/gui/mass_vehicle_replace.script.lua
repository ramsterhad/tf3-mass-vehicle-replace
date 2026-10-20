-- Mass Vehicle Replace: replaces all vehicle parts of one model with another model, on all lines and in the depot.
-- "Replace Vehicles" button in the depot window, window with two selection lists. The swap uses makeVehicleReplaceCmd like
-- the game's replace dialog (gui/line_vehicle_mgmt/vehicle_util.tl makePart, vehicle_react_util.tl).
-- Loop variables without `_`, that is the translation function here.
local react = ug_require "::/gui/main/react.lua"
local builtin = ug_require "::/gui/main/builtin.lua"
local gui_react_util = ug_require "::/gui/main/gui_react_util.tl"
local engine_react_util = ug_require "::/gui/main/engine_react_util.tl"
local okGlobals, game_react_globals = pcall(ug_require, "::/gui/main/game_react_globals.tl")
-- vehicle stats (#16): the purchase window's own data collection and the game's collapsible card. Missing: no details.
local okStore, vehicle_store_util = pcall(ug_require, "::/gui/line_vehicle_mgmt/vehicle_store_util.tl")
local okCard, content_card = pcall(ug_require, "::/gui/main/content_card.tl")
-- replacement queue: text buttons, the inner panel of the game's windows and its confirmation dialog
local function optional(path)
	local ok, m = pcall(ug_require, path)
	return ok and type(m) == "table" and m or nil
end
local button_react_util = optional("::/gui/main/button_react_util.tl")
local entity_window_util = optional("::/gui/entity_window/entity_window_util.tl")
local dialog_react_util = optional("::/gui/menu/dialog_react_util.tl")

local WINDOW_KEY = "mass_vehicle_replace.window"
local CT = api.type.ComponentType

local function log(...)
	debugPrint("[MassVehicleReplace]", ...)
end

-- Model data -------------------------------------------------------------------------------------
-- Two kinds of entries, both with the key key:
--   "m<id>": single model (locomotive, wagon, bus, ship ...), id from modelRep
--   "u<id>": multiple unit as a whole, id from multipleUnitRep; in a train it is a group with its file name
--            (TransportVehicleConfig.vehicleGroups and muFileNames, like in the game's purchase window)

local catalog -- key -> Info
local muByPath -- file name of the multiple unit -> Info
-- carrier here is the value from the model data. It is only compared with other model data; whether it
-- has the same form as the vehicle type of depot and vehicle (api.type.enum.Carrier) is not certain.

-- Does the model carry passengers or cargo? Locomotives also have a load (4, crew), but without a cargo type;
-- railcars name a cargo class (e.g. PASSENGERS). Only a load with a cargo type counts.
local function carriesLoad(tv)
	local ok, res = pcall(function()
		for __, c in ipairs(tv.compartments) do
			for __, lc in ipairs(c.loadConfigs) do
				local e = lc.cargoEntry
				local set = e and e.cargoTypeSet
				if e and e.capacity > 0 and set and (#set.cargoClassesIncluded > 0 or #set.cargoTypesIncluded > 0) then return true end
			end
		end
		return false
	end)
	return ok and res or false
end

-- Cargo types the model can load, like in the purchase window (vehicle_store_util): for each load with capacity
-- all cargo types of its cargoTypeSet; sorted by the game's order
-- Look up a cargo type once and remember it (icon, name, order); otherwise the list asks again on every
-- redraw for each entry and slot. false: unknown cargo type
local cargoCache = {}
local function cargoType(id)
	local c = cargoCache[id]
	if c == nil then
		local ok, ct = pcall(api.res.cargoTypeRep.get, id)
		c = ok and ct and { icon = ct.icon, name = ct.name, order = ct.order or 0 } or false
		cargoCache[id] = c
	end
	return c
end

local function cargoOrder(id)
	local c = cargoType(id)
	return c and c.order or 0
end

local function sortCargos(list)
	table.sort(list, function(a, b)
		local oa, ob = cargoOrder(a), cargoOrder(b)
		if oa ~= ob then return oa < ob end
		return a < b
	end)
	return list
end

local function cargoList(tv)
	local seen, list = {}, {}
	pcall(function()
		for __, c in ipairs(tv.compartments) do
			for __, lc in ipairs(c.loadConfigs) do
				local e = lc.cargoEntry
				if e and e.capacity > 0 then
					api.res.cargoTypeRep.forEachCargoType(e.cargoTypeSet, function(id)
						if not seen[id] then seen[id] = true; list[#list + 1] = id end
					end)
				end
			end
		end
	end)
	return sortCargos(list)
end

-- Class for the swap: locomotives only for locomotives, wagons only for wagons; railcars (engine and load, e.g.
-- ACF M-300, Roter Pfeil, also buses) and multiple units among each other. Without engine and without cargo: dummies,
-- such as the "Fake" locomotives of some mods (engines empty, only crew without cargo type); the window shows them nowhere
local function classOf(engine, load)
	if not engine then return load and "wagon" or "dummy" end
	return load and "self" or "loco"
end

-- Engine types in the game's order (vehicle_store_window.tl:4718-4724 makeEngineKey); keys of VehicleEngineType
-- (api/tealdef/api/type.d.tl:1892) with the text shown for them
local ENGINE_TYPES = {
	{ key = "HORSE", label = "mvr_engine_horse" },
	{ key = "STEAM", label = "mvr_engine_steam" },
	{ key = "DIESEL", label = "mvr_engine_diesel" },
	{ key = "ELECTRIC", label = "mvr_engine_electric" },
}
for __, et in ipairs(ENGINE_TYPES) do
	local ok, v = pcall(function() return api.type["enum"].VehicleEngineType[et.key] end)
	if ok then et.value = v end
end

-- Engine types of a land vehicle as a set of ENGINE_TYPES keys, like the purchase window collects them
-- (vehicle_store_util.tl:333-337: every engine of landVehicle.engines with its type)
local function engineTypesOf(land)
	local set = {}
	pcall(function()
		for __, e in ipairs(land.engines) do
			for __, et in ipairs(ENGINE_TYPES) do
				if et.value ~= nil and e.type == et.value then set[et.key] = true end
			end
		end
	end)
	return set
end

local function modelInfo(id)
	local m = api.res.modelRep.get(id)
	local md = m and m.metadata
	local tv = md and md["transportVehicle"]
	if not tv then return nil end
	local desc = md["description"]
	local land = md["landVehicle"]
	local av = md["availability"]
	local cost = md["cost"]
	local name = desc and desc.name
	local path = tostring(api.res.modelRep.getName(id))
	if not name or name == "" then name = path:match("([^/]+)%.mdl$") or tostring(id) end
	-- locomotives, buses, railcars have an engine, wagons do not; ships and aircraft count as having an engine
	local engine = (not land) or #land.engines > 0
	local load = carriesLoad(tv)
	return {
		key = "m" .. id,
		id = id,
		path = path,
		load = load,
		cargos = cargoList(tv),
		class = classOf(engine, load),
		-- like the purchase list (vehicle_store_util.depotMatchesVehicleFilterTags): without filterTags not for sale.
		-- This also covers the game's pure variant group heads (vehicle_store_window.tl:4814 variantGroupOnly:
		-- has variants and no filterTags).
		noTags = #(tv.filterTags or {}) == 0,
		name = name,
		carrier = tv.carrier,
		engine = engine,
		engineTypes = land and engineTypesOf(land) or {},
		yearFrom = av and av.yearFrom or 0,
		yearTo = av and av.yearTo or 0,
		price = cost and cost.price or 0,
		compartments = #tv.compartments,
		-- side views: small at list height (icon20), large like in the purchase list (iconSmall)
		icon = desc and ((desc.icon20 ~= nil and desc.icon20 ~= "") and desc.icon20 or desc.iconSmall) or nil,
		iconBig = desc and ((desc.iconSmall ~= nil and desc.iconSmall ~= "") and desc.iconSmall or desc.icon20) or nil,
	}
end

-- Multiple unit like vehicle_store_util.makeVehicleData: price is the sum of the parts, image and vehicle type from the first part.
-- Years exactly like the game (vehicle_store_util.tl:160-161, 315-320): start at -1 / 5000, max yearFrom and
-- min yearTo over the parts, skipping only -1. A part without an end year (0) makes the whole unit unlimited.
local function muInfo(id)
	local mu = api.res.multipleUnitRep.get(id)
	if not mu or #mu.vehicles == 0 then return nil end
	local parts, price, yearFrom, yearTo, load = {}, 0, -1, 5000, false
	local cargos, seenCargo, engineTypes = {}, {}, {}
	for k, v in ipairs(mu.vehicles) do
		local mid = api.res.modelRep.find(v.name)
		local mi = mid and mid >= 0 and modelInfo(mid) or nil
		if not mi then
			log("multiple unit", tostring(api.res.multipleUnitRep.getName(id)), "part not found:", tostring(v.name), tostring(mid))
			return nil
		end
		parts[k] = { info = mi, forward = v.forward }
		load = load or mi.load
		-- like the purchase window, which collects the engines of all parts (vehicle_store_util.tl:333-337)
		for et in pairs(mi.engineTypes) do engineTypes[et] = true end
		for __, c in ipairs(mi.cargos) do
			if not seenCargo[c] then seenCargo[c] = true; cargos[#cargos + 1] = c end
		end
		price = price + mi.price
		if mi.yearFrom ~= -1 then yearFrom = math.max(yearFrom, mi.yearFrom) end
		if mi.yearTo ~= -1 then yearTo = math.min(yearTo, mi.yearTo) end
	end
	local first = parts[1].info
	return {
		key = "u" .. id,
		id = id,
		mu = true,
		-- multiple unit with passengers or cargo like a railcar; made of locomotives only (EMD F series, SS4G) like a locomotive
		class = load and "self" or "loco",
		path = api.res.multipleUnitRep.getName(id),
		name = (mu.name ~= nil and mu.name ~= "") and mu.name or first.name,
		carrier = first.carrier,
		engine = true,
		engineTypes = engineTypes,
		yearFrom = yearFrom,
		yearTo = yearTo,
		price = price,
		parts = parts,
		noTags = #(mu.filterTags or {}) == 0,
		cargos = sortCargos(cargos),
		icon = first.icon,
		iconBig = first.iconBig,
	}
end

local function buildCatalog()
	if catalog then return catalog end
	catalog, muByPath = {}, {}
	for id in pairs(api.res.modelRep.getAll()) do
		local ok, i = pcall(modelInfo, id)
		if ok and i then catalog[i.key] = i end
	end
	local okAll, all = pcall(function() return api.res.multipleUnitRep.getAll() end)
	if not okAll then log("multiple units not retrievable", tostring(all)) end
	for id in pairs(okAll and all or {}) do
		local ok, i = pcall(muInfo, id)
		if ok and i then
			catalog[i.key] = i
			muByPath[i.path] = i
			-- parts of a multiple unit only exist together with it; they are not offered on their own
			for __, part in ipairs(i.parts) do part.info.muPart = true; if catalog[part.info.key] then catalog[part.info.key].muPart = true end end
		elseif not ok then
			log("multiple unit unreadable", tostring(id), tostring(i))
		end
	end
	return catalog
end

local function info(key)
	if key == nil then return nil end
	local c = buildCatalog()
	if c[key] == nil then
		local id = tonumber(key:sub(2))
		local ok, i = false, nil
		if key:sub(1, 1) == "m" and id then ok, i = pcall(modelInfo, id) end
		c[key] = ok and i or false
	end
	return c[key] or nil
end

local function muOfPath(path)
	buildCatalog()
	return muByPath[path]
end

-- like vehicle_store_util: yearFrom > 0 and a year before it = not yet, yearTo > 0 and that year or later = no longer
local function available(i, year)
	if i.yearFrom > 0 and year < i.yearFrom then return false end
	if i.yearTo > 0 and year >= i.yearTo then return false end
	return true
end

-- text with a number, singular via its own key (key_1), otherwise plural (key)
-- a translated text whose numbers get the game's thousands separator, like its own counters in the game bar
-- (game_bar_display_transported.script.tl:39 lang_util.formatInt = api.util.lang.formatInt, util.d.tl:11-27;
-- "896.439" in the German game). Every placeholder is %s (user decision 20.10.2026: always a thousands separator).
local function int(v)
	local ok, t = pcall(function() return api.util.lang.formatInt(math.floor(v + 0.5)) end)
	return ok and type(t) == "string" and t or string.format("%.0f", v)
end

local function tr(key, ...)
	local n, args = select("#", ...), { ... }
	for i = 1, n do
		if type(args[i]) == "number" then args[i] = int(args[i]) end
	end
	return string.format(_(key), table.unpack(args, 1, n))
end

local function count(key, n)
	if n == 1 then return _(key .. "_1") end
	return tr(key, n)
end

local function money(v)
	local ok, s = pcall(api.util.formatMoney, math.floor(v + 0.5))
	return ok and s or tostring(v)
end

-- engine types of a set as text in the game's order, e.g. "Diesel" or "Steam/Diesel"
local function engineNames(set)
	local names = {}
	for __, et in ipairs(ENGINE_TYPES) do
		if set[et.key] then names[#names + 1] = _(et.label) end
	end
	return table.concat(names, "/")
end

-- Warning text when the new model has other engine types than the old one (issue #50), else nil.
-- Only when both have engines: wagons have none, ships and aircraft no landVehicle.
local function engineChange(altInfo, neuInfo)
	local a, n = altInfo and altInfo.engineTypes or {}, neuInfo and neuInfo.engineTypes or {}
	if next(a) == nil or next(n) == nil then return nil end
	local same = true
	for __, et in ipairs(ENGINE_TYPES) do
		if (a[et.key] or false) ~= (n[et.key] or false) then same = false end
	end
	if same then return nil end
	return tr("mvr_engine_change", engineNames(a), engineNames(n))
end

-- Net amount after residual value. Below 0 the player gets money back (the game books exactly that, measured
-- 19.10.2026); the game's own button then shows a negative price (vehicle_store_window.tl:4277), we say
-- "proceeds" with the positive amount instead (user decision 19.10.2026)
local function netLine(cost)
	if cost < 0 then return tr("mvr_gain_net", money(-cost)) end
	return tr("mvr_cost_net", money(cost))
end

-- Vehicles in the game ------------------------------------------------------------------------------

-- Groups of a vehicle: { from, to, path } with path = file name of the multiple unit or "" for single parts.
-- Without group data each part counts on its own.
local function groupsOf(cfg)
	local groups, from = {}, 1
	local sizes = cfg.vehicleGroups or {}
	local total = #cfg.vehicles
	for gi = 1, #sizes do
		local n = sizes[gi]
		-- group sizes beyond the part list (inconsistent data) are clamped, so no part index is ever nil
		if from > total then break end
		groups[#groups + 1] = { from = from, to = math.min(from + n - 1, total), path = (cfg.muFileNames or {})[gi] or "" }
		from = from + n
	end
	if from <= #cfg.vehicles then
		for j = from, #cfg.vehicles do groups[#groups + 1] = { from = j, to = j, path = "" } end
	end
	return groups
end

-- Fleet per entry: parts = pieces (single parts or multiple units), vehicles = vehicles (trains) it is
-- in, plus the vehicle type from the vehicle component; that one can be compared with the depot like in the game.
-- Parts of a multiple unit count only with the multiple unit, not on their own.
local unknownMu = {} -- report only once
-- only the player's vehicles: campaign missions hand lines and vehicles to AI players
-- (mission.zip transfer_ownership_util.tl), the game filters its own lists the same way (statistic_vehicles.tl:322)
local function ownVehicles()
	return api.engine.getEntitiesWithComponent(CT.TRANSPORT_VEHICLE, { requireOwnedByPlayer = api.engine.util.getPlayer() })
end

-- the models of a vehicle's parts in order, to notice a vehicle rebuilt under the same id (#10)
local function partsOf(cfg)
	local models = {}
	for j, part in ipairs(cfg.vehicles) do models[j] = tostring(part.part.modelId) end
	return table.concat(models, ",")
end

-- keys: the entry key of every part of a vehicle: "m<id>" for single parts, the multiple unit's key for its parts,
-- false for parts of an unknown multiple unit (mod missing: not offered, kept as they are)
local function useOf(v, cfg)
	local keys, units = {}, {}
	for __, g in ipairs(groupsOf(cfg)) do
		if g.path ~= "" then
			local mi = muOfPath(g.path)
			if not mi and not unknownMu[g.path] then unknownMu[g.path] = true; log("unknown multiple unit in train", tostring(g.path)) end
			for j = g.from, g.to do keys[j] = mi and mi.key or false end
			units[#units + 1] = mi and mi.key or false
		else
			for j = g.from, g.to do
				keys[j] = "m" .. cfg.vehicles[j].part.modelId
				units[#units + 1] = keys[j]
			end
		end
	end
	-- one vehicle the way the cost functions see it: its parts with the entry key of each (creditOf, unitsIn);
	-- units: one key per group, a multiple unit counts once (fleet)
	return { vehicle = v, parts = cfg.vehicles, keys = keys, units = units }
end

-- returns the entries by key and the parts of every vehicle read (partsOf)
local function fleet()
	local byKey, partsByVehicle = {}, {}
	-- uses: every vehicle this entry is in, with the entry of each of its parts, so the residual value can
	-- tell replaced parts from kept ones (#26). keys[j] is false for parts of an unknown multiple unit.
	local function add(key, tv, seen)
		local e = byKey[key]
		if not e then e = { parts = 0, vehicles = 0, carrier = tv.carrier, uses = {} }; byKey[key] = e end
		e.parts = e.parts + 1
		if not seen[key] then seen[key] = true; e.vehicles = e.vehicles + 1 end
	end
	for __, v in ipairs(ownVehicles()) do
		local tv = api.engine.getComponent(v, CT.TRANSPORT_VEHICLE)
		local cfg = tv and tv.transportVehicleConfig
		if cfg then
			partsByVehicle[v] = partsOf(cfg)
			local seen = {}
			local use = useOf(v, cfg)
			for __, key in ipairs(use.units) do
				if key then add(key, tv, seen) end
			end
			for key in pairs(seen) do local u = byKey[key].uses; u[#u + 1] = use end
		end
	end
	return byKey, partsByVehicle
end

-- new part: paint from the old part; reversed from the old part or, in a multiple unit, from its definition
local function newPart(model, reversed, color, t)
	local p = api.type.TransportVehiclePart.new()
	p.part.modelId = model.id
	p.part.reversed = reversed
	p.part.color = color
	local lcs, auto = {}, {}
	for i = 1, model.compartments do
		local lc = api.type.LoadConfig.new()
		lc.loadConfigIndex = 0
		lcs[i] = lc
		auto[i] = true
	end
	p.part.compartment2loadConfig = lcs
	p.autoLoadConfig = auto
	p.purchaseTime = t
	return p
end

-- Result of the last batch. Commands sent from the GUI run in the next simulation step and their callbacks
-- come a frame later (api/tealdef/api/cmd.d.tl:2-10); until then the vehicles still look unchanged, so a
-- second batch would replace the same vehicles again. Like the game (engine_react_util.tl:36-55, 66-98) we
-- count pending callbacks for as long as the window is open; batch tells callbacks of an earlier window apart.
-- queued, note: what the click queued, "full" or "foreign" (replacement queue)
local result = { batch = 0, sent = 0, ok = 0, failed = 0, text = "", total = nil, queued = 0, note = nil }
-- the replacement queue: Queue holds its functions (filled below, in one block to stay within Lua's limit of 200
-- locals per chunk), queue its state, replaced as a whole when a savegame is loaded
local Queue = {}
local queue

local function pending()
	return result.sent > result.ok + result.failed
end

-- Fleet of the window (#10): reading every vehicle on every redraw is the expensive part, so the window keeps the
-- last fleet and builds it again only when the player's vehicles change. fleetSig runs every step and redraws the
-- window on a change:
-- - bought, sold or handed to another player: the list of ids changes (cheap, no components);
-- - rebuilt under the same id (the game's own vehicle window, "Replace"): each step compares the parts of the next
--   CHECK_PER_STEP vehicles with the fleet read last, in turn, so a large fleet is covered within a few steps.
--   Game test 18.10.2026: the parts change at once; api.engine.getRevision did not (num[2] stayed 5 while the
--   model changed), so revisions are not used;
-- - the callbacks of our own batch.
local CHECK_PER_STEP = 100
-- the vehicle check runs only every SIG_EVERY steps (game test 18.10.2026: 1-3 fps less with 1808 vehicles when it
-- ran every step); in between its last result stands. Opening the window (result.batch) and the callbacks of our
-- own batch are cheap and count at once; a new batch also refreshes the vehicle part, so the fleet read on opening
-- is not read a second time a few steps later.
local SIG_EVERY = 6
local cachedFleet = { sig = nil, byKey = nil, parts = nil, nextCheck = 1, rebuilt = 0, steps = 0, vehiclesSig = nil,
	vehiclesBatch = nil }

local function checkSomeParts(ids)
	local parts = cachedFleet.parts
	if not parts or #ids == 0 then return end
	for __ = 1, math.min(CHECK_PER_STEP, #ids) do
		local i = cachedFleet.nextCheck
		if i > #ids then i = 1 end
		cachedFleet.nextCheck = i + 1
		local v = ids[i]
		local ok, now = pcall(function() return partsOf(api.engine.getComponent(v, CT.TRANSPORT_VEHICLE).transportVehicleConfig) end)
		if ok and parts[v] ~= nil and now ~= parts[v] then
			parts[v] = now -- count each rebuild once; the fleet is read again anyway
			cachedFleet.rebuilt = cachedFleet.rebuilt + 1
		end
	end
end

local function vehiclesSig()
	local ids = ownVehicles()
	checkSomeParts(ids)
	-- order-free, so a different order of the same vehicles is no change
	local sum, squares = 0, 0
	for __, v in ipairs(ids) do
		sum = sum + v
		squares = (squares + v * v) % 2147483647
	end
	return tostring(#ids) .. ":" .. tostring(sum) .. ":" .. tostring(squares) .. ":" .. tostring(cachedFleet.rebuilt)
end

local function fleetSig()
	cachedFleet.steps = cachedFleet.steps + 1
	if cachedFleet.vehiclesSig == nil or cachedFleet.vehiclesBatch ~= result.batch or cachedFleet.steps % SIG_EVERY == 0 then
		cachedFleet.vehiclesSig, cachedFleet.vehiclesBatch = vehiclesSig(), result.batch
	end
	return cachedFleet.vehiclesSig .. ":" .. tostring(result.batch) .. ":" .. tostring(result.ok + result.failed)
end

local function windowFleet(sig)
	if cachedFleet.sig ~= sig or cachedFleet.byKey == nil then
		-- sig only after a successful read: if fleet() throws, the next redraw tries again (as before #10)
		cachedFleet.byKey, cachedFleet.parts = fleet()
		cachedFleet.sig = sig
	end
	return cachedFleet.byKey
end

local function updateText()
	local queued = result.queued or 0
	if result.sent == 0 and queued == 0 and result.note == nil then
		result.text = _("mvr_none_found")
		return
	end
	-- nothing sent and nothing queued because the queue belongs to another version: only that
	if result.sent == 0 and result.note == "foreign" then
		result.text = _("mvr_queue_foreign")
		return
	end
	-- the result shows once, when the game has answered every command (user decision 19.10.2026); until then
	-- the button says "Replacing ..." and no half-counted line like "0 of 8" appears
	if pending() then
		result.text = ""
		return
	end
	local s = tr("mvr_replaced", result.ok, result.sent)
	-- partial (#23): of all vehicles with the old model, not only of those sent; same wording as a full batch,
	-- the money was already named on the button (user decision 19.10.2026)
	if result.total and result.total > result.sent then s = tr("mvr_replaced", result.ok, result.total) end
	-- queued the rest: the same line names the queued ones
	if queued > 0 then s = tr("mvr_replaced_queued", result.ok, result.total or result.sent, queued) end
	-- commands the game refused, apart from the vehicles skipped for money: the game gives no reason, and it
	-- does not refuse for lack of money (measured 19.10.2026, tf3-sdk knowledge/vehicles.md)
	if result.failed > 0 then s = s .. " " .. count("mvr_rejected", result.failed) end
	-- a sentence ends with a full stop, like the other lines of the window (user decision 20.10.2026)
	s = s .. "."
	if result.note == "full" then s = s .. " " .. tr("mvr_queue_full", Queue.MAX_QUEUED) end
	if result.note == "foreign" then s = s .. " " .. _("mvr_queue_foreign") end
	result.text = s
end

-- Builds the new consist of a vehicle; nil if alt does not occur in it.
-- Single model: every single part alt becomes neu, multiple units in the same train stay.
-- Multiple unit: every group alt is replaced by the parts of neu, group size and file name adapt.
-- The game reverses a multiple unit by reversing the order of its parts and flipping each part's
-- reversed flag (vehicle_store_window.tl, reverse). A group in a train is reversed when its parts
-- match the definition read backwards with flipped flags; a group that matches neither (unknown
-- state) counts as forward.
local function groupReversed(cfg, g, muInfoOfGroup)
	local parts = muInfoOfGroup.parts
	local n = g.to - g.from + 1
	if n ~= #parts then return false end
	local forward, backward = true, true
	for k = 1, n do
		local p = cfg.vehicles[g.from + k - 1].part
		local def, rdef = parts[k], parts[n + 1 - k]
		if p.modelId ~= def.info.id or p.reversed ~= (not def.forward) then forward = false end
		if p.modelId ~= rdef.info.id or p.reversed ~= rdef.forward then backward = false end
	end
	return backward and not forward
end

local function rebuild(cfg, altInfo, neuInfo, t)
	local vehicles, sizes, paths, units = {}, {}, {}, 0
	-- puts the new model where the old one was, facing the same way: a multiple unit as its own group
	-- with its file name, a single model as a group of one. reversedUnit: the old unit faces backwards
	-- (a single model by its reversed flag, a multiple unit by groupReversed)
	local function putNew(old, reversedUnit)
		if neuInfo.mu then
			local parts = neuInfo.parts
			for k = 1, #parts do
				-- no "a and b or c" here: p.forward can be false
				local p, reversed
				if reversedUnit then
					p = parts[#parts + 1 - k]
					reversed = p.forward
				else
					p = parts[k]
					reversed = not p.forward
				end
				vehicles[#vehicles + 1] = newPart(p.info, reversed, old.part.color, t)
			end
			sizes[#sizes + 1] = #parts
			paths[#paths + 1] = neuInfo.path
		else
			vehicles[#vehicles + 1] = newPart(neuInfo, reversedUnit, old.part.color, t)
			sizes[#sizes + 1] = 1
			paths[#paths + 1] = ""
		end
		units = units + 1
	end
	for __, g in ipairs(groupsOf(cfg)) do
		if g.path ~= "" then
			if altInfo.mu and g.path == altInfo.path then
				putNew(cfg.vehicles[g.from], groupReversed(cfg, g, altInfo))
			else
				for j = g.from, g.to do vehicles[#vehicles + 1] = cfg.vehicles[j] end
				sizes[#sizes + 1] = g.to - g.from + 1
				paths[#paths + 1] = g.path
			end
		else
			-- single parts each sit in a group of their own, like in the purchase window
			for j = g.from, g.to do
				local p = cfg.vehicles[j]
				if not altInfo.mu and p.part.modelId == altInfo.id then
					putNew(p, p.part.reversed == true)
				else
					vehicles[#vehicles + 1] = p
					sizes[#sizes + 1] = 1
					paths[#paths + 1] = ""
				end
			end
		end
	end
	if units == 0 then return nil end
	local conf = api.type.TransportVehicleConfig.new(cfg)
	conf.vehicles = vehicles
	conf.vehicleGroups = sizes
	conf.muFileNames = paths
	return conf, units
end

-- The replace command does not check the balance (the game's purchase window does that itself,
-- vehicle_store_window.tl hasEnoughMoney), so without this check the player could go into debt.
-- Like the game, the cost is the purchase price minus the residual value of the replaced vehicles (#26).
-- what the window shows, read by its step states: price of the new parts, fleet entry and model being replaced
local shown = { price = 0, e = nil, key = nil, cost = 0, time = nil }

-- The player's balance, read in one place; the three functions below each answer one question about it.
-- ok is false when the call failed. funds nil means infinite money (sandbox mode, "no costs";
-- vehicle_store_window.tl fundsState: "nil if infinite!").
local function readBalance()
	return pcall(function() return api.engine.util.finance.getPlayersBalance(api.engine.util.getPlayer()) end)
end

-- infinite money: the game then hides the balance card in the depot window
-- (maintenance_station_eow.script.tl conditionMaintenanceStationBalance, state.infiniteMoney)
local function infiniteMoney()
	local ok, funds = readBalance()
	return ok and funds == nil
end

-- whether the balance covers cost, like the purchase window (funds >= cost): inf covers everything, nan nothing
local function enoughMoney(cost)
	if cost <= 0 then return true end
	local ok, funds = readBalance()
	if not ok then return true end -- unreadable: leave it to the game, as before
	return funds == nil or funds >= cost
end

-- the balance for partial replacing: a real, finite number or nil; nan or inf would let every comparison pass
-- (a test with a nan balance replaced all vehicles), so they count as unreadable
local function balance()
	local ok, funds = readBalance()
	if ok and type(funds) == "number" and funds == funds and funds > -math.huge and funds < math.huge then return funds end
	return nil
end

-- a value the game gave us that can be counted: a number, not nan (value == value), not negative, finite
local function readValue(fn, arg)
	local ok, value = pcall(fn, arg)
	if ok and type(value) == "number" and value == value and value >= 0 and value < math.huge then return value end
	return nil
end

-- Residual value credited when the entry key is replaced in the vehicles of fleet() entry e, like the game:
-- the purchase window subtracts getDepreciatedValue of each replaced vehicle (vehicle_store_window.tl:3525-3547);
-- its "Modify" mode, which keeps some parts of a vehicle, also charges the kept parts at getPartPrice
-- (vehicle_store_window.tl:3758-3768). Per vehicle: residual value minus the value of the parts that stay.
-- A vehicle with an unreadable value credits nothing: it counts at the full price of its new parts.
local function creditOf(use, key)
	-- the window reads this every step, so a vehicle may be gone since fleet() saw it; the game also checks
	-- its vehicles before valuing them (vehicle_store_window.tl:3496-3503). Gone: nothing to credit.
	local okE, exists = pcall(api.engine.entityExists, use.vehicle)
	local credit = okE and exists and readValue(api.engine.util.vehicle.getDepreciatedValue, use.vehicle) or nil
	for j, part in ipairs(use.parts) do
		if credit and use.keys[j] ~= key then
			local kept = readValue(api.engine.util.vehicle.getPartPrice, part)
			credit = kept and credit - kept or nil
		end
	end
	-- may be below 0 when the kept parts are worth more than the vehicle: the game charges that too
	return credit or 0
end

local function residual(e, key)
	local sum = 0
	for __, use in ipairs(e and e.uses or {}) do sum = sum + creditOf(use, key) end
	return sum
end

-- Replacing only as many vehicles as the balance covers (#23). A vehicle (a whole train) is replaced completely
-- or not at all; oldest first, by the purchase time of its oldest part; the cost of a vehicle is the price of its
-- new units minus its credit, by the same rule as the whole batch.
local function unitsIn(use, key, altInfo)
	local n = 0
	for j = 1, #use.parts do if use.keys[j] == key then n = n + 1 end end
	-- a multiple unit is one unit with several parts (fleet() counts its groups the same way)
	if altInfo and altInfo.mu then n = n / math.max(1, #altInfo.parts) end
	return n
end

local function purchasedAt(use)
	local oldest = math.huge
	for __, part in ipairs(use.parts) do
		-- tostring first: an engine value need not be a Lua number (lesson of #10)
		local ok, t = pcall(function() return tonumber(tostring(part.purchaseTime)) end)
		if ok and t and t < oldest then oldest = t end
	end
	return oldest
end

-- the vehicles of entry e the balance covers: set of vehicle ids, their number and the cost; fourth value: all
-- vehicles of the entry sorted oldest first (the queue takes the rest in that order)
local function affordablePart(e, key, altInfo, neuInfo, funds)
	local list = {}
	for __, use in ipairs(e and e.uses or {}) do
		list[#list + 1] = { vehicle = use.vehicle, age = purchasedAt(use),
			cost = neuInfo.price * unitsIn(use, key, altInfo) - creditOf(use, key) }
	end
	table.sort(list, function(a, b)
		if a.age ~= b.age then return a.age < b.age end
		return a.vehicle < b.vehicle
	end)
	local picked, n, sum = {}, 0, 0
	for __, x in ipairs(list) do
		-- stop at the first vehicle the rest of the money does not cover, so the oldest go first
		if sum + x.cost > funds then break end
		sum = sum + x.cost
		picked[x.vehicle] = true
		n = n + 1
	end
	return picked, n, sum, list
end

local function gameTime()
	local ok, t = pcall(function() return api.engine.getComponent(api.engine.util.getWorld(), CT.GAME_TIME).gameTime end)
	return ok and t or nil
end

-- Cost of what the window shows. Residual values drop as the vehicles age, and the game's purchase window reads
-- the refund every step (vehicle_store_window.tl:3529-3547), so the window does too. Read again only once game
-- time has passed (nothing ages while paused) or the window was drawn anew (shown.time reset).
local function shownCost()
	local t = gameTime()
	if t == nil or t ~= shown.time then
		shown.cost = shown.price - residual(shown.e, shown.key)
		shown.time = t
	end
	return shown.cost
end

-- Settings and queue in the savegame ---------------------------------------------------------------------
-- selection in the window; lives outside the recipe so every opening starts fresh
-- details: the stats card is expanded (#16); expanded at first (user decision 19.10.2026)
-- sortOld, sortNew: each list has its own sorting (user decision 19.10.2026); by year at first, the old list oldest
-- first, the new list newest first, so the modern models are on top (user decision 20.10.2026)
-- queueRest: "queue the rest" box in the window, off at first (plan 20.10.2026, section 4)
local sel = { carrier = nil, alt = nil, neu = nil, sortOld = "year", sortNew = "year", sortOldAsc = true, sortNewAsc = false,
	sameCargo = true, details = true, queueRest = false }

-- Sorting, "Same cargo", the details card and the queue are kept in the savegame (user decision 19.10.2026), in
-- the game's GUI save data per mod (api/tealdef/api/gui.d.tl:773-781 getGuiSaveData/setGuiSaveData). The game
-- keeps its HUD filters there (layer_hud_filter.tl:59-82), Clean HUD and Line Manager their settings. Settings are
-- read on every opening of the window, the queue when the host mounts; written on every change; a missing or odd
-- value keeps the default. Only strings and booleans are stored: those are measured to survive save, restart and
-- load (tf3-sdk knowledge/ui.md, MVR #54).
do
local MOD_ID = "mass_vehicle_replace_1"
local function isBool(v) return type(v) == "boolean" end
local KEPT = {
	sortOld = function(v) return v == "name" or v == "year" end,
	sortNew = function(v) return v == "name" or v == "year" end,
	sortOldAsc = isBool,
	sortNewAsc = isBool,
	sameCargo = isBool,
	details = isBool,
	queueRest = isBool,
}

-- the save data as last read, so a write keeps every field it does not own (another version of this mod may have
-- written more; its queue must survive a sort change here)
local savedRaw = {}

local function readSaveData()
	local ok, data = pcall(function() return api.gui.game.getGuiSaveData(MOD_ID) end)
	if not ok or type(data) ~= "table" then return nil end
	local copy = {}
	if pcall(function() for k, v in pairs(data) do copy[k] = v end end) then savedRaw = copy end
	return data
end

local function loadKept()
	local data = readSaveData()
	if data == nil then return end
	for k, valid in pairs(KEPT) do
		local okV, v = pcall(function() return data[k] end)
		if okV and valid(v) then sel[k] = v end
	end
end

-- Replacement queue ---------------------------------------------------------------------------------------
-- Vehicles the money did not cover when the player clicked are queued and replaced one by one as the balance
-- allows (#23 stage 2, plan of 20.10.2026). A job is one click: old model, new model and the vehicles left over,
-- oldest first; jobs run one after the other (FIFO). The truth is in the vehicle, not in the queue: right before
-- a command is sent, the head vehicle is checked against the game (exists, same entity, still the player's, still
-- has the old model, new model still for sale), so the queue may be stale but never sends something wrong.
-- Driven by a host plugin at the game's ModEntryPointExtension (gui/main/mod_entry_point.tl:5, always mounted and
-- invisible, game.tl:83-89), stepping about once a second of real time; the game sends its own background
-- commands from react.onStep too (game.tl:640-676, game speed).
local QUEUE_FORMAT = "1"
local TICK_S = 1.0 -- longest interval the game itself uses (construction.tl:4308-4311); money comes in slower
local INFLIGHT_TIMEOUT_S = 10 -- a callback is not documented as guaranteed (tf3-sdk knowledge/commands.md)
local DROPS_PER_TICK = 20 -- stale entries dropped per tick, bounds the work of one frame
-- commands sent per tick at most: as many as the balance covers, like the window's own batch (user decision
-- 20.10.2026: one per second took minutes for a large order); bounds the work of one frame
local SENDS_PER_TICK = 100
Queue.MAX_QUEUED = 10000 -- vehicles the queue holds at most; bounds the save data (about 12 bytes each)
local ERRORS_TO_PAUSE = 5 -- Lua errors in a row before the queue pauses itself
local FAILURES_TO_DROP = 3 -- commands the game answered with false before the vehicle is dropped

local function newQueue()
	return {
		jobs = {}, -- { id, alt, neu, open = { { entity, birth, failures } ... }, done, skipped = { sold, replaced, reused, rejected }, blocked, cost, short }
		byEntity = {}, -- entity -> job id, so a vehicle is queued once
		reserve = 0, -- money that stays on the account
		paused = false,
		nextId = 1,
		inflight = {}, -- entity -> { job, sentAt, parts }: the commands of the last tick waiting for their callback
		inflightN = 0,
		nextTick = 0, -- application time of the next tick
		cache = nil, -- { entity, cost }: last net cost of the head; a lower bound, the residual value only falls
		loaded = false, -- read from the savegame
		foreign = false, -- save data of another version or unreadable: not processed, never overwritten
		editor = false, -- map editor: nothing to do
		errors = 0, -- Lua errors in a row
		lastError = nil,
	}
end
queue = newQueue()

local function num(v)
	return string.format("%.0f", v)
end

-- a counted number from the game or the save data: finite, not nan, not negative
local function countValue(v)
	v = tonumber(v)
	if v and v == v and v >= 0 and v < math.huge then return v end
	return nil
end

local function emptySkipped()
	return { sold = 0, replaced = 0, reused = 0, rejected = 0 }
end

-- Save format (string, version QUEUE_FORMAT): jobs separated by ";", each "id,alt,neu,done,sold,replaced,reused,
-- rejected:entity/birth,entity/birth". Replaced and skipped vehicles are not stored, only their counters.
local function serializeQueue()
	local jobs = {}
	for k, j in ipairs(queue.jobs) do
		local es = {}
		for i, e in ipairs(j.open) do es[i] = num(e.entity) .. "/" .. num(e.birth) end
		local s = j.skipped
		jobs[k] = table.concat({ num(j.id), j.alt, j.neu, num(j.done), num(s.sold), num(s.replaced), num(s.reused), num(s.rejected) }, ",")
			.. ":" .. table.concat(es, ",")
	end
	return table.concat(jobs, ";")
end

-- jobs and the entity index from the saved string; nil when anything in it is not as written by serializeQueue
local function parseQueue(s)
	if type(s) ~= "string" then return nil end
	local jobs, byEntity, maxId = {}, {}, 0
	if s == "" then return jobs, byEntity, maxId end
	for jobStr in (s .. ";"):gmatch("([^;]*);") do
		local head, tail = jobStr:match("^([^:]*):(.*)$")
		if not head then return nil end
		local f = {}
		for x in (head .. ","):gmatch("([^,]*),") do f[#f + 1] = x end
		if #f ~= 8 then return nil end
		local id, done = countValue(f[1]), countValue(f[4])
		local skipped = { sold = countValue(f[5]), replaced = countValue(f[6]), reused = countValue(f[7]), rejected = countValue(f[8]) }
		if not (id and done and skipped.sold and skipped.replaced and skipped.reused and skipped.rejected) then return nil end
		if not (f[2]:match("^[mu]%d+$") and f[3]:match("^[mu]%d+$")) then return nil end
		local job = { id = id, alt = f[2], neu = f[3], open = {}, done = done, skipped = skipped }
		if tail ~= "" then
			for piece in (tail .. ","):gmatch("([^,]*),") do
				local e, b = piece:match("^(%d+)/(%d+)$")
				e, b = countValue(e), countValue(b)
				if not (e and b) then return nil end
				-- a vehicle in two jobs (should not happen): the first keeps it
				if not byEntity[e] then
					job.open[#job.open + 1] = { entity = e, birth = b, failures = 0 }
					byEntity[e] = id
				end
			end
		end
		jobs[#jobs + 1] = job
		if id > maxId then maxId = id end
	end
	return jobs, byEntity, maxId
end

-- reads the queue from the savegame; replaces whatever was in memory (a new savegame may be loaded)
local function loadQueue()
	local q = newQueue()
	q.loaded = true
	local data = readSaveData()
	if data ~= nil then
		local okF, fmt = pcall(function() return data.queueFormat end)
		if okF and fmt ~= nil then
			local jobs, byEntity, maxId
			if fmt == QUEUE_FORMAT then
				local okQ, s = pcall(function() return data.queue end)
				jobs, byEntity, maxId = parseQueue(okQ and s or nil)
			end
			if jobs then
				q.jobs, q.byEntity = jobs, byEntity
				local okR, r = pcall(function() return data.queueReserve end)
				q.reserve = okR and countValue(r) or 0
				local okP, p = pcall(function() return data.queuePaused end)
				q.paused = okP and p == true
				local okN, n = pcall(function() return data.queueNextId end)
				n = okN and countValue(n) or nil
				q.nextId = (n and n > maxId) and n or maxId + 1
			else
				-- another version wrote this (or it is damaged): leave it alone, the other version may read it again
				q.foreign = true
				log("queue in the savegame is from another version or unreadable, format", tostring(fmt), "- not processed, not overwritten")
			end
		end
	end
	queue = q
end

local function ensureLoaded()
	if not queue.loaded then loadQueue() end
end

-- writes settings and queue together; fields this version does not know are written back as read
local function writeSaveData()
	ensureLoaded()
	local data = {}
	for k, v in pairs(savedRaw) do data[k] = v end
	for k in pairs(KEPT) do data[k] = sel[k] end
	if not queue.foreign then
		data.queueFormat = QUEUE_FORMAT
		data.queue = serializeQueue()
		data.queueReserve = num(queue.reserve)
		data.queuePaused = queue.paused == true
		data.queueNextId = num(queue.nextId)
	end
	local ok, err = pcall(function() api.gui.game.setGuiSaveData(MOD_ID, data) end)
	if not ok then log("settings not saved", tostring(err)) else savedRaw = data end
end

-- open vehicles in memory only: safe inside a timed step state (those run as deferred steps with a restricted
-- api, react.lua:525-534), so it never reads the savegame; the host loads the queue when it mounts
local function queuedNow()
	if not queue.loaded then return 0 end
	local n = 0
	for __, j in ipairs(queue.jobs) do n = n + #j.open end
	return n
end

local function openCount()
	ensureLoaded()
	return queuedNow()
end

local function jobById(id)
	for k, j in ipairs(queue.jobs) do
		if j.id == id then return j, k end
	end
	return nil
end

-- num[1] of the vehicle's revision, copied as a Lua number: it changes when an entity id is reused for another
-- entity (scripts/entity_util.tl:35-39 entityChanged0; 0 = unreadable, then the check is skipped)
local function birthOf(v)
	local ok, b = pcall(function() return tonumber(tostring(api.engine.getRevision(v).num[1])) end)
	return ok and countValue(b) or 0
end

local function indexOf(job, e)
	for i, x in ipairs(job.open) do
		if x.entity == e then return i end
	end
	return nil
end

-- a command answered, cancelled or given up
local function settle(e)
	if queue.inflight[e] then
		queue.inflight[e] = nil
		queue.inflightN = queue.inflightN - 1
	end
end

-- a job without open vehicles goes at once, finished or not (user decision 20.10.2026); a vehicle in flight is
-- still open, so its job stays until the answer
local function pruneJobs()
	for k = #queue.jobs, 1, -1 do
		if #queue.jobs[k].open == 0 then table.remove(queue.jobs, k) end
	end
end

-- Takes the entities out of the jobs they are queued in: the newest order wins (user decision 20.10.2026: a newer
-- model came out, the player orders that one instead). A vehicle whose command is under way stays. A job left
-- without vehicles goes. Returns how many.
local function release(entities)
	ensureLoaded()
	local n = 0
	for __, e in ipairs(entities) do
		local id = queue.byEntity[e]
		local job = id and not queue.inflight[e] and jobById(id)
		local i = job and indexOf(job, e)
		if i then
			table.remove(job.open, i)
			queue.byEntity[e] = nil
			n = n + 1
		end
	end
	if n == 0 then return 0 end
	pruneJobs()
	queue.cache = nil
	return n
end

-- releases the vehicles the window has just replaced itself, and saves when that changed the queue
local function releaseReplaced(entities)
	if release(entities) > 0 then writeSaveData() end
end

-- queues the vehicles of list (as sorted by affordablePart) as one job; returns how many were queued and a note:
-- "full" (limit reached) or "foreign" (queue of another version, nothing queued). Vehicles in older jobs move to
-- this one (release).
local function enqueue(altKey, neuKey, list)
	ensureLoaded()
	if queue.foreign then return 0, "foreign" end
	local entities = {}
	for k, x in ipairs(list) do entities[k] = x.vehicle end
	local moved = release(entities)
	local job = { id = queue.nextId, alt = altKey, neu = neuKey, open = {}, done = 0, skipped = emptySkipped() }
	local note = nil
	local total = openCount()
	for __, v in ipairs(entities) do
		-- a vehicle still in an older job has a command under way there: that command decides
		local free = not (queue.byEntity[v] or queue.inflight[v])
		if free and total >= Queue.MAX_QUEUED then note, free = "full", false end
		if free then
			job.open[#job.open + 1] = { entity = v, birth = birthOf(v), failures = 0 }
			queue.byEntity[v] = job.id
			total = total + 1
		end
	end
	if #job.open == 0 then
		if moved > 0 then writeSaveData() end
		return 0, note
	end
	queue.nextId = queue.nextId + 1
	queue.jobs[#queue.jobs + 1] = job
	queue.cache = nil
	writeSaveData()
	return #job.open, note
end

-- a cancelled job's commands may still be running: their answers no longer matter, the vehicle tells (checkHead)
local function removeJob(id)
	local job, k = jobById(id)
	if not job then return end
	for __, e in ipairs(job.open) do
		queue.byEntity[e.entity] = nil
		local f = queue.inflight[e.entity]
		if f and f.job == id then settle(e.entity) end
	end
	table.remove(queue.jobs, k)
	queue.cache = nil
	writeSaveData()
end

local function cancelAll()
	for __, job in ipairs(queue.jobs) do
		for __, e in ipairs(job.open) do queue.byEntity[e.entity] = nil end
	end
	queue.jobs = {}
	queue.inflight, queue.inflightN, queue.cache = {}, 0, nil
	writeSaveData()
end

-- upper bound of the reserve: far above any balance a normal game reaches, and an exact integer in a double
Queue.RESERVE_MAX = 1e12

local function setReserve(v)
	ensureLoaded()
	queue.reserve = math.min(countValue(v) or 0, Queue.RESERVE_MAX)
	writeSaveData()
end

local function setPaused(p)
	ensureLoaded()
	queue.paused = p == true
	if not p then queue.errors, queue.lastError = 0, nil end
	writeSaveData()
end

-- the first job with open vehicles that can run, after the job after if given: a job whose new model is unknown
-- (mod removed) or no longer for sale is marked blocked and skipped, the jobs behind it go on; it runs again once
-- the model is back
local function headJob(year, after)
	local skipping = after ~= nil
	for __, j in ipairs(queue.jobs) do
		if skipping then
			skipping = j ~= after
		elseif #j.open > 0 then
			local neuInfo = info(j.neu)
			if not (neuInfo and info(j.alt)) then
				j.blocked = "unknown"
			elseif not available(neuInfo, year) then
				j.blocked = "model"
			else
				j.blocked = nil
				return j
			end
		end
	end
	return nil
end

local function finishEntry(job, i)
	local e = table.remove(job.open, i)
	queue.byEntity[e.entity] = nil
	job.done = job.done + 1
	job.cost, job.short = nil, nil
	queue.cache = nil
end

local function dropEntry(job, i, reason)
	local e = table.remove(job.open, i)
	queue.byEntity[e.entity] = nil
	job.skipped[reason] = job.skipped[reason] + 1
	job.cost, job.short = nil, nil
	queue.cache = nil
end

local function failEntry(job, i)
	local entry = job.open[i]
	entry.failures = entry.failures + 1
	if entry.failures >= FAILURES_TO_DROP then dropEntry(job, i, "rejected") end
end

-- the balance for the queue: a finite number, or nil with infinite = true for infinite money (sandbox mode, "no
-- costs"), or nil, false when it cannot be read: then the queue sends nothing (the window leaves that to the game,
-- but a click is the player's decision, a tick is not)
local function queueFunds()
	local ok, funds = readBalance()
	if not ok then return nil, false end
	if funds == nil then return nil, true end
	if type(funds) == "number" and funds == funds and funds > -math.huge and funds < math.huge then return funds, false end
	return nil, false
end

-- Checks the head vehicle of job against the game and builds its command. Returns a table { conf, cost, parts }
-- when it can be replaced, or nil and the reason to drop it: "sold" (gone, or another player's), "reused" (the
-- entity id now belongs to something else), "replaced" (the old model is no longer in it, e.g. replaced by hand
-- in the game's vehicle window: the id stays, the parts change at once, game test 18.10.2026).
local function checkHead(job, entry, t)
	local e = entry.entity
	if not api.engine.entityExists(e) then return nil, "sold" end
	if entry.birth ~= 0 then
		local b = birthOf(e)
		if b ~= 0 and b ~= entry.birth then return nil, "reused" end
	end
	-- the owner from PLAYER_OWNED, the way the game's entity windows read it (eow_extension_util.tl:5-17); a vehicle
	-- without the component is nobody's (campaign missions hand vehicles to AI players, tf3-sdk knowledge/ownership.md)
	local okO, mine = pcall(function()
		local po = api.engine.getComponent(e, CT.PLAYER_OWNED)
		return po ~= nil and po.player == api.engine.util.getPlayer()
	end)
	if okO and not mine then return nil, "sold" end
	local tv = api.engine.getComponent(e, CT.TRANSPORT_VEHICLE)
	local cfg = tv and tv.transportVehicleConfig
	if not cfg then return nil, "sold" end
	local altInfo, neuInfo = info(job.alt), info(job.neu)
	local conf, units = rebuild(cfg, altInfo, neuInfo, t)
	if not conf then return nil, "replaced" end
	-- the same formula as the window and the batch (#26, #37): new units at list price minus the credit for this vehicle
	local cost = neuInfo.price * units - creditOf(useOf(e, cfg), job.alt)
	return { conf = conf, cost = cost, parts = partsOf(cfg) }
end

-- Sends one command; it counts as in flight until its callback, a throwing command gets no callback (#9).
-- The callback comes a frame after the command ran (api/tealdef/api/cmd.d.tl:2-10); a callback of a cancelled or
-- reloaded queue finds no matching inflight entry and does nothing. The queue is saved once the last answer of a
-- tick is in, not per answer. Returns false when the command could not be sent.
local function sendEntry(job, entry, checked, now)
	local e = entry.entity
	queue.inflight[e] = { job = job.id, sentAt = now, parts = checked.parts }
	queue.inflightN = queue.inflightN + 1
	local ok, err = pcall(api.cmd.sendCommand, api.cmd.makeVehicleReplaceCmd(e, checked.conf), function(__, success)
		local f = queue.inflight[e]
		if not f then return end
		settle(e)
		local j = jobById(f.job)
		local i = j and indexOf(j, e)
		if i then
			if success then
				finishEntry(j, i)
			else
				-- the game gives no reason (tf3-sdk knowledge/commands.md); it is not the money, that goes through
				log("queue: replace refused by the game", e)
				failEntry(j, i)
			end
		end
		if queue.inflightN == 0 then
			pruneJobs()
			writeSaveData()
		end
	end)
	if not ok then
		settle(e)
		log("queue: command not sent", e, tostring(err))
		failEntry(job, indexOf(job, e))
		return false
	end
	return true
end

-- No callback within INFLIGHT_TIMEOUT_S: the vehicle tells what happened. Other parts than when the command was
-- sent: it was replaced, the entry is done. Unchanged: the entry stays and is sent again by a later tick.
local function resolveInflight(now)
	local dirty = false
	for e, f in pairs(queue.inflight) do
		if now - f.sentAt > INFLIGHT_TIMEOUT_S then
			settle(e) -- assigning nil to a present field during pairs is allowed (Lua 5.2 manual, next)
			local j = jobById(f.job)
			local i = j and indexOf(j, e)
			if i then
				local ok, partsNow = pcall(function() return partsOf(api.engine.getComponent(e, CT.TRANSPORT_VEHICLE).transportVehicleConfig) end)
				local replaced = ok and partsNow ~= f.parts
				log("queue: no answer for vehicle", e, "after", INFLIGHT_TIMEOUT_S, "s, replaced:", tostring(replaced))
				if replaced then
					finishEntry(j, i)
					dirty = true
				end
			end
		end
	end
	if dirty then
		pruneJobs()
		writeSaveData()
	end
end

local function appTime()
	return api.util.getApplicationTime()
end

-- One tick. Per frame with nothing queued: a few Lua comparisons. Per frame with a queue: one getApplicationTime.
-- Per tick: one balance read; the head is validated (about ten native calls) only when the balance minus the
-- reserve reaches its last known net cost, which only rises as the residual value falls (user decision 20.10.2026).
-- Then, oldest first, every vehicle the money covers is checked and sent in this tick, up to SENDS_PER_TICK, and the
-- next tick waits until the game has answered all of them: only then does the balance show what they cost.
local function queueTick()
	ensureLoaded()
	if queue.paused or queue.foreign or queue.editor then return end
	local hasOpen = queue.inflightN > 0
	for __, j in ipairs(queue.jobs) do
		if hasOpen then break end
		hasOpen = #j.open > 0
	end
	if not hasOpen then return end
	local now = appTime()
	if now < queue.nextTick then return end
	queue.nextTick = now + TICK_S
	if queue.inflightN > 0 then
		resolveInflight(now)
		return
	end
	-- the window's own batch is still being answered: its vehicles still look unchanged (#9), so wait
	if pending() then return end
	local year = api.engine.util.getYear()
	local job = headJob(year)
	if not job then return end
	local funds, infinite = queueFunds()
	if funds == nil and not infinite then return end
	local spendable = funds and funds - queue.reserve or nil
	local c, head = queue.cache, job.open[1]
	if c and spendable and c.entity == head.entity and spendable < c.cost then
		job.cost, job.short = c.cost, c.cost - spendable
		return
	end
	local t = api.engine.getComponent(api.engine.util.getWorld(), CT.GAME_TIME).gameTime
	local dirty, drops, sends, i = false, 0, 0, 1
	while job and sends < SENDS_PER_TICK and drops < DROPS_PER_TICK do
		local entry = job.open[i]
		if not entry then
			job, i = headJob(year, job), 1
		else
			local checked, reason = checkHead(job, entry, t)
			if not checked then
				dropEntry(job, i, reason)
				drops, dirty = drops + 1, true
			elseif spendable and spendable < checked.cost then
				-- strictly oldest first: the money waits for this one, the jobs behind it wait too
				job.cost, job.short = checked.cost, checked.cost - spendable
				queue.cache = { entity = entry.entity, cost = checked.cost }
				break
			else
				job.cost, job.short = checked.cost, nil
				if spendable then spendable = spendable - checked.cost end
				sends = sends + 1
				-- a command that could not be sent stays in place, or was dropped after its third failure
				if sendEntry(job, entry, checked, now) then
					i = i + 1
				else
					dirty = true
					if job.open[i] == entry then i = i + 1 end
				end
			end
		end
	end
	if dirty then
		pruneJobs()
		writeSaveData()
	end
end

-- a Lua error in a tick never reaches the game's UI: logged, the next tick waits, after several in a row the
-- queue pauses itself and the window shows the error
local function tickFailed(err)
	queue.errors = queue.errors + 1
	queue.lastError = tostring(err)
	log("queue: error", tostring(err))
	queue.nextTick = appTime() + 10 * TICK_S
	if queue.errors >= ERRORS_TO_PAUSE and not queue.paused then
		queue.paused = true
		writeSaveData()
	end
end

local okEntry, mod_entry_point = pcall(ug_require, "::/gui/main/mod_entry_point.tl")
local MvrQueueHost = okEntry and type(mod_entry_point) == "table" and mod_entry_point.ModEntryPointExtension
	and react.RegisterPluginRecipe(mod_entry_point.ModEntryPointExtension, "MvrQueueHost", function()
		react.onMount(function()
			-- the host hangs below the game UI root (game.tl:73-96): mounted anew for every savegame, so the queue
			-- of the loaded game replaces whatever was in memory (plan 20.10.2026, probe 7.1)
			loadQueue()
			local okE, editor = pcall(function() return api.gui.game.isMapEditor() end)
			queue.editor = okE and editor == true
			log("queue host mounted, queued vehicles:", openCount(), "editor:", tostring(queue.editor))
		end)
		react.onStep(function()
			local ok, err = pcall(queueTick)
			if not ok then tickFailed(err) end
		end)
		-- a recipe must return a layout; this one shows nothing
		return builtin.BoxLayout{ children = {} }
	end) or nil
if not MvrQueueHost then log("mod entry point not available, queue host disabled") end

Queue.loadKept, Queue.ensureLoaded, Queue.writeSaveData, Queue.openCount, Queue.jobById = loadKept, ensureLoaded, writeSaveData, openCount, jobById
Queue.enqueue, Queue.removeJob, Queue.cancelAll, Queue.setReserve, Queue.setPaused = enqueue, removeJob, cancelAll, setReserve, setPaused
Queue.release = releaseReplaced
Queue.num, Queue.host, Queue.queuedNow = num, MvrQueueHost, queuedNow
end

-- Replaces alt with neu in every vehicle; the other parts stay as they are. partial: only the vehicles the balance
-- covers right now (#23), an explicit choice next to the disabled button; otherwise all or nothing. queueRest: the
-- vehicles the balance does not cover now are queued (affordable ones, if any, are replaced at once).
local function replaceAll(altKey, neuKey, partial, queueRest)
	local altInfo, neuInfo = info(altKey), info(neuKey)
	if pending() then return end
	if not (altInfo and neuInfo) or altInfo.class ~= neuInfo.class then return end
	-- the window may have stayed open over a year change; the replace command itself does not check
	-- availability (vehicle_react_util.tl HandleVehicleChanges), the game only filters its list
	if not available(neuInfo, api.engine.util.getYear()) then
		result.text = _("mvr_not_available")
		return
	end
	local t = api.engine.getComponent(api.engine.util.getWorld(), CT.GAME_TIME).gameTime
	-- partial: decided once, with the balance read now and a fresh fleet
	local only, total, rest = nil, nil, nil
	if partial or queueRest then
		local funds = balance()
		if funds == nil then return end -- infinite or unreadable money: the normal button covers it
		local e = fleet()[altKey]
		local part = { affordablePart(e, altKey, altInfo, neuInfo, funds) }
		local n, sorted = part[2], part[4]
		only = part[1]
		if n == 0 and not queueRest then
			result.text = _("mvr_not_enough_money")
			return
		end
		total = e and #e.uses or n
		if queueRest then
			-- the rest, oldest first; the vehicle the queue is replacing right now is already in the queue
			rest = {}
			for __, x in ipairs(sorted) do
				if not only[x.vehicle] and not queue.inflight[x.vehicle] then rest[#rest + 1] = x end
			end
		end
	end
	-- build all first: either every vehicle is replaced or none, like the purchase window
	local jobs, units = {}, 0
	for __, v in ipairs(ownVehicles()) do
		local tv = api.engine.getComponent(v, CT.TRANSPORT_VEHICLE)
		local cfg = tv and tv.transportVehicleConfig
		local conf, n = nil, 0
		-- a vehicle the queue has just sent a command for would be replaced twice
		local inflight = queue.inflight[v]
		if cfg and (only == nil or only[v]) and not inflight then conf, n = rebuild(cfg, altInfo, neuInfo, t) end
		if conf then
			jobs[#jobs + 1] = { entity = v, conf = conf }
			units = units + n
		end
	end
	-- checked again here: the balance may have changed since the window was drawn; residual value by the
	-- same rule as the window
	if not partial and not queueRest and not enoughMoney(neuInfo.price * units - residual(fleet()[altKey], altKey)) then
		result.text = _("mvr_not_enough_money")
		return
	end
	-- counters are reset only here, right before sending: a refused click leaves the previous batch alone
	local batch = result.batch
	result.sent, result.ok, result.failed, result.total = 0, 0, 0, total
	result.queued, result.note = 0, nil
	if rest then result.queued, result.note = Queue.enqueue(altKey, neuKey, rest) end
	-- the newest order wins: the vehicles replaced now leave the jobs they were queued in
	local direct = {}
	for k, job in ipairs(jobs) do direct[k] = job.entity end
	Queue.release(direct)
	for __, job in ipairs(jobs) do
		local entity = job.entity
		api.cmd.sendCommand(api.cmd.makeVehicleReplaceCmd(entity, job.conf), function(__, success)
			-- the window was closed and opened again meanwhile: this batch no longer counts
			if batch ~= result.batch then return end
			if success then
				result.ok = result.ok + 1
			else
				result.failed = result.failed + 1
				log("replace failed", entity)
			end
			updateText()
		end)
		-- counted only once it is really sent: a command that throws gets no callback, and counting it
		-- would leave the button disabled until the window is reopened
		result.sent = result.sent + 1
	end
	updateText()
end

-- Window ----------------------------------------------------------------------------------------------
-- Built from rows of fixed-width cells (classes in mass_vehicle_replace.css.lua):
--   vehicle type and sorting
--   [Old model]      [     ]  [New model]
--   [select list]    [arrow]  [select list]    <- arrow is centered on the lists
--   [large image]    [     ]  [large image]
--   count and purchase price             [Replace]
-- Fixed widths and heights: list, popup and window do not change size, whatever is selected.
-- styleutil.makeStyle only knows size, no minSize/maxSize/gravity/padding; so those are in classes.

local ITEM_NAME_CHARS = 42 -- longer names are shortened, full name as tooltip

local function text(s, class)
	return builtin.TextView{ meta = { class = class or "font-scale-body" }, text = s }
end

-- model names sometimes contain line breaks (name and livery); in the entry everything is on one line
local function oneLine(s)
	return (tostring(s or ""):gsub("%s*\n%s*", " "))
end

-- shortens by characters, not bytes, so umlauts stay intact
local function shorten(s, n)
	local chars = {}
	for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do chars[#chars + 1] = ch end
	if #chars <= n then return s, false end
	return table.concat(chars, "", 1, n - 1) .. "…", true
end

local function itemLine(s)
	local short, cut = shorten(oneLine(s), ITEM_NAME_CHARS)
	return builtin.TextView{
		meta = { class = "font-scale-annotation, mvr-item-text", tooltip = cut and oneLine(s) or nil },
		text = short,
	}
end

-- Cargo as its own row below image and text: fixed-size slots, always the same number, so all entries
-- are the same height. If not all cargo fits, the last slot shows "+n"; all names are in the tooltip.
-- Without cargo (locomotives) the row stays empty.
local CARGO_SLOTS = 16

local function cargoInfo(id)
	local c = cargoType(id)
	if not c then return nil, nil end
	return c.icon, c.name
end

local function cargoRow(cargos)
	cargos = cargos or {}
	local n = #cargos
	local show = n > CARGO_SLOTS and CARGO_SLOTS - 1 or n
	local slots, names = {}, {}
	for k = 1, CARGO_SLOTS do
		local icon = k <= show and cargoInfo(cargos[k]) or nil
		if icon and icon ~= "" then
			slots[k] = builtin.ImageView{ meta = { class = "mvr-cargo-icon", mouseTransparent = true }, path = icon, scaling = builtin.type.ImageViewScaling.AutoFit }
		elseif k == CARGO_SLOTS and n > CARGO_SLOTS then
			slots[k] = builtin.TextView{ meta = { class = "font-scale-annotation, mvr-cargo-icon, mvr-cargo-more" }, text = "+" .. (n - show) }
		else
			slots[k] = builtin.Component{ meta = { class = "mvr-cargo-icon" } }
		end
	end
	for k = 1, n do
		local __, name = cargoInfo(cargos[k])
		if name and name ~= "" then names[#names + 1] = name end
	end
	return builtin.Component{
		meta = { class = "mvr-cargo", tooltip = #names > 0 and table.concat(names, ", ") or nil },
		layout = builtin.BoxLayout{ orientation = builtin.type.Orientation.Horizontal, children = slots },
	}
end

-- Entry: small image on the left, name and second line on the right. Always two lines and an image slot of the
-- same size, even without an image; so all entries are the same size and neither list nor popup jumps.
-- The content must be a component, a layout alone crashes the game.
local function item(value, name, second, icon, cargos)
	local img = (icon and icon ~= "")
		and builtin.ImageView{ meta = { class = "mvr-item-image", mouseTransparent = true }, path = icon, scaling = builtin.type.ImageViewScaling.AutoFit }
		or builtin.Component{ meta = { class = "mvr-item-image" } }
	return builtin.ComboBoxItem{ value = value, content = builtin.Component{
		meta = { class = "mvr-item" },
		layout = builtin.BoxLayout{
			orientation = builtin.type.Orientation.Vertical,
			children = {
				builtin.BoxLayout{
					orientation = builtin.type.Orientation.Horizontal,
					children = {
						img,
						builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = { itemLine(name), itemLine(second or " ") } },
					},
				},
				cargoRow(cargos),
			},
		},
	} }
end

-- List with a placeholder as first entry while nothing is selected: the closed list shows it instead of becoming
-- empty and narrower. With a selection it is left out, or it stands as an empty or misleading first line in the open
-- list (game test 19.10.2026: "Keine Fahrzeuge dieser Art" above the vehicles).
local NONE = "none" -- not empty: the game may treat an empty value as no selection
-- content: short description of selection and entries. The game's list keeps its display when its
-- entries change (after replacing, the old model was still shown on the left, the new image already below it).
-- When content changes, the list gets a new localKey and is built afresh (like construction.tl).
local function combo(value, items, placeholder, onChange, content)
	local all = {}
	if value == nil then all[1] = item(NONE, placeholder, " ", nil) end
	for __, it in ipairs(items) do all[#all + 1] = it end
	return builtin.ComboBox{
		meta = { class = "mvr-combo", localKey = "combo:" .. tostring(value or NONE) .. "|" .. tostring(content or "") },
		value = value or NONE,
		items = all,
		onValueChange = function(v) if v ~= NONE then onChange(v) end end,
	}
end

-- fixed-width cell; kind "cell" for the columns, "mid" for the narrow middle
local function cell(kind, child)
	return builtin.Component{
		meta = { class = kind == "mid" and "mvr-mid" or "mvr-cell" },
		layout = builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = { child } },
	}
end

local function row(children)
	return builtin.BoxLayout{ orientation = builtin.type.Orientation.Horizontal, children = children }
end

local function empty()
	return builtin.Component{}
end

-- large image of the selected model in a fixed area; without a model the area stays empty
local function bigPicture(i)
	if i and i.iconBig and i.iconBig ~= "" then
		return builtin.ImageView{ meta = { class = "mvr-big-image", tooltip = oneLine(i.name) }, path = i.iconBig, scaling = builtin.type.ImageViewScaling.AutoFit }
	end
	return builtin.Component{ meta = { class = "mvr-big-image" } }
end

-- Vehicle stats (#16) ---------------------------------------------------------------------------------
-- Collapsible "Details" card below the window, expanded by default. Values come from the purchase window's own
-- data collection: vehicle_store_util.makeVehicleData(repId, isMultipleUnit) (vehicle_store_util.tl:785-797) sums
-- or picks per part like the store (collectVehicleData, vehicle_store_util.tl:122-391), so a multiple unit counts
-- as the whole unit, like in the store. Model metadata does not change during a game, so each model is read once;
-- the card's body is only built while it is expanded (content_card.tl:362-386), so collapsed costs nothing.
local statsCache = {} -- key -> VehicleData, or false when unreadable

local function statsOf(i)
	if not (i and okStore and type(vehicle_store_util) == "table") then return nil end
	local c = statsCache[i.key]
	if c == nil then
		local ok, d = pcall(vehicle_store_util.makeVehicleData, i.id, i.mu == true)
		c = (ok and d) or false
		if not ok then log("stats unreadable", tostring(i.key), tostring(d)) end
		statsCache[i.key] = c
	end
	return c or nil
end

-- a field of the game's data that can be shown: a finite number (speed is math.huge without parts)
local function statValue(d, field)
	if not d then return nil end
	local ok, v = pcall(function() return d[field] end)
	if ok and type(v) == "number" and v == v and v > -math.huge and v < math.huge then return v end
	return nil
end

-- like mathutil.mapClamp, which the store uses for its bars (vehicle_store_window.tl:574-588)
local function mapClamp(v, a, b, lo, hi)
	if b == a then return lo end
	local t = math.max(0, math.min(1, (v - a) / (b - a)))
	return lo + t * (hi - lo)
end

local function formatted(fn, v)
	local ok, s = pcall(fn, v)
	if ok and type(s) == "string" then return s end
	return string.format("%.0f", v)
end

-- the units the store uses for each stat (vehicle_store_window.tl:497-623, 117-124)
local function fmtSpeed(v) return formatted(function(x) return api.util.formatSpeed(x) end, v) end
local function fmtPower(v) return formatted(function(x) return api.util.formatPower(x) end, v) end
local function fmtForce(v) return formatted(function(x) return api.util.formatForce(x) end, v) end
local function fmtWeight(v) return formatted(function(x) return api.util.formatWeight(x) end, v) end
local function fmtLoad(v) return string.format("%.1fx", v) end
local function fmtCount(v) return string.format("%.0f", v) end

-- Rows in the order of the store. higher: true if a higher value is better. optional: the row only shows if one of
-- the two models has a value above 0 (the store hides tractive effort, thrust and power the same way).
-- rating: shown as a word ("Good") from the carrier's range for the current year, like the store's noise,
-- pollution and comfort (vehicle_store_window.tl:552-598, vehicle_store_util.tl:393-406); inverted for emissions.
local STATS = {
	{ label = "mvr_stat_capacity", field = "totalCapacity", fmt = fmtCount, higher = true, optional = true },
	{ label = "mvr_stat_speed", field = "speed", fmt = fmtSpeed, higher = true },
	{ label = "mvr_stat_loading", field = "loadingSpeed", fmt = fmtLoad, higher = true, optional = true },
	{ label = "mvr_stat_power", field = "power", fmt = fmtPower, higher = true, optional = true },
	{ label = "mvr_stat_tractive", field = "tractiveEffort", fmt = fmtForce, higher = true, optional = true },
	{ label = "mvr_stat_thrust", field = "thrust", fmt = fmtForce, higher = true, optional = true },
	{ label = "mvr_stat_weight", field = "weight", fmt = fmtWeight, higher = false },
	{ label = "mvr_stat_running", field = "runningCosts", fmt = function(v) return money(v) end, higher = false },
	{ label = "mvr_stat_noise", field = "noise", rating = "noiseScoreRange", inverted = true },
	{ label = "mvr_stat_pollution", field = "pollution", rating = "pollutionScoreRange", inverted = true },
	{ label = "mvr_stat_comfort", field = "comfortFactor", rating = "comfortScoreRange", optional = true },
}

-- like the store's formatDelta (vehicle_store_window.tl:24-32, local there): "+" or "-" and the formatted
-- difference; the value itself when equal as shown (user decision 19.10.2026, like the store)
local function delta(new, old, fmt)
	if fmt(new) == fmt(old) then return fmt(new) end
	if new > old then return "+" .. fmt(new - old) end
	return "-" .. fmt(old - new)
end

-- the carrier's ranges for the rating words; the store passes its carrier and year (vehicle_store_window.tl:1773-1777)
local function rangesFor(d, carrier, year)
	if not (d and carrier ~= nil) then return nil end
	local ok, r = pcall(vehicle_store_util.getRangesFromData, d, carrier, year)
	return ok and r or nil
end

local function ratingOf(v, ranges, s)
	if v == nil or not ranges then return nil end
	local ok, pct = pcall(function()
		local r = ranges[s.rating]
		if s.inverted then return mapClamp(v, r[1], r[2], 1, 0) end
		return mapClamp(v, r[1], r[2], 0, 1)
	end)
	if not ok or type(pct) ~= "number" then return nil end
	local okText, word = pcall(vehicle_store_util.goodnessToTextString, pct)
	return pct, okText and type(word) == "string" and word or nil
end

-- one row: { label, old, new, change, better }; better: true, false or nil (equal or not comparable)
local function statRow(s, oldData, newData, ranges)
	local o, n = statValue(oldData, s.field), statValue(newData, s.field)
	if s.optional and not ((o or 0) > 0 or (n or 0) > 0) then return nil end
	if o == nil and n == nil then return nil end
	if s.rating then
		local po, wo = ratingOf(o, ranges, s)
		local pn, wn = ratingOf(n, ranges, s)
		if not (wo or wn) then return nil end
		-- colored only when the words differ: the same word on both sides reads as equal (game test 19.10.2026)
		local better = nil
		if po and pn and wo ~= wn then better = pn > po end
		return { label = _(s.label), old = wo or "-", new = wn or "-", change = "", better = better }
	end
	local better, change = nil, ""
	-- equal as shown (the formatted values match): the value without color, not "+0 kN" in red
	if o and n then
		change = delta(n, o, s.fmt)
		if s.fmt(n) ~= s.fmt(o) then better = (n > o) == s.higher end
	end
	return { label = _(s.label), old = o and s.fmt(o) or "-", new = n and s.fmt(n) or "-", change = change, better = better }
end

-- rows for the selected models; carrier from the fleet (the vehicle component's carrier, like the store's)
local function statRows(altInfo, neuInfo, carrier, year)
	local oldData, newData = statsOf(altInfo), statsOf(neuInfo)
	if not (oldData or newData) then return {} end
	-- one range for both, like the store's comparison (both bars on the ranges of the shown vehicle)
	local ranges = rangesFor(newData or oldData, carrier, year)
	local rows = {}
	for __, s in ipairs(STATS) do
		local ok, r = pcall(statRow, s, oldData, newData, ranges)
		if ok and r then rows[#rows + 1] = r elseif not ok then log("stat row failed", s.label, tostring(r)) end
	end
	return rows
end

local function statCell(s, class)
	return builtin.TextView{ meta = { class = class }, text = s }
end

-- half of the table: header and rows in a TableLayout (columns label, change, old, new; the change first as the
-- most important column, user decision 19.10.2026)
local function statTable(rows)
	local ANN = "font-scale-annotation"
	local list = { builtin.Row{ cells = {
		statCell(" ", ANN), statCell(_("mvr_stat_change"), ANN), statCell(_("mvr_stat_old"), ANN), statCell(_("mvr_stat_new"), ANN),
	} } }
	for __, r in ipairs(rows) do
		-- the game's global text colors for better and worse (default.css.lua "!positive", "!negative")
		-- old and new each show whether they are the better or the worse one (user decision 19.10.2026); the change
		-- takes the color of the new value
		local mark = r.better == true and ", positive" or r.better == false and ", negative" or ""
		local markOld = r.better == true and ", negative" or r.better == false and ", positive" or ""
		list[#list + 1] = builtin.Row{ cells = {
			statCell(r.label, "font-scale-body"),
			statCell(r.change, "font-scale-body" .. (r.change ~= "" and mark or "")),
			statCell(r.old, "font-scale-body" .. markOld),
			statCell(r.new, "font-scale-body" .. mark),
		} }
	end
	return builtin.Component{
		meta = { class = "mvr-stats-half" },
		layout = builtin.TableLayout{ meta = { class = "mvr-stats" }, columnWeights = { 3, 2, 2, 2 }, rows = list },
	}
end

-- body of the card: two halves side by side, like the store's stats table (left and right column), so the
-- expanded card stays about half as tall
local MvrStats = react.RegisterRecipe("MvrStats", function(p)
	local rows = statRows(p.alt, p.neu, p.carrier, p.year)
	if #rows == 0 then
		return builtin.BoxLayout{ children = { text(_("mvr_stat_none")) } }
	end
	local half = math.ceil(#rows / 2)
	local left, right = {}, {}
	for k, r in ipairs(rows) do
		if k <= half then left[#left + 1] = r else right[#right + 1] = r end
	end
	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Horizontal,
		children = { statTable(left), builtin.Component{ meta = { class = "mvr-mid" } }, statTable(right) },
	}
end)

-- the card itself; nil without the game's card module or without an old model
local function detailsCard(altInfo, neuInfo, carrier, year, expanded, setExpanded)
	if not (altInfo and okCard and type(content_card) == "table" and okStore and type(vehicle_store_util) == "table") then return nil end
	return builtin.BoxLayout{ child = content_card.ContentCard{
		title = _("mvr_details"),
		recipeAndParamCollapsible = content_card.makeRecipeAndParam(MvrStats, { alt = altInfo, neu = neuInfo, carrier = carrier, year = year }),
		collapsibleExpanded = expanded,
		setCollapsibleExpanded = setExpanded,
	} }
end

-- vehicle types with the icons of the vehicle management; nil = all
local CARRIERS = {}
for __, c in ipairs({
	{ key = "ROAD", icon = "::/gui/line_vehicle_mgmt/icons/vehicle_bus_18.tga", tooltip = "mvr_carrier_road" },
	{ key = "TRAM", icon = "::/gui/line_vehicle_mgmt/icons/vehicle_tram_18.tga", tooltip = "mvr_carrier_tram" },
	{ key = "RAIL", icon = "::/gui/line_vehicle_mgmt/icons/vehicle_train_18.tga", tooltip = "mvr_carrier_rail" },
	{ key = "WATER", icon = "::/gui/line_vehicle_mgmt/icons/vehicle_ship_18.tga", tooltip = "mvr_carrier_water" },
	{ key = "AIR", icon = "::/gui/line_vehicle_mgmt/icons/vehicle_airplane_18.tga", tooltip = "mvr_carrier_air" },
}) do
	local ok, v = pcall(function() return api.type["enum"].Carrier[c.key] end)
	if ok and v ~= nil then c.value = v; CARRIERS[#CARRIERS + 1] = c end
end

local okRail, RAIL = pcall(function() return api.type["enum"].Carrier.RAIL end)
if not okRail then RAIL = nil end

-- Vehicle type of a depot. The carrier field is sometimes empty in the game (log: nil); then from the transport
-- modes of the depot, last from the vehicles standing in it right now.
local MODE_TO_CARRIER = {
	CAR = "ROAD", BUS = "ROAD", TRUCK = "ROAD",
	TRAM = "TRAM", ELECTRIC_TRAM = "TRAM", TRAM_TRACK = "TRAM", ELECTRIC_TRAM_TRACK = "TRAM",
	TRAIN = "RAIL", ELECTRIC_TRAIN = "RAIL",
	SHIP = "WATER", SMALL_SHIP = "WATER",
	AIRCRAFT = "AIR", SMALL_AIRCRAFT = "AIR", HELICOPTER = "AIR",
}

local function enumValue(group, key)
	local ok, v = pcall(function() return api.type["enum"][group][key] end)
	return ok and v or nil
end

local function depotCarrier(depot)
	if not depot then return nil end
	local ok, d = pcall(api.engine.getComponent, depot, CT.VEHICLE_DEPOT)
	if not ok or not d then log("depot without VehicleDepot", tostring(depot), tostring(d)); return nil end
	local okC, c = pcall(function() return d.carrier end)
	if okC and c ~= nil then return c end
	-- transport modes: unambiguous if they all belong to the same vehicle type
	local found = nil
	pcall(function()
		for mode, enabled in pairs(d.transportModes) do
			if enabled then
				for key, carrierKey in pairs(MODE_TO_CARRIER) do
					if enumValue("TransportMode", key) == mode then
						local v = enumValue("Carrier", carrierKey)
						if found == nil then found = v elseif found ~= v then found = false end
					end
				end
			end
		end
	end)
	if found then return found end
	-- vehicles in the depot
	local okV, list = pcall(api.engine.system.transportVehicleSystem.getDepotVehicles, depot)
	if okV and list then
		for __, v in ipairs(list) do
			local tv = api.engine.getComponent(v, CT.TRANSPORT_VEHICLE)
			if tv and tv.carrier ~= nil then return tv.carrier end
		end
	end
	return nil
end

-- Sorting ---------------------------------------------------------------------------------------------
-- "name": alphabetical, numbers by their value (BR 50 before BR 103), ignoring case.
-- "year": by year of introduction, oldest first, same year by name.
-- In the list of old models both put the powered vehicles first, then the wagons.

local function naturalKey(s)
	-- pad digit runs as text: %d on tonumber(d) fails for runs of 19 or more digits
	local key = oneLine(s):lower():gsub("%d+", function(d)
		d = d:gsub("^0+(%d)", "%1")
		return string.rep("0", 20 - #d) .. d
	end)
	return key
end

-- ascending: A to Z or oldest first. Equal years go by name A to Z.
local function compareModels(a, b, sort, ascending)
	if sort == "year" and a.yearFrom ~= b.yearFrom then
		if ascending then return a.yearFrom < b.yearFrom end
		return a.yearFrom > b.yearFrom
	end
	local ka, kb = naturalKey(a.name), naturalKey(b.name)
	if ka ~= kb then
		if sort == "name" and not ascending then return ka > kb end
		return ka < kb
	end
	return a.key < b.key
end

local SORTS = { { key = "name", label = "mvr_sort_name" }, { key = "year", label = "mvr_sort_year" } }

local function topBar(update)
	local children = {}
	for __, c in ipairs(CARRIERS) do
		children[#children + 1] = builtin.ToggleButton{
			meta = { class = "mvr-filter", tooltip = _(c.tooltip) },
			content = builtin.ImageView{ meta = { class = "mvr-filter-icon" }, path = c.icon, scaling = builtin.type.ImageViewScaling.AutoFit },
			value = sel.carrier == c.value and 1 or 0,
			onValueChange = function(v)
				update(function()
					sel.carrier = v == 1 and c.value or nil
					sel.alt, sel.neu = nil, nil
				end)
			end,
		}
	end
	children[#children + 1] = gui_react_util.makeHorizontalSpacer()
	-- cargo filter can be switched off: on = on the right only models that can load everything the old one could
	children[#children + 1] = builtin.ToggleButton{
		meta = { class = "mvr-cargo-filter", tooltip = _("mvr_same_cargo_tip") },
		content = text(_("mvr_same_cargo"), "font-scale-annotation"),
		value = sel.sameCargo and 1 or 0,
		onValueChange = function(v) update(function() sel.sameCargo = v == 1; Queue.writeSaveData() end) end,
	}
	return row(children)
end

-- heading of one list with its own sort buttons on the right; field is "sortOld" or "sortNew"
-- Direction per list (user decision 19.10.2026): a click on the active button turns it round, a click on the other
-- one starts in the list's own direction: the old list oldest first (those are the ones to replace), the new list
-- newest first; by name A to Z on both. The active button shows the direction with the purchase window's icons
-- (vehicle_store_window.tl:2016-2017, 2090-2099).
local SORT_ICON = { [true] = "::/gui/line_vehicle_mgmt/icons/sorting_bars_ascending.tga",
	[false] = "::/gui/line_vehicle_mgmt/icons/sorting_bars_descending.tga" }
local function defaultAscending(sortKey, field)
	return not (sortKey == "year" and field == "sortNew")
end

local function listHead(label, field, update)
	local ascField = field .. "Asc"
	local children = { text(label), gui_react_util.makeHorizontalSpacer() }
	for __, s in ipairs(SORTS) do
		local active = sel[field] == s.key
		local content = text(_(s.label), "font-scale-annotation")
		if active then
			content = row({ content, builtin.ImageView{ meta = { class = "mvr-sort-icon" }, path = SORT_ICON[sel[ascField] ~= false],
				scaling = builtin.type.ImageViewScaling.AutoFit } })
		end
		children[#children + 1] = builtin.ToggleButton{
			meta = { class = "mvr-sort" },
			content = content,
			value = active and 1 or 0,
			onValueChange = function()
				update(function()
					if sel[field] == s.key then
						sel[ascField] = sel[ascField] == false
					else
						sel[field], sel[ascField] = s.key, defaultAscending(s.key, field)
					end
					Queue.writeSaveData()
				end)
			end,
		}
	end
	return row(children)
end

-- a text button the way the game makes them (button_react_util.makeTextButton, 5th argument = disabled); the same
-- shape by hand should the module be missing
local function textButton(class, label, onClick, tooltip, disabled)
	if button_react_util and button_react_util.makeTextButton then
		return button_react_util.makeTextButton(class, label, onClick, tooltip, disabled)
	end
	return builtin.Button{ meta = { class = class, tooltip = tooltip, enabled = not disabled }, content = text(label), onClick = onClick }
end

local queueContent -- the recipe of the orders tab, defined with it below

local MvrContent = react.RegisterRecipe("MvrContent", function(p)
	react.useInputAction("IA_MENU_BACK", react.iaHandler(p.onClose))
	-- counter only for redrawing; the selection itself is in sel
	local tick = react.useState(0)
	local function update(change)
		change()
		tick:set(tick:old() + 1)
	end
	local resultState = engine_react_util.useStepState(function() return result.text end)

	-- redraw when the player's vehicles change; the fleet itself is built again only then (#10)
	local byKey = windowFleet(engine_react_util.useStepState(fleetSig):old())
	-- redraw at a year change, so models that expire or appear update while the window is open
	engine_react_util.useStepState(function() return api.engine.util.getYear() end)
	local year = api.engine.util.getYear()
	local carrier = sel.carrier

	-- alt: everything in the game right now (single models and multiple units), limited to the selected vehicle type
	local alts = {}
	for key, e in pairs(byKey) do
		local i = info(key)
		-- the window ignores dummies (without engine and cargo) entirely; in a train they stay in place during the swap
		if i and i.class ~= "dummy" and (carrier == nil or e.carrier == carrier) then alts[#alts + 1] = { i = i, e = e } end
	end
	-- multiple units first, then powered vehicles, then wagons
	local RANK = { self = 0, loco = 1, wagon = 2 }
	local function rank(i) return RANK[i.class] or 4 end
	table.sort(alts, function(a, b)
		if rank(a.i) ~= rank(b.i) then return rank(a.i) < rank(b.i) end
		return compareModels(a.i, b.i, sel.sortOld, sel.sortOldAsc ~= false)
	end)

	local altInfo = sel.alt and byKey[sel.alt] and info(sel.alt) or nil
	if altInfo and carrier ~= nil and byKey[altInfo.key].carrier ~= carrier then altInfo = nil end
	if not altInfo and alts[1] then altInfo = alts[1].i end

	-- neu fits alt: same vehicle type, same class, and neu can load at least every cargo alt could
	local altCargo = {}
	for __, c in ipairs(altInfo and altInfo.cargos or {}) do altCargo[#altCargo + 1] = c end
	local function carriesAll(i)
		local has = {}
		for __, c in ipairs(i.cargos or {}) do has[c] = true end
		for __, c in ipairs(altCargo) do if not has[c] then return false end end
		return true
	end
	local function fits(i)
		return altInfo and i.key ~= altInfo.key and i.carrier == altInfo.carrier and i.class == altInfo.class and (not sel.sameCargo or carriesAll(i))
	end
	local neus = {}
	if altInfo then
		for __, i in pairs(buildCatalog()) do
			-- like the purchase list: without filterTags not for sale (vehicle_store_util.depotMatchesVehicleFilterTags),
			-- e.g. decoration copies from other mods without an image; group heads and multiple unit parts neither
			if i and not i.noTags and not i.muPart and fits(i) and available(i, year) then neus[#neus + 1] = i end
		end
	end
	table.sort(neus, function(a, b) return compareModels(a, b, sel.sortNew, sel.sortNewAsc ~= false) end)

	local neuInfo = sel.neu and info(sel.neu) or nil
	if neuInfo and not (fits(neuInfo) and available(neuInfo, year)) then neuInfo = nil end
	-- nothing chosen yet: the top model, like the old list (user decision 19.10.2026), so the list shows no empty
	-- placeholder line; replacing still needs the click. Not while the result of the last batch is shown: it stands in
	-- the summary until a model is chosen (below), and a preselected model would hide it
	if not neuInfo and neus[1] and result.text == "" then neuInfo = neus[1] end

	local altItems = {}
	for k, x in ipairs(alts) do
		local second = count("mvr_n_vehicles", x.e.vehicles)
		if x.i.mu then
			-- multiple units: number of units, with multiple traction also the number of trains
			second = count("mvr_n_mus", x.e.parts)
			if x.e.parts ~= x.e.vehicles then second = second .. " " .. count("mvr_in_trains", x.e.vehicles) end
		elseif x.e.parts ~= x.e.vehicles and x.e.carrier == RAIL then
			-- wagons and locomotives often occur several times in one train: piece count and number of trains
			second = count(x.i.engine and "mvr_n_locos" or "mvr_n_wagons", x.e.parts) .. " " .. count("mvr_in_trains", x.e.vehicles)
		end
		altItems[k] = item(x.i.key, x.i.name, second, x.i.icon, x.i.cargos)
	end
	local neuItems = {}
	for k, i in ipairs(neus) do
		local second = money(i.price)
		if i.yearFrom > 0 then second = second .. " · " .. tostring(i.yearFrom) end
		-- multiple units of the same name come in several lengths
		if i.mu then second = second .. " · " .. count("mvr_n_parts", #i.parts) end
		neuItems[k] = item(i.key, i.name, second, i.icon, i.cargos)
	end

	-- without a new model the space stays empty; two lines so nothing jumps
	local summary = { " ", " " }
	local e = altInfo and byKey[altInfo.key]
	local price = e and neuInfo and neuInfo.price * e.parts or 0
	-- with infinite money no cost line (#20), so no residual values are read either
	local free = infiniteMoney()
	shown.price, shown.e, shown.key, shown.time = price, (e and neuInfo and not free) and e or nil, altInfo and altInfo.key, nil
	-- redraw when the cost changes while the game runs. Twice a second, not every step: shownCost reads the residual
	-- value of every vehicle that would be replaced (1450 trucks in a game test, 18.10.2026), and residual values
	-- drop slowly. useStepStateTimer is the game's own timed step state (engine_react_util.tl:126-157, 0.5 s).
	engine_react_util.useStepStateTimer(shownCost, 0.5)
	local cost = shownCost()
	local refund = price - cost
	-- the check below reads the balance now; this state only redraws the window when that answer changes
	engine_react_util.useStepStateTimer(function() return enoughMoney(shownCost()) end, 0.5)
	local affordable = enoughMoney(cost)
	-- not enough for all (#23): how many the balance covers, oldest first. Read when drawing (like the cost line, so
	-- a new selection never shows the number of the last one); the timer only redraws when it changes, twice a second
	local function someCount()
		if not (shown.e and neuInfo) or enoughMoney(shownCost()) then return 0, 0 end
		local funds = balance()
		if funds == nil then return 0, 0 end
		local __, n, sum = affordablePart(shown.e, shown.key, altInfo, neuInfo, funds)
		return n, sum
	end
	engine_react_util.useStepStateTimer(function() return (someCount()) end, 0.5)
	local some, someCost = 0, 0
	if not affordable and e and neuInfo then some, someCost = someCount() end
	-- the button itself says "2 of 8" then (user decision 18.10.2026: no extra element, the label tells it)
	local partial = some > 0
	-- the rest can be queued when the money does not cover all and can be counted (not infinite, not unreadable);
	-- with nothing affordable and the box ticked the button queues everything (replacement queue)
	local canQueue = (e and neuInfo and not affordable and not free and balance() ~= nil) == true
	local queueAll = canQueue and not partial and sel.queueRest == true
	-- redraw when the last callback of a batch arrives, so the button comes back
	engine_react_util.useStepState(pending)
	local busy = pending()
	if e and neuInfo then
		-- like the game, which shows only the net cost; the purchase price as long as nothing is credited
		local priceLine = refund ~= 0 and netLine(cost) or tr("mvr_price", money(price))
		if free then priceLine = " " end
		summary = { count("mvr_will_replace", e.vehicles), priceLine }
		-- partial (#23): what the button does, so count, cost and label agree
		if partial then summary = { count("mvr_will_replace", some), netLine(someCost) } end
	elseif #neus == 0 and altInfo then
		summary = { _("mvr_none_buyable"), " " }
	elseif not altInfo then
		summary = { _("mvr_no_vehicles"), " " }
	end
	-- the result of the last replacement stays in the same place until a new model is selected
	if not neuInfo and resultState:old() ~= "" then summary = { resultState:old(), " " } end

	local altContent, neuContent = {}, {}
	for k, x in ipairs(alts) do altContent[k] = x.i.key .. ":" .. x.e.parts .. ":" .. x.e.vehicles end
	for k, i in ipairs(neus) do neuContent[k] = i.key end
	neuContent[#neuContent + 1] = sel.sameCargo and "fracht" or "alle"
	local altCombo = combo(altInfo and altInfo.key, altItems, _("mvr_no_vehicles"), function(v)
		update(function() sel.alt, sel.neu = v, nil; result.text = "" end)
	end, table.concat(altContent, ","))
	local neuCombo = combo(neuInfo and neuInfo.key, neuItems,
		#neuItems > 0 and " " or _("mvr_no_model"),
		function(v) update(function() sel.neu = v; result.text = "" end) end, table.concat(neuContent, ","))

	local swap = builtin.ImageView{
		meta = { class = "mvr-swap" },
		path = "::/gui/line_vehicle_mgmt/icons/symbol_arrows_refresh.tga",
		scaling = builtin.type.ImageViewScaling.AutoFit,
	}

	local button = builtin.Button{
		-- like the purchase window: disabled, red (mass_vehicle_replace.css.lua), labelled and with tooltip when the money is not enough
		-- not enough for all but for some (#23): enabled, labelled "2 of 8", tooltip explains which ones
		meta = {
			class = "primary, mvr-replace-btn" .. (affordable and "" or (partial or queueAll) and ", mvr-partial" or ", mvr-no-money"),
			-- disabled while the previous batch is still being replaced (issue #9)
			enabled = (affordable or partial or queueAll) and not busy,
			tooltip = partial and (some == 1 and tr("mvr_replace_some_tip_1", e.vehicles)
				or tr("mvr_replace_some_tip", some, e.vehicles)) or queueAll and _("mvr_queue_rest_tip")
				or not affordable and _("mvr_not_enough_money") or nil,
		},
		content = builtin.Component{
			layout = builtin.BoxLayout{
				orientation = builtin.type.Orientation.Horizontal,
				children = {
					builtin.ImageView{ meta = { class = "mvr-btn-icon" }, path = "::/gui/entity_window/icons/symbol_arrows_refresh.tga", scaling = builtin.type.ImageViewScaling.AutoFit },
					text(busy and _("mvr_replacing") or partial and tr("mvr_replace_some", some, e.vehicles)
						or queueAll and count("mvr_queue_all", e.vehicles)
						or not affordable and _("mvr_not_enough_money") or _("mvr_replace")),
				},
			},
		},
		onClick = function()
			if not (altInfo and neuInfo) then return end
			local ok, err = pcall(replaceAll, altInfo.key, neuInfo.key, partial, canQueue and sel.queueRest == true)
			if not ok then
				result.text = _("mvr_error") .. " " .. tostring(err)
				log("error", tostring(err))
			end
			-- clear the selection: the result is now shown below
			update(function() sel.alt, sel.neu = nil, nil end)
		end,
	}

	-- The summary lines fill the height of the button and the box beside them: the first line level with the top of
	-- the button, the last visible line level with the bottom of the box, the rest spread between them (user decision
	-- 20.10.2026: they ended at different heights). The warning when the engine type changes (issue #50) is a line of
	-- its own in the game's warning colour (class warning, main/default.css.lua), only when there is one.
	local engineWarning = e and engineChange(altInfo, neuInfo) or nil
	local shownLines = {}
	for __, line in ipairs(summary) do
		if line ~= " " then shownLines[#shownLines + 1] = text(line) end
	end
	if engineWarning then
		shownLines[#shownLines + 1] = builtin.TextView{ meta = { class = "font-scale-body, warning", tooltip = _("mvr_engine_change_tip") },
			text = engineWarning }
	end
	local summaryLines = {}
	for k, line in ipairs(shownLines) do
		if k > 1 then summaryLines[#summaryLines + 1] = gui_react_util.makeVerticalSpacer() end
		summaryLines[#summaryLines + 1] = line
	end

	-- orders: "order the rest" box under the replace button while the money does not cover all (user decision
	-- 20.10.2026); the orders themselves are in the second tab of the window
	-- without a box its place stays, so the button keeps its height and the window does not jump
	-- build only the node that is shown: a node built and not attached makes the game warn "Preserved props ... a
	-- recipe was called but not attached to the tree" on every redraw (game log 20.10.2026)
	local queueBox
	if canQueue then
		queueBox = builtin.CheckBox{
			meta = { tooltip = _("mvr_queue_rest_tip") },
			label = count("mvr_queue_rest", e.vehicles - some),
			value = sel.queueRest and 1 or 0,
			onValueChange = function(v) update(function() sel.queueRest = v == 1; Queue.writeSaveData() end) end,
		}
	else
		queueBox = builtin.Component{ meta = { class = "mvr-box-slot" } }
	end


	local children = {
		topBar(update),
		row({ cell("cell", listHead(_("mvr_old_model"), "sortOld", update)), cell("mid", empty()),
			cell("cell", listHead(_("mvr_new_model"), "sortNew", update)) }),
		row({ cell("cell", altCombo), cell("mid", swap), cell("cell", neuCombo) }),
		row({ cell("cell", bigPicture(altInfo)), cell("mid", empty()), cell("cell", bigPicture(neuInfo)) }),
		-- gap between images and text; the button stays centered on the text block
		builtin.Component{ meta = { class = "mvr-gap" } },
		row({
			builtin.BoxLayout{ meta = { class = "mvr-summary" }, orientation = builtin.type.Orientation.Vertical, children = summaryLines },
			gui_react_util.makeHorizontalSpacer(),
			builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = { button, queueBox } },
		}),
		-- room between the order box under the button and the details (game test 20.10.2026: the box touched them)
		builtin.Component{ meta = { class = "mvr-gap" } },
	}
	-- stats of both models below the button (#16): collapsed it adds only a title and the game's arrow bar
	local details = detailsCard(altInfo, neuInfo, e and e.carrier, year, sel.details == true,
		function(v) update(function() sel.details = v == true; Queue.writeSaveData() end) end)
	if details then children[#children + 1] = details end

	-- a recipe must return a layout, not a component
	return builtin.BoxLayout{ children = {
		builtin.Component{
			meta = { class = "mvr-content" }, -- the fixed width comes from the cells
			layout = builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = children },
		},
	} }
end)

local windowOpen = false

-- Two tabs, "Replace" and "Orders (n)" (user decision 20.10.2026), built like the game's entity windows with several
-- parts (make_entity_window.tl:220-250: TabWidget of class no-content, empty items, the content follows the selected
-- tab). They sit at the top of the content, below the title: as the window's header they took the title's place
-- and cut it to "Mass Veh" (game test 20.10.2026).
local function tabs(tabState, n, replaceContent, ordersContent)
	-- Each tab keeps the same content node, like the game's own tabs (town.tl:1296-1330: both items always built).
	-- Swapping an item between a placeholder and the content crashed the game when the tab changed (game test
	-- 20.10.2026, react_transform.cpp:183 "Assertion (oldNode->recipeId)==(newNode.recipeId)", MvrQueueContent).
	local function tab(value, label, content)
		return builtin.TabWidgetChild{
			localKey = "mvr_tab_" .. value,
			value = value,
			indicator = builtin.TextView{ meta = { class = "font-scale-tab-widget-indicator" }, text = label },
			item = content,
		}
	end
	-- the game's own tab look, the tabs joined to a framed content (builtin.css.lua:969-984, like its statistics and
	-- purchase windows); with "no-content" the tabs ended in nothing (game test 20.10.2026)
	return builtin.TabWidget{
		orientation = builtin.type.TabOrientation.North,
		deselectAllowed = false,
		value = tabState:old(),
		onValueChange = function(v) tabState:set(v) end,
		tabs = {
			tab(0, _("mvr_tab_replace"), replaceContent),
			tab(1, n > 0 and tr("mvr_tab_orders_n", n) or _("mvr_tab_orders"), ordersContent),
		},
	}
end

local MvrWindow = react.RegisterWrapperRecipe("MvrWindow", builtin.Window, function(p)
	local tabState = react.useState(0)
	-- the count in the tab: two Lua numbers from memory, redrawn only when it changes
	local countState = engine_react_util.useStepStateTimer(Queue.queuedNow, 0.5)
	-- the orders tab is always built (see tabs); it reads prices only while it is the one shown
	Queue.ordersShown = tabState:old() == 1
	react.onUnmount(function()
		Queue.ordersShown = false
		windowOpen = false
		-- the fleet holds a copy of every vehicle's parts; the next window reads it afresh anyway (#10)
		cachedFleet.byKey, cachedFleet.parts, cachedFleet.sig = nil, nil, nil
	end)
	return builtin.Window{
		meta = { class = "mvr-window" },
		id = "mass_vehicle_replace.window",
		-- 0 to 1 across the screen like the game's centered windows (main_page 0.5/0.5);
		-- it is only centered with the anchor of the CSS class mvr-window
		initialX = 0.5,
		initialY = 0.5,
		title = _("mvr_title"),
		onClose = p.onClose,
		closable = true,
		movable = true,
		autoFocusOnBecomingVisible = true,
		content = queueContent and tabs(tabState, countState:old() or 0, MvrContent{ onClose = p.onClose },
				queueContent{ onClose = p.onClose })
			or MvrContent{ onClose = p.onClose },
	}
end)

local function windowApi()
	return okGlobals and game_react_globals.getDefaultWindowApi() or nil
end
local function closeWindow()
	windowOpen = false
	local wc = windowApi()
	if wc then pcall(wc.removeWindow, MvrWindow, WINDOW_KEY) end
end
-- carrier: vehicle type the window is set to when it opens (nil = all)
local function openWindow(carrier)
	local wc = windowApi()
	if not wc then log("no window access"); return end
	result.text = ""
	-- a new window starts without pending commands, like the game's counter that lives with its component
	result.batch = result.batch + 1
	result.sent, result.ok, result.failed, result.total = 0, 0, 0, nil
	result.queued, result.note = 0, nil
	sel.carrier, sel.alt, sel.neu = carrier, nil, nil
	Queue.loadKept()
	Queue.ensureLoaded()
	local ok, err = pcall(wc.addWindow, MvrWindow, WINDOW_KEY, { onClose = closeWindow })
	if ok then windowOpen = true else log("opening window failed", tostring(err)) end
end

-- Orders tab -----------------------------------------------------------------------------------------------
-- Cards like the game's entity windows: the game's scroll container (entity_window_util.tl:2467-2489), one card
-- with the settings, one per job. Redrawn twice a second from a
-- signature string of the queue, so an unchanged queue costs nothing (tf3-ui-design skill, tf3-sdk ui.md).
do
local ensureLoaded, num, jobById = Queue.ensureLoaded, Queue.num, Queue.jobById
local removeJob, cancelAll, setReserve, setPaused = Queue.removeJob, Queue.cancelAll, Queue.setReserve, Queue.setPaused
local CONFIRM_KEY = "mass_vehicle_replace.confirm"

local function modelName(key)
	local i = info(key)
	return i and oneLine(i.name) or tostring(key)
end

local function jobSig(j)
	local s = j.skipped
	return table.concat({ num(j.id), #j.open, j.done, s.sold, s.replaced, s.reused, s.rejected, j.blocked or "",
		j.cost and num(j.cost) or "", j.short and num(j.short) or "" }, ":")
end

-- memory only (runs in a timed step state, see queuedNow); the content recipe loads the queue before it renders
local function queueSig()
	local parts = { queue.paused and "p" or "r", num(queue.reserve), queue.foreign and "f" or "", queue.lastError or "",
		num(queue.inflightN) }
	for __, j in ipairs(queue.jobs) do parts[#parts + 1] = jobSig(j) end
	return table.concat(parts, "|")
end

local function spacer()
	return gui_react_util.makeHorizontalSpacer()
end

local function vbox(class, children)
	return builtin.BoxLayout{ meta = { class = class }, orientation = builtin.type.Orientation.Vertical, children = children }
end

local function hbox(class, children)
	return builtin.BoxLayout{ meta = { class = class }, orientation = builtin.type.Orientation.Horizontal, children = children }
end

-- a card the way the game's entity windows build theirs (content_card.tl:207-455): the card is the frame, the body
-- a recipe with plain layouts
local function card(key, title, recipe, params)
	return builtin.BoxLayout{ child = content_card.ContentCard{
		meta = { localKey = key },
		title = title,
		initialCalloutTextPermanent = "",
		recipeAndParamPermanent = content_card.makeRecipeAndParam(recipe, params),
	} }
end

local function confirmCancelAll()
	local wc = windowApi()
	local dialog = dialog_react_util and dialog_react_util.DialogWindow or nil
	if not (wc and dialog) then cancelAll(); return end
	local function close() pcall(wc.removeWindow, dialog, CONFIRM_KEY) end
	-- the game's dialog, with an own key, never as a singleton (tf3-ui-design skill, rule 12)
	local ok, err = pcall(wc.addWindow, dialog, CONFIRM_KEY, {
		x = 0.5, y = 0.5,
		windowTitle = _("mvr_cancel_all"),
		displayText = _("mvr_cancel_all_q"),
		choices = {
			{ text = _("mvr_cancel_all"), onClick = function() cancelAll(); close() end },
			{ text = _("mvr_keep"), onClick = close, isSecondary = true },
		},
		onClose = close,
	})
	if not ok then log("confirmation not opened", tostring(err)) end
end

-- settings card: reserve, paused, a status line, "cancel all"
-- a line above the orders only when something needs saying; the number of open vehicles is in the tab
local function queueStatus()
	if queue.foreign then return _("mvr_queue_foreign") end
	if queue.paused and queue.lastError then return tr("mvr_queue_error", queue.lastError) end
	if #queue.jobs == 0 then return _("mvr_queue_empty") end
	return nil
end

-- Settings as one footer row below the orders (variant D, user decision 20.10.2026: whoever opens the tab wants
-- the orders first; reserve and hold are changed rarely): reserve, hold, and "cancel all" on the right.
local MvrQueueSettings = react.RegisterRecipe("MvrQueueSettings", function()
	ensureLoaded()
	local parts = {}
	-- infinite money (sandbox mode, "no costs"): a reserve means nothing and is left out, like the game hides its
	-- balance card then (maintenance_station_eow.script.tl conditionMaintenanceStationBalance)
	if not infiniteMoney() then
		parts[#parts + 1] = builtin.TextView{ meta = { class = "font-scale-body", tooltip = _("mvr_reserve_tip") }, text = _("mvr_reserve") }
		-- the currency sign as the game writes money, "$" in front (user decision 20.10.2026: "Reserve $ [field]")
		parts[#parts + 1] = text((money(0):gsub("[%d%s%.,]", "")))
		-- the game's money field (game_bar.tl:252-266 uses it for the balance): typed or stepped, numbers only;
		-- the game marks its own text number field deprecated in favour of it (gui_react_util.d.tl:130)
		parts[#parts + 1] = builtin.DoubleSpinBox{ meta = { class = "mvr-setting", tooltip = _("mvr_reserve_tip") }, min = 0,
			max = Queue.RESERVE_MAX, step = 100000, value = queue.reserve, onValueChange = function(v) setReserve(v) end }
	end
	parts[#parts + 1] = builtin.CheckBox{ meta = { tooltip = _("mvr_paused_tip") }, label = _("mvr_paused"), value = queue.paused and 1 or 0,
		onValueChange = function(v) setPaused(v == 1) end }
	parts[#parts + 1] = spacer()
	parts[#parts + 1] = textButton("secondary", _("mvr_cancel_all"), confirmCancelAll, nil, #queue.jobs == 0)
	-- indented like the cards above it (game test 20.10.2026: the row stuck out on both sides)
	return builtin.BoxLayout{ children = { builtin.Component{ meta = { class = "mvr-orders-foot" },
		layout = vbox("mvr-rows", { hbox("mvr-row", parts) }) } } }
end)

-- the small image of a model, as in the lists, and its name
local function modelCell(key)
	local i = info(key)
	local img = (i and i.icon and i.icon ~= "")
		and builtin.ImageView{ meta = { class = "mvr-item-image", mouseTransparent = true }, path = i.icon, scaling = builtin.type.ImageViewScaling.AutoFit }
		or builtin.Component{ meta = { class = "mvr-item-image" } }
	return hbox("mvr-row", { img, text(modelName(key)) })
end

-- Cost of one open vehicle by the formula of the window and the tick (#26, #37): price of its new units minus its
-- credit. nil when the vehicle cannot be read (sold: the tick drops it).
local function entryCost(entry, job, altInfo, neuInfo)
	local ok, cost = pcall(function()
		local cfg = api.engine.getComponent(entry.entity, CT.TRANSPORT_VEHICLE).transportVehicleConfig
		local use = useOf(entry.entity, cfg)
		return neuInfo.price * unitsIn(use, job.alt, altInfo) - creditOf(use, job.alt)
	end)
	return ok and type(cost) == "number" and cost or nil
end

-- Live prices of every order's open vehicles, like the replace window's cost line (shownCost): read again only once
-- game time has passed (nothing ages while paused), at most twice a second and only while the tab is open (user
-- decision 20.10.2026: the total must follow the falling residual values). About five engine calls per open
-- vehicle, the same work the replace window does for the vehicles it shows.
local prices = { key = nil, byJob = {} }
local function orderPrices()
	-- read again when game time passed or an order changed (another vehicle at the head, one gone)
	local t = gameTime()
	local key = tostring(t) .. "#" .. queueSig()
	if t == nil or key ~= prices.key then
		prices.key = key
		local byJob = {}
		for __, j in ipairs(queue.jobs) do
			local altInfo, neuInfo = info(j.alt), info(j.neu)
			if not j.blocked and altInfo and neuInfo then
				local first, total = nil, 0
				for __, e in ipairs(j.open) do
					local c = entryCost(e, j, altInfo, neuInfo)
					if c then
						first = first or c
						total = total + c
					end
				end
				if first then byJob[j.id] = { first, total } end
			end
		end
		prices.byJob = byJob
	end
	local parts = {}
	for __, j in ipairs(queue.jobs) do
		local pr = prices.byJob[j.id]
		parts[#parts + 1] = pr and (num(pr[1]) .. ":" .. num(pr[2])) or ""
	end
	return table.concat(parts, "|")
end

-- one figure of an order: a small label over its value, on a tile of its own (user decision 20.10.2026, variant E of
-- the card mock-ups)
local function tile(label, value, tooltip)
	return builtin.Component{ meta = { class = "mvr-tile", tooltip = tooltip },
		layout = vbox("mvr-tile-rows", { text(label, "font-scale-annotation"), text(value, "font-scale-title-4") }) }
end

-- one order: its number, both models with their images, four tiles (open, skipped, the price of the next vehicle and
-- of all open ones) and cancel; a model no longer available shows a red line instead of the tiles (user decision
-- 20.10.2026)
local MvrQueueJob = react.RegisterRecipe("MvrQueueJob", function(p)
	local j = jobById(p.id)
	if not j then return builtin.BoxLayout{ children = {} } end
	local s = j.skipped
	local altInfo, neuInfo = info(j.alt), info(j.neu)
	local rows = { hbox("mvr-order-head", { modelCell(j.alt), text("→"), modelCell(j.neu) }) }
	if j.blocked then
		rows[2] = text(j.blocked == "model" and _("mvr_queue_blocked_model") or _("mvr_queue_blocked_unknown"), "font-scale-body, error")
	else
		-- prices of the next and of all open vehicles (orderPrices), a dash while they cannot be read
		local pr = altInfo and neuInfo and prices.byJob[j.id] or nil
		rows[2] = hbox("mvr-tiles", {
			tile(_("mvr_tile_open"), int(#j.open)),
			-- a vehicle whose id now belongs to something else is gone like a sold one
			tile(_("mvr_tile_skipped"), int(s.sold + s.replaced + s.reused + s.rejected),
				tr("mvr_queue_skipped_tip", s.sold + s.reused, s.replaced, s.rejected)),
			tile(_("mvr_tile_next"), pr and money(pr[1]) or "-"),
			tile(_("mvr_tile_total"), pr and money(pr[2]) or "-"),
		})
	end
	-- three parts with a thin line between them (user decision 20.10.2026): the number, the order, cancel
	local function divider() return builtin.Component{ meta = { class = "mvr-divider" } } end
	return hbox("mvr-row", {
		text(tostring(p.index), "font-scale-title-2, mvr-order-side"),
		divider(),
		vbox("mvr-order-body", rows),
		divider(),
		textButton("secondary, mvr-order-side", _("mvr_cancel_job"), function() removeJob(p.id) end),
	})
end)

local MvrQueueContent = react.RegisterRecipe("MvrQueueContent", function(p)
	react.useInputAction("IA_MENU_BACK", react.iaHandler(p.onClose))
	ensureLoaded()
	-- redraw when anything in the queue changes; the signature is a short string compared twice a second
	engine_react_util.useStepStateTimer(queueSig, 0.5)
	-- and when the prices change, only while this tab is shown (about five engine calls per open vehicle); read once
	-- here as well, so the first drawing has them
	engine_react_util.useStepStateTimer(function() return Queue.ordersShown and orderPrices() or "" end, 0.5)
	if Queue.ordersShown then orderPrices() end
	local status = queueStatus()
	-- one card per order, numbered in the order they run; the card has no title, the body says it all
	local cards = {}
	for k, j in ipairs(queue.jobs) do
		local pr = prices.byJob[j.id]
		cards[#cards + 1] = card("job" .. num(j.id), nil, MvrQueueJob, { id = j.id, index = k,
			sig = jobSig(j) .. (pr and (":" .. num(pr[1]) .. ":" .. num(pr[2])) or "") })
	end
	local panel
	if entity_window_util and entity_window_util.ContentWidgetScrollContainer then
		-- the inner panel of the game's windows: two positional arguments
		panel = entity_window_util.ContentWidgetScrollContainer(cards, true)
	else
		panel = builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = cards }
	end
	-- as wide as the replace tab, so the window keeps its width when the tab changes
	return builtin.BoxLayout{ children = { builtin.Component{ meta = { class = "mvr-orders" },
		layout = builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical,
			children = { status and text(status, "font-scale-body") or builtin.BoxLayout{ children = {} }, panel,
				MvrQueueSettings{ sig = queueSig() } } } } } }
end)
queueContent = (okCard and type(content_card) == "table") and MvrQueueContent or nil
if not queueContent then log("orders tab needs the game's content card, left out") end

Queue.window = MvrQueueContent
end

-- "Replace Vehicles" button in the depot window, to the right of "Manage Vehicles".
-- Two hooks, both as small as the game allows (see the tf3-mod-compat rules):
-- 1. The depot entity comes from the condition of a MaintenanceStationEowExtensionPoint plugin. The depot
--    window calls every plugin condition with its entity while it renders, before it builds its button bar
--    (maintenance_station.tl: usePlugins, then entity_window_util.ActionButtonBar). The condition only
--    remembers the depot and returns false, so the plugin never shows anything.
-- 2. The button bar recipe is replaced through the replacement API and chained with a replacement another
--    mod installed earlier. The module field stays untouched: other mods pass it to react.CallOriginalRecipe,
--    which only works with the registered recipe. There is no extension point for the button bar.
local MANAGE_TAG = "entityWindow.maintenanceStation.manageVehicle"
local okEow, maintenance_station_eow = pcall(ug_require, "::/gui/entity_window/maintenance_station/maintenance_station_eow.script.tl")
-- captured at load: other mods may overwrite the module field later
local ActionButtonBar = entity_window_util and entity_window_util.ActionButtonBar or nil

local depotOfWindow -- depot of the depot window that is rendering right now

local function depotProbeCondition(extensionParams)
	if type(extensionParams) == "table" then depotOfWindow = extensionParams.entityId end
	return false
end
-- never instantiated (the condition is always false), but the plugin resource needs a recipe
local MvrDepotProbe = okEow and type(maintenance_station_eow) == "table"
	and react.RegisterPluginRecipe(maintenance_station_eow.MaintenanceStationEowExtensionPoint, "MvrDepotProbe", function()
		return builtin.BoxLayout{}
	end) or nil

-- The button sits at the right edge: the bar puts a spacer between primary and secondary buttons, so it
-- goes in as the first secondary button (customItem, styled like a primary button) before any tool button.
-- Only the depot window has "Manage Vehicles", other windows stay unchanged.
local function replaceButton(depot)
	return builtin.Button{
		meta = { class = "primary", tag = "mass_vehicle_replace.replaceVehicles" },
		onClick = function()
			if windowOpen then closeWindow() end
			openWindow(depotCarrier(depot))
		end,
		content = builtin.Component{
			layout = builtin.BoxLayout{
				orientation = builtin.type.Orientation.Horizontal,
				children = {
					builtin.ImageView{
						path = "::/gui/entity_window/icons/symbol_arrows_refresh.tga",
						scaling = builtin.type.ImageViewScaling.AutoFit,
					},
					builtin.TextView{ meta = { class = "font-scale-body" }, text = _("mvr_replace_vehicles") },
				},
			},
		},
	}
end

-- The game keeps one replacement per recipe. A replacement another mod installed earlier is read here
-- and called from ours, so both stay in the chain.
local function currentReplacement(recipe)
	-- the game's GUI Lua has no rawget; _react is a plain global set up by the game
	local okReg, reg = pcall(function() return _react end)
	local okId, id = pcall(react.GetRecipeId, recipe)
	if not okReg or type(reg) ~= "table" or type(reg.recipeReplace) ~= "table" or not okId or id == nil then return nil end
	return reg.recipeReplace[id]
end

local function withReplaceButton(p)
	if type(p) ~= "table" or not p.primaryButtons then return p end
	local found = false
	for __, b in ipairs(p.primaryButtons) do
		if b.tag == MANAGE_TAG then found = true end
	end
	if not found then return p end
	local secondary = { { customItem = replaceButton(depotOfWindow) } }
	for __, b in ipairs(p.secondaryButtons or {}) do secondary[#secondary + 1] = b end
	local copy = {}
	for k, v in pairs(p) do copy[k] = v end
	copy.secondaryButtons = secondary
	return copy
end

local priorBar -- replacement of the button bar by another mod, installed before ours
-- Replacement for ActionButtonBar; the params are the last argument, a ref may come before them.
local function actionButtonBar(...)
	local n = select("#", ...)
	local args = { ... }
	if n > 0 then args[n] = withReplaceButton(args[n]) end
	if priorBar then return priorBar(table.unpack(args, 1, n)) end
	return react.CallOriginalRecipe(ActionButtonBar, table.unpack(args, 1, n))
end

local installed = false
local function doReplace(replacementApi)
	if installed then return end
	installed = true
	-- a failed hook only loses the depot button, never the game UI
	local ok, err = pcall(function()
		local okId, id = pcall(react.GetRecipeId, ActionButtonBar)
		if not okId or id == nil then
			log("ActionButtonBar is not a recipe, depot button disabled", tostring(ActionButtonBar))
			return
		end
		priorBar = currentReplacement(ActionButtonBar)
		log("replacements by other mods", "ActionButtonBar", tostring(priorBar ~= nil), "depot plugin", tostring(MvrDepotProbe ~= nil))
		replacementApi.ReplaceRecipe(ActionButtonBar, actionButtonBar)
	end)
	if not ok then log("depot button not installed", tostring(err)) end
end

-- .script.lua resources expose their exports through data(), not a return value
function data()
	return {
		doReplace = doReplace,
		depotProbe = MvrDepotProbe,
		depotProbeCondition = depotProbeCondition,
		queueHost = Queue.host,
		-- for the offline UI check (tf3-sdk ui_check), not referenced by a resource
		queueWindow = Queue.window,
	}
end
