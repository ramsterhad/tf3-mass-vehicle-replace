# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Orders (#23, stage 2): when the money does not cover all vehicles, a box "Order the other n as soon as money allows" appears above the warning line. With it ticked, the yellow button replaces what the balance covers now and puts the rest on order, oldest first; with nothing affordable it says "Order 8". About once a second of real time, the orders replace as many vehicles at once as the balance minus a reserve covers (oldest first, up to 100 per second), also while the game is paused. A new order takes over vehicles from older ones (a newer model came out: order that one instead), and replacing vehicles at once takes them out of the orders. Orders are kept in the savegame and survive saving, a restart and loading.
- The replace window has two tabs, "Replace" and "Orders (n)". The box "Order the other n" sits under the replace button. The orders tab shows one numbered card per order; below the list one row with the reserve (stays on the account, hidden with infinite money), "Hold orders" and "Cancel all" (with the game's confirmation dialog): both models with their small images, four tiles "Open", "Skipped" (the reasons in the tooltip), "Next" and "Total" (the price of the next vehicle and of all open ones, live while the game runs) and "Cancel"; "Model no longer available" in red instead of the tiles when the new model can no longer be bought.
- Numbers carry the game's thousands separator.
- Both model lists start sorted by year: the old list oldest first, the new list newest first.
- Each queued vehicle is checked right before its command is sent: sold or handed to another player, entity id reused, or already carrying the new model (replaced by hand) is skipped and counted; a new model that is no longer for sale or unknown (mod removed) blocks only that job, the jobs behind it go on. A command the game refuses three times drops the vehicle; a command without an answer for 10 s is resolved by looking at the vehicle. Five Lua errors in a row pause the orders and the window says so.

## [1.1.0] - 2026-10-19

### Added

- A warning below the cost line when the new model has a different engine type than the old one, e.g. diesel to electric (#50). The tooltip reminds you to check that every line is equipped for it, such as with catenary.
- When the money does not cover the whole replacement, the button turns yellow and says "Replace 7 of 8" (#23). It replaces only the vehicles the balance covers now, oldest first; each vehicle (a whole train) is replaced completely or not at all. The result line says how many of all were replaced. The red "Not enough money" stays for when not even one vehicle is covered.
- A collapsible "Details" card at the bottom of the window compares the old and the new model value by value (#16), the better value in blue and the worse one in red.
- The result line after replacing shows once, when the game has answered for every vehicle, instead of counting up from "0 of 8".
- Vehicles the game refuses to replace are named apart from those skipped for money, e.g. "Replaced: 7 of 8 (1 planned vehicle was rejected by the game)".
- The window keeps the sorting of both lists, the "Same cargo" filter and whether the "Details" card is open in the savegame, so they survive a restart.

### Changed

- The new list preselects its top model like the old list, so no empty line stands at the top of the open list; replacing still needs the click. Right after a replacement it waits for a choice, so the result line stays visible.
- The old and the new list each have their own sort buttons (name or year). A second click on the active button reverses the order, shown with the game's sort icons. By year the old models start oldest first, the new ones newest first, as a player usually looks for the latest model.
- When the residual value of the old vehicles is higher than the price of the new ones, the window says "Proceeds after residual value: $100" instead of a negative cost ("$-100"). The game credits that amount.
- With infinite money (sandbox mode, "no costs") the window no longer shows the cost line, like the game hides the balance in the depot window (#20). The prices in the model list stay.
- The cost line updates twice a second instead of every frame while the game runs. With many vehicles of the selected model (1450 trucks in a test) the window cost frames, because every update reads the residual value of each vehicle.

### Fixed

- The window now notices when vehicles are bought, sold, handed to another player or rebuilt in the game's own vehicle window while it is open, and updates the count (#10).
- The window no longer reads the whole fleet again on every redraw, only when the fleet changes.
- With a model selected, the open lists no longer show an extra first line ("No vehicles of this type" on the left, empty on the right).

## [1.0.3] - 2026-10-17

### Changed

- The depot is now read through the game's extension point for the depot window. The depot window itself is no longer replaced, so mods that change it no longer conflict with this one (#8).
- Internal names (recipes, CSS classes, translation keys) carry the prefix "mvr", so they cannot clash with other mods.
- Development log lines are no longer written to `stdout.txt` (#19). Errors, warnings and the startup line about other mods' replacements stay.
- Code comments, log lines and tests are in English, dead code is removed (#11, #12). No change in behaviour.

### Fixed

- Replacing was blocked although the balance covered the cost after the residual value of the old vehicles (#26). Like the game's purchase window, the money check now subtracts the residual value; trains where some vehicles stay (e.g. a new locomotive in front of the old wagons) are priced like the game's "Modify" window. The window shows the cost after residual value and keeps it up to date while the game runs.
- With several depot windows open, the button always opens the depot of its own window (#4).
- If another mod overwrites the game's button bar in an incompatible way, only the depot button is switched off instead of the game crashing.
- Reversed vehicles came back facing forward after replacing them (#7): multiple units, and single models replaced by a multiple unit or the other way round (e.g. Talent 1 by Talent 2). The new vehicle now faces the same way as the old one.
- Trains with inconsistent group data (more group slots than vehicles) were skipped when replacing (#13). Group sizes are now clamped to the vehicles that exist.
- Vehicles owned by someone else were listed and replaced at the player's cost (#1). Every campaign mission with vehicles hands some of them to an AI player. Only the player's own vehicles are listed and replaced now.
- A new model that expired while the window was open (turn of the year) could still be bought (#3). The window now updates at a year change, and Replace checks availability again.
- Multiple units where one part has no end year expired too early (#3). Like the game's store, such a unit now stays available.
- Clicking Replace again before the game had carried out the first replacement could replace the same vehicles twice (#9). The button now shows "Replacing …" and stays disabled until the game has answered every command.

## [1.0.2] - 2026-10-16

### Fixed

- Vehicles could be replaced beyond the money balance, which the game itself does not allow (#21). The full purchase price must now be covered, otherwise the Replace button is disabled and shows "Not enough money". Infinite money is not affected.
- Lua error "bad argument #2 to 'format' (not a number in proper range)" after replacing vehicles when the money balance is extremely large, e.g. set by a money mod or cheat. The internal money log that caused it has been removed.
- The same error could occur when sorting the lists if a vehicle name contains a run of 19 or more digits.

## [1.0.1] - 2026-10-16

### Fixed

- Crash ("attempt to call field '?'") when opening a depot together with other mods that replace the window button bar, e.g. "Manage Line from Vehicle". The button bar is now replaced through the game's replacement API, and replacements by other mods stay in the chain.

## [1.0.0] - 2026-10-15

First public release. Versions 0.x were internal test builds.

### Added

- "Replace Vehicles" button in the depot window, next to "Manage Vehicles".
- Replace window: old model on the left (only models you own, with their count), new model on the right (only models that are currently available).
- Replaces all vehicles of the chosen model across the whole game, on every line, using the game's own replace command.
- The depot's vehicle type is preselected, icons at the top switch to another type.
- Locomotives are only replaced by locomotives, wagons only by wagons.
- Multiple units are listed and replaced as complete sets, with the number of cars shown.
- In mixed trains only the chosen model is replaced, the rest of the train stays.
- Reversed locomotives, wagons and multiple units stay reversed.
- Cargo icons for every model, in a row below image and name.
- "Same cargo" filter: only offer models that can carry at least everything the old one could. On by default, can be switched off.
- Sorting by name or year.
- Summary with the number of vehicles and the purchase price before replacing.
- The color of the old vehicles is kept where possible.
- Decorative models are hidden: copies without a store entry (e.g. from asset mods) and "fake" locomotives without engine and cargo.
- English and German.

[Unreleased]: https://github.com/ramsterhad/tf3-mass-vehicle-replace/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/ramsterhad/tf3-mass-vehicle-replace/compare/v1.0.3...v1.1.0
[1.0.3]: https://github.com/ramsterhad/tf3-mass-vehicle-replace/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/ramsterhad/tf3-mass-vehicle-replace/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/ramsterhad/tf3-mass-vehicle-replace/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/ramsterhad/tf3-mass-vehicle-replace/releases/tag/v1.0.0
