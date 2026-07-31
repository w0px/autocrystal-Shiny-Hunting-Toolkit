<p align="center">
  <img
    src="https://github.com/user-attachments/assets/5c0f7928-15db-4d34-b5f5-3c53a770c37d"
    alt="star_transparent"
    width="151"
    height="151">

</p>

<h1 align="center">autocrystal</h1>
 
<p align="center">
  <b>Pokémon G/S/C Automated Shiny & perfect DV Hunting, Fishing, Headbutt, Egg, Static, Item & Level Grinding Toolkit</b><br>
  <b>API Project:</b> <a href="https://github.com/w0px/w0p-autocrystal">w0p-autocrystal</a><br>
  <b>Discord:</b> w0p
</p>

 

## Table of Contents

- [Functions](#functions)
- [How to Run](#how-to-run)
- [Modules](#modules)
  - [Wild Encountes Module](#wild-encountes-module)
  - [Starters Module](#starters-module)
  - [Headbutt Module](#headbutt-module)
  - [Egg Module](#egg-hatching-module)
  - [Static Module](#static-module)
  - [Gamecorner Module](#gamecorner-module)
  - [Friendship Module](#friendship-module)
- [FAQ](#faq)
  - [Supported Versions](#supported-versions)
  - [Transferring Save Files from One Emulator to Another](#transferring-save-files-from-one-emulator-to-another)
  - [Emulator Speed](#emulator-speed)
  - [Discord Notifications](#discord-notifications)
  - [Savestate Slot Usage](#savestate-slot-usage)
  - [Simulating Randomness: RNG Manipulation in Deterministic Emulation](#simulating-randomness-rng-manipulation-in-deterministic-emulation)
  - [How Headbutt Trees work in Gen 2](#how-headbutt-trees-work-in-gen-2)
- [Roadmap](#roadmap)

  
## Functions

### Wild Encounter Module ✅
- Shiny Detection
- Held Item Detection
- Perfect DV Detection
- Perfect Negative DV Detection
- Discord Notifications
- Automatic Level Grinding
- Specific Encounter Hunting
- Stuck Detection & Auto-Recovery

### Starter Module ✅
- Shiny Detection
- Perfect DV Detection
- Perfect Negative DV Detection
- Discord Notifications

### Fishing Encounter Module ✅
- Shiny Detection
- Held Item Detection
- Perfect DV Detection
- Perfect Negative DV Detection
- Discord Notifications
- Automatic Level Grinding
- Specific Encounter Hunting
- Stuck Detection & Auto-Recovery

### Static EncounterModule ✅
- Shiny Detection
- Perfect DV Detection
- Perfect Negative DV Detection
- Discord Notifications

### Headbutt Encounter Module ✅
- Shiny Detection
- Held Item Detection
- Perfect DV Detection
- Perfect Negative DV Detection
- Discord Notifications
- Automatic Level Grinding
- Specific Encounter Hunting
- Stuck Detection & Auto-Recovery

### Egg Module ✅
- Shiny Detection
- Perfect DV Detection
- Perfect Negative DV Detection
- Discord Notifications

### Gamecorner Module ✅
- Shiny Detection
- Perfect DV Detection
- Perfect Negative DV Detection
- Discord Notifications

### Friendship Module ✅
- Auto Grinds Pokemon Friendship via Walking
- Friendship Tracking
- Discord Notifications once 220 Friendship is reached




## How to run

download latest BizHawk release
https://github.com/TASEmulators/BizHawk/releases/

- Download an official Crystal ROM

- Start the ROM in the BizHawk Emulator

- In the BizHawk menu select LUA Console

<img width="698" height="452" alt="image" src="https://github.com/user-attachments/assets/1e42e0d1-a74f-464d-910b-987cd6fced1e" />

- In the console select the launcher.lua

![image](https://github.com/w0px/autocrystalprivate/assets/152983879/ae20fbce-1346-4566-8643-486ca3d4d655)

<img width="617" height="147" alt="image" src="https://github.com/user-attachments/assets/e3a24d3c-8313-4932-a01d-2f9476cca13d" />

- in the launcher select a module you want to run
<img width="463" height="405" alt="image" src="https://github.com/user-attachments/assets/8359c386-c4a6-47a1-bcca-45ea3dcd2b3c" />



# Modules

## Wild Encountes Module

Self-correcting movement (auto-detects safe directions)
RAM-verified menu navigation, self-corrects on dropped inputs
Automatically Handles Phone Calls and Other Interruptions (e.g. Egg Hatching)


<img width="454" height="828" alt="image" src="https://github.com/user-attachments/assets/8fe1a5a9-6e31-4098-a79a-59e4bdbb1f42" />



### Stop Conditions

- **Perfect DVs (15/15/15/15)** – Stops when a Pokémon with perfect DVs is encountered
- **Perfect Negative DVs (0/0/0/0)** – Stops when a Pokémon with perfect negative DVs is encountered
- **Specific Species (Name or ID)** – Stops when a specified Pokémon is encountered, whether shiny or non-shiny
- **Held Item (Any or Specific)** – Stops when a Pokémon holding any or a specified item is encountered, if a specific item is in the Allowlist the bot will only stop if that item is encountered
- **Shiny Pokémon** – Always stops upon encountering a shiny Pokémon

### Kill Mode

- Automatically battles non-shiny Pokémon using the first move
- Species Allowlist to avoid unfavorable matchups, the bot will only battle the Pokemon in the Allowlist (ID or Name)
- Automatically flees when all PP for the selected move is depleted or active Pokémon HP is < 20%
- Pauses Auto-leveling when a Pokémon attempts to learn a new move (unless an empty move slot is available)

<img width="800" height="486" alt="2cd5b3901b2209c85db0407c3c6df5ae-ezgif com-video-to-gif-converter" src="https://github.com/user-attachments/assets/138b7d12-612b-4572-a941-e44c0ccc7467" />

- Allowlist is set to Hoothoot only, so the bot will escape from any other encounter

<img width="800" height="506" alt="fd2bc9aa5d130eeae9db2edcb0025bf5-ezgif com-video-to-gif-converter" src="https://github.com/user-attachments/assets/7eb87d91-bb47-4782-bc4b-83257861b5a7" />

### Verbose Logging

Displays every action performed by the bot in the console. Primarily intended for debugging and troubleshooting.


## Starters Module

Place the bot directly in front of the starter Pokémon without interacting with the Poké Ball.

<img width="955" height="519" alt="image" src="https://github.com/user-attachments/assets/15215323-254a-4efb-82a9-2776d4979c91" />

The bot will use Save Slot 3 to soft reset the game, from now on don't touch it.

Start the Starters module from the launcher

<img width="1495" height="614" alt="image" src="https://github.com/user-attachments/assets/fc6c480e-af67-41f3-82f1-3a309e9dcdda" />

Once the bot is running, verify that the starter Pokémon have different stats after each soft reset

<img width="206" height="171" alt="image" src="https://github.com/user-attachments/assets/cd4da4b3-f1b7-49f3-909f-a79f0ec11812" />

If the stats remain the same, the save state was not created correctly, and the bot will keep encountering the same starter repeatedly

### About the "True Randomness" Checkbox


Off (default): fast, ~96.8% empirically-measured DV coverage. Plenty for shiny hunting - 8 valid combinations out of 65536, so a small coverage gap is very unlikely to exclude all of them.
On: much slower (single delay of 65536+ frames instead of the fast split approach), but mathematically guarantees reaching every possible DV combination given enough time. Use this specifically when hunting a single unique target like 15/15/15/15 (Perfect DVs) or 0/0/0/0 (Perfect Negative DVs), where there's only one valid combination and the stakes of a coverage gap are much higher.

Whether the fast "Off" mode happens to already cover a specific rare target like 15/15/15/15 depends on the individual save file - it might, or it might not, with no way to know in advance. "On" removes that uncertainty at the cost of speed.

## Fishing Module

- Place any Pokémon with **Surf** learned from your party into a PC Box.
- Automatically Handles Phone Calls and Other Interruptions (e.g. Egg Hatching)
- put your fishing rod on the select button --> inventory --> fishing rod --> SEL
  
<img width="512" height="410" alt="image" src="https://github.com/user-attachments/assets/bc09182a-441e-47a0-9b63-3ea6fd400329" />

- position infront of a water tile

<img width="357" height="289" alt="image" src="https://github.com/user-attachments/assets/7ce8d36e-e236-4936-b828-6dc3e5480fb1" />




## Headbutt Module

Automatically Handles Phone Calls and Other Interruptions (e.g. Egg Hatching)
- position infront of a headbutt tree and start the module

<img width="504" height="475" alt="image" src="https://github.com/user-attachments/assets/4ab1a4a0-e977-4c50-8edd-9a53b675d07a" />



## Egg Hatching Module

- position infront of the NPC handing you the egg, don't interact
- the bot will stop once an egg with a shiny Pokémon is obtained
- Walk it until it hatches

<img width="356" height="243" alt="image" src="https://github.com/user-attachments/assets/8e8dea01-cea2-42c9-978e-138991556db5" />

  
## Static Module

- position infront of the NPC handing you the Pokèmon / position infront of the static encounter, don't interact

<img width="461" height="359" alt="image" src="https://github.com/user-attachments/assets/947e7e38-c76b-47b9-b353-cb216d83628d" />

## Gamecorner Module

- position infront of the Vendor and pre-select the Pokémon you want to hunt without interacting

<img width="967" height="828" alt="image" src="https://github.com/user-attachments/assets/7fd545d5-67f2-4428-83cb-de90d3784331" />



## Friendship Module

- Automatically grinds Pokémon Friendship by walking
- Every **500 steps**, the friendship of all Pokémon in the party increases by **1**
- Displays the friendship value of the **first Pokémon in the party** in the GUI
- Sends a Discord notification once **220 Friendship** is reached

<img width="249" height="261" alt="image" src="https://github.com/user-attachments/assets/9d475e9d-b7f9-41c9-930f-7672828408a8" />


# FAQ

## Supported Versions

| Game | US | EU | JP |
|------|:--:|:--:|:--:|
| Crystal | ✅ | ✅ | ❌ |
| Silver | ✅ | ✅ | ❌  |
| Gold | ✅ | ✅ | ❌ |

## Transferring Save Files from one Emulator to another

lets use Bizhawk and mGBA as an example.

BizHawk save states (`.State`) and mGBA save states are **not compatible**.

A save state contains the complete internal state of a specific emulator core. Since BizHawk's **Gambatte** core and mGBA's **Game Boy** core are completely different implementations, save states cannot be transferred between them, regardless of the file extension.

Instead, use the game's **battery save (SRAM)**—the same save data created when you save through the in-game **SAVE** menu.

### Steps

1. In **BizHawk**, save the game using the in-game **SAVE** option (just like on a real Game Boy cartridge).
2. Ignore the Save State dialog—you do **not** need to export or convert a save state.
3. Navigate to your BizHawk directory and open:
   ```
   Gameboy/SaveRAM/
   ```
4. Locate the generated `.SaveRAM` file, for example:
   ```
   Pokemon - Crystal Version (USA, Europe) (Rev A).SaveRAM
   ```
5. Copy the file to the same folder as your mGBA ROM.
6. Rename the file so it matches the ROM filename exactly, using the `.sav` extension.

   **Example:**
   ```
   ROM:  Pokemon Crystal.gbc
   Save: Pokemon Crystal.sav
   ```
7. Launch the ROM in **mGBA** normally using **File → Load ROM**. If the `.sav` file is in the same directory and has the correct filename, mGBA will automatically load your save.

## Emulator Speed

| Emulator Speed | Status |
|----------------|--------|
| 100% | Fully Supported ✅ |
| 200% | Fully Supported ✅ |
| 400% | Fully Supported ✅ |
| Unthrottled | Fully Supported ✅ |

## Discord Notifications
<img width="571" height="173" alt="image" src="https://github.com/user-attachments/assets/4c882ee4-8eab-4c6c-a6d0-7c9113ad187b" />




BizHawk's comm.httpPost can't send Discord's required JSON format directly (it wraps everything as a form field, which Discord rejects). A tiny local relay handles the translation instead.

### 1. Create a webhook


Discord → Server Settings → Integrations → Webhooks → New Webhook
Copy the Webhook URL


### 2. Set up the relay


Open discord_relay.ps1, paste your webhook URL into $DiscordWebhookUrl - this will create a local http listener on your computer which is needed for discord notifications
Double-click start_relay.bat — a console window opens and must stay running the whole time you're botting


### 3. Point BizHawk at the relay

move the DCNotifications_start.bat file into your downloaded Bizhawk directory and double click to start the emulator

<img width="697" height="390" alt="image" src="https://github.com/user-attachments/assets/d63698f5-4544-4824-bc9d-33cfd69406cc" />

### 4. Configure the bot

in any module, check "Send Discord notification (shiny/stop)" in the GUI.

## Why is there a local HTTP listener? (`discord_relay.ps1`)

**Short answer:** It's a workaround for a BizHawk limitation, not anything that sends data out from your PC.

### The problem it solves

BizHawk's Lua `comm.httpPost()` function always wraps its request body as a URL-encoded form field (`payload=`). This is fixed behavior in every BizHawk version, not a bug.

Discord's Webhook API, however, expects **raw JSON** and rejects form-encoded requests. As a result, BizHawk cannot communicate with Discord directly, regardless of how the Lua script is written.

### What the relay actually does

`discord_relay.ps1` is a small PowerShell script that:

- Listens only on **127.0.0.1 (localhost)** (port **5000** by default)
- Receives BizHawk's form-encoded request
- Decodes it back into plain JSON
- Forwards the JSON to the Discord Webhook URL **you configured yourself**

That's all it does—**decode, forward, done.**

### Why this is safe

- ✅ Listens only on **127.0.0.1 (localhost)**, meaning **no other device or internet host can connect to it**
- ✅ Requires **no administrator privileges**
- ✅ Plain-text PowerShell script—open `discord_relay.ps1` in any text editor and inspect every line yourself
- ✅ No hidden or obfuscated code
- ✅ The only information forwarded is the notification generated by the bot (e.g. Pokémon species, DVs, shiny/stop message)
- ✅ No system information, credentials, or personal data are collected or transmitted
- ✅ The script only communicates with the single Discord Webhook URL that **you** configure

### How to verify this yourself

- Read the ~30 lines of `discord_relay.ps1`
- Check **Windows Firewall**, **Resource Monitor**, or **TCPView** while it's running—you'll see it bound only to **127.0.0.1**, never `0.0.0.0` or your network IP
- Discord notifications are completely **optional**. The bot functions normally even if the relay is never started.

## Savestate Slot Usage

Modules that soft-reset use BizHawk savestate slots to mark their reset point. You never need to manually save these yourself - each module's on_resume() calls savestate.saveslot(N) automatically, every time you click Start, capturing whatever position you're currently standing in at that exact moment.

Your only manual step is positioning your character correctly (facing the starter table, facing the egg-giving NPC, etc.) before clicking Start - the bot takes it from there.

Each module uses its own dedicated slot to avoid collisions if you switch between them in the same session.

| Slot | Module | Reset point (auto-saved on Start) |
|------|--------|------------------------------------|
| 3 | Starters | Right before picking a starter |
| 4 | Egg Hatching | Right before talking to the egg-giving NPC |
| 5 | Static Encounters | Right before talking to the NPC |

Slots 1-2 and 6-9 are free for your own manual use without conflicting with any module.

# Simulating Randomness: RNG Manipulation in Deterministic Emulation

## What "randomness" actually means in software

Almost nothing in software is truly random. What games (and most computer systems) use is a **pseudo-random number generator (PRNG)**—a completely deterministic algorithm that takes some internal state, transforms it with a fixed mathematical formula, and produces output that looks statistically random.

Given the exact same starting state and the exact same sequence of calls, a PRNG produces the exact same "random" output every single time. That's not a bug—it's how PRNGs are built.

On real hardware, this determinism is normally invisible. A PRNG's internal state is usually tied to something like elapsed CPU cycles since power-on, and in real life no two play sessions have identical timing down to the cycle because a human's button presses are never frame-perfect.

The PRNG is still deterministic—it just never sees the same inputs twice, so it feels random.

---

## Where this breaks: Deterministic emulation

Tools like **BizHawk** are deliberately engineered for perfect, bit-exact determinism—a core requirement for tool-assisted speedrunning, where a recorded input sequence must replay identically on any machine, forever.

That same property is exactly what breaks "randomness" for automated, reset-based interaction with a game's PRNG:

- Reload the same save state.
- Replay the same inputs.
- The emulator restores the exact same PRNG state.
- The game produces the exact same "random" result every single time.

This isn't specific to any one game; it affects any automation that repeatedly resets and retries against a deterministic emulator.

---

## Simulating randomness on purpose

Since the natural source of entropy (human timing variance) is gone, an automation script has to manufacture some on purpose.

Typically this is done by deliberately varying frame timing between attempts so the PRNG's state differs each time even though the algorithm itself stays perfectly deterministic.

This isn't generating true entropy—it's artificially reintroducing the timing variance that a human player would naturally provide.

---

## The naive approach—and its hidden trap

The obvious solution is adding one random delay after every reset.

The problem is that if the PRNG's state depends on a deterministic value such as elapsed frames, then a delay of **1–N frames** can only ever reach **N distinct PRNG states**, regardless of how many thousands of attempts are made.

A delay range that's too small doesn't merely reduce randomness—it silently limits which outcomes are mathematically reachable, potentially preventing some rare results from ever occurring.

---

## A better technique: Splitting delays across multiple points

Rather than using one large delay (which guarantees better coverage but dramatically increases average attempt time), the delay can be split across several different points in the automation sequence.

These split points occur naturally during gameplay, for example:

- Button presses
- Dialogue
- Animations
- Menu transitions

Testing consistently showed that distributing delays across genuinely different gameplay moments produced much better state coverage per unit of waiting time than placing all randomness into one large delay.

---

## Where splitting reaches its limit

Splitting delays improves efficiency, but it doesn't remove the underlying limitation—it only distributes the same waiting time more effectively.

When testing Pokémon Crystal's DV generation while gradually increasing the delay range, two clear observations emerged:

- **Delay range mattered far more than the number of split points.**
  - Doubling the number of split points barely changed measured DV coverage.
  - Doubling the delay range (256 → 512 frames) increased measured coverage from roughly **2–6%** to roughly **21%**, making it by far the most significant improvement observed.

- **Coverage never approached 100%.**
  - Even with delay ranges four to eight times larger than the original implementation, most DV combinations remained permanently unreachable from a single save state.

This ruled out the obvious conclusion of simply "making the delay bigger." Something deeper was imposing a hard ceiling.

---

## The actual mechanism: One shared hardware timer

Inspecting the game's disassembly—not just its observed behavior—revealed why.

Generation II's RNG is not two independent random draws.

Instead, both running totals are updated from the same hardware timer sample every time the RNG function executes:

```text
hRandomAdd += [timer sample]
hRandomSub -= [timer sample]
```

The Attack/Defense DV roll and the Speed/Special DV roll are simply two consecutive calls to this same routine.

Because both draws originate from the same timer sample instead of two independent sources, they are **correlated**.

Increasing delay ranges cannot make them independent because only one underlying timer value exists.

---

### The hardware limitation

The timer itself advances only once every **256 CPU cycles**.

One Game Boy frame lasts **70,224 CPU cycles**.

Since:

```text
70,224 mod 256 = 64
```

A script that can only advance whole frames can only ever observe **16 distinct timer phases** out of the timer's 256 possible phases.

That ceiling is imposed by the Game Boy hardware itself.

It does **not** change by:

- increasing the delay range,
- adding more split points,
- or simply waiting longer.

Splitting delays only improves exploration of the states already reachable from a save state—it cannot expand that reachable set.

That limitation belongs to the exact instant the save state was captured.

---

## The real fix: Re-rolling the save state

Since the limitation belongs to the save state rather than the delay strategy, the only way to move beyond it is to periodically stop reusing the same save state.

The implemented solution is straightforward:

- Every **30 minutes**, the script performs one large, full-range entropy injection.
- It then immediately creates a brand-new save state.
- All subsequent resets begin from this newly generated baseline.

Each newly captured save state has its own unique set of reachable RNG states.

This mirrors real gameplay: if a human walks away and returns later, the game's internal RNG registers have naturally drifted, meaning a save captured later starts from an entirely different baseline.

Practically, this means that if one save state's reachable set excludes every desired outcome, that state is no longer a permanent dead end—it simply represents one unlucky 30-minute window before the next automatic re-roll replaces it.

---

## The trade-off: Wide and slow vs. narrow and fast

Introducing periodic save-state re-rolling changes the optimization problem completely.

Before re-rolling existed, larger delay ranges were preferable because they expanded the portion of the reachable state space explored.

Once the save state itself is periodically refreshed, however, spending additional time squeezing more coverage from a single save state becomes much less valuable.

A "bad" save state—one whose reachable set excludes every desired outcome—lasts the same **30 minutes** regardless of how large that reachable set is.

Modeling real measured throughput showed that:

- Narrow delay ranges complete significantly more attempts within each 30-minute window.
- Wider delay ranges complete far fewer attempts, despite slightly better coverage.

The increased number of independent windows explored over time outweighs the improved coverage of any individual window.

For that reason, the delay range was intentionally reduced after introducing periodic save-state re-rolling.

Once the ceiling itself is guaranteed to reset, **speed becomes the dominant optimization.**

---

## Honest limitations

This approach **cannot mathematically prove 100% coverage**.

Since the emulator is fully deterministic, every specific combination of delays always maps to one fixed outcome.

The automation samples random combinations—it does **not** exhaustively test every possible combination.

There is therefore no guarantee that every possible outcome has a reachable path through any particular delay strategy.

Real hardware has the exact same philosophical limitation.

A physical Game Boy's RNG isn't "true" random either—it's exactly as deterministic as an emulator's, just seeded by genuinely unpredictable human timing instead of scripted delays.

Neither approach is provably complete.

What **can** be measured is whether the observed distribution behaves like ordinary statistical randomness or whether it shows obvious structural bias—for example, a very small set of outcomes repeating constantly no matter how long the automation runs.

That distinction is empirically testable, even if complete coverage is not.

---


### The "True Randomness" checkbox (legacy)

Soft-reset modules (**Starters** and **Egg**) include a **True Randomness** option.

#### Off (default)

- Fast
- ~98.8% empirically measured DV coverage
- Ideal for shiny hunting

Since there are **8 shiny DV combinations out of 65,536**, the small remaining coverage gap is extremely unlikely to exclude all shiny combinations.

#### On

- Significantly slower
- Uses one delay of **65,536+ frames**
- Mathematically guarantees reaching every possible DV combination given enough time

This mode is intended specifically for hunting unique DV combinations such as:

- Perfect DVs (**15/15/15/15**)
- Perfect Negative DVs (**0/0/0/0**)

where only **one** valid combination exists.

Whether the fast mode already reaches one of these rare combinations depends entirely on the individual save file.

It might.

It might not.

There is no way to know in advance.

Enabling **True Randomness** removes that uncertainty at the cost of substantially longer reset times.

---

### A small aside: Determinism in miniature

The entire RNG manipulation problem ultimately comes down to one simple rule:

> **Same input → same result.**

Give a PRNG the same starting state and the same sequence of calls, and it will always produce identical output.

Everything described above—the split delays, the coverage testing, and the True Randomness checkbox—exists solely to deliberately vary those inputs instead of replaying identical ones.

This project ends up illustrating a broader concept:

### Deterministic chaos

The RNG is fully known.

We can literally read the formula.

Yet it still *feels* unpredictable because we, as an external script, cannot control timing precisely enough to predict the exact starting conditions every attempt.

Nothing about the system is actually random.

The unpredictability comes entirely from imperfect control over its initial conditions.

This is the same reason classical systems like:

- Dice rolls
- Coin flips
- Weather

appear random despite being governed by deterministic physics.

Newtonian mechanics never stops applying to a tumbling coin.

"Randomness" in those cases is simply a statement about our own ignorance—not about the system itself lacking a cause.

Worth noting:

This says **nothing** about whether quantum mechanics contains fundamentally irreducible randomness or whether hidden-variable theories might ultimately describe reality.

That remains an open question in modern physics.

Our RNG is unquestionably deterministic because we can inspect the algorithm directly.

This project is therefore a demonstration of **classical determinism disguised as randomness**, not evidence for or against quantum interpretations.

---

### Applying this elsewhere

Any automation that repeatedly resets against a deterministic emulator's RNG encounters the same fundamental problem.

The general recipe is:

1. Confirm that repeated resets produce identical outcomes.
2. Introduce random timing delays.
3. Verify empirically that the results actually become more diverse.
4. If one delay still produces limited variety, split it across multiple distinct points instead of simply making one delay larger.
5. Measure actual coverage using real sample data rather than assuming the solution worked.

The important part is **measurement**.

Don't assume a timing strategy is effective simply because it contains "random" delays—verify that the observed distribution actually behaves like randomness.

## How Headbutt Trees work in Gen 2

A tree's identity is permanently fixed, not random per attempt. Which encounter table a tree draws from (and its encounter rate — some trees are 80%, some 50%, some as low as 10% "rare") is determined by a formula using your Trainer ID plus that tree's exact map coordinates. It's baked into your save file the moment that tree exists on the map — it never rotates, never moves to a different tree, and doesn't change between attempts.
Trees don't deplete. Unlike the HGSS remakes (where a tree that gives nothing on the first try stays empty forever), Gen 2's mechanic has no exhaustion at all — every headbuttable tree has some nonzero encounter chance, permanently, no matter how many times you've already hit it. There are 3 Types of Trees Forest Group, City Group and Mountain Group, all with unique [encounters](https://bulbapedia.bulbagarden.net/wiki/Headbutt_tree).

### Encounter Mechanics

[Source](https://bulbapedia.bulbagarden.net/wiki/Headbutt_tree)

The encounter rate and encounter table of each tree depends on the tree's index and the player's **Trainer ID number**.

The tree's index is an integer from **0 to 9**, which depends on its **X** and **Y** coordinates on the map—that is, its distance from the westernmost and northernmost edges, respectively. Specifically, the tree's index is calculated using the following formula:

```
TreeIndex = ⌊(X·Y + X + Y) / 5⌋ mod 10
```

The encounter rate and tree type depends on the last digit of the player's Trainer ID.

- If a tree's index is equal to that ID digit, the tree is a **"high-encounter tree"** and its encounter rate is **80%**.
- If the tree's index is one of the next four indices after that ID digit (wrapping back around to 0 after 9), the tree is a **"moderate-encounter tree"** and its encounter rate is **50%**.
- Otherwise, the tree is a **"moderate-encounter tree"** and its encounter rate is **10%**.
- High Encounter Trees can be calculated [here](http://tshadowknight.com/Headbutt%20Grid.htm)

### Encounter Rate by Index and Trainer ID

The following is a table depicting the encounter rate of the tree, based on the tree index and the last digit of the player's Trainer ID. Tree indexes are displayed in rows, while Trainer ID digits are displayed in columns.

An **80%** encounter rate indicates the tree is a **"high-encounter tree"**. Otherwise it is a **"moderate-encounter tree"**.

| Tree Index | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 |
|------------|---|---|---|---|---|---|---|---|---|---|
| **0** | 80% | 10% | 10% | 10% | 10% | 10% | 50% | 50% | 50% | 50% |
| **1** | 50% | 80% | 10% | 10% | 10% | 10% | 10% | 50% | 50% | 50% |
| **2** | 50% | 50% | 80% | 10% | 10% | 10% | 10% | 10% | 50% | 50% |
| **3** | 50% | 50% | 50% | 80% | 10% | 10% | 10% | 10% | 10% | 50% |
| **4** | 50% | 50% | 50% | 50% | 80% | 10% | 10% | 10% | 10% | 10% |
| **5** | 10% | 50% | 50% | 50% | 50% | 80% | 10% | 10% | 10% | 10% |
| **6** | 10% | 10% | 50% | 50% | 50% | 50% | 80% | 10% | 10% | 10% |
| **7** | 10% | 10% | 10% | 50% | 50% | 50% | 50% | 80% | 10% | 10% |
| **8** | 10% | 10% | 10% | 10% | 50% | 50% | 50% | 50% | 80% | 10% |
| **9** | 10% | 10% | 10% | 10% | 10% | 50% | 50% | 50% | 50% | 80% |

### Analysis

Since **X** and **Y** are interchangeable in the tree index formula, it is possible to "fix" one dimension to consider traveling along the other. Substituting **Z** for the fixed axis and **n** for the axis that will be traversed, the formula becomes:

```
TreeIndex = ⌊(Z·n + Z + n) / 5⌋ mod 10
          = ⌊((Z + 1)·n + Z) / 5⌋ mod 10
```

This result shows that, if a single row or column of trees is traversed, moving to an adjacent tree increases the tree's index by **(Z + 1) / 5** (modulo 10), where **Z** is the distance of that row or column from its origin edge (north or west). This means that the closer a row or column is to the edge, the slower the indices of those trees change as the row or column is traversed.


## Roadmap

- [ ] Auto Catch for Crystal




