function data()
	return {
		-- "Queued n" next to the game's earnings in the bottom bar; positive order appends it to the right of
		-- the game's own displays (they use negative values, game_bar_display_earnings.res.lua)
		type = "react-plugin ::GameBarInfoDisplayExtension",
		data = {
			filePath = "mass_vehicle_replace_1::/gui/mass_vehicle_replace.script@queueBar",
			order = 20,
		},
	}
end
