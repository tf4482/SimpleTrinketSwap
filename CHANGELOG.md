# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Priority list of trinkets per trinket slot; a trinket may be in both lists
- One passive trinket per list as filler, always last
- Automatic swap to the highest-priority ready trinket out of combat
- Trinket sets tied to the equipment manager's sets, Default set without them
- Settings page with all lists, and `/sts` chat commands

### Fixed

- Equipping falls back to the global `EquipItemByName` when `C_Item.EquipItemByName` is missing
- A failed swap between the trinket slots no longer leaves a trinket on the cursor
