# Changelog

## [1.8.0] - 2026-10-14

### Graph controls and current rate labels
- Rename the ledger's Rates button to Graph Rates.
- Add a Text menu with detailed, compact and hidden pack rows. Hiding names and prices reduces the floating graph height while preserving its plot size and position.
- Add saved labels per pack/route through Text > Customize route labels. A custom label replaces the entire pack/origin/destination text in graph legends and headers. Blank labels restore the original text; custom labels do not affect pack identities, prices, history or selection lists.
- Show 5% axis marks such as 115% and 125% when the graph is tall enough. Switch to wider intervals on shorter plots and reuse hidden marks when resized taller.
- Connect actual minute readings across the expected route polling interval, with bounded timing allowance. Keep markers and coverage based on actual observations; longer gaps and incomplete aggregate buckets still break the line.
- Move the combined graph's update status to the right footer and display the selected Commerce proficiency mode on the left, beside Color.
- Bind both edges of the status label explicitly, with its right edge anchored before the resize handle. Restore those anchors after text changes in separate and combined graph footers.
- Show a loading message in the Rates pack picker while the selected route's available packs are being fetched. Keep saved selections usable and show request/retry progress until the list arrives.
- In the combined Rate graph, show the latest payout percentage at the right edge, using the matching series color so each value can be identified with its pack and route.
- Include the latest reading in the visible rate range and reserve space for the labels. Labels follow the plot during movement, updates and resizing. Separate close or equal values with a short colored guide to their exact rate height; add `*` when a displayed reading is stale.

## [1.7.6] - 2026-10-12

### Easier-to-read, customizable rate graphs
- **Rate + Price** and **Graph: Both** now show each pack's name and payout rate on the first line, with its estimated price directly below. The price remains visible in compact mode and at narrow widths; the graph background grows to fit the extra rows.
- Add **2h** and **3h** recent-history periods. Click the period shown on a floating graph to change it there; the selected period stays in sync across the full panel and all graphs.
- Add a **Color** control to floating graphs. Choose a preset or enter a custom `#RRGGBB` color for a pack and route. In the combined graph, select which route to customize. The color is used for its rate line, normal markers, price line, and legend, and is saved between sessions. **Automatic pack color** restores the default; amber partial-coverage markers retain their meaning.
- Validation covers narrow and compact graphs, period selection, custom color input and persistence, and rate/price color consistency. In-game appearance and mouse input still require a full client restart and visual check.

## [1.7.5] - 2026-10-12

### Align selected pack text with the graph background
- Explicitly left-align combined graph legend rows and clear inherited text insets. Names start at a small 10-unit left margin instead of leaving a large centered gap.
- Anchor each row to both edges of the same window that owns the background, with equal margins. Reapply those edge anchors after text changes, rather than assigning a standalone width that can disagree with the background during resizing.
- Keep native ellipsis, compact/detailed modes, and rate/price options. Regression checks cover left alignment, insets, both edge anchors, changing text, and 320–1000-unit chart widths at all three font sizes. Native appearance remains subject to an in-game check after restarting.

## [1.7.4] - 2026-10-12

### Bounded labels and simultaneous rate/price display
- Constrain graph text at the native label level: disable automatic label resizing, enable native ellipsis, and restore the label extent after changing its text. Font-width estimates alone did not prevent the selected pack rows from extending outside the background.
- **Values: Rate + Price** displays both current payout percentage and estimated gross price in graph labels while preserving the selected plot metric. The setting is saved; **Values: Selected** restores the previous display.
- **Graph: Both** plots percentage as solid lines against the left axis and estimated gross price as dashed lines against a separate right gold axis. Available in full, separate, and combined views; both values appear in labels and full-view point details. Series keep their pack colors.
- Price lines use the same server-specific payout, Commerce, and freshness calculation already used by Price mode. Missing prices leave the percentage line intact and an explicit unavailable-price label. Existing observation gaps remain gaps, and display changes make no additional native queries.
- Reuse the secondary plots and geometry, follow graph resizing, hide them when leaving Both mode, and reduce tick density on small charts. Regression checks cover native label auto-growth, separate scales, missing prices, mode switches, restart settings, and unchanged-data redraw costs. In-game appearance still requires a full restart and visual verification.

## [1.7.3] - 2026-10-12

