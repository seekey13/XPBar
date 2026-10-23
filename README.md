# XPBar

A 6px bar along the bottom of the game window, from the lower left across the full width. It shows experience while you are leveling, and limit points while the merit bar is up.

```
/addon load XPBar
/xpb              settings for the rate tab
```

The bar does not take mouse clicks. Its width follows the game window (3440×1440 is used only if that size cannot be read).

A tab sits on the top edge of the bar. It shows the rate of whatever the bar is measuring:

- `EXP/hr` while leveling.
- `MP/hr` on the merit bar. One merit is 10000 limit points, so the tab is that pace divided by 10000.
- `CP/hr` when the bar is capacity points.

The pace is the points gained since the first of the last 50 gains, over the time since that gain, counting the wait since the last one. The first gain only starts the clock, so the tab reads 0 until the second. Kills 30 seconds apart for 200 each read 24.0k EXP/hr from the second kill on. Experience comes from the gain lines (including a chain). Limit and capacity come from the same kill message that moves the bar. A gap longer than 15 minutes starts the estimate over, and so does changing your main job.

`/xpb` opens a settings card drawn the way Sidekick3 draws Sidekick Settings, at the same sizes and in the same colours: show or hide the rate, the tab's text size, a position slider, and reset. The text size is in pixels, as Sidekick3's HUD text sizes are: 14 is 14 pixels on any screen, and the tab grows with it. Drag the tab along the bar, or use the slider. Click a slider's number to type one. Hover a label to see what it does. The choice is saved. The bar stays click-through. The tab only takes the pointer while that card is open. Turning the rate off hides the tab immediately, and fades the tab's rows on the card (they can still be set).

The tab is an amber chip on the top edge of the bar: Sidekick3's amber chip. The card is a dark rounded panel with the accent switch and slider. Their text is Segoe UI on Ashita 4.30 and on 4.16, loaded once from Windows' fonts when the addon loads. Without it, text falls back to ImGui's own font.

The fill is Vanacore amber, `#E8B45C`, at 70%. The unfilled track is Sidekick3's bar background while the pointer is off its HUD, `#0c0c0c` at 70%, with the same 1px `#0c0c0c` edge Sidekick3 draws on its bars. The fill eases up to each gain, as Sidekick3's bars do, and starts over at once on a level or a merit.

What fills it is the same choice HXUI's exp bar makes:

- Experience, current out of needed, while leveling.
- Limit points, out of 10000, in limit mode, when experience is locked at level 75 or higher, or when experience sits at the 55999 cap.
- Capacity points, out of 30000, at level 99 unless limit mode is on. CatsEyeXI's cap is 75, so that path stays unused there.

Limit and capacity points are read from the client when the addon loads and after a zone, then updated from the kill message and replaced when the character update arrives. The rate is kept from those gain lines and is not reset by a zone. A new main job starts it over.

## Tests

```
luajit tests/progress_test.lua
luajit tests/ui_test.lua
```

The first checks the bar's arithmetic, the packets and the rate. The second draws the bar, the tab and the card through a fake ImGui, on 1.92 and on 1.81 (with Segoe UI and without), and fails on a Lua error or an ImGui scope left open (either would stop the game), or on a font added to ImGui's shared atlas during a frame.

## Licence

XPBar is free software under the GNU General Public License, version 3 or (at your option) any later version: see [LICENSE](LICENSE). Copyright (c) 2026 Seekey.

Its look (`look.lua`) is based on Sidekick3's UI kit (`ui/kit.lua`), which is based on VanaCore's `/vana` window (`addons/vanacore/vana/draw.lua`, Copyright (C) 2026 Vekien, GPL-3.0-or-later). XPBar is not VanaCore, and isn't made or endorsed by Vekien; VanaCore's name and logo aren't licensed with it.
