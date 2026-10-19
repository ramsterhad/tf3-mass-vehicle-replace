function data()
	return {
		-- the replacement queue's ticker: an invisible plugin at the game's mod entry point (always mounted),
		-- see the script; adds a plugin, replaces nothing
		type = "react-plugin ::ModEntryPointExtension",
		data = {
			filePath = "mass_vehicle_replace_1::/gui/mass_vehicle_replace.script@queueHost",
			order = 20,
		},
	}
end