### Keep selected pack text inside the graph background
- Fit combined-chart legend rows using the native font's measured text width at the selected text size instead of an average character-width estimate. Reserve padding for outlined text and shorten names before the value/reading age where possible.
- Apply the same fitting to compact and detailed legends. Cache unchanged measurements; resize and font changes recalculate the fit. Mock regressions cover wide lettering, all three font sizes, and narrow/wide charts. Native visual fit still requires an in-game check.

## [1.7.2] - 2026-10-12

### Resizable floating charts and compact text
- Drag the **//** handle at the bottom-right of a separate or combined graph to resize its width and plot height independently. Plot lines, axes, tick positions, empty states, backgrounds, and controls follow the new dimensions; resizing preserves the graph's screen position.
- **Text** toggles detailed labels or compact text. Compact separate graphs combine pack/route information, value, and period in one header; combined graphs use one legend line per selected route. Names shorten to fit narrow widths and reveal more text when widened.
- **Aa** cycles 12, 14, and 10 point text independently for each graph. Size and text options survive restarts, with separate settings for each pack-and-route and for the combined view. Retain custom settings for up to 12 recently positioned routes, prioritizing active selections.
- Width is bounded to 320–1200 logical UI units and plot height to 80–500. Live resizing is throttled; settings save on release. Resizing invalidates cached geometry so unchanged readings redraw at the new scale without new server requests.
- Syntax and mock regression checks cover resized line geometry, UI scaling, independent preferences, compact layout, bounds, and restart persistence. Native sizing and visual text fit require in-game validation after a full client restart.

## [1.7.1] - 2026-10-12

### Free graph placement, readable menus, and background options
- Fix scaled graph positions jumping when dropped or reopened. Save without rebuilding anchors on release, preserve placement while legends grow, and let graph bodies extend beyond screen edges while keeping saved titles reachable. Full Rates layout refreshes no longer interrupt an active drag.
- Add a saved **Graph background** setting: Transparent, Shaded (50%), or Dark (90%). The **BG** control on each floating graph cycles the same shared preference for separate and combined graphs; backdrops remain behind the content and preserve click-through behavior.
- All Rates pickers now have Close/Done controls and toggle closed from their selector. Raise menus and the custom period editor above dynamically created chart labels, including after refreshes. Use opaque menu backgrounds in Rates, the ledger pack list, and cost editors.
- Regression coverage includes scaled dragging and restart, partial offscreen placement, changing combined legends, picker dismissal/layering, and background persistence/reuse. Native rendering and mouse behavior still require an in-game check after a full restart.

## [1.7.0] - 2026-10-12

### Compare packs across routes with readable graph scales
- Each selected pack now keeps its own origin and destination. Changing From/To browses another route without clearing selections. The Pack list shows full names and routes, with existing selections first; up to six entries can include the same pack delivered to different destinations.
- Keep quotes, hourly/minute history, graph positions, and price/freshness calculations separate by pack and route. Migrate previous single-route selections and positions. Replies belong to the requested route even if the browser changes while waiting; an omitted pack retains its last reading and age.
- Cycle unique selected routes through one request at a time, respecting the existing global 30-second minimum and any longer server cooldown. Packs sharing a route share its request. Show each reading's own age, and validate saved routes against the available zones before requesting them.
- **Graphs: Separate / Combined** chooses independently movable transparent mini-graphs or one transparent comparison graph with colored lines and route legends. **Show graphs** opens the chosen layout. Both layouts remember their positions and share the selected period and metric.
- Add labeled horizontal percentage brackets: normally 90%, 100%, 110%, 120%, and 130%, with bounds extended for readings outside that range. Price and Profit use suitable money intervals. Grid widgets and unchanged line geometry are reused; observation gaps remain gaps.
- Include the full Rates window dragging fix from 1.6.9. Expanded mock coverage includes cross-route identities, duplicate names, destination-specific payouts, serialized requests, restart migration, picker/graph integration, combined-view lifecycle, and axis bounds/caching. Native input and rendering require a full client restart and in-game validation.

## [1.6.9] - 2026-10-12

### Easier Rates window dragging
- Drag the full Rates window from its header, unused background, or noninteractive text. Previously only the small title label initiated movement.
- Keep buttons, dropdowns, comparison legends, and graph points clickable. Dragging still detaches the panel and saves its position with the current UI scale; transparent mini-graphs retain their existing controls.

## [1.6.8] - 2026-10-12

