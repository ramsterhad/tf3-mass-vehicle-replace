# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
- Cargo icons for every model, in a row below image and name.
- "Same cargo" filter: only offer models that can carry at least everything the old one could. On by default, can be switched off.
- Sorting by name or year.
- Summary with the number of vehicles and the purchase price before replacing.
- The color of the old vehicles is kept where possible.
- Decorative models are hidden: copies without a store entry (e.g. from asset mods) and "fake" locomotives without engine and cargo.
- English and German.

[Unreleased]: https://github.com/ramsterhad/tf3-vehicle-bulk-replace/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/ramsterhad/tf3-vehicle-bulk-replace/releases/tag/v1.0.0
