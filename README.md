# SpellPad Studio

**A macro and keybind manager with action bars of its own. Built for Stream Deck and other macro pads.**

Put a spell, item or macro on every key. See them all in one window, and on screen as a button pad. Made for **WoW Retail (Midnight)**, and it works the same on **WoW Forever**.

**Works with:** Elgato Stream Deck, Corsair iCUE, other macro pads and keypads, a numpad, or just your keyboard.

Download: [SpellPad Studio on CurseForge](https://www.curseforge.com/wow/addons/spellpad-studio)

## Your own action bars

SpellPad Studio is a second set of action bars that lives inside the addon.

- Up to 36 buttons per page, and dozens of pages.
- It doesn't use Blizzard action bar slots. Your own bars stay as they are, and you can still work with them: drag a spell off a Blizzard bar onto a card and it stays on the bar, or hold the middle mouse button on a SpellPad button to copy its spell or item onto a bar.
- **Your saved Key Bindings are not changed.** A card's key works as a temporary override while the addon is running. The original binding stays in the game's Key Bindings screen and works again as soon as the card no longer uses that key. If a card takes a key the game already uses, the card tooltip, the Audit and the import preview tell you which action it overrides.
- Pages switch by themselves: mounted, stealthed, in a group or raid, in combat and more.
- Every button is a key you choose. Page 1 starts at ALT-1, ALT-2 and so on. Any key works.

## What you can do with it

- **See every key in one place.** A card for each key, with a name, icon and macro. Search them, drag them to reorder.
- **Build macros by clicking.** No syntax to remember. The SpellPad Builder shows in plain English what a macro does.
- **Know it works before you start.** The setup guide checks that your keypad really reaches the game.
- **Never lose your work.** A backup (snapshot) is saved before every risky change.

## Features

**Organize**
- One card per key, with a name, icon and macro.
- 4 to 36 cards per page, in any grid shape that fits your device.
- Search your pages and cards. Drag pages to reorder them.

**Build macros**
- Ready-made macros for your class, travel and teleports, target markers, world markers, group tools and emotes. (Forever also has consumable and raid-prep sets.)
- Macro text is colored and flags mistakes as you type. It suggests spell names too.
- Arsenal: click or drag a spell or item you know onto a card, or pick a ready-made macro or one of your game macros on its Easy Macros and My Macros tabs.
- SpellPad Builder: build a macro by clicking and dragging, with conditions like mouseover, focus and modifier keys.

**The SpellPad (on-screen buttons)**
- A copy of your macro pad on screen. Set its size and shape to match your device.
- Icons work like a normal action bar: cooldowns, charges, counts, range and procs.
- Click a button to run its macro.

**Bring in what you already have**
- Import Game Macros and Import Action Bars (footer > Tools) copy them onto new pages. Nothing is replaced, and you see a preview first.

**Stay safe**
- Snapshots: go back to how a page looked before a change.
- Audit: one list of every problem on every page. Click an entry to jump to it.
- Import preview: see what a shared page or profile will do before it is applied.

**Share and customize**
- Export and import pages and profiles as text. Keep several profiles per account.
- Save a card as a normal game macro.
- 7 window styles, a macro font size slider and many SpellPad options.

## Getting started

1. Install the addon (below) and log in. A setup guide opens by itself the first time. To open it again, type `/sps setup`.
2. Tell it how many buttons you have, and whether the pad is wider than tall or taller than wide.
3. In your keypad app (Stream Deck, iCUE or another), make the top-left button send **Alt + 1**, the next one **Alt + 2**, and so on. The guide shows the key for every spot, and lights a spot up when the game receives it.
4. Click a spell in the Arsenal (or drag one onto card 1), then press the button.
5. After you change a macro, press **Save & Apply** (or Ctrl+S).

## Install

- **CurseForge app or website:** search for SpellPad Studio.
- **By hand:** copy this folder to `World of Warcraft\_<client>_\Interface\AddOns\SpellPadStudio`, start the game and type `/spellpad` (or `/sps`).

No other addons are needed. The libraries are included.

## Commands

- `/spellpad` or `/sps`: open or close the window
- `/sps setup`: open the setup guide
- `/sps help`: list all commands

## Good to know

- Tested on Retail Midnight (12.1.5) and on WoW Forever (1.60.1). Retail support is new, so please tell me what you find.
- Macros are limited to 255 characters, the same as the game's own. SpellPad Studio can't get around that.
- Changes to macros and keys can't be applied in combat. They apply when it ends. Your buttons and keys work in combat.
- This is not a rotation helper. One key press runs one macro, the same as the game does with any macro.

## Feedback

I wanted a Stream Deck that was easy to use in WoW, and I couldn't find an addon that did it, so I made one. Bugs and ideas are very welcome: [open an issue](https://github.com/ranben8/SpellPadStudio/issues).

## Licence

GNU General Public License v3.0, see [LICENSE](LICENSE). The bundled libraries in `libs/` keep their own licences.