### Independently movable pack graphs
- **Show graphs** opens a separate transparent mini-graph for each selected pack, up to six. Drag each title to move that graph; positions are remembered per pack across selection changes and restarts. The first graph preserves the previous transparent overlay's position.
- Each mini-graph has its own value scale, current quote, reading age, coverage, and missing-data or missing-cost message. Route, period, metric, and price settings remain shared through the full Rates controls, which retain the combined comparison chart.
- Use **...** on a graph to reopen the full controls focused on that pack. Its **x** removes that pack from the selection; closing the last graph closes Rates while retaining the last pack for reopening.
- Reuse windows and unchanged line geometry, bound saved positions, and keep the existing shared route request and history queues. An empty selection retains a placeholder so controls and initial rate collection remain available.
- Added regression coverage for independent movement and scales, saved-position migration/restart, slot reassignment, shared periods, missing prices/costs, individual stale ages, default placement, screen clamping, and redraw/persistence overhead. Native rendering and dragging still require an in-game check after a full client restart.

## [1.6.7] - 2026-10-12

### Compare packs and complete delayed auction prices
- The Rates pack dropdown now keeps ticked selections open until Done, supports up to six packs, and remembers the selection. Both graphs use distinct colored series on one shared axis. Click a legend row or point in the full panel to choose the pack used for the headline, cost details, coverage, and best-hour text. Changing route resets the selection to the new route's available packs.
- Each series uses its own payout price and costs; a pack with missing prices or costs does not hide the other series. Legends retain stale observation/cached-cost warnings. The full panel and transparent overlay grow to fit their legends, including the full window's tint and border.
- Load only the selected period's history, share cached reads across selection changes, coalesce history redraws, and avoid rebuilding unchanged native line geometry. Selecting more packs still uses one request for the route at the existing cooldown.
- Auction requests now continue with the ledger and OPS control hidden, through a lightweight scheduler that pauses during loading. Turn-ins trigger a short fixed batching delay that further sales cannot keep extending, and entering the world reconciles unfinished prices.
- Refresh preserves in-flight and queued work. Removed the 25-item cutoff, prioritize missing ledger quotes before configured-item refreshes, and retry delayed/empty/rejected searches up to three times with backoff without blocking later ingredients. Keep the two-second search gap.
- Name-only payout quotes now complete the corresponding ledger records. Existing material/payout snapshots remain fixed. Corrected Onyx validation leaking into unrelated price replies and ownership of synchronous auction responses.
- Added comparison and auction-queue regression suites covering migration/restart, multiple series, shared axes, gaps, missing costs, native-geometry reuse, hidden-window pricing, more than 25 lookups, overlapping refreshes, bounded retries, loading transitions, snapshot preservation, and continuous turn-ins. Native rendering and real auction response timing still require a full client restart and in-game validation.

## [1.6.6] - 2026-10-10

### Explain unavailable graphs when changing periods
- Added messages inside the full and transparent plots for missing profit costs, unavailable payout/Commerce data, loading history, and periods with no observations. A selected period can have recorded rate readings while Profit remains unavailable.
- Added Show rate graph to the full plot when a money estimate cannot be calculated. The switch is explicit, preserves the selected period, and saves the metric choice. Period changes clear the previously selected point.
- Reproduced the reported missing Transport/Labor state in the graph mocks: switching 15m/30m/1h updates axis and coverage immediately, and choosing Rate renders the same collected observations without inventing costs.

## [1.6.5] - 2026-10-10

### Minute detail, background collection, profit and coverage
- Added 15-minute, 30-minute and 1-hour graphs using actual minute observations. Three reusable hourly slots per pack/route retain recent detail through restart; each has at most 60 readings and verified A/B commits. No hourly data is fabricated into minute history, and minute-storage failures do not block hourly collection.
- Added a saved, initially-off Collect while hidden toggle. Collection retains the existing request cooldown and background save budget while skipping hidden chart/Commerce/cost work. Saved routes survive temporarily empty route lists during login and retry automatically.
- Added estimated Profit alongside Rate and Price, using current exact-pack materials, transport and labor costs. Missing configuration or required prices leave the estimate incomplete. Both charts display losses and a grey zero-profit break-even line; historical estimates use current assumptions, with stale cached costs marked.
- Marked partially observed intervals amber and added coverage to the transparent overlay. Point details report observed minutes/hours and stay selected through refreshes. Gaps remain unconnected. Expanded the panel footer for collection and legend controls.
- Added minute persistence/recovery/size tests, a read-only cost-adapter suite, and graph integration checks for minute migration, profit signs/zero/missing prices, hidden restart collection, cooldowns and login recovery. Lua syntax, Folio105 pricing comparisons, ledger and turn-in performance mock checks pass. In-game rendering and live server behavior still require a full client restart and runtime validation.

