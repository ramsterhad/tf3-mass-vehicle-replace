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
| Replacement queue ticker | `ModEntryPointExtension` plugin `MvrQueueHost` (invisible, `react.onStep` with a 1 s real-time throttle), order 20 | (already the smallest) |
| "Queued n" in the game bar | `GameBarInfoDisplayExtension` plugin `MvrQueueBar`, order 20, built like the game's earnings display | (already the smallest) |

The queue lives in the savegame's GUI save data (`getGuiSaveData(MOD_ID)`): strings and booleans only, field
`queueFormat` = `"1"`. Another format is left alone (not processed, never overwritten); a parser per old format
must stay when the format changes.

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
- Tests: `bash test/run.sh` in WSL (metadata, lint, luacheck, text check, Lua syntax, translations, mock test).
  luacheck runs from an unpacked Ubuntu package via `~/.local/bin/luacheck` (no sudo in WSL); CI installs `lua-check`.
  Code comments are plain ASCII (`test/textcheck.py`). Add game facts to the
  mock first; a new test must fail against the old code.
- What the tests can and cannot show (review 18.10.2026): they cover our own logic on our own data and the
  compatibility mechanics. They are blind to everything the engine delivers (types, values, when something
  changes), performance and looks; 5 of the 9 bugs that reached the game were of that kind.
  - Only facts seen in the game go into the mock. A new `api.*` access nobody has measured yet is "game test
    only": say so in the PR instead of inventing a mock for it.
  - A failing existing test is a finding first. Never change an existing test to make a fix pass unless the PR
    says so explicitly, with the reason (#10 attempt 1: a test caught the bug and was adjusted instead, addeb11).
  - Count honestly: `check` is one scenario assertion; per-node rules of rendered trees use `invariant`.
- Staging folder (what the game loads and uploads):
  `C:\Program Files (x86)\Steam\userdata\17526841\3493540\local\staging_area\mass_vehicle_replace_1`.
  Only mirror it from the repo, never patch it, with the private tf3-sdk script (WSL):
  `~/projekte/tf3-sdk/tools/stage.sh <repo> mass_vehicle_replace_1` for a dev build. It stamps the
  description in the staging copy only ("DEV-BUILD ..., branch, commit, time"), so the user sees in the
  mod hub under "My mods" which build the game loaded. Lint rejects the stamp in the repo.
- PR titles carry no version; each PR adds its entry under `## [Unreleased]` in the CHANGELOG.
- Release: its own commit `Release X.Y.Z` straight on `main` after the user's game test and OK: bump
  `revision` in `mod.json`, version line in `_metadata/modinfo.json` (both languages), turn `Unreleased`
  into `## [X.Y.Z] - date`; tag `vX.Y.Z`. Before the upload, ALWAYS mirror with
  `stage.sh --release <repo> mass_vehicle_replace_1`: plain mirror, fails if a DEV-BUILD stamp is left.
  The user uploads from the game; mod.io release notes in English only.
- Release notes for players (decided 17.10.2026; mod.io lists every upload as version "1.0", so the
  version must be in the texts). Claude prepares all of them, the user uploads:
  - `CHANGELOG.md`: the full entry (Keep a Changelog), the complete history lives here.
  - Top of the description in `_metadata/modinfo.json`, in both languages: the version line, then
    "Neu (mehr im Changelog unten)" / "What's new (more in the changelog below)" with the main points (no version
    there: the line above has it; not "Details": that is also a section name, user decision 19.10.2026), then "Was die
    Mod macht" / "What it does" over the introduction.
  - Bottom of the description, once, in English: "Changelog", newest version first, every bug fix and
    feature a player notices (no internal changes such as comments, tests, tooling), then a link to
    `CHANGELOG.md` on GitHub.
  - Changelog field of the upload dialog: English, version first, short summary of the new version.
  The game overwrites the mod.io description from `modinfo.json` on every upload, so edit it there only.
