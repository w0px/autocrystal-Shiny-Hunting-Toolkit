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
  - [Case Study: Pokémon Gen 1 & Gen 2 Soft Reset Automation](#case-study-pokémon-gen-1--gen-2-soft-reset-automation)
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

Simulating Randomness: RNG Manipulation in Deterministic Emulation
What "randomness" actually means in software

Almost nothing in software is truly random. What games (and most computer systems) use is a pseudo-random number generator (PRNG)—a completely deterministic algorithm that takes some internal state, transforms it with a fixed mathematical formula, and produces output that looks statistically random.

Given the exact same starting state and the exact same sequence of calls, a PRNG produces the exact same "random" output every single time. That's not a bug—it's how PRNGs are built.

On real hardware, this determinism is normally invisible. A PRNG's internal state is usually tied to something like elapsed CPU cycles since power-on, and in real life no two play sessions have identical timing down to the cycle because a human's button presses are never frame-perfect.

The PRNG is still deterministic—it just never sees the same inputs twice, so it feels random.

Where this breaks: Deterministic emulation

Tools like BizHawk are deliberately engineered for perfect, bit-exact determinism—a core requirement for tool-assisted speedrunning, where a recorded input sequence must replay identically on any machine, forever.

That same property is exactly what breaks "randomness" for automated, reset-based interaction with a game's PRNG:

Reload the same save state, replay the same inputs, and you get the exact same PRNG state—and therefore the exact same "random" result—every single time.

This isn't specific to any one game; it affects any automation that resets and retries against a deterministic emulator's internal RNG.

Simulating randomness on purpose

Since the natural source of entropy (human timing variance) is gone, an automation script has to manufacture some on purpose.

Typically this is done by deliberately varying frame timing between attempts so the PRNG's state differs each time even though the algorithm itself stays perfectly deterministic.

This is genuinely simulating randomness—not generating true entropy, but artificially reintroducing the kind of variance a human would have supplied by accident.

The naive approach, and its hidden trap

The obvious fix is adding a single random delay after each reset.

The problem is that if the PRNG's state is tied to a countable deterministic quantity (such as elapsed frames), then a delay of 1–N frames can only ever reach N distinct PRNG states, regardless of how many times the script retries.

A delay range that's too small doesn't merely add "some" randomness—it silently caps how many outcomes are even reachable, potentially locking a script out of ever producing specific rare results.

A better technique: Splitting delays across multiple points

Rather than one large delay (which can guarantee full coverage but at a steep average-time cost), splitting the delay across several different points in the automation sequence produces significantly better coverage per unit of waiting time.

Each delay is separated by real game logic, such as:

Button presses
Dialogue
Animations
Menu transitions

Testing consistently showed that adding more split points across genuinely different moments closed the gap toward true random-like behavior far more efficiently than one large combined delay.

Where splitting itself hits a ceiling

Splitting helps, but it doesn't remove the underlying constraint—it just distributes the same cost more efficiently. Measured directly against Pokémon Crystal's DV roll, two things fell out of tuning the per-split delay range wider and wider:

Range mattered far more than count. Doubling how many split points fired barely moved measured coverage of the DV space. Doubling the range of each individual delay (256 → 512 frames) jumped measured coverage from roughly 2–6% to roughly 21%—by far the single biggest change tested.
Coverage still never approached 100%, no matter how wide the range got. Even at 4–8x the original delay range, a large majority of the DV space stayed structurally unreachable from a single starting save state.

That second point ruled out "just keep widening the delay" as a real fix. Something underneath was capping the ceiling regardless of how the delay was shaped.

The actual mechanism: a shared hardware timer, sampled once

Digging into the game's actual disassembly (not just observed behavior) explained why. Generation II's RNG isn't two independent random draws—both of its running totals are updated from the same single hardware timer sample on every call:

hRandomAdd += [timer sample]
hRandomSub -= [timer sample]

The Attack/Defense DV roll and the Speed/Special DV roll are two back-to-back calls to this same function. Because they draw from the same timer sample rather than two independent sources, they're correlated, not independent—inflating the delay range can't decouple them, since there's only one underlying value driving both.

That timer itself only advances once every 256 CPU cycles, while a single emulated frame is 70,224 cycles long. The math on how the two line up (70,224 mod 256) means a delay measured in whole frames—the only granularity a frame-advance-based script can produce—can only ever land on 16 distinct phases of that timer, out of 256 possible. This ceiling is fixed by the hardware itself: it doesn't move no matter how wide the delay range gets, how many split points fire, or how long the script waits.

In short: splitting and widening delays optimizes how efficiently a script explores the states reachable from one save state. It cannot expand what's reachable from that save state in the first place. That's a structural property of the exact instant the save state was captured, not something later button-press timing can undo.

The real fix: periodically re-rolling the save state itself

Since the ceiling belongs to the save state, not to the delay strategy, the only way past it is to stop reusing the same save state forever.

The working fix: on a fixed timer (every 30 minutes, in this implementation), the script fires one large, full-range entropy injection—paying the steep average-time cost once—and then re-saves the save state at that new point. Every reset after that draws from a freshly re-baselined starting point, with its own, different set of reachable states. This mirrors what a human player would get for free just by walking away and coming back later: the game's RNG registers keep evolving in the background regardless, and capturing a new save state at a different moment inherits whatever they've drifted to by then.

Practically, this means a save state whose reachable set happens to exclude every winning outcome isn't a permanent dead end—it's just the current 30-minute window's bad luck, corrected automatically at the next re-roll.

The trade-off this creates: wide-and-slow vs. narrow-and-fast

Once re-rolling exists, the earlier "wider range is better" conclusion actually flips. A wasted window—one whose reachable set happens to exclude every desired outcome—costs the same fixed 30 minutes either way, regardless of how large that window's reachable set was. Modeling realistic measured throughput at each range (a narrower, faster range completing many more attempts per window vs. a wider, slower range completing far fewer) showed that cycling through more 30-minute windows per hour matters more than any single window's odds of success. The delay range was deliberately dialed back down after adding the re-roll, for exactly this reason—speed wins once there's a guaranteed periodic reset of the ceiling itself.

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

# Case Study: Pokémon Gen 1 & Gen 2 Soft Reset Automation

Applying the above concepts to a real example.

Gen 1/2's RNG (documented by the **pokecrystal** disassembly project and the TAS/speedrunning community) is updated using the Game Boy hardware register **rDIV**, representing the upper 8 bits of a continuously incrementing 16-bit CPU cycle counter.

```text
hRandomAdd += rDIV
hRandomSub -= rDIV
```

This updates every time the game's `Random()` function is called and once every V-Blank.

Because it is CPU-cycle-based rather than simply incremented once per frame, it provides genuinely high entropy—not a small repeating cycle.

Automated soft resetting (reload → check → reset → repeat) runs directly into the deterministic problem described above.

Measured from real automated console logs:

| Split Points | Delay | Unique / Total | Coverage | Worst Repeat |
|--------------|-------|---------------:|---------:|-------------:|
| 1 | 1–30 frames | ~20 / 80 | ~25% | Severe clustering |
| 2 | 1–256 each | 193 / 270 | 71.5% | 5× |
| 4 | 1–256 each | 234 / 249 | 94.0% | 3× |
| 8 | 1–256 each | 248 / 251 | 98.8% | 2× |

The theoretical ceiling for perfectly uniform randomness at this sample size is approximately **99.8%**.

Using **8 split points** reached **98.8%**, placing it within roughly one percentage point of ideal randomness—a difference consistent with normal statistical variation rather than obvious structural bias.

Average added delay was roughly **1,000 frames**, corresponding to only a few seconds at normal speed and effectively instantaneous while fast-forwarding.

---

### The "True Randomness" checkbox

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