## [1.6.4] - 2026-10-09

### Configurable graph periods
- Added a Period dropdown with recent presets from 6 hours to 30 days and a custom whole-hour input from 1 to 720 hours. The time-of-day view has a separate 1-to-30-day lookback. Both settings persist and also apply to the transparent graph.
- Kept the panel dimensions and moved the timezone selector to its bottom row. Point positions, axis labels, sample details, coverage, and best-hour calculations follow the selected period.
- Longer recent views average groups of hours into at most 30 points. Each observed hour has equal weight; empty intervals remain empty, and partially observed intervals break the line. Retained the partial first UTC day needed by a rolling 30-day window.
- Added checks for presets, custom input validation/cancel, independent saved periods, restart recovery, short/long chart geometry, date labels, weighted averages, gaps, future-data exclusion, and the history boundary. Pricing, refresh, ledger, and turn-in performance mock checks also pass; live widget/input behavior still needs verification after a full client restart.

## [1.6.3] - 2026-10-09

### Rate refresh recovery
- Moved the rate timer and response subscription onto a dedicated, always-shown empty window, independent of the OPS launcher, ledger, and full-panel visibility. Its update handler uses native millisecond frame times explicitly.
- Manual Refresh now expires a stuck request itself. Rejected requests and missing replies retry without leaving a permanent pending flag, and scheduling respects the cooldown returned by the game's specialty API.
- Accept matching-route replies observed from the older rate tracker so its five-second polling cannot keep extending a 30-second pause. Different-route replies remain excluded.
- Replaced the fixed refresh claim with a live request/countdown/cooldown status in the panel and transparent overlay. The graph still uses hourly averages and one recorded sample per minute.
- Added callback-driven checks for repeated refreshes, hidden-panel operation, millisecond timing, manual recovery, native cooldowns, failed requests, same-route sharing, and closed-panel polling limits. Live server delivery still needs in-game verification.

## [1.6.2] - 2026-10-09

### Server price estimates
- Matched Folio105's price calculation: reference coefficient × payout percentage × Commerce bonus × selected freshness bonus, rounded down to copper. The current quote, historical price graph, point details, and transparent overlay use the same formula.
- Added a Prof selector for current Commerce (including bonus points), OFF, 272k, or 332k, plus an optional Max freshness toggle with Folio105's pack categories and Heedmar rule. Current Commerce is the default; maximum freshness starts off because carried-pack age is not detected.
- Saved both settings and recalculate existing observations immediately when they change. Missing Commerce data is shown explicitly; current-skill reads are limited to once per five seconds while the panel is visible.
- Added pricing comparisons against Folio105's actual formula and all reference price tables, plus checks for current-skill changes, missing data, display consistency, and settings persistence.

## [1.6.1] - 2026-10-09

### Line charts
- Replaced bars with native line charts in the Rates panel and transparent Graph only overlay, for both rate and price views.
- Kept small markers for individual observations, clickable sample details in the full panel, and breaks wherever an hour has no data. The overlay remains transparent and ignores clicks through the chart area.
- Added checks for rising, falling, and flat lines, isolated points, gaps, metric changes, and clearing old graph data. Live rendering still needs verification after a full client restart.

## [1.6.0] - 2026-10-09

### Route rates and graphs
- Added a Rates side panel with origin, destination, and full-name pack dropdowns, 30-second payout-rate refreshes, last-update age, and base price estimates where reference prices are available.
- Added detachable positioning and a transparent Graph only overlay that stays open independently of the ledger. Positions, selected route/pack, metric, timezone, and display mode are saved.
- Added graphs for recent hourly averages and time-of-day averages across 30 days. Missing observations stay empty, days receive equal weight, and the best observed hour requires several days of coverage.
- Kept rate history separate from sales, with small verified daily save banks, one sample per minute per pack, and background jobs spread across updates. Queries stop when the panel is closed; the existing turn-in performance checks remain unchanged.
- Added tests for route-response ownership, polling limits, detaching and transparent mode, persistence/recovery, timezone grouping, daily weighting, and retention. Live widget rendering and server replies still require in-game verification after a full restart.

