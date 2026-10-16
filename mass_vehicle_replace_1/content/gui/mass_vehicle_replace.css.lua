-- Mass Vehicle Replace: Knoepfe und Fenster. Feste Breiten, damit Liste, Popup und Fenster nicht springen.
-- Rechnung fuer einen Eintrag: Innenabstand der Liste 12 + Bild 96 + Abstand 8 + Text 290 = 406. Im Spiel gemessen
-- beginnt der Pfeil der Liste etwa bei 420 (Zelle 440), der Text endet also knapp davor. Frachtzeile 394 breit:
-- 16 Felder zu 18 + 2 Rand = 320, bei mehr Frachten 15 Symbole und ein breiteres Feld "+n" (300 + 24).
local ssu = require "::/gui/main/stylesheetutil.lua"

local CELL = 440
local MID = 48
local ITEM_IMAGE = { 96, 20 }
local ITEM_TEXT = 290
local CARGO_ICON = 18
local CARGO_ROW = ITEM_IMAGE[1] + 8 + ITEM_TEXT
local BIG_IMAGE = { CELL, 56 } -- so breit wie die Liste: das eingepasste Bild steht mittig darunter

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

	-- Startposition 0.5/0.5 meint die Ecke des Fensters; mit dem Anker in der Mitte steht es mittig
	-- (so auch die Fenster Firma und Finanzen des Spiels)
	a("Window!mvr-window", {
		anchorPoint = { 0.5, 0.5 },
	})

	-- oben kein Innenabstand: unter dem Titel sonst mehr Luft ueber den Symbolen als darunter
	a("Window!mvr-window Window::Content", {
		padding = { 0, 12, 12, 12 },
	})
	a("Window!mvr-window BoxLayout", {
		innerSpacing = { 4, 8 },
	})

	-- Zellen der Zeilen: Spalten und schmale Mitte, mittig zur Zeile
	a("!mvr-cell", with(fixed(CELL), { gravity = { 0, 0.5 } }))
	a("!mvr-mid", with(fixed(MID), { gravity = { 0, 0.5 } }))
	-- Liste fuellt ihre Zelle
	a("ComboBox!mvr-combo", {
		gravity = { -1, 0.5 },
	})
	-- Tauschsymbol mittig in der Mitte: Ausrichtung wirkt in der Zelle nicht, daher fuellen Symbol und
	-- gleich breite Raender links und rechts die Mitte genau aus (10 + 28 + 10 = MID)
	a("ImageView!mvr-swap", with(fixed(28, 28), { margin = { 0, (MID - 28) / 2, 0, (MID - 28) / 2 } }))
	-- grosses Bild: feste Flaeche ueber die ganze Spaltenbreite, das Bild wird mittig eingepasst
	a("!mvr-big-image", with(fixed(BIG_IMAGE[1], BIG_IMAGE[2]), { gravity = { 0, 0 } }))

	-- Eintraege der Listen (stehen auch im Popup, ausserhalb des Fensters)
	a("!mvr-item-image", with(fixed(ITEM_IMAGE[1], ITEM_IMAGE[2]), { gravity = { 0, 0.5 } }))
	a("TextView!mvr-item-text", fixed(ITEM_TEXT))
	-- Frachtzeile unter Bild und Text, links buendig
	a("!mvr-cargo", with(fixed(CARGO_ROW, CARGO_ICON + 2), { gravity = { 0, 0 }, margin = { 2, 0, 0, 0 } }))
	a("!mvr-cargo-icon", with(fixed(CARGO_ICON, CARGO_ICON), { margin = { 1, 1, 1, 1 } }))
	a("TextView!mvr-cargo-more", with(fixed(24, CARGO_ICON), { margin = { 1, 1, 1, 1 } }))
	a("!mvr-item", {
		gravity = { -1, 0.5 },
	})
	a("!mvr-content", {
		gravity = { 0, 0 },
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
