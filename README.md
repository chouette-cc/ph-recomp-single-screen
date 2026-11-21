<img width="1917" height="1050" alt="image" src="https://github.com/user-attachments/assets/11149fc0-d232-45e5-aa18-a99d07440d60" />
<img width="1917" height="1050" alt="image" src="https://github.com/user-attachments/assets/2b6d260f-7b96-4b49-bfc6-ed6e21de6b1d" />



# Single Screen (Modern HUD) — Phantom Hourglass Recomp Mod

Play *The Legend of Zelda: Phantom Hourglass* on **one screen** or in a **fully customizable Side-by-Side layout**, with 8-way Picture-in-Picture (PiP) placement + X/Y offsets, full click-to-bind hotkeys, automatic top-screen NPC speech bubble pop-up, and **zero clutter text** drawn on screen.

Cross-platform **Lua 5.4** mod — works on both **PC (Windows/Linux)** and **Android**, for both USA (`AZEE`) and Europe (`AZEP`) ROMs.

## Features (v2.0.0)

- **Modern PiP (Overlaid Mode)**: Full-screen primary touch gameplay with a translucent antique-gold framed top screen:
  - **8 anchor positions**: `Top-Right` *(default)*, `Top-Center`, `Top-Left`, `Mid-Right`, `Mid-Left`, `Bottom-Right`, `Bottom-Center`, `Bottom-Left`.
  - **Fine X / Y Offsets**: `-25%` to `+25%` for pixel-perfect placement anywhere on screen.
  - **Size & Opacity**: `10% – 50%` *(default: `20%`)*, `0.25 – 1.00` *(default: `0.83`)*.
  - **Tap PiP Action**: `Cycle Size`, `Toggle Hide`, `Click-Through` *(default)*.
- **Customizable Side-by-Side / Stacked Mode (Non-Overlapping)**:
  - **Split Placement**: `Main Left / Top Right`, `Top Left / Main Right`, `Top Above Main`, `Main Above Top`.
  - **Split Main (%)**: `40% – 80%` *(default: `62%`)* to resize both screens freely.
  - **Split Align**: `Center`, `Top / Left`, `Bottom / Right`.
  - **Split Gap (px)**: `0 – 24 px` *(default: `6 px`)*.
- **Automatic Top-Screen NPC Dialogue Pop-Up**:
  - Detects when an NPC speaks on the bottom of the Top Screen (USA `AZEE` & Europe `AZEP`) and smoothly pops ONLY the speech bubble cleanly at the top-center of your primary screen while the secondary screen is hidden or minimized (`Hidden / Small` *(default)*, `When Hidden`, `Off`).
  - Supports **HD Text** seamlessly when enabled in the recomp.
- **Full Click-to-Bind Hotkeys** (Keyboard, Gamepad `Pad:*`, or Mouse buttons):
  - **Peek Top (Hold)** *(default: `V`)* — smoothly expands the top screen centered (no overlay text).
  - **Toggle Hide Top** *(default: `H`)* — show/hide the secondary screen in any mode.
  - **Shrink Top** / **Grow Top** — dynamically decrease/increase PiP size or Side-by-Side split ratio.
  - **Switch Mode** — cycle `Modern PiP` → `Side-by-Side` → `Hidden (Single)`.
- **Zero On-Screen Mod Text**: No labels, titles, or corner text drawn over the game.
- **Flicker-Free Startup & Dual-3D Handling**: Debounces 60 Hz dual-3D screen swaps (Title Screen / intro) cleanly in 4:3 and 16:9 Widescreen.
- **Optional Dual-Screen Boss Layouts**: `Auto Split`, `Enlarge PiP`, or `Off` *(default)*.

## Installation

### Recommended — Built-in Mod Browser (1-Click)
- **PC**: Open the in-game menu (`F1` / `Esc`) → **Mods** → **Browse Online** → click **Install** (or **Update**) on *Single Screen (Modern HUD)*.
- **Android**: Open the launcher → **Mods** → **Browse Online…** → select *Single Screen (Modern HUD)* → **Install**.

### Manual Installation
1. Download `single-screen.phmod` from the [Latest Release](https://github.com/chouette-cc/ph-recomp-single-screen/releases/latest).
2. **PC**: Drop `single-screen.phmod` directly into `<data-dir>/mods/` (no unzipping needed).
3. **Android**: Open the launcher → **Mods** → **Import file…** → select `single-screen.phmod`.

## License

MIT License — see [LICENSE](LICENSE). Contains no copyrighted game assets or code.