## [1.5.13] - 2026-10-08

### Turn-in performance
- Save each new ledger record once, including its history fields, and verify it immediately. History still recovers a sale if its separate summary save is interrupted.
- Keep record chunks in stable ID order so a new sale does not shift every saved chunk. Reuse independent, verified chunk snapshots for unchanged records, runs, and history maps; changed chunks and commit pointers still require readback verification.
- Convert older record storage and warm the save caches during addon startup, keeping the first turn-ins after loading inexpensive too.
- Skip ledger and history rendering while their windows are closed. Opening them displays current data; auction updates and failed-history retries continue to maintain saved totals with both windows closed.
- Added mock benchmarks with 100 and 1,000 records, immediate-reload checks, and failed-write/migration recovery coverage. These measure addon work rather than in-game frame rates.

## [1.5.12] - 2026-10-03

### History save verification
- Accept the client's expected single-precision rounding when reading back `totalProfitCopper`. The old exact comparison could reject a complete history save after profits grew large, leaving the previous history bank active and showing a save failure.

## [1.5.11] - 2026-10-03

### Labor cost repair
- Use the working multiline editbox for cost inputs and validate empty reads without a Lua error. The single-line widget could throw when saving labor points, so no rule was stored.
- Read auction listing buyout prices through `GetSearchedItemPrice`, as the client auction UI does. Bid-only listings still do not count.
- Save labor auction quotes in a small verified key, separate from the oversized general price cache, so the selected labor rate survives a restart.

## [1.5.10] - 2026-10-01

### Labor editor and details
- Reopening a cost editor no longer collides with its ledger button's widget name. The editor opens on the currently selected ledger pack, so a saved labor rule applies to the pack being inspected.
- Details distinguishes labor points that were never configured from points awaiting an auction price. When labor is not configured, it labels the displayed total as known cost rather than implying labor was included.

### History reliability
- Split growing history maps into verified chunks, and removed duplicate run data from the aggregate save. The aggregate and its run bank still commit only after all values read back successfully; incomplete chunks fall back to the previous committed bank.

## [1.5.9] - 2026-10-01

### Labor pricing
- Labor cost now uses the labor points entered for each pack type multiplied by the cheapest known auction price per restored labor point among fixed-amount Worker's Compensation items.
- The Labor editor shows the selected item, its auction price, recovery amount, and per-point rate, with a Refresh prices button. The manual per-point rate field was removed. New auction results update matching saved records and history; a missing quote leaves labor cost unpriced.

## [1.5.8] - 2026-09-30

### Ledger
- The pack-name text now uses the space gained by horizontal resizing. Names that fit the wider column display in full; compact widths still shorten names that exceed the column.

## [1.5.7] - 2026-09-29

### Cost editors and ledger
- Added pack-type Transport rules for Eco-Friendly Fuel and Axle Grease quantities and manual or auction-house unit prices.
- Added dedicated Labor and Materials editors with full-name pack dropdowns. Labor uses points and a manual value per point; Materials supports quantities and manual or AUTO unit prices for recipe items, with a total-cost fallback for packs without a recipe.
- Removed the Edit/Step/minus/plus/Reset Cost row. Ledger width now resizes from 660 to 990 pixels, widens the pack-name column, and persists with row count.

## [1.5.6] - 2026-09-29

### Fixes
- Moved the Pack dropdown and ledger event handler out of `createUi` to stay below the game client's 60-upvalue Lua limit. Dropdown construction now happens after the floating OPS button exists, so a future menu error cannot hide the launcher.

## [1.5.5] - 2026-09-29

### Pack filter
- Replaced pack-name cycling with a wider dropdown listing full available pack names, an All packs option, and page controls for long lists. The Pack button keeps its existing width and shortens only its selected label.

## [1.5.4] - 2026-09-29

### Ledger
- Made the ledger vertically resizable with a lower-right drag handle. It starts at twelve rows, grows or shrinks between eight and twenty-four rows as screen space allows, moves Details and footer controls with the window, and saves the selected size.
- Clarified that transport and labor costs are optional, manually entered gold values; neither is detected automatically.

## [1.5.3] - 2026-09-29

