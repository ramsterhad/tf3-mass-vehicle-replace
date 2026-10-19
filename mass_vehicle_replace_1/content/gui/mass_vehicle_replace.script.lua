-- Mass Vehicle Replace: replaces all vehicle parts of one model with another model, on all lines and in the depot.
-- "Replace Vehicles" button in the depot window, window with two selection lists. The swap uses makeVehicleReplaceCmd like
-- the game's replace dialog (gui/line_vehicle_mgmt/vehicle_util.tl makePart, vehicle_react_util.tl).
-- Loop variables without `_`, that is the translation function here.
local react = ug_require "::/gui/main/react.lua"
local builtin = ug_require "::/gui/main/builtin.lua"
local gui_react_util = ug_require "::/gui/main/gui_react_util.tl"
local engine_react_util = ug_require "::/gui/main/engine_react_util.tl"
local okGlobals, game_react_globals = pcall(ug_require, "::/gui/main/game_react_globals.tl")

local WINDOW_KEY = "mass_vehicle_replace.window"
local CT = api.type.ComponentType

local function log(...)
	debugPrint("[MassVehicleReplace]", ...)
end

-- Shared with add-on mods (#24): the consist rebuild and the extension point of the window, each in a module of
-- its own, so an add-on loads them with ug_require without loading this script. Without the rebuild module the
-- window cannot work, so the depot button is then left out (doReplace); without the extension point the window
-- only lacks the add-ons.
local okRebuild, rebuildLib = pcall(ug_require, "mass_vehicle_replace_1::/gui/mass_vehicle_replace_rebuild.lua")
if not okRebuild or type(rebuildLib) ~= "table" then
	log("rebuild module not loaded", tostring(rebuildLib))
	rebuildLib = nil
end
local groupsOf = rebuildLib and rebuildLib.groupsOf
local rebuild = rebuildLib and rebuildLib.rebuild
local okExtension, extension = pcall(ug_require, "mass_vehicle_replace_1::/gui/mass_vehicle_replace_extension.lua")
if not okExtension or type(extension) ~= "table" then
	log("extension point not registered", tostring(extension))
	extension = nil
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
	local cargos, seenCargo = {}, {}
	for k, v in ipairs(mu.vehicles) do
		local mid = api.res.modelRep.find(v.name)
		local mi = mid and mid >= 0 and modelInfo(mid) or nil
		if not mi then
			log("multiple unit", tostring(api.res.multipleUnitRep.getName(id)), "part not found:", tostring(v.name), tostring(mid))
			return nil
		end
		parts[k] = { info = mi, forward = v.forward }
		load = load or mi.load
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
local function count(key, n)
	if n == 1 then return _(key .. "_1") end
	return string.format(_(key), n)
end

local function money(v)
	local ok, s = pcall(api.util.formatMoney, math.floor(v + 0.5))
	return ok and s or tostring(v)
end

-- Vehicles in the game ------------------------------------------------------------------------------

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
			local seen, keys = {}, {}
			for __, g in ipairs(groupsOf(cfg)) do
				if g.path ~= "" then
					local mi = muOfPath(g.path)
					if mi then add(mi.key, tv, seen) -- unknown multiple unit (mod missing): do not offer
					elseif not unknownMu[g.path] then unknownMu[g.path] = true; log("unknown multiple unit in train", tostring(g.path)) end
					for j = g.from, g.to do keys[j] = mi and mi.key or false end
				else
					for j = g.from, g.to do
						keys[j] = "m" .. cfg.vehicles[j].part.modelId
						add(keys[j], tv, seen)
					end
				end
			end
			local use = { vehicle = v, parts = cfg.vehicles, keys = keys }
			for key in pairs(seen) do local u = byKey[key].uses; u[#u + 1] = use end
		end
	end
	return byKey, partsByVehicle
end

-- Result of the last batch. Commands sent from the GUI run in the next simulation step and their callbacks
-- come a frame later (api/tealdef/api/cmd.d.tl:2-10); until then the vehicles still look unchanged, so a
-- second batch would replace the same vehicles again. Like the game (engine_react_util.tl:36-55, 66-98) we
-- count pending callbacks for as long as the window is open; batch tells callbacks of an earlier window apart.
local result = { batch = 0, sent = 0, ok = 0, failed = 0, text = "", total = nil }

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
	if result.sent == 0 then
		result.text = _("mvr_none_found")
		return
	end
	-- the result shows once, when the game has answered every command (user decision 19.10.2026); until then
	-- the button says "Replacing ..." and no half-counted line like "0 of 8" appears
	if pending() then
		result.text = ""
		return
	end
	local s = string.format(_("mvr_replaced"), result.ok, result.sent)
	-- partial (#23): of all vehicles with the old model, not only of those sent; same wording as a full batch,
	-- the money was already named on the button (user decision 19.10.2026)
	if result.total and result.total > result.sent then s = string.format(_("mvr_replaced"), result.ok, result.total) end
	-- commands the game refused, apart from the vehicles skipped for money: the game gives no reason, and it
	-- does not refuse for lack of money (measured 19.10.2026, tf3-sdk knowledge/vehicles.md)
	if result.failed > 0 then s = s .. " " .. count("mvr_rejected", result.failed) end
	result.text = s
end

-- The replace command does not check the balance (the game's purchase window does that itself,
-- vehicle_store_window.tl hasEnoughMoney), so without this check the player could go into debt.
-- Like the game, the cost is the purchase price minus the residual value of the replaced vehicles (#26).
-- what the window shows, read by its step states: price of the new parts, fleet entry and model being replaced
local shown = { price = 0, e = nil, key = nil, cost = 0, time = nil }

-- infinite money (sandbox mode, "no costs"): the game then hides the balance card in the depot window
-- (maintenance_station_eow.script.tl conditionMaintenanceStationBalance, state.infiniteMoney); the balance is nil
-- (vehicle_store_window.tl fundsState: "nil if infinite!")
local function infiniteMoney()
	local ok, funds = pcall(function() return api.engine.util.finance.getPlayersBalance(api.engine.util.getPlayer()) end)
	return ok and funds == nil
end

local function enoughMoney(cost)
	if cost <= 0 then return true end
	-- nil means infinite money (vehicle_store_window.tl fundsState: "nil if infinite!")
	local ok, funds = pcall(function() return api.engine.util.finance.getPlayersBalance(api.engine.util.getPlayer()) end)
	if not ok then return true end -- unreadable: leave it to the game, as before
	return funds == nil or funds >= cost
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

-- the vehicles of entry e the balance covers: set of vehicle ids, their number and the cost
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
	return picked, n, sum
end

-- the balance for partial replacing: a real, finite number or nil; nan or inf would let every comparison pass
-- (a test with a nan balance replaced all vehicles), so they count as unreadable
local function balance()
	local ok, funds = pcall(function() return api.engine.util.finance.getPlayersBalance(api.engine.util.getPlayer()) end)
	if ok and type(funds) == "number" and funds == funds and funds > -math.huge and funds < math.huge then return funds end
	return nil
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

-- Replaces alt with neu in every vehicle; the other parts stay as they are. partial: only the vehicles the balance
-- covers right now (#23), an explicit choice next to the disabled button; otherwise all or nothing.
local function replaceAll(altKey, neuKey, partial)
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
	local only, total = nil, nil
	if partial then
		local funds = balance()
		if funds == nil then return end -- infinite or unreadable money: the normal button covers it
		local e = fleet()[altKey]
		local n
		only, n = affordablePart(e, altKey, altInfo, neuInfo, funds)
		if n == 0 then
			result.text = _("mvr_not_enough_money")
			return
		end
		total = e and #e.uses or n
	end
	-- build all first: either every vehicle is replaced or none, like the purchase window
	local jobs, units = {}, 0
	for __, v in ipairs(ownVehicles()) do
		local tv = api.engine.getComponent(v, CT.TRANSPORT_VEHICLE)
		local cfg = tv and tv.transportVehicleConfig
		local conf, n = nil, 0
		if cfg and (only == nil or only[v]) then conf, n = rebuild(cfg, altInfo, neuInfo, t) end
		if conf then
			jobs[#jobs + 1] = { entity = v, conf = conf }
			units = units + n
		end
	end
	-- checked again here: the balance may have changed since the window was drawn; residual value by the
	-- same rule as the window
	if not partial and not enoughMoney(neuInfo.price * units - residual(fleet()[altKey], altKey)) then
		result.text = _("mvr_not_enough_money")
		return
	end
	-- counters are reset only here, right before sending: a refused click leaves the previous batch alone
	local batch = result.batch
	result.sent, result.ok, result.failed, result.total = 0, 0, 0, total
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

-- List with a placeholder as first entry: without a selection it shows that instead of becoming empty and narrower
local NONE = "none" -- not empty: the game may treat an empty value as no selection
-- content: short description of selection and entries. The game's list keeps its display when its
-- entries change (after replacing, the old model was still shown on the left, the new image already below it).
-- When content changes, the list gets a new localKey and is built afresh (like construction.tl).
local function combo(value, items, placeholder, onChange, content)
	local all = { item(NONE, placeholder, " ", nil) }
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

local function compareModels(a, b, sort)
	if sort == "year" and a.yearFrom ~= b.yearFrom then return a.yearFrom < b.yearFrom end
	local ka, kb = naturalKey(a.name), naturalKey(b.name)
	if ka ~= kb then return ka < kb end
	return a.key < b.key
end

local SORTS = { { key = "name", label = "mvr_sort_name" }, { key = "year", label = "mvr_sort_year" } }

-- selection in the window; lives outside the recipe so every opening starts fresh
local sel = { carrier = nil, alt = nil, neu = nil, sort = "name", sameCargo = true }

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
		onValueChange = function(v) update(function() sel.sameCargo = v == 1 end) end,
	}
	for __, s in ipairs(SORTS) do
		children[#children + 1] = builtin.ToggleButton{
			meta = { class = "mvr-sort" },
			content = text(_(s.label), "font-scale-annotation"),
			value = sel.sort == s.key and 1 or 0,
			onValueChange = function() update(function() sel.sort = s.key end) end,
		}
	end
	return row(children)
end

-- Add-ons (#24) ------------------------------------------------------------------------------------------
-- Plugins of the window's extension point (mass_vehicle_replace_extension.lua) sit left of the Replace button.

-- a plain copy of what rebuild() needs from a catalog entry; plugins never get the entry itself
local function unitOf(i)
	if not i then return nil end
	if i.mu then
		local parts = {}
		for k, part in ipairs(i.parts) do
			parts[k] = { info = { id = part.info.id, compartments = part.info.compartments }, forward = part.forward }
		end
		return { key = i.key, mu = true, path = i.path, parts = parts }
	end
	return { key = i.key, mu = false, id = i.id, compartments = i.compartments }
end

local pluginErrors = {} -- the window renders often: each failure is logged once
local function pluginFailed(what, err)
	local msg = what .. ": " .. tostring(err)
	if not pluginErrors[msg] then
		pluginErrors[msg] = true
		log("add-on plugin failed", msg)
	end
end

-- Like gui_react_util.usePlugins (gui_react_util.tl:513-565, react.getPlugins react.lua:92-117), but every plugin
-- in pcall: the game calls condition and recipe unguarded, so one broken add-on would break the window. Each call
-- gets a fresh params table from makeParams, so no plugin can change what the window or the next plugin sees.
-- Gamepad refs and hardcoded entries of usePlugins are not needed here.
local function addonNodes(makeParams)
	if not extension then return {} end
	local ok, plugins = pcall(react.getPlugins, extension.MvrReplaceWindowExtension)
	if not ok then
		pluginFailed("getPlugins", plugins)
		return {}
	end
	local nodes = {}
	for k, plugin in ipairs(type(plugins) == "table" and plugins or {}) do
		if type(plugin) == "table" then
			local okC, show = pcall(function() return plugin.condition == nil or plugin.condition(makeParams()) end)
			if not okC then
				pluginFailed("condition " .. k, show)
			elseif show then
				-- a missing recipe (react.lua:103-105 logs "Recipe not found") fails here as a call of nil
				local okR, node = pcall(plugin.recipe, makeParams())
				if not okR then pluginFailed("recipe " .. k, node)
				elseif node ~= nil then nodes[#nodes + 1] = node end
			end
		end
	end
	return nodes
end

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
		return compareModels(a.i, b.i, sel.sort)
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
	table.sort(neus, function(a, b) return compareModels(a, b, sel.sort) end)

	local neuInfo = sel.neu and info(sel.neu) or nil
	if neuInfo and not (fits(neuInfo) and available(neuInfo, year)) then neuInfo = nil end

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
	-- redraw when the last callback of a batch arrives, so the button comes back
	engine_react_util.useStepState(pending)
	local busy = pending()
	if e and neuInfo then
		-- like the game, which shows only the net cost; the purchase price as long as nothing is credited
		local priceLine = refund ~= 0 and string.format(_("mvr_cost_net"), money(cost)) or string.format(_("mvr_price"), money(price))
		if free then priceLine = " " end
		summary = { count("mvr_will_replace", e.vehicles), priceLine }
		-- partial (#23): what the button does, so count, cost and label agree
		if partial then summary = { count("mvr_will_replace", some), string.format(_("mvr_cost_net"), money(someCost)) } end
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
			class = "primary, mvr-replace-btn" .. (affordable and "" or partial and ", mvr-partial" or ", mvr-no-money"),
			-- disabled while the previous batch is still being replaced (issue #9)
			enabled = (affordable or partial) and not busy,
			tooltip = partial and (some == 1 and string.format(_("mvr_replace_some_tip_1"), e.vehicles)
				or string.format(_("mvr_replace_some_tip"), some, e.vehicles)) or not affordable and _("mvr_not_enough_money") or nil,
		},
		content = builtin.Component{
			layout = builtin.BoxLayout{
				orientation = builtin.type.Orientation.Horizontal,
				children = {
					builtin.ImageView{ meta = { class = "mvr-btn-icon" }, path = "::/gui/entity_window/icons/symbol_arrows_refresh.tga", scaling = builtin.type.ImageViewScaling.AutoFit },
					text(busy and _("mvr_replacing") or partial and string.format(_("mvr_replace_some"), some, e.vehicles)
						or not affordable and _("mvr_not_enough_money") or _("mvr_replace")),
				},
			},
		},
		onClick = function()
			if not (altInfo and neuInfo) then return end
			local ok, err = pcall(replaceAll, altInfo.key, neuInfo.key, partial)
			if not ok then
				result.text = _("mvr_error") .. " " .. tostring(err)
				log("error", tostring(err))
			end
			-- clear the selection: the result is now shown below
			update(function() sel.alt, sel.neu = nil, nil end)
		end,
	}

	local summaryLines = {}
	for k, line in ipairs(summary) do summaryLines[k] = text(line) end

	-- the selection for add-ons (#24), documented in mass_vehicle_replace_extension.lua; built anew for each call
	local function selection()
		return {
			version = extension.VERSION,
			oldKey = altInfo and altInfo.key,
			newKey = neuInfo and neuInfo.key,
			vehicles = e and e.vehicles or 0,
			units = e and e.parts or 0,
			price = price,
			cost = cost,
			infiniteMoney = free,
			affordable = affordable,
			affordableCount = some,
			affordableCost = someCost,
			busy = busy,
			oldUnit = unitOf(altInfo),
			newUnit = unitOf(neuInfo),
		}
	end
	-- without add-ons the row is the same as before: summary, spacer, button
	local bottomRow = {
		builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = summaryLines },
		gui_react_util.makeHorizontalSpacer(),
	}
	for __, node in ipairs(addonNodes(selection)) do bottomRow[#bottomRow + 1] = node end
	bottomRow[#bottomRow + 1] = button

	local children = {
		topBar(update),
		row({ cell("cell", text(_("mvr_old_model"))), cell("mid", empty()), cell("cell", text(_("mvr_new_model"))) }),
		row({ cell("cell", altCombo), cell("mid", swap), cell("cell", neuCombo) }),
		row({ cell("cell", bigPicture(altInfo)), cell("mid", empty()), cell("cell", bigPicture(neuInfo)) }),
		-- gap between images and text; the button stays centered on the text block
		builtin.Component{ meta = { class = "mvr-gap" } },
		row(bottomRow),
	}

	-- a recipe must return a layout, not a component
	return builtin.BoxLayout{ children = {
		builtin.Component{
			meta = { class = "mvr-content" }, -- the fixed width comes from the cells
			layout = builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = children },
		},
	} }
end)

local windowOpen = false

local MvrWindow = react.RegisterWrapperRecipe("MvrWindow", builtin.Window, function(p)
	react.onUnmount(function()
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
		content = MvrContent{ onClose = p.onClose },
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
	sel.carrier, sel.alt, sel.neu = carrier, nil, nil
	local ok, err = pcall(wc.addWindow, MvrWindow, WINDOW_KEY, { onClose = closeWindow })
	if ok then windowOpen = true else log("opening window failed", tostring(err)) end
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
local okEwu, entity_window_util = pcall(ug_require, "::/gui/entity_window/entity_window_util.tl")
local okEow, maintenance_station_eow = pcall(ug_require, "::/gui/entity_window/maintenance_station/maintenance_station_eow.script.tl")
-- captured at load: other mods may overwrite the module field later
local ActionButtonBar = okEwu and type(entity_window_util) == "table" and entity_window_util.ActionButtonBar or nil

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
	if not rebuildLib then return end -- logged at load: the window could not replace anything
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
	}
end
