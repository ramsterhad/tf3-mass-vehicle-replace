function data()
	return {
		type = "react-plugin ::MaintenanceStationEowExtensionPoint",
		data = {
			-- only reads the depot entity in its condition and never shows anything, see the script
			filePath = "mass_vehicle_replace_1::/gui/mass_vehicle_replace.script@depotProbe",
			condition = "mass_vehicle_replace_1::/gui/mass_vehicle_replace.script@depotProbeCondition",
		},
	}
end