### Delivery
- Tradepack payment now moves from Waiting to Delivered exactly eight hours after the sale. Older saved per-pack delays and manual receipt flags no longer affect status and are discarded on the next record save.
- Removed the Received filter and Mark Received/Undo Receipt control. Archive Done now archives Delivered rows. The optional alert announces new deliveries.

## [1.5.2] - 2026-09-29

### Fixes
- Restored the floating OPS launcher to the skin's original natural size while keeping fixed extents for ledger buttons.
- Fixed the Alerts toggle so Off actually removes the saved setting.
- Save verification now allows the client's single-precision numeric round-trip while still checking every field and record. This resolves false record-metadata, record-chunk, and run-chunk save failures; genuine repeated failures are reported at most once per minute per save area.

## [1.5.1] - 2026-09-29

### Interface
- Aligned the status and filter buttons in evenly spaced rows, with more separation before the column headings.
- Kept styled buttons at their intended width after setting or changing their labels, so their artwork and clickable areas stay aligned.
- Put Edit, Step, minus, plus, and Reset Cost in one styled row, and reduced the ledger to eight rows per page so its controls fit comfortably on a shorter window. The Details panel still supports eight lines.

## [1.5.0] - 2026-09-29

### Ledger and delivery
- Added a payout-type filter derived from saved payout items, plus separate transport and labor cost adjustments. Profit, ROI, Cost sorting, and History totals now include these additional costs.
- Added an optional, saved due alert. The floating OPS control checks delivery status while the ledger is closed; new Due transitions produce one chat notice, while startup catches up silently.

### History
- Trade runs now use verified, alternate-bank chunks rather than relying on a single size-limited History value. The History window pages through all retained runs, four at a time, and existing ledger records can restore older summaries that still have run IDs.

## [1.4.0] - 2026-09-29

### Delivery and recovery
- The delivery timer now changes Waiting to Due. Received is an explicit, reversible confirmation; older PAID records load as Due because receipt was never verified.
- Row removal and the bulk archive control keep records in the saved ledger. Archived rows can be restored individually or all at once, while all-time history stays intact.

### Clarity and performance
- Details shows cost and payout price source and age, including manual costs and auction snapshots.
- The one-second update changes countdown labels and refreshes the full ledger only when a delivery status changes. Record saves reuse matching chunks in the alternate bank instead of rewriting every chunk.

## [1.3.0] - 2026-09-29

### Reliability
- Record saves now alternate between two banks, verify every chunk before committing, and preserve the previous copy if a new save fails. Incomplete legacy chunks are moved into verified new chunks using the complete records still readable, while the original keys remain available for repair. Failed history saves keep the previous history bank; a saved sale missing from history is recovered on the next load.
- Daily totals are stored independently of ledger rows, so Clear Paid does not erase recent day summaries. Older cleared days cannot be reconstructed during migration.

### Pricing and workflow
- Auction search pricing reads sparse buyout fields correctly and excludes bid-only values. Cached estimates expire after six hours; Refresh can request updated estimates without changing locked record snapshots.
- The ledger adds date, pack, and unpriced filters, button-based manual cost adjustments, a known-profit subtotal when some records lack prices, and recent trade-run summaries.
- Sale previews only merge into the matching pack, and the preview delay can replace the eight-hour default. Payment terms expire after 30 seconds.

## [1.2.0] - 2026-06-15

### Added
- **Profit margin column + sortable ledger** — The ledger gained a **Margin** (ROI %) column. Click any column header (Pack Name, Total, Cost, Profit, Margin, ETA) to sort by it; click again to reverse direction. A `^`/`v` marker shows the active sort. The default remains newest-first.
- **Most Profitable Packs** — The History window now lists your top 3 packs by all-time profit, alongside the existing most-sold "Favourite pack".

### Fixed
- **Onyx payout price drifted in Details** — The Details panel showed the live auction price for an item payout instead of the price snapshotted at turn-in, which was misleading (Total and Profit were already frozen and correct). The Details line now shows the locked snapshot.

### Changed
- The ledger window is wider (610 → 660 px) to fit the Margin column, and the History window is taller to fit the Most Profitable Packs section.

### Notes
- A pack-name search box and a manual cost/payout editor were prototyped but pulled from this release: text editboxes render in this client but the addon cannot read their text (`GetText()` returns nil and the change event carries no text), so they could not be made functional. Deferred pending a button-based input approach.

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
