# XPBar

A 6px bar along the bottom of the game window, from the lower left across the full width. It shows experience while you are leveling, and limit points while the merit bar is up.

```
/addon load XPBar
/xpbar            show or hide
/xpbar on
/xpbar off
/xpbar config     place the rate tab
```

The bar does not take mouse clicks. Its width follows the game window (3440×1440 is used only if that size cannot be read).

A tab sits on the top edge of the bar. It shows the rate of whatever the bar is measuring:

- `EXP/hr` while leveling.
- `MP/hr` on the merit bar. One merit is 10000 limit points, so the tab is that pace divided by 10000.
- `CP/hr` when the bar is capacity points.

The pace is the points addon's estimate: the average gain and the average gap over the last 50 gains, counting the wait since the last one. Experience comes from the gain lines (including a chain). Limit and capacity come from the same kill message that moves the bar. A gap longer than 15 minutes starts the estimate over.

`/xpbar config` opens the placer. Drag the tab, or use the position slider. The choice is saved. The bar stays click-through. The tab only takes the pointer while that window is open.

The fill is Vanacore amber, `#E8B45C`, at 70%. The unfilled track is Sidekick3's bar background while the pointer is off its HUD, `#0c0c0c` at 70%, with the same 1px `#0c0c0c` edge Sidekick3 draws on its bars.

What fills it is the same choice HXUI's exp bar makes:

- Experience, current out of needed, while leveling.
- Limit points, out of 10000, in limit mode, when experience is locked at level 75 or higher, or when experience sits at the 55999 cap.
- Capacity points, out of 30000, at level 99 unless limit mode is on. CatsEyeXI's cap is 75, so that path stays unused there.

Limit and capacity points are read from the client when the addon loads and after a zone, then updated from the kill message and replaced when the character update arrives. The rate is kept from those gain lines and is not reset by a zone.
