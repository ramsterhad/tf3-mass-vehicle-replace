-- Mass Vehicle Replace: extension point of the replace window, for add-on mods (#24).
-- Registered like the game registers its own points (gui/main/main_mod_button_area.tl:7,
-- gui/entity_window/maintenance_station/maintenance_station_eow.script.tl:13): the name is qualified by the mod
-- id (gui/main/react.lua:67-77), so its full id is "mass_vehicle_replace_1::MvrReplaceWindowExtension".
--
-- An add-on adds UI next to the Replace button without replacing anything:
--   <addon>/content/gui/<addon>_mvr.res.lua
--     function data() return { type = "react-plugin mass_vehicle_replace_1::MvrReplaceWindowExtension",
--       data = { filePath = "<addon>::/gui/<addon>_mvr.script@Button", condition = "...@show", order = 10 } } end
--   <addon>/content/gui/<addon>_mvr.script.lua
--     local ext = ug_require "mass_vehicle_replace_1::/gui/mass_vehicle_replace_extension.lua"
--     M.Button = react.RegisterPluginRecipe(ext.MvrReplaceWindowExtension, "<Addon>Button", function(params)
--       return builtin.BoxLayout{ children = { builtin.Button{ ... } } } -- a plugin recipe must return a layout
--     end)
--
-- Plugin params, VERSION 1: a fresh plain table per plugin and render, never the window's own state.
--   version          VERSION below
--   oldKey, newKey   selected models ("m<modelId>" single model, "u<id>" multiple unit), nil if none
--   vehicles         number of the player's vehicles with the old model (0 if none)
--   units            number of old units in them (single parts or whole multiple units)
--   price            list price of the new units for all of them
--   cost             net cost: price minus the residual value credited, like the cost line
--   infiniteMoney    true when the balance is infinite (sandbox, "no costs"); price and cost then do not matter
--   affordable       the balance covers the whole replacement
--   affordableCount  without affordable: how many vehicles the balance covers now, oldest first (#23), else 0
--   affordableCost   net cost of those
--   busy             a replacement of this window is still running
--   oldUnit, newUnit units for mass_vehicle_replace_rebuild.lua (rebuild(cfg, oldUnit, newUnit, t)), nil if none
-- The window calls condition and recipe of every plugin in pcall: a plugin that throws there is left out and
-- logged once. Its recipe body runs later as its own node, outside the window's reach, so an add-on guards its
-- own body (the game takes the whole UI down on an error that escapes a recipe).
--
-- Versioning: VERSION grows only when an existing param changes its meaning or goes away. New params are added
-- without a new VERSION; a plugin treats a missing param as unknown.

local react = ug_require "::/gui/main/react.lua"

local NAME = "MvrReplaceWindowExtension"
local MOD_ID = "mass_vehicle_replace_1"

local M = {}

M.VERSION = 1

-- getOwningModId() is the mod of this file (api/tealdef/main.d.tl:49-57); read in pcall like other globals
local okMod, modId = pcall(function() return getOwningModId() end)
if not okMod or type(modId) ~= "string" or modId == "" then modId = MOD_ID end

-- A second registration of the same name returns nil with a warning (react.lua:69-72). That only happens when this
-- file is loaded a second time under another path spelling; the point is then already known to the game, and the
-- game only needs its id (react.lua:73-75, getPlugins :92-97), so that copy uses the same id.
M.MvrReplaceWindowExtension = react.RegisterExtensionPoint(modId, NAME) or { id = modId .. "::" .. NAME }

return M
