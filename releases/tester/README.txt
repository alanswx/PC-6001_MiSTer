NEC PC-6001 for MiSTer - tester build 2026-10-30
================================================

This is a work-in-progress core. It runs N60-BASIC, loads tapes, runs ROM
cartridges and has the PC-6031 disk unit (one drive); the mkII/SR models are
not done yet.

Install
-------
Unzip this at the root of the SD card (/media/fat/). It puts:
  _Computer/PC6001_20261030.rbf   the core
  games/PC6001/boot.rom           BASICROM.60 + CGROM60.60 + DISK.ROM (22528 bytes;
                                  DISK.ROM is the disk unit's firmware)
  games/PC6001/MAME/              tapes from the MAME software list
  games/PC6001/TOSEC/             tapes from the TOSEC set
  games/PC6001/Cartridges/        ROM cartridges
  games/PC6001/Disks/             a blank formatted disk and the disk format program
No sub CPU (8049) ROM is needed.

Only PC-6001 (mode 1 and 2) tapes are included; mkII-only titles are left out.
The name says how to start each one: {m2p3} or [Mode 2, Page 3] means
answer 3 at "How Many Pages?". Mode 1 runs in 16 or 32 KB, mode 2 needs
32 KB (the default). "The Tank" needs CLEAR 10,&HD7FF before CLOAD.
Some TOSEC names give the wrong page count: "Dual" needs 2 pages and Memory
16 KB, "Seven" (The Seven Bibles) 2 pages, "Steal" 1 page.
"Star Wrecker": CLOAD, RUN, press Return (loads machine code), then CLOAD
and RUN again for the second program on the tape.
Memory: "Mode 1" in a name does not settle it. If CLOAD gives ?OM Error, use
32 KB (Outlaw, Pop, Risu, Seven). If a tape hangs or crashes at RUN with
32 KB, try 16 KB (Dual, Kaiten, Nostro): it assumes a 16 KB machine.

Using it
--------
- Disks: load "[OS] N60 Extended BASIC" as the cartridge and a .d88 as the
  Disk (top of the OSD). Answer "How Many Files?" and "How Many Pages?"
  (Enter for both), then FILES, SAVE"NAME", LOAD"NAME", KILL"NAME" etc.
  What the drive writes goes back into the .d88 file on the SD card; copy
  "Blank (formatted).d88" first to keep a clean one. To format a disk, mount
  it, CLOAD "Disk Format Program {m3}.p6" from the Disks folder, RUN and
  answer y (it formats the disk in the drive). Only 1D disks (up to 176 KB)
  and one drive; mkII/SR disks are not expected to work.
- At "How Many Pages?" press Enter (or type 1-4).
- Load a tape from the OSD (F12 > Tape), then type CLOAD and press Enter.
  When it says Ok, type RUN. Some tapes need other steps; follow the
  instructions that came with the tape.
- Cartridge (top of the OSD): pick a ROM; the machine resets and BASIC starts
  it. Machine > Remove cartridge takes it out and resets to BASIC. A
  cartridge is not remembered: the next core start goes to BASIC.
  Star Fire plays music on a blank screen for about 25 s before its first
  screen. Crowley Manor stops at an empty screen (it does in MAME too).
- Tape speed (Machine page): 7x by default while the tape plays, or Normal.
- Tape overlay (Video page): status bar while the tape plays; while it is
  stopped, what to type next (TYPE CLOAD, then TYPE RUN) for BASIC tapes.
- Memory (32/16 KB) and Aspect ratio need "Apply and reset".

Keyboard
--------
Input > Keyboard: JP (default) or US.
- US: the symbols are as printed on a US keyboard (\ gives the yen sign;
  ` { } | ~ do not exist on the PC-6001).
- JP: the keys are at the positions of the Japanese (JIS) keyboard, so some
  symbols differ from what is printed on a US keyboard:
    '  = :        Shift+'  = *       Shift+2 = "
    Shift+8 = (   Shift+9 = )        [ = @     ] = [     \ = ]     = = ^
Held keys repeat (after half a second).
GRAPH = Alt (or Win, see Input page), STOP = F9 / Pause / End, KANA = F7,
MODE = F8, PAGE = Page Up/Down, F1-F5 function keys (Shift: F6-F10).
Letters without Shift are lower case, as on the real machine.

What to test / report
---------------------
- Which tapes load and run, at 7x and at Normal tape speed. Name the file.
- Sound (PSG): does it sound right compared to an emulator or real hardware?
- Picture: wrong colours, glitches, sync problems on your display.
- Joystick games (STICK / STRIG).
- Cartridges: does each one start and play?
- Disks: format, SAVE, FILES, LOAD with Extended BASIC; any disk software
  for the plain PC-6001 you have.
Please include the tape name, the OSD settings, and a photo or screenshot.

Known issues
------------
- Mode 4 NTSC artifact colours are not emulated.
- No CSAVE, no WAV tapes. A .p6t tape plays without its gaps.
- Disk: one drive, 1D images only; "SYS" boot disks do not start yet.
- Only plain ROM cartridges (up to 16 KB); no RAM or bank-switched ones.
