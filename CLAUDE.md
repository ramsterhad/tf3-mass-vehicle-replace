# Mass Vehicle Replace: notes for Claude

Transport Fever 3 GUI mod. Mod folder `mass_vehicle_replace_1/`, offline tests in `test/`.

## Compatibility first

Load the `tf3-mod-compat` skill before changing any code. In short: smallest possible
hook, never overwrite game module fields, chain every recipe replacement, never break
other mods. `test/lint.py` enforces the mechanical part and runs in CI.

Mod prefix: **`mvr`**. Recipes `Mvr...`, CSS classes `mvr-...`, translation keys `mvr_...`,
log prefix `[MassVehicleReplace]`, window key `mass_vehicle_replace.window`.

Current hooks into the game, keep this list up to date:

| Hook | How | Why no smaller way |
|---|---|---|
| Depot entity | condition of a `MaintenanceStationEowExtensionPoint` plugin, always `false` | (already the smallest) |
| Button in the depot button bar | chained `ReplaceRecipe(ActionButtonBar)`, order 1000, recipe captured at load | the button bar has no extension point |

## Compatibility test mods

Keep these subscribed and active in the compatibility savegame; check `stdout.txt` after a start.

| mod.io id | modId | Touches |
|---|---|---|
| 6424111 | manage_line_from_vehicle | replaces `ActionButtonBar` (order 0, calls `CallOriginalRecipe` on the module field) |
| 6426728 | tf3_clean_hud | replaces HUD recipes |
| 6416547 | cayde_vue_vehicule_1 | wraps `react.useMirrorState` |
| 6416135 | zhenya_auto_assign_terminals | wraps `builtin.Button`, line manager recipes |
| 6416672 | zhenya_auto_color_lines | wraps `makeHorizontalSpacer`, `useStepState` |
| 6415575 | gabri_cargo_catchment_1 | `MaintenanceStationEowExtensionPoint` plugin |
| 6424525 | ui_overhaul_1 | wraps `ActionButtonBar` by swapping the field (Sell confirmation); switches it off when any mod replaces the bar, also ours |
| 6422607 | bulk_vehicle_replace | replaces the vehicle window, wraps `builtin.ImageView`/`ToggleButton` in the line manager only |
| 6424341 | quadraticfour_reworked_vehicle_maintenance | `MaintenanceStationEowExtensionPoint` plugin; suspected of the load crash on 16.10.2026 |

## Reported to other mods

Check for answers at the start of a session.

- [maxblan/ui-overhaul#9](https://github.com/maxblan/ui-overhaul/issues/9): Sell confirmation could chain instead of stepping aside (16.10.2026).

## Workflow

- Code changes on a branch, PR into `main` (squash), merge only after the user's game test and OK.
  Texts (README, CHANGELOG, description) may go straight to `main`. `main` is protected
  against force pushes and deletion.
- Tests: `bash test/run.sh` in WSL (metadata, lint, translations, mock test). Add game facts to the
  mock first; a new test must fail against the old code.
- Staging folder (what the game loads and uploads):
  `C:\Program Files (x86)\Steam\userdata\17526841\3493540\local\staging_area\mass_vehicle_replace_1`.
  Only mirror it from the repo, never patch it:
  `rsync -a --delete --exclude _metadata/mod.io_fileid.txt mass_vehicle_replace_1/ "<staging>/"` (WSL).
- Release: bump `revision` in `mod.json`, version line in `_metadata/modinfo.json` (both languages),
  CHANGELOG; tag `vX.Y.Z` on `main`. The user uploads from the game; mod.io release notes in English only.
