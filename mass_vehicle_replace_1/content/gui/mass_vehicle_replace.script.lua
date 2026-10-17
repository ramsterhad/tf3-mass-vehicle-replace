-- Mass Vehicle Replace: ersetzt alle Fahrzeugteile eines Modells durch ein anderes Modell, auf allen Linien und im Depot.
-- Knopf "Fahrzeuge ersetzen" im Depotfenster, Fenster mit zwei Auswahllisten. Der Tausch nutzt makeVehicleReplaceCmd wie der
-- Ersetzen-Dialog des Spiels (gui/line_vehicle_mgmt/vehicle_util.tl makePart, vehicle_react_util.tl).
-- Schleifenvariablen ohne `_`, das ist hier die Uebersetzungsfunktion.
local react = ug_require "::/gui/main/react.lua"
local builtin = ug_require "::/gui/main/builtin.lua"
local styleutil = ug_require "::/gui/main/styleutil.tl"
local gui_react_util = ug_require "::/gui/main/gui_react_util.tl"
local engine_react_util = ug_require "::/gui/main/engine_react_util.tl"
local okGlobals, game_react_globals = pcall(ug_require, "::/gui/main/game_react_globals.tl")

local WINDOW_KEY = "mass_vehicle_replace.window"
local CT = api.type.ComponentType

local function log(...)
	debugPrint("[MassVehicleReplace]", ...)
end

-- Number as whole-number text for the log. Never use %d: in the game's Lua 5.2 it fails with
-- "not a number in proper range" on values beyond 2^63, inf and nan.
local function num(v)
	if type(v) == "number" then return string.format("%.0f", v) end
	return tostring(v)
end

-- Modelldaten ------------------------------------------------------------------------------------
-- Zwei Arten von Eintraegen, beide mit Schluessel key:
--   "m<id>": einzelnes Modell (Lok, Wagen, Bus, Schiff ...), id aus modelRep
--   "u<id>": Triebzug als Ganzes, id aus multipleUnitRep; im Zug steht er als Gruppe mit seinem Dateinamen
--            (TransportVehicleConfig.vehicleGroups und muFileNames, wie im Kauffenster des Spiels)

local catalog -- key -> Info
local muByPath -- Dateiname des Triebzugs -> Info
-- carrier ist hier der Wert aus den Modelldaten. Er wird nur mit anderen Modelldaten verglichen; ob er
-- dieselbe Form hat wie die Fahrzeugart von Depot und Fahrzeug (api.type.enum.Carrier), ist nicht sicher.

-- Traegt das Modell Fahrgaeste oder Fracht? Loks haben auch eine Ladung (4, Personal), aber ohne Frachtart;
-- Triebwagen nennen eine Frachtklasse (z. B. PASSENGERS). Gezaehlt wird nur eine Ladung mit Frachtart.
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

-- Frachtarten, die das Modell laden kann, wie im Kauffenster (vehicle_store_util): je Ladung mit Kapazitaet
-- alle Frachtarten ihres cargoTypeSet; sortiert nach der Reihenfolge des Spiels
-- Frachtart einmal nachschlagen und merken (Symbol, Name, Reihenfolge); die Liste fragt sonst bei jedem
-- Neuzeichnen je Eintrag und Feld erneut nach. false: unbekannte Frachtart
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

-- Klasse fuer den Tausch: Loks nur gegen Loks, Wagen nur gegen Wagen; Triebwagen (Motor und Ladung, z. B.
-- ACF M-300, Roter Pfeil, auch Busse) und Triebzuege untereinander. Ohne Motor und ohne Fracht: Attrappen, etwa
-- die "Fake"-Loks mancher Mods (engines leer, nur Personal ohne Frachtart); das Fenster zeigt sie nirgends
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
	-- Loks, Busse, Triebwagen haben einen Motor, Wagen nicht; Schiffe und Flugzeuge zaehlen als Motor
	local engine = (not land) or #land.engines > 0
	return {
		key = "m" .. id,
		id = id,
		path = path,
		load = carriesLoad(tv),
		cargos = cargoList(tv),
		class = classOf(engine, carriesLoad(tv)),
		-- Varianten nennen in groupFileName ihr Kopfmodell; ein Kopf ohne filterTags ist nur Gruppe
		group = tv.groupFileName or "",
		noTags = #(tv.filterTags or {}) == 0,
		name = name,
		carrier = tv.carrier,
		engine = engine,
		yearFrom = av and av.yearFrom or 0,
		yearTo = av and av.yearTo or 0,
		price = cost and cost.price or 0,
		compartments = #tv.compartments,
		-- Seitenansichten: klein in Listenhoehe (icon20), gross wie in der Kaufliste (iconSmall)
		icon = desc and ((desc.icon20 ~= nil and desc.icon20 ~= "") and desc.icon20 or desc.iconSmall) or nil,
		iconBig = desc and ((desc.iconSmall ~= nil and desc.iconSmall ~= "") and desc.iconSmall or desc.icon20) or nil,
	}
