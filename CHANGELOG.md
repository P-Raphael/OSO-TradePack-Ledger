# Changelog

## [1.1.1] - 2026-06-11

### Fixed
- **Auroran Cargo payout detection** — Fixed regression where Auroran Cargo sales with non-Onyx payouts (e.g. Dragon Essence Stabilizer) were incorrectly resolved as Onyx. The addon now trusts the captured item type from the sale event, preventing name-based fallbacks from overriding real data.
- **PAID record price updates** — Records marked as PAID no longer update with live price changes. Payout snapshots are locked when delivery completes, ensuring profit calculations remain final.
- **Broken record cleanup** — Removed ghost records with missing or malformed cargo names that displayed as "? ? ? ?" in the ledger.
- **Legacy Onyx item-type support** — Old records carrying stale Onyx item-type IDs from prior game patches (e.g. 1107253) continue to resolve correctly as Onyx.

### Added
- **Sold-at timestamp** — Details panel now displays "Turned in: YYYY-MM-DD HH:MM" for each trade pack, allowing verification of when payouts were delivered.
- **First/Last page buttons** — Navigation bar now includes `<<` (first page) and `>>` (last page) buttons alongside the existing `<` and `>` buttons.
- **Larger detail panel** — Increased from 6 to 7 detail lines and window height from 744 to 762 pixels to accommodate the new timestamp while preserving material cost display.
- **Improved pagination** — Button sizing standardized at 26×22 with 2px spacing for cleaner layout.

## [1.0.1] - 2026-06-10

### Fixed
- Fixed Onyx price resolution for records with stale item-type IDs
- Added version label to UI

## [1.0.0]

### Initial Release
- Trade pack ledger with cost tracking
- Live auction house price lookups
- Delivery countdown timer
- Pending vs. paid pack separation
- Historical profit summary
