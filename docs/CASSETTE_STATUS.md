# Cassette status

Results for the tape standard (`~/dev2/tape-standard.md`): 7x turbo, the status bar, the next-step hint and
.p6t, measured on 2026-10-29/30.

## What the core does

| Feature | State |
|---|---|
| Formats | .p6 / .cas byte images; .p6t plays its byte image (the footer's gaps are skipped). Up to 64 KB |
| Tape speed | 7x (default) or Normal, Machine page; taken when the motor starts |
| Turbo | Z80 x7 (27.96 MHz) only while the motor relay is on; tape bytes, the 2 ms timer and the sub CPU's delays count Z80 states; the display's bus steal is off meanwhile |
| Quick start | none: the PC-6001 loads tapes with a typed CLOAD (standard: "Other machines") |
| Status bar | `TAPE ▶ m:ss/ m:ss x7` and a 64-step bar while the motor runs (X1 module) |
| Next-step hint | `TYPE CLOAD ↵` at the start of a tape with a BASIC header, `TYPE RUN ↵` after that first file, until Return |
| Rewind tape, Tape ready (rewound) | yes |
| CSAVE, WAV, gaps, 600 baud | no |

## Method

`verilator/tape_sweep.py` loads each tape in the headless simulator the way a user would:
1. It answers "How Many Pages?" from the file name.
2. It types CLOAD, then RUN when the motor stops.
3. When the machine sits idle for 5 s with tape left, it presses Space, then Return (up to 4 presses), as for a
   title or instruction screen.
4. It stops once the motor has stayed off for 10 s and keeps the last frame.

Memory was 32 KB unless noted. The corpus is the tester set: 28 tapes from MAME's software list and 45 from
TOSEC. Both include only PC-6001 (mode 1 and 2) titles.

## Turbo: 7x and 3x against Normal

16 tapes ran at all three speeds. Each showed the same final screen, tape position, motor stops and key presses
at every speed, and each loaded exactly 7 (or 3) times faster than at Normal (load time = frames with the motor
on; 7x measured 7.00-7.03x):

| Tape | 7x | 3x | Normal |
|---|---|---|---|
| Asalt | 6 s | 13 s | 39 s |
| AX-9 Blue Sky | 19 s | 45 s | 136 s |
| AX-9 Bounder Robo | 32 s | 75 s | 225 s |
| Eggy | 32 s | 74 s | 223 s |
| Hanabi | 2 s | 5 s | 16 s |
| Kaiten | 1 s | 3 s | 9 s |
| Lights Out (BASIC prototype) | 2 s | 5 s | 14 s |
| Master | 10 s | 23 s | 68 s |
| Meteorite | 4 s | 9 s | 26 s |
| Moon Raiders | 23 s | 54 s | 162 s |
| Nostro | 13 s | 29 s | 88 s |
| Orkanoid II (Part 2) | 4 s | 10 s | 30 s |
| Porice | 9 s | 21 s | 62 s |
| Quest 3 | 43 s | 99 s | 297 s |
| Tiny Xevious | 25 s | 59 s | 178 s |
| Toilet Adventure II | 20 s | 47 s | 142 s |

Kaiten and Nostro first looked different at Normal. The cause was the memory size, not the speed: both need
16 KB. With 32 KB both hang at both speeds, and the program in RAM after CLOAD is identical at 3x, 7x and Normal
except for 10-27 bytes of BASIC work area (F99B-FA28 with one page, DF98-DFBE with two; one byte at FECA in
Nostro and Porice).

Two turbo bugs found during bring-up have been fixed. At 3x the first program byte after a BASIC header was
lost (`?SN Error`), because the display's bus steal runs on the video clock and does not speed up. Bus steal is
now off while turbo is active. At 7x the clock-enable accumulator overflowed its 19 bits (286363 + 279552),
which made 7x load at only 5.2x; the sum is 20 bits now. 7x is the largest whole factor: 7.17x would be a Z80
enable on every 28.6 MHz clock.

## The corpus at 3x

All 73 tapes load at 3x. In each case where a tape stopped short, the reason was something the tape or its
file name needs, not something the core does wrong. Where MAME could run the tape, it behaved the same.

| Result | Tapes |
|---|---|
| Title, game or demo (43) | Asalt, Astero, AX-9 (3D Flight Simulator, Blue Sky, Bounder Robo, Demo), Ax7 Demo, Ax9 Demo, Bound, Break Through, Car, Demo, Eggy (both), Fls, Foot, Galaxy (all three), Hanabi, Headon, Invaders, Lights Out (both), Magnetic Field, Master, Meteorite, Moon Raiders, Orion 3, Orion 4, Orkanoid II Part 2, Outlaw\*, Pop\*, Porice, Quest 3, Quest 4, Risu\*, Sky, Ston Ball, Take Off 6000, The Tank, Tiny Xevious, Toilet Adventure II |
| Its own menu or a key-wait the sweep does not answer (13) | Amazon (k/s), Arabia (Y/N), Asteroid, Barri, Block (speed 1-3), Destroy (joystick Y/N), Godhar (C/G), Power (C/B), Shut, Simon, Tiny Xevious 2 (1/2/3), Trick Boy (1/2), Woods |
| Asks the user for input (4) | Flight Simulator (runway direction), Graphic Maze (all three versions, maze size) |
| Needs more than CLOAD and RUN (5) | Star Wrecker (both copies), Kita, Holy Sword, Earth Bound |
| Two-tape games (3) | Cyber Village Tape 1 and 2, Orkanoid II Part 1 |
| Pages or memory differ from the file name (5) | Dual, Kaiten, Nostro, Seven, Steal |

\* needs 32 KB although TOSEC calls it Mode 1 (`?OM Error` at 16 KB).

- **Star Wrecker**: CLOAD, RUN, Return (loads machine code), then CLOAD and RUN again for the second BASIC
  file. Done that way, it reaches its title.
- **Kita**: after RUN it waits about 40 s, then asks "ロードノ ジュンビハ OK? [Y]", as in MAME; Y loads the rest.
- **Holy Sword, Earth Bound**: stop at a y/n question or a title with tape left. The sweep's Space and Return
  don't answer them.
- **Cyber Village**: Tape 1 plays to its end and then needs Tape 2; Tape 2 alone holds only the second part.
  Orkanoid II Part 1 writes its machine code and then wants Part 2.
- **Pages and memory:**
  - Dual: 2 pages and 16 KB. Its line 30 is SCREEN 2,2,2, which gives `?FC Error` with 1 page; MAME, with
    32 KB, resets at RUN.
  - Steal: 1 page; its line 5 CLEARs up to F9FF, which gives `?FC Error` with 2 or 3 pages.
  - Seven (The Seven Bibles): 2 pages and 32 KB. With 1 page, its EXEC into machine code inside the BASIC text
    resets the machine.
  - Kaiten and Nostro: 16 KB.

So "Mode 1" in a file name does not settle the memory size. A tape that gives `?OM Error` during CLOAD needs
32 KB; one that hangs or crashes at RUN with 32 KB may need 16 KB. Its fixed addresses assume BASIC's 16 KB
layout, as on a real PC-6001 with the 16 KB expansion.

## Next-step hint

The hint shows only what the tape says. A tape that starts with ten D3h bytes and a name is BASIC, so its hint is
`TYPE CLOAD ↵`. After the first file has loaded, the hint is `TYPE RUN ↵`. Both commands are exactly what the
sweep types, and they started every BASIC tape in the corpus. Tapes that need more (Star Wrecker's second CLOAD,
Kita's Y) say so on their own screens; the hint shows nothing for them.

## On a MiSTer (Mister 126)

All 73 tapes ran at 7x on 2026-10-30 (`runs/hw126/sweep/drive.py`), with the simulator sweep's steps typed
through MiSTerKVMS: an MGL loads the tape, then the page count, any setup line, CLOAD, RUN when the motor stops,
and Space / Return when the machine sits idle. Each tape loaded and showed the same screen as the simulator, or a
later one where a key press started the game (Blue Sky, Eggy, Godhar, Invaders, Magnetic Field, Pop, Seven,
Outlaw and others). Points worth noting:

- Orkanoid II Part 2 ended black in the earlier 3x run (stopped at 52 tapes); at 7x it reaches its title.
- Arabia: Return on the instruction page gives `?FC Error in 310`, the same at 3x on hardware and in MAME 0.283.
- Steal: Space on the title starts the game screen, then the machine is back at "How Many Pages?". The simulator
  and MAME 0.283 do the same (in MAME already after RUN), so it is the tape image.
- Star Wrecker stops after its first part on both: it needs a second CLOAD (README).
- The driver's motor detection takes a screenshot about every second, so at 7x it misses short first files
  ("never played" in its log for 15 tapes); those tapes still loaded, as the screens show.

Earlier: Lights Out (.cas) at Normal and 3x, and Tiny Xevious (.p6t) at 3x with the hint (`TYPE CLOAD ↵`, then
`TYPE RUN ↵`) and the status bar (`0:59/ 2:57 x3`; 2:57 is the byte image without the P6T footer).

## Not done

- WAV input, CSAVE, the .p6t footer's gaps and 600 baud blocks.
- A Normal-speed run of the whole corpus (16 tapes so far, in the simulator).