end

-- Triebzug wie vehicle_store_util.makeVehicleData: Preis ist die Summe der Teile, Bild und Fahrzeugart vom ersten Teil.
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
			log("Triebzug", tostring(api.res.multipleUnitRep.getName(id)), "Teil nicht gefunden:", tostring(v.name), tostring(mid))
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
		-- Triebzug mit Fahrgaesten oder Fracht wie ein Triebwagen; nur aus Loks (EMD F-Serie, SS4G) wie eine Lok
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
	local heads = {}
	for id in pairs(api.res.modelRep.getAll()) do
		local ok, i = pcall(modelInfo, id)
		if ok and i then
			catalog[i.key] = i
			if i.group ~= "" then heads[i.group] = true end
		end
	end
	-- wie die Kaufliste (vehicle_store_window variantGroupOnly): reine Gruppenkoepfe nicht anbieten,
	-- sie haben oft kein eigenes Bild und stehen sonst doppelt neben ihrer Variante
	for __, i in pairs(catalog) do
		if heads[i.path] and i.noTags then i.groupOnly = true end
	end
	local okAll, all = pcall(function() return api.res.multipleUnitRep.getAll() end)
	if not okAll then log("Triebzuege nicht abrufbar", tostring(all)) end
	local muCount, muTags = 0, 0
	for id in pairs(okAll and all or {}) do
		local ok, i = pcall(muInfo, id)
		if ok and i then
			catalog[i.key] = i
			muByPath[i.path] = i
			muCount = muCount + 1
			if not i.noTags then muTags = muTags + 1 end
			-- Teile eines Triebzugs gibt es nur mit ihm zusammen; einzeln werden sie nicht angeboten
			for __, part in ipairs(i.parts) do part.info.muPart = true; if catalog[part.info.key] then catalog[part.info.key].muPart = true end end
		elseif not ok then
			log("Triebzug nicht lesbar", tostring(id), tostring(i))
		end
	end
	local classes = { loco = 0, self = 0, wagon = 0 }
	for __, i in pairs(catalog) do if not i.mu and classes[i.class] then classes[i.class] = classes[i.class] + 1 end end
	log("Katalog:", "Triebzuege geladen", muCount, "davon mit Tags", muTags, "Loks", classes.loco, "Triebwagen", classes.self, "Wagen", classes.wagon)
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

-- wie vehicle_store_util: yearFrom > 0 und Jahr davor = noch nicht, yearTo > 0 und Jahr ab dann = nicht mehr
local function available(i, year)
	if i.yearFrom > 0 and year < i.yearFrom then return false end
	if i.yearTo > 0 and year >= i.yearTo then return false end
	return true
end

-- Text mit Zahl, Einzahl ueber eigenen Schluessel (key_1), sonst Mehrzahl (key)
local function count(key, n)
	if n == 1 then return _(key .. "_1") end
	return string.format(_(key), n)
end

local function money(v)
	local ok, s = pcall(api.util.formatMoney, math.floor(v + 0.5))
	return ok and s or tostring(v)
end

-- Fahrzeuge im Spiel --------------------------------------------------------------------------------

-- Gruppen eines Fahrzeugs: { from, to, path } mit path = Dateiname des Triebzugs oder "" fuer Einzelteile.
-- Ohne Gruppenangabe zaehlt jedes Teil einzeln.
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

