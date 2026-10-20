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
local SETTING = 140 -- width of the reserve field in the orders tab

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
	-- the TabWidget stacks its tabs and its framed content in an inner BoxLayout (debug.css.lua:59 "TabWidget > BoxLayout");
	-- the rule above put a gap between them (game test 20.10.2026), the game's tabs touch their frame
	a("Window!mvr-window TabWidget > BoxLayout", {
		innerSpacing = { 0, 0 },
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
	-- orders tab: as wide as the replace tab (two cells, the middle and the row spacing), so the window keeps its width
	-- when the tab changes (game test 20.10.2026: it was narrower)
	a("!mvr-orders", with(fixed(2 * CELL + MID + 8), { gravity = { 0, 0 } }))
	-- orders tab: wider gaps in the counter row of an order (game test 20.10.2026: too cramped). With the window in
	-- the selector, or the window's own BoxLayout rule above wins (game test 20.10.2026: the gap stayed small)
	-- the order between number and cancel takes the rest of the card; its rows stretch so the tiles share its width
	a("!mvr-order-body", {
		gravity = { -1, 0.5 },
		innerSpacing = { 8, 4 },
	})
	a("Window!mvr-window BoxLayout!mvr-order-head", {
		gravity = { -1, 0.5 },
		innerSpacing = { 8, 0 },
	})
	-- the four tiles of an order share its width
	a("Window!mvr-window BoxLayout!mvr-tiles", {
		gravity = { -1, 0.5 },
		innerSpacing = { 6, 0 },
	})
	-- custom: tiles with a label over a figure, the card variant the user chose (20.10.2026). The look is the game's
	-- own info box of the line manager (line_vehicle_mgmt.css.lua:884-893: button surface, AccentDark at half
	-- transparency), whose rule only reaches that recipe
	-- transparency (color further down)
	a("!mvr-tile", {
		gravity = { -1, -1 },
		padding = { 4, 8, 4, 8 },
		backgroundImage1 = {
			fileName = "::/gui/builtin/button/default_surface.tga",
			horizontal = { 0, 9, 21, 30 },
			vertical = { 0, 9, 21, 30 },
		},
	})
	a("Window!mvr-window BoxLayout!mvr-tile-rows", {
		innerSpacing = { 0, 0 },
	})
	-- number and cancel centered in the height of the card
	a("!mvr-order-side", {
		gravity = { 0, 0.5 },
	})
	-- custom: thin vertical lines around the order (number | order | cancel), asked for by the user (20.10.2026); the game has
	-- such a line only in its bottom bar, so this reuses that bar's divider image (game_bar.css.lua:884-889)
	a("!mvr-divider", {
		gravity = { 0.5, -1 },
		backgroundImage1 = { fileName = "::/gui/game_bar/design/tool_button/divider.tga" },
		size = { 2, -1 },
		margin = { 0, 8, 0, 8 },
	})
	-- orders tab: the reserve field
	-- with a fixed height like the game's own number fields (camera_tool.css.lua:44-47: 24): without it the field
	-- grew huge in the game (game test 20.10.2026)
	a("!mvr-setting", with(fixed(SETTING, 24), { gravity = { 0, 0.5 } }))

	-- vehicle stats (#16): two halves of a fixed width below the two columns. The game's card around them takes
	-- 3 + 3 + 3 px on each side (content_card.css.lua: collapse margin, card-collapsible padding, card-margin-inner
	-- margin), so 2 x 420 + MID stays inside the window width and expanding does not widen it.
	a("!mvr-stats-half", with(fixed(STATS_HALF), { gravity = { 0, 0 } }))
	-- the game's spacing values: 8 between columns, 2 between rows like its entity window tables (entity_window.css.lua:623-626)
	a("TableLayout!mvr-stats", {
		innerSpacing = { 8, 2 },
	})

	a("!mvr-gap", fixed(10, 8))
	-- the summary stretches to the height of the button and the box beside it; its spacers spread the lines
	a("BoxLayout!mvr-summary", {
		gravity = { 0, -1 },
	})
	-- the place of the order box while there is none (a CheckBox line of the game is about 24 high)
	a("!mvr-box-slot", fixed(1, 24))
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
	-- the tiles of an order: AccentDark at half transparency like the game's info box (color_util.tl:53-55
	-- withTransparencyRaw keeps red, green and blue and sets the fourth value)
	if okColors and colors and type(colors.AccentDark) == "table" then
		a("!mvr-tile", {
			backgroundColor1 = { colors.AccentDark[1], colors.AccentDark[2], colors.AccentDark[3], 0.5 },
		})
	end
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
	-- the direction icon in the active sort button, like the purchase window's (fixed size, see ui_check)
	a("ImageView!mvr-sort-icon", with(fixed(14, 14), { margin = { 0, 0, 0, 4 } }))
	a("Window!mvr-window ToggleButton!mvr-sort", {
		padding = { 4, 10, 4, 10 },
	})
	a("Window!mvr-window ToggleButton!mvr-cargo-filter", {
		padding = { 4, 10, 4, 10 },
		margin = { 0, 16, 0, 0 },
	})

	-- queue window: the game's spacing values (tf3-ui-design skill). Card body rows 4 apart, 8 between a label
	-- and its control (box-plugin-vertical-space, entity_window_util.css.lua); button rows 4 apart
	a("!mvr-rows", {
		innerSpacing = { 8, 4 },
	})
	a("!mvr-row", {
		innerSpacing = { 8, 0 },
	})
	a("!mvr-tools", {
		innerSpacing = { 4, 4 },
	})

	return result
end
