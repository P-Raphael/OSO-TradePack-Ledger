# Changelog

## [1.1.2] - 2026-06-12

### Fixed
- **Wrong payout prices from unrelated auction searches** — Auction events triggered by the player's own auction-house activity (manual searches, browsing) were attributed to arbitrary pending price lookups, so item payouts (e.g. Dragon Essence Stabilizer) could be priced and locked at the cheapest listing of a completely unrelated item. The addon now only reads search results for searches it issued itself, and only stores lowest-price events that explicitly name the item. A one-time repair unlocks contaminated payout prices on unpaid records and purges the bad cached prices; PAID records keep their final profit.
- **Numeric payout names** — Records showing the raw item-type id (e.g. "127211") instead of the item name now resolve the real name from the id at display time as well as on load.
- **Onyx item-type detection** — The real Onyx auction item type is 32103; the large ids previously chased across "patches" (979983, 1107253, 1001195) are per-item instance ids the sale event leaks into the name/type fields. 32103 is now recognized, so Auroran Cargo turned in for Onyx displays "Onyx" again and gets the Onyx price sanity range applied.
- **Dragon Essence Stabilizer name and search** — Item type 32106 maps to "Dragon Essence Stabilizer" via a built-in name table (the client API fails to resolve it), enabling both correct display and the auction-house name-search fallback instead of relying on lowest-price events alone.

- **Queued searches dying with "No response"** — The 8-second response timeout started at refresh time for every lookup, so any search queued behind the first (e.g. Dragon Essence Stabilizer behind Onyx) timed out before its turn. The timeout now only ticks while a lookup's own search is active. Consecutive searches are also spaced 2 seconds apart, since the client silently drops a search fired immediately after the previous one.

### Removed
- **Leftover debug record** — Removed a debug block that injected a fake "Auroran Cargo / Dragon Essence Stabilizer" record (with a wrong hardcoded item id) into the ledger on every load. The injected record is deleted from saved data.

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