-- Bestand je Eintrag: parts = Stueck (Einzelteile bzw. Triebzuege), vehicles = Fahrzeuge (Zuege), in denen er
-- steckt, dazu die Fahrzeugart aus der Fahrzeug-Komponente; die laesst sich wie im Spiel mit dem Depot vergleichen.
-- Teile eines Triebzugs zaehlen nur beim Triebzug, nicht einzeln.
local unknownMu = {} -- nur einmal melden
-- only the player's vehicles: campaign missions hand lines and vehicles to AI players
-- (mission.zip transfer_ownership_util.tl), the game filters its own lists the same way (statistic_vehicles.tl:322)
local function ownVehicles()
	return api.engine.getEntitiesWithComponent(CT.TRANSPORT_VEHICLE, { requireOwnedByPlayer = api.engine.util.getPlayer() })
end

local function fleet()
	local byKey = {}
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
			local seen, keys = {}, {}
			for __, g in ipairs(groupsOf(cfg)) do
				if g.path ~= "" then
					local mi = muOfPath(g.path)
					if mi then add(mi.key, tv, seen) -- unbekannter Triebzug (Mod fehlt): nicht anbieten
					elseif not unknownMu[g.path] then unknownMu[g.path] = true; log("Triebzug im Zug unbekannt", tostring(g.path)) end
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
	return byKey
end

-- neues Teil: Lackierung vom alten Teil; reversed vom alten Teil oder, im Triebzug, aus dessen Vorgabe
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
local result = { batch = 0, sent = 0, ok = 0, failed = 0, text = "" }

local function pending()
	return result.sent > result.ok + result.failed
end

local function updateText()
	if result.sent == 0 then
		result.text = _("mvr_none_found")
		return
	end
	local s = string.format(_("mvr_replaced"), result.ok, result.sent)
	if result.failed > 0 then s = s .. string.format(_("mvr_failed"), result.failed) end
	result.text = s
end

-- Baut die neue Zusammenstellung eines Fahrzeugs; nil, wenn alt darin nicht vorkommt.
-- Einzelmodell: jedes Einzelteil alt wird zu neu, Triebzuege im selben Zug bleiben.
-- Triebzug: jede Gruppe alt wird durch die Teile von neu ersetzt, Gruppengroesse und Dateiname passen sich an.
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
			-- Einzelteile stehen wie im Kauffenster je in einer eigenen Gruppe
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
local shownCost = 0 -- cost shown in the window, read by its step state

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
local function residual(e, key)
	local sum = 0
	for __, use in ipairs(e and e.uses or {}) do
		local credit = readValue(api.engine.util.vehicle.getDepreciatedValue, use.vehicle)
		for j, part in ipairs(use.parts) do
			if credit and use.keys[j] ~= key then
				local kept = readValue(api.engine.util.vehicle.getPartPrice, part)
				credit = kept and credit - kept or nil
			end
		end
		-- may be below 0 when the kept parts are worth more than the vehicle: the game charges that too
		if credit then sum = sum + credit end
	end
	return sum
end

