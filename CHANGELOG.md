# SpellPad Studio 1.3.0

## New

- **A glow when the page or profile changes.** The SpellPad's background flashes gold behind the buttons when the active page or the profile changes: a page tab click, a `!PAGE` key, a context rule or a profile switch. It works in combat, follows the backdrop opacity, and can be turned off in Options > SpellPad ("Glow on page or profile change").
- **A Colors tab in Options.** Choose the SpellPad's fill, line, background flash (the glow above) and button flash (what a pressed key does to its button and card). Click a swatch to use the game's color picker, or type a hex code. Presets include High Contrast and two color-blind friendly sets (red-green and blue-yellow), which also keep the two flashes easy to tell apart. "Flash Background" and "Flash Buttons" show each color once.
- **Thick window border (Retail).** Every window style can be drawn inside the thick metal frame the game uses for its own dialog windows, such as the Game Menu. It is off by default; turn it on in Options > General > Windows. Forever keeps its own bronze frame and doesn't show the option.
- **Flash button on key press.** The SpellPad button that lights when you press its key now has its own switch in Options > SpellPad. Cards in the main window still flash.
- **Drag a card onto the SpellPad to swap it** with the button under the cursor. Both buttons flash when the swap is done. When the drag turns grey (you left the card list), the list scrolls so the card you are holding is at the top.
- **Toggle Housing Dashboard and Toggle Adventure Guide (Retail)** are in Easy Macros > Advanced > Interface. They work from a key and from the SpellPad.
- **Cards name themselves.** A card without a name now shows what it holds: an Easy Macros entry shows the entry's name ("Toggle Spellbook"), and a one-line spell or item macro shows the spell or item ("Frostbolt"). The name is grey, and its tooltip says it was applied automatically. A name you type is white and always wins.
- **Prefix modes.** Options > General > Key Prefix chooses between **Per Page** (each page has its own prefix, new pages start with no keys: how it always worked) and **Global** (one prefix for every page: setting it changes all pages, and new pages start with it). Right-click the Prefix key cap above the cards, or the prefix box in Page Options, to remove the prefix: the cards of that page (every page in Global mode) lose their keys, after a snapshot, so Restore can bring them back. The first time you finish the setup guide, Global is turned on with the prefix you set up.
- **A new addon icon**: the gold key on its pad, in a frame that is bronze on one side and metal on the other. It shows in the AddOn list, the addon compartment and broker bars, and a round version without a frame sits on the minimap button.
- **A main page.** Tick "Main page" in Page Options to make that page your home page (one per profile). It is marked with a star in the Pages list. SpellPad returns to it when you close the main window, when a context ends (you dismount, leave the water, the fight is over), at login and when you switch profiles. A context page that applies at that moment still wins. A page you picked by hand or with a `!PAGE` key stays until one of those happens.
- **Three more page contexts:** Flying, Swimming and Resting (town or inn), chosen with Select Context in Page Options. Swimming waits a second before it counts, so wading at the water's edge doesn't flip pages; Flying waits a third of a second. Like every context except In Combat, they switch pages out of combat only.
- **A key binding to show or hide the SpellPad.** Key Bindings > AddOns > "SpellPad Studio: Show / Hide SpellPad". It is a plain toggle (the "Always show SpellPad" setting is not changed) and does nothing in combat. The pad, and the minimap right-click that shows it, bring it back where it was.

## Changes

- **The Spell Browser opens to the left of the main window**, level with its top edge, so you can see your cards while you pick spells. Audit and the Spell Browser share that spot and replace each other. The Spell Browser no longer closes Options, Profiles and the other windows, and they no longer close it. With SpellPad Builder open, the browser still sits against the Builder.
- **The SpellPad docks at the lower left of the main window** (it used to dock at the upper left), so it sits under the Spell Browser. A pad you moved by hand, or locked, stays where you put it.
- **Mage teleports and portals are listed by city** (teleport, then portal), newest city first starting with Silvermoon City, and the original capitals last.
- The key press flash on SpellPad buttons and cards is shorter (0.35 s), the same length as the new glow.

## Fixes

