-- Mass Vehicle Replace: buttons and window. Fixed widths, so that list, popup and window do not jump.
-- Sum for one entry: list padding 12 + image 96 + gap 8 + text 290 = 406. Measured in the game, the list's
-- arrow starts at about 420 (cell 440), so the text ends just before it. Cargo row 394 wide:
-- 16 slots of 18 + 2 margin = 320, with more cargo 15 icons and a wider "+n" slot (300 + 24).
local ssu = require "::/gui/main/stylesheetutil.lua"

local CELL = 440
local MID = 48
local ITEM_IMAGE = { 96, 20 }
local ITEM_TEXT = 290
local CARGO_ICON = 18
local CARGO_ROW = ITEM_IMAGE[1] + 8 + ITEM_TEXT
local BIG_IMAGE = { CELL, 56 } -- as wide as the list: the fitted image sits centered below it
local STATS_HALF = CELL - 20

local function fixed(w, h)
	return {
		size = { w, h or -1 },
		minSize = { w, h or 0 },
		maxSize = { w, h or 10000 },
	}
end

local function with(t, extra)
	for k, v in pairs(extra) do t[k] = v end
	return t
end

function data()
	local result = {}
	local a = ssu.makeAdder(result)

	-- start position 0.5/0.5 means the corner of the window; with the anchor in the middle it is centered
	-- (the game's Company and Finances windows do the same)
	a("Window!mvr-window", {
		anchorPoint = { 0.5, 0.5 },
	})

	-- no padding at the top: below the title there would otherwise be more space above the icons than below them
	a("Window!mvr-window Window::Content", {
		padding = { 0, 12, 12, 12 },
	})
	a("Window!mvr-window BoxLayout", {
		innerSpacing = { 4, 8 },
	})

	-- cells of the rows: columns and narrow middle, centered in the row
	a("!mvr-cell", with(fixed(CELL), { gravity = { 0, 0.5 } }))
	a("!mvr-mid", with(fixed(MID), { gravity = { 0, 0.5 } }))
	-- the list fills its cell
	a("ComboBox!mvr-combo", {
		gravity = { -1, 0.5 },
	})
	-- swap icon centered in the middle: alignment has no effect in the cell, so the icon and equally
	-- wide margins on the left and right fill the middle exactly (10 + 28 + 10 = MID)
	a("ImageView!mvr-swap", with(fixed(28, 28), { margin = { 0, (MID - 28) / 2, 0, (MID - 28) / 2 } }))
	-- large image: fixed area across the full column width, the image is fitted centered
	a("!mvr-big-image", with(fixed(BIG_IMAGE[1], BIG_IMAGE[2]), { gravity = { 0, 0 } }))

	-- list entries (also shown in the popup, outside the window)
	a("!mvr-item-image", with(fixed(ITEM_IMAGE[1], ITEM_IMAGE[2]), { gravity = { 0, 0.5 } }))
	a("TextView!mvr-item-text", fixed(ITEM_TEXT))
	-- cargo row below image and text, left-aligned
	a("!mvr-cargo", with(fixed(CARGO_ROW, CARGO_ICON + 2), { gravity = { 0, 0 }, margin = { 2, 0, 0, 0 } }))
	a("!mvr-cargo-icon", with(fixed(CARGO_ICON, CARGO_ICON), { margin = { 1, 1, 1, 1 } }))
	a("TextView!mvr-cargo-more", with(fixed(24, CARGO_ICON), { margin = { 1, 1, 1, 1 } }))
	a("!mvr-item", {
		gravity = { -1, 0.5 },
	})
	a("!mvr-content", {
		gravity = { 0, 0 },
	})

	-- vehicle stats (#16): two halves of a fixed width below the two columns. The game's card around them takes
	-- 3 + 3 + 3 px on each side (content_card.css.lua: collapse margin, card-collapsible padding, card-margin-inner
	-- margin), so 2 x 420 + MID stays inside the window width and expanding does not widen it.
	a("!mvr-stats-half", with(fixed(STATS_HALF), { gravity = { 0, 0 } }))
	-- the game's spacing values: 8 between columns, 2 between rows like its entity window tables (entity_window.css.lua:623-626)
	a("TableLayout!mvr-stats", {
		innerSpacing = { 8, 2 },
	})

	a("!mvr-gap", fixed(10, 8))
	a("ImageView!mvr-btn-icon", with(fixed(20, 20), { margin = { 0, 8, 0, 0 } }))
	a("Window!mvr-window Button!mvr-replace-btn", {
		gravity = { 1, 0.5 },
		minSize = { 140, 0 },
	})
	-- not enough money: red like the game's buy button (vehicle_store.css.lua "R::VehicleCart !error!error!error",
	-- which only applies inside the purchase window); class repeated for precedence over the button states
	local okColors, colors = pcall(function()
		return api.gui.genericRep.get(api.gui.genericRep.find("::/gui/main/default_colors.gres")).data
	end)
	if okColors and colors and colors.Error then
		a([[Window!mvr-window Button!mvr-no-money!mvr-no-money!mvr-no-money,
			Window!mvr-window Button!mvr-no-money!mvr-no-money!mvr-no-money:hover]], {
			backgroundColor1 = colors.Error,
		})
	end
	-- money for some, not all (#23): yellow, the game's warning color with dark text on it, like its speed warning
	-- (entity_window.css.lua "R::SpeedIndicator TextView!warning": Warning background, NeutralDarkest text)
	if okColors and colors and colors.Warning then
		a([[Window!mvr-window Button!mvr-partial!mvr-partial!mvr-partial,
			Window!mvr-window Button!mvr-partial!mvr-partial!mvr-partial:hover]], {
			backgroundColor1 = colors.Warning,
		})
		if colors.NeutralDarkest then
			a([[Window!mvr-window Button!mvr-partial TextView,
				Window!mvr-window Button!mvr-partial ImageView]], {
				color = colors.NeutralDarkest,
			})
		end
	end

	a("Window!mvr-window ToggleButton!mvr-filter", {
		padding = { 0, 0, 0, 0 },
	})
	a("Window!mvr-window ImageView!mvr-filter-icon", {
		padding = { 6, 6, 6, 6 },
	})
	a("Window!mvr-window ToggleButton!mvr-sort", {
		padding = { 4, 10, 4, 10 },
	})
	a("Window!mvr-window ToggleButton!mvr-cargo-filter", {
		padding = { 4, 10, 4, 10 },
		margin = { 0, 16, 0, 0 },
	})

	return result
end
