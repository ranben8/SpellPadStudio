# In-game rundown template

Copy this for every change that is tested in game. Fill the points in, run each
one on both clients, and mark the result. A change counts as confirmed only when
both columns pass. While the Forever client can't be run, a point stays
"Retail OK, Forever pending" and goes on the pending list.

Before testing: run `python tools/check.py` (must print 0 errors), then `/reload`
(or restart the game if the `.toc` changed). After editing a macro or a key, press
Save & Apply.

| # | Do this (exact clicks and keys) | Expect | Retail | Forever |
|---|---------------------------------|--------|--------|---------|
| 1 | `/reload` | No Lua error, the main window opens with `/sps` | | |
| 2 | `/sps keys` | First line `Client: Retail ...` or `Client: Forever ...`; no key guard line | | |
| 3 | `/sps retail` (retail only) | Report opens; "Needs attention" is empty | | n/a |
| 4 | *the change under test* | *what you should see* | | |
| 5 | Pull a target dummy, press a card key | The card casts; no "Interface action failed" | | |
| 6 | After combat: Save & Apply | `Everything is applied.` | | |

How to read the columns: `OK`, `FAIL` (paste the error text), `pending` (client
not available), or `n/a`. A failure looks like a Lua error popup, a red chat line,
or a window that is empty or in the wrong place.

## Pending on Forever

List every point that is "Retail OK, Forever pending" here, and clear it when the
Forever client can run it again:

-