-- Ausrichtung zum Pruefen gedrehter Triebzuege: Modell-ID je Teil, ">" vorwaerts, "<" gedreht, "|" trennt Gruppen
local function orientation(c)
	local out, k = {}, 1
	for __, size in ipairs(c.vehicleGroups) do
		local g = {}
		for j = k, k + size - 1 do
			local p = c.vehicles[j]
			g[#g + 1] = tostring(p.part.modelId) .. (p.part.reversed and "<" or ">")
		end
		out[#out + 1] = table.concat(g, " ")
		k = k + size
	end
	return table.concat(out, " | ")
end

-- Ersetzt in jedem Fahrzeug alt durch neu; die uebrigen Teile bleiben, wie sie sind.
local function replaceAll(altKey, neuKey)
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
	-- build all first: either every vehicle is replaced or none, like the purchase window
	local jobs, units = {}, 0
	for __, v in ipairs(ownVehicles()) do
		local tv = api.engine.getComponent(v, CT.TRANSPORT_VEHICLE)
		local cfg = tv and tv.transportVehicleConfig
		local conf, n = nil, 0
		if cfg then conf, n = rebuild(cfg, altInfo, neuInfo, t) end
		if conf then
			jobs[#jobs + 1] = { entity = v, cfg = cfg, conf = conf }
			units = units + n
		end
	end
	-- checked again here: the balance may have changed since the window was drawn; residual value by the
	-- same rule as the window
	if not enoughMoney(neuInfo.price * units - residual(fleet()[altKey], altKey)) then
		result.text = _("mvr_not_enough_money")
		return
	end
	-- counters are reset only here, right before sending: a refused click leaves the previous batch alone
	local batch = result.batch
	result.sent, result.ok, result.failed = 0, 0, 0
	for __, job in ipairs(jobs) do
		pcall(function() log("Ausrichtung", job.entity, "alt:", orientation(job.cfg), "neu:", orientation(job.conf)) end)
		local entity = job.entity
		api.cmd.sendCommand(api.cmd.makeVehicleReplaceCmd(entity, job.conf), function(__, success)
			-- the window was closed and opened again meanwhile: this batch no longer counts
			if batch ~= result.batch then return end
			if success then
				result.ok = result.ok + 1
			else
				result.failed = result.failed + 1
				log("Ersetzen fehlgeschlagen", entity)
			end
			updateText()
		end)
		-- counted only once it is really sent: a command that throws gets no callback, and counting it
		-- would leave the button disabled until the window is reopened
		result.sent = result.sent + 1
	end
	updateText()
	log(string.format("alt=%s neu=%s geschickt=%s", altKey, neuKey, num(result.sent)))
end

-- Fenster ---------------------------------------------------------------------------------------------
-- Aufbau in Zeilen aus Zellen fester Breite (Klassen in mass_vehicle_replace.css.lua):
--   Fahrzeugart und Sortierung
--   [Altes Modell]   [    ]   [Neues Modell]
--   [Auswahlliste]   [Pfeil]  [Auswahlliste]   <- Pfeil steht mittig zu den Listen
--   [grosses Bild]   [    ]   [grosses Bild]
--   Anzahl und Kaufpreis                 [Ersetzen]
-- Feste Breiten und Hoehen: Liste, Popup und Fenster aendern ihre Groesse nicht, egal was gewaehlt ist.
-- styleutil.makeStyle kennt nur size, keine minSize/maxSize/gravity/padding; die stehen daher in Klassen.

local ITEM_NAME_CHARS = 42 -- laengere Namen werden gekuerzt, voller Name als Tooltip
-- Umschalter der Fahrzeugart: bleibt sichtbar, das Depot waehlt seine Art nur vor (ersetzt wird ohnehin ueberall)
local SHOW_CARRIER_BAR = true

local function text(s, class)
	return builtin.TextView{ meta = { class = class or "font-scale-body" }, text = s }
end

-- Modellnamen enthalten teils Zeilenumbrueche (Name und Lackierung); im Eintrag steht alles in einer Zeile
local function oneLine(s)
	return (tostring(s or ""):gsub("%s*\n%s*", " "))
end

-- kuerzt nach Zeichen, nicht nach Bytes, damit Umlaute heil bleiben
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

-- Frachten als eigene Zeile unter Bild und Text: Felder fester Groesse, immer gleich viele, damit alle Eintraege
-- gleich hoch sind. Passen nicht alle Frachten, zeigt das letzte Feld "+n"; alle Namen stehen im Tooltip.
-- Ohne Fracht (Loks) bleibt die Zeile leer.
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

-- Eintrag: kleines Bild links, rechts Name und zweite Zeile. Immer zwei Zeilen und ein Bildfeld gleicher
-- Groesse, auch ohne Bild; so sind alle Eintraege gleich gross und Liste wie Popup springen nicht.
-- Der Inhalt muss eine Komponente sein, ein Layout allein laesst das Spiel abstuerzen.
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

-- Liste mit Platzhalter als erstem Eintrag: ohne Auswahl zeigt sie ihn, statt leer und schmaler zu werden
local NONE = "none" -- nicht leer: ein leerer Wert gilt im Spiel womoeglich als keine Auswahl
-- content: kurze Beschreibung von Auswahl und Eintraegen. Die Liste des Spiels behaelt ihre Anzeige, wenn sich
-- ihre Eintraege aendern (nach dem Ersetzen stand links noch das alte Modell, darunter schon das neue Bild).
-- Aendert sich content, bekommt sie einen neuen localKey und wird frisch aufgebaut (wie construction.tl).
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

-- Zelle fester Breite; kind "cell" fuer die Spalten, "mid" fuer die schmale Mitte
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

-- grosses Bild des gewaehlten Modells in fester Flaeche; ohne Modell bleibt die Flaeche leer
local function bigPicture(i)
	if i and i.iconBig and i.iconBig ~= "" then
		return builtin.ImageView{ meta = { class = "mvr-big-image", tooltip = oneLine(i.name) }, path = i.iconBig, scaling = builtin.type.ImageViewScaling.AutoFit }
	end
	return builtin.Component{ meta = { class = "mvr-big-image" } }
end

-- Fahrzeugarten mit den Symbolen der Fahrzeugverwaltung; nil = alle
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

-- Fahrzeugart eines Depots. Das Feld carrier ist im Spiel teils leer (Log: nil); dann aus den Verkehrsarten
-- des Depots, zuletzt aus den Fahrzeugen, die gerade darin stehen.
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
	if not ok or not d then log("Depot ohne VehicleDepot", tostring(depot), tostring(d)); return nil end
	local okC, c = pcall(function() return d.carrier end)
	if okC and c ~= nil then return c end
	-- Verkehrsarten: eindeutig, wenn alle zur selben Fahrzeugart gehoeren
	local found, modes = nil, {}
	local okM = pcall(function()
		for mode, enabled in pairs(d.transportModes) do
			if enabled then
				for key, carrierKey in pairs(MODE_TO_CARRIER) do
					if enumValue("TransportMode", key) == mode then
						modes[#modes + 1] = key
						local v = enumValue("Carrier", carrierKey)
						if found == nil then found = v elseif found ~= v then found = false end
					end
				end
			end
		end
	end)
	log("Depot", tostring(depot), "carrier", tostring(c), "Verkehrsarten", okM and table.concat(modes, ",") or "?", "ergibt", tostring(found))
	if found then return found end
	-- Fahrzeuge im Depot
	local okV, list = pcall(api.engine.system.transportVehicleSystem.getDepotVehicles, depot)
	if okV and list then
		for __, v in ipairs(list) do
			local tv = api.engine.getComponent(v, CT.TRANSPORT_VEHICLE)
			if tv and tv.carrier ~= nil then return tv.carrier end
		end
	end
	return nil
end

-- Sortierung ------------------------------------------------------------------------------------------
-- "name": alphabetisch, Zahlen nach ihrem Wert (BR 50 vor BR 103), ohne Gross-/Kleinschreibung.
-- "year": nach Jahr der Einfuehrung, aelteste zuerst, bei gleichem Jahr nach Name.
-- In der Liste der alten Modelle stehen bei beiden zuerst die Fahrzeuge mit Antrieb, dann die Wagen.

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

-- Auswahl im Fenster; liegt ausserhalb des Rezepts, damit jedes Oeffnen frisch beginnt
local sel = { carrier = nil, locked = false, alt = nil, neu = nil, sort = "name", sameCargo = true }

local function topBar(update)
	local children = {}
	if SHOW_CARRIER_BAR or not sel.locked then
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
	end
	children[#children + 1] = gui_react_util.makeHorizontalSpacer()
	-- Frachtfilter abschaltbar: an = rechts nur Modelle, die alles laden koennen, was das alte konnte
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

local MvrContent = react.RegisterRecipe("MvrContent", function(p)
	react.useInputAction("IA_MENU_BACK", react.iaHandler(p.onClose))
	-- Zaehler nur zum Neuzeichnen; die Auswahl selbst steht in sel
	local tick = react.useState(0)
	local function update(change)
		change()
		tick:set(tick:old() + 1)
	end
	local resultState = engine_react_util.useStepState(function() return result.text end)

	local byKey = fleet()
	-- redraw at a year change, so models that expire or appear update while the window is open
	engine_react_util.useStepState(function() return api.engine.util.getYear() end)
	local year = api.engine.util.getYear()
	local carrier = sel.carrier

	-- alt: alles, was gerade im Spiel ist (Einzelmodelle und Triebzuege), auf die gewaehlte Fahrzeugart beschraenkt
	local alts = {}
	for key, e in pairs(byKey) do
		local i = info(key)
		-- Attrappen (ohne Motor und Fracht) behandelt das Fenster gar nicht; im Zug bleiben sie beim Tausch stehen
		if i and i.class ~= "dummy" and (carrier == nil or e.carrier == carrier) then alts[#alts + 1] = { i = i, e = e } end
	end
	-- Triebzuege zuerst, dann Fahrzeuge mit Antrieb, dann Wagen
	local RANK = { self = 0, loco = 1, dummy = 2, wagon = 3 }
	local function rank(i) return RANK[i.class] or 4 end
	table.sort(alts, function(a, b)
		if rank(a.i) ~= rank(b.i) then return rank(a.i) < rank(b.i) end
		return compareModels(a.i, b.i, sel.sort)
	end)

	local altInfo = sel.alt and byKey[sel.alt] and info(sel.alt) or nil
	if altInfo and carrier ~= nil and byKey[altInfo.key].carrier ~= carrier then altInfo = nil end
	if not altInfo and alts[1] then altInfo = alts[1].i end

	-- neu passt zu alt: gleiche Fahrzeugart, gleiche Klasse, und neu kann mindestens jede Fracht laden, die alt konnte
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
			-- wie die Kaufliste: ohne filterTags nicht kaufbar (vehicle_store_util.depotMatchesVehicleFilterTags),
			-- z. B. Deko-Kopien anderer Mods ohne Bild; Gruppenkoepfe und Triebzugteile ebenfalls nicht
			if i and not i.noTags and not i.groupOnly and not i.muPart and fits(i) and available(i, year) then neus[#neus + 1] = i end
		end
	end
	table.sort(neus, function(a, b) return compareModels(a, b, sel.sort) end)

	local neuInfo = sel.neu and info(sel.neu) or nil
	if neuInfo and not (fits(neuInfo) and available(neuInfo, year)) then neuInfo = nil end

	local altItems = {}
	for k, x in ipairs(alts) do
		local second = count("mvr_n_vehicles", x.e.vehicles)
		if x.i.mu then
			-- Triebzuege: Zahl der Einheiten, bei Mehrfachtraktion dazu die Zahl der Zuege
			second = count("mvr_n_mus", x.e.parts)
			if x.e.parts ~= x.e.vehicles then second = second .. " " .. count("mvr_in_trains", x.e.vehicles) end
		elseif x.e.parts ~= x.e.vehicles and x.e.carrier == RAIL then
			-- Wagen und Loks kommen oft mehrfach in einem Zug vor: Stueckzahl und Zahl der Zuege
			second = count(x.i.engine and "mvr_n_locos" or "mvr_n_wagons", x.e.parts) .. " " .. count("mvr_in_trains", x.e.vehicles)
		end
		altItems[k] = item(x.i.key, x.i.name, second, x.i.icon, x.i.cargos)
	end
	local neuItems = {}
	for k, i in ipairs(neus) do
		local second = money(i.price)
		if i.yearFrom > 0 then second = second .. " · " .. tostring(i.yearFrom) end
		-- Triebzuege gleichen Namens gibt es in mehreren Laengen
		if i.mu then second = second .. " · " .. count("mvr_n_parts", #i.parts) end
		neuItems[k] = item(i.key, i.name, second, i.icon, i.cargos)
	end

	-- ohne neues Modell bleibt der Platz leer; zwei Zeilen, damit nichts springt
	local summary = { " ", " " }
	local e = altInfo and byKey[altInfo.key]
	local price = e and neuInfo and neuInfo.price * e.parts or 0
	local refund = (e and neuInfo) and residual(e, altInfo.key) or 0
	shownCost = price - refund
	-- the check below reads the balance now; this state only redraws the window when that answer changes
	engine_react_util.useStepState(function() return enoughMoney(shownCost) end)
	local affordable = enoughMoney(shownCost)
	-- redraw when the last callback of a batch arrives, so the button comes back
	engine_react_util.useStepState(pending)
	local busy = pending()
	if e and neuInfo then
		-- like the game, which shows only the net cost; the purchase price as long as nothing is credited
		local priceLine = refund ~= 0 and string.format(_("mvr_cost_net"), money(shownCost)) or string.format(_("mvr_price"), money(price))
		summary = { count("mvr_will_replace", e.vehicles), priceLine }
	elseif #neus == 0 and altInfo then
		summary = { _("mvr_none_buyable"), " " }
	elseif not altInfo then
		summary = { _("mvr_no_vehicles"), " " }
	end
	-- Ergebnis des letzten Ersetzens steht an derselben Stelle, bis ein neues Modell gewaehlt wird
	if not neuInfo and resultState:old() ~= "" then summary = { resultState:old(), " " } end

	local altContent, neuContent = {}, {}
	for k, x in ipairs(alts) do altContent[k] = x.i.key .. ":" .. x.e.parts .. ":" .. x.e.vehicles end
	for k, i in ipairs(neus) do neuContent[k] = i.key end
	neuContent[#neuContent + 1] = sel.sameCargo and "fracht" or "alle"
	local altCombo = combo(altInfo and altInfo.key, altItems, _("mvr_no_vehicles"), function(v)
		local i = info(v)
		if i then log("Auswahl alt", tostring(i.key), oneLine(i.name), "Klasse", tostring(i.class), "Motor", tostring(i.engine), "Ladung", tostring(i.load), "Triebzugteil", tostring(i.muPart or false), "Pfad", tostring(i.path)) end
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
		meta = {
			class = "primary, mvr-replace-btn" .. (affordable and "" or ", mvr-no-money"),
			-- disabled while the previous batch is still being replaced (issue #9)
			enabled = affordable and not busy,
			tooltip = not affordable and _("mvr_not_enough_money") or nil,
		},
		content = builtin.Component{
			layout = builtin.BoxLayout{
				orientation = builtin.type.Orientation.Horizontal,
				children = {
					builtin.ImageView{ meta = { class = "mvr-btn-icon" }, path = "::/gui/entity_window/icons/symbol_arrows_refresh.tga", scaling = builtin.type.ImageViewScaling.AutoFit },
					text(not affordable and _("mvr_not_enough_money") or busy and _("mvr_replacing") or _("mvr_replace")),
				},
			},
		},
		onClick = function()
			if not (altInfo and neuInfo) then return end
			local ok, err = pcall(replaceAll, altInfo.key, neuInfo.key)
			if not ok then
				result.text = _("mvr_error") .. " " .. tostring(err)
				log("Fehler", tostring(err))
			end
			-- Auswahl leeren: unten steht nun das Ergebnis
			update(function() sel.alt, sel.neu = nil, nil end)
		end,
	}

	local summaryLines = {}
	for k, line in ipairs(summary) do summaryLines[k] = text(line) end

	local children = {
		topBar(update),
		row({ cell("cell", text(_("mvr_old_model"))), cell("mid", empty()), cell("cell", text(_("mvr_new_model"))) }),
		row({ cell("cell", altCombo), cell("mid", swap), cell("cell", neuCombo) }),
		row({ cell("cell", bigPicture(altInfo)), cell("mid", empty()), cell("cell", bigPicture(neuInfo)) }),
		-- Abstand zwischen Bildern und Text; der Knopf bleibt mittig zum Textblock
		builtin.Component{ meta = { class = "mvr-gap" } },
		row({
			builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = summaryLines },
			gui_react_util.makeHorizontalSpacer(),
			button,
		}),
	}

	-- ein Rezept muss ein Layout liefern, keine Komponente
	return builtin.BoxLayout{ children = {
		builtin.Component{
			meta = { class = "mvr-content" }, -- feste Breite ergibt sich aus den Zellen
			layout = builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = children },
		},
	} }
end)

local windowOpen = false

local MvrWindow = react.RegisterWrapperRecipe("MvrWindow", builtin.Window, function(p)
	react.onUnmount(function() windowOpen = false end)
	return builtin.Window{
		meta = { class = "mvr-window" },
		id = "mass_vehicle_replace.window",
		-- 0 bis 1 ueber den Bildschirm wie die mittigen Fenster des Spiels (main_page 0.5/0.5);
		-- mittig steht es erst mit dem Anker der CSS-Klasse mvr-window
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
-- carrier: Fahrzeugart, auf die das Fenster beim Oeffnen eingestellt wird (nil = alle)
-- locked: aus dem Depot geoeffnet; ohne Umschalter (SHOW_CARRIER_BAR aus) bleibt es bei dieser Art
local function openWindow(carrier, locked)
	local wc = windowApi()
	if not wc then log("kein Fensterzugang"); return end
	result.text = ""
	-- a new window starts without pending commands, like the game's counter that lives with its component
	result.batch = result.batch + 1
	result.sent, result.ok, result.failed = 0, 0, 0
	sel.carrier, sel.locked, sel.alt, sel.neu = carrier, locked and carrier ~= nil or false, nil, nil
	log("Fenster", "Fahrzeugart", tostring(carrier), type(carrier), "Depot", tostring(locked))
	local ok, err = pcall(wc.addWindow, MvrWindow, WINDOW_KEY, { onClose = closeWindow })
	if ok then windowOpen = true else log("Fenster fehlgeschlagen", tostring(err)) end
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
			log("Depotknopf", tostring(depot))
			openWindow(depotCarrier(depot), true)
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
	}
end