- **Summon Random Favorite Mount works on Retail.** A card with `/cast Summon Random Favorite Mount` (what dropping the journal's random favorite button gives you) now summons a mount from a key and from the SpellPad. The card text stays as you see it; only the macro the game runs is changed behind the scenes. A card with `/run C_MountJournal.SummonByID(0)` shows the mount's icon too.

- **The "Specific Stance / Form" page rule matched the wrong form on Retail.** The rule saved the form's position on the shapeshift bar but compared it with the game's form ID, so a druid's Cat Form rule could switch the page in the wrong form. It now compares the bar position.

## Known issues

- Forever: these changes haven't been re-tested there since Forever's beta went offline. They will be checked again at Forever's launch.

# SpellPad Studio 1.2.1

This is the first release that runs on **Retail (Midnight)** as well as **WoW Forever**. One download works on both.

## New

- **Retail (Midnight) support.** Tested on Midnight 12.1.5. On Retail the main window reads "SpellPad Studio Midnight". Your buttons and keys work in combat, and the SpellPad's cooldowns, charges and range keep working under Midnight's new combat rules.
- **Drop a mount on a card or a SpellPad button** (Retail). Drag a mount from the Collections journal, or the Summon Random Favorite Mount button, onto a card or SpellPad button and it becomes `/cast <Mount Name>` with the mount's icon.
- **Swap two cards by dragging.** Drop a card on the middle of another card and the two swap their macro, icon and name. The target glows gold while you hover. Dropping near the top or bottom edge of a card still moves it to that spot, as before. A snapshot is taken first, and the keys stay with their positions.
- **Class macros for all 13 Retail classes**, including new sets for Death Knight, Demon Hunter, Monk and Evoker, with Retail spell IDs.
- **More travel macros for mages** (Retail): 19 more teleports and portals, plus Silvermoon City.
- **Spellbook, Talents and Achievements entries** in the Interface menu on Retail. They work from a key and from a SpellPad click.
- **Reports for bug hunting:** `/sps retail` (a Retail compatibility report), `/sps combat` and `/sps cursor` (what the cursor is holding). Copy the text into a comment or issue if something looks wrong.

## Changes

- **The setup guide remembers Horizontal / Vertical.** Pages you add later follow the choice you made in the guide. Existing pages keep their look.
- **Dismount / Leave Vehicle** has its own icon. A card whose only lines are `/dismount` or `/leavevehicle` shows the vehicle exit icon.
- **Fewer false "unknown command" warnings.** The macro checker now reads the commands and emotes the game itself lists, so emotes and commands like `/usetalents` are no longer flagged.
- **Spell proc glow and `/equipset` icons** (Retail): a proc lights the SpellPad button, and an `/equipset` card shows the set's own icon.
- **Menus fit each client.** On Retail the Consumables and Raid Prep menus, `/joke`, `/rolecheck` and the Primary / Secondary Specialization entries are hidden, because they don't exist or don't apply there. Forever keeps them.
- The window frame is trimmed to sit correctly on Retail, and `/sps help` lists the report words on short lines.

## Known issues

- On Retail, in combat, a charge spell that still has a charge left doesn't show its recharge ring.
- Forever: this release hasn't been re-tested there since Forever's beta went offline. It will be checked again at Forever's launch.
- The Class Specializations entries (`/usetalents`) do nothing until dual specialization exists on Forever.
- The "Toggle Legacy Menu" preset may not open the Legacy panel on Forever.
- Two characters with the same first name on the same realm share one set of per-character settings.

# SpellPad Studio 1.2.0 (WoW Forever)

## New

- **Setup guide.** A short, hands-on guide that opens by itself the first time you install the addon (never for existing users). It walks you through five steps: pick how many buttons your device has, tell your device software which key each button sends (click paths for Elgato Stream Deck and Corsair iCUE, plus generic wording for other apps), press a button to prove it works, put a spell on card 1, and press the button to cast it. Reopen it any time with `/sps setup`, from Options > General > Getting Started, from the game's Settings > AddOns page, or from the hint on an empty page.
- **"Nothing happening?" button check.** In the guide, it listens to what a physical button really sends (including Shift, Ctrl and Alt) and offers a one-click fix, such as switching a page to the right prefix.
- **Drag pages to reorder them** in the Pages list. `!PAGE` cards follow the move (can be turned off in Options > General), page keys, shapes and context rules travel with the page, and a snapshot is taken first. Double-click a page to rename it.
- **Hover a page** to see its number, which is what `!PAGE n` uses.
- **Shift-click a lower rank in the spellbook** and the card gets that rank, for example `/cast Frostbolt(Rank 1)`. Your best rank stays the plain name.
- **Right-click the profile selector** in the main window to open the Profiles window directly.
- **More Advanced menu entries** (formerly Power User): Interface, Class Specializations, target, movement and interaction commands, with icons.
- Icons for the Advanced, Travel, Consumables, crowd control, party and broadcaster menus. An `/equipset` card shows the set's own icon.

## Changes

- **Empty cards are small and calm.** A blank card is a compact ghost with a dashed outline and a dim key cap; it opens when you select it, drop something on it or open it in the Builder. Empty cards can't be dragged by accident.
- The card right-click menu is regrouped into **Copy and Move** and **Shift** submenus.
- Empty SpellPad buttons no longer show the red question mark; they are a quiet dark square (with the key shown faintly when "Show keys" is on). The key and stack count on SpellPad buttons are easier to read.
- The main window, sidebar, cards, Options, Page Options and Profiles windows have a new look: inset panels, thin scroll bars, a card header with key cap and problem badge, a footer bar showing how many changes are not applied, a profile dropdown in the sidebar, and Options split into General, Editor, SpellPad and Data tabs.
- **SpellPad Builder** and the Spell Browser use new Any / Yes / No chips, list panels and search boxes. The old separate Condition builder and Castsequence windows are gone (the Builder replaces them).
- The Spell Browser on its own now replaces the selected card when you click an entry, and you can drag entries onto cards, SpellPad buttons or action bars.
- Page Options shows labelled fields, and you set the page prefix by clicking the box and pressing the keys. You can also click the "Prefix" chip in the main window.
- New profiles start with an **ALT- prefix** (ALT-1 to ALT-=), 15 cards and no starter macros. ALT-F4 is never bound; that card gets another key.
- "Save as game macro", "Copy from profile" and several other cards and menus were reworded for consistency.
- Cooldown numbers, key labels and several SpellPad options can be switched in Options > SpellPad.
- Ctrl+Z also works while Shift is held.

## Fixes

- **Shift-clicking a spell in the game's spellbook did nothing.** Fixed.
- **Dropping a game macro onto a card** now copies the macro's text instead of writing a `/click` line that did nothing.
- **Re-binding a card's key** (right-click the key cap) now keeps the Shift, Ctrl and Alt your keypad sends, instead of dropping them. It also has safety exits: a click, combat, a page change or 30 seconds without a key press cancel it, so your movement keys can't get stuck.
- SpellPad Builder no longer causes an "Interface action failed" message when used in combat.
- Adding, copying or importing a page now stays on that page when automatic page switching is on.
- Switching to the "In Combat" page at the start of a fight, and back afterwards, works again.
- The unapplied-changes marker is reliable on every page, and switching pages no longer applies your pending edits behind your back.
- Clear Card now redraws at once and takes a single snapshot.
- Deleting a page keeps context rules and page snapshots pointing at the right pages.
- A spell dropped on a card whose name can't be read is refused instead of writing a number into the macro.
- The Audit flags a card on ALT-F4.
- Profile switches now refresh every part of the window.
- Hide empty buttons now treats icon-only cards as in use and whitespace-only macros as empty.
- Macro boxes scroll back to the top when their text changes behind your back.
- Page names, card names and macros containing `|` display correctly in more places.
- A spell name picked from autocomplete no longer triggers the card's save twice.
- The template icon lookup no longer re-scans every 30 seconds.
- Minimap, data broker, addon compartment and `/sps` all open the window the same safe way and refuse the first build in combat.
- Many smaller internal fixes and clean-ups. The code was reviewed and simplified throughout (no behaviour change intended beyond the notes above).

## Known issues

- The Class Specializations entries (`/usetalents`) do nothing until dual specialization exists on Forever.
- The "Toggle Legacy Menu" preset may not open the Legacy panel on Forever.
- Two characters with the same first name on the same realm share one set of per-character settings.
