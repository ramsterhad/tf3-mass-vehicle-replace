-- Mass Vehicle Replace: rebuild of a consist, shared with add-on mods (#24).
-- Pure functions over the game's TransportVehicleConfig (api/tealdef/api/type.d.tl:1502-1544): no react, no GUI,
-- no state, so an add-on can load it in its own GUI script with
--   local rebuild = ug_require "mass_vehicle_replace_1::/gui/mass_vehicle_replace_rebuild.lua"
-- and check rebuild.VERSION first.
--
-- Interface, VERSION 1:
--   groupsOf(cfg) -> { { from, to, path } }
--   groupReversed(cfg, group, unit) -> boolean
--   newPart(model, reversed, color, purchaseTime) -> TransportVehiclePart
--   rebuild(cfg, oldUnit, newUnit, purchaseTime) -> TransportVehicleConfig, units | nil
-- A unit is a plain table:
--   single model:   { mu = false, id = modelId, compartments = n }
--   multiple unit:  { mu = true, path = file name, parts = { { info = { id, compartments }, forward }, ... } }
-- The window hands both units of the current selection to its plugins (oldUnit, newUnit), see
-- mass_vehicle_replace_extension.lua.
--
-- Versioning: VERSION grows only when an existing function changes its arguments, results or meaning.
-- New functions are added without a new VERSION; check them with type(rebuild.fn) == "function".
-- Callers must not write to this table, it is shared with Mass Vehicle Replace itself.

local M = {}

M.VERSION = 1

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

M.groupsOf = groupsOf
M.groupReversed = groupReversed
M.newPart = newPart
M.rebuild = rebuild

return M
