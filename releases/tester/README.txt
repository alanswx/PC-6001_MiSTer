NEC PC-6001 for MiSTer - tester build 2026-11-13
================================================

This is a work-in-progress core. It runs N60-BASIC, loads tapes, runs ROM
cartridges and has the PC-6031 disk unit (two drives). Machine > Model also
has the PC-6001mkII, the PC-6601 with its built-in drive and the
PC-6001mkIISR (below). The 6601SR is not done (its ROMs have not been dumped).
New in this build:
- Tape auto-start now always goes to the tape's model: a PC-6001 tape
  mounted while Model is the mkII switches back to the PC-6001 (before, it
  stayed on the mkII and some tapes failed there), and a mkII tape that is
  not in the game list is recognised from its contents (mode 5 BASIC, a
  monitor tape) and switches to the mkII.
- Fixed: after a load that never finished (the wrong model, a CLOAD still
  waiting), mounting the next tape only played it into that CLOAD: nothing
  was reset and RUN had to be typed by hand. A new tape now always starts
  from a reset, except for a game that asked for its next tape.
- Tapes up to 128 KB (it was 64 KB: Door Door MkII's mkII version, Lode
  Runner, Flappy, Mystery House II, Soreyuke Kurukuru and others were cut
  off, so they were not found in the game list and could not load whole).
- Fixed: Door Door's PC-6001 version showed "MADE FOR THE PC-6001MKII"
  when a game started (it sets a mkII port so one tape runs on both). A
  tape the game list gives the running model no longer shows that hint.
- Fixed: Umibe no Monogatari gave ?FC Error after its second tape. Part 1
  is RUN and leaves machine code in memory, then part 2 is loaded over it;
  mounting part 2 reset the machine and lost it. For such a tape (marked
  in the game list) there is now no reset: wait for Ok after part 1, mount
  part 2, and CLOAD and RUN are typed. Marked the same way after a run of
  34 two-part sets: White Day Happening!, Tanabata, Magnet Bead (all gave
  ?FC Error). Where part 1 loads part 2 itself and stops at Ok, RUN is
  now typed when the tape stops: Orkanoid II, Cube Puzzle, Watashi no Kare
  wa Pilot Game, Slayer. Windy Wolf and Circumference - Onion House are
  marked too. If another one fails after its second tape, tell me.
- Fixed: a tape image that begins with noise before its header (Runner,
  Circumference - Onion House) was not recognised and nothing was typed.
- Fixed: a BASIC program loaded while a graphics screen was shown could
  lose its first bytes (Slayer's part 2: ?SN Error after RUN). The tape now
  pauses briefly after a program's header, as a real tape's carrier does.
- Game list: Tiny Druaga MkII is a mkII tape (mode 5, 3 pages); it was
  listed as a PC-6001 one and stopped at Ok after RUN.
- Aspect ratio Original is now 8:7, the shape the picture has on a TV
  (it was 4:3, about 17% too wide). Full Screen still stretches it.
- Fixed: with a later model (mkII, 6601, SR) saved in the settings, the
  MiSTer froze at the core's start and only deleting PC6001.CFG brought it
  back. Saved models now start normally.
- Fixed: Pause left STOP held down (Tiny Xevious 2 stayed paused). STOP is
  F9 or End now. The kana key of a Japanese keyboard is KANA (F7 too).
- Two disk drives: OSD Disk 1 and Disk 2 (FILES 2, LOAD"2:NAME").
- mkIISR: its disk unit is the PC-6031SR and reads and writes 1DD disks
  (80 tracks), so the SR disks now work (Golf Island, Hydlide, The Akunin).
- mkII disks that start with a SYS program boot by themselves (Nyahacks 60).
- Wrong-model hint: when a program uses hardware the running model lacks,
  the corner says which model it was made for (Tiny Xevious 2 on a PC-6001
  says PC-6001MKII).
- Composite (TV) video on every model, not only the PC-6001.
Earlier (2026-11-09):
- A game list inside the core (571 tapes): it knows each tape by its contents,
  whatever the file is called, and sets the mode and pages, types what the
  readme says (Space Mouse's clear 10,&hd5ff; MON, R-0, G9000), adds the
  last byte Space Mouse's dump lacks, and shows a hint (Fruit Panic's Append,
  Portopia's colour pick). With Tape auto-start, a tape made for a later
  model switches Machine > Model to it (Portopia goes to the mkII).
- Two-tape games and "loader, then data" type-ins (Slender Island, Space
  Mouse 2): when the first tape ends the corner says MOUNT THE NEXT TAPE;
  mount it from the OSD and the game goes on.
- SCREEN 4 (the 256-dot black and white mode) in colour on every model, as
  on a TV and in PC6001VX: Video > B/W colours (Red/Blue by default; None
  for plain black and white).
Earlier: tape auto-start. Mount a tape and the core resets the
machine and types what the tape needs (the mode, the pages, CLOAD, RUN) by
itself (Machine > Tape auto-start, On by default). While the tape is
stopped, the corner also shows what it will type (MODE 5  PAGES 3 /
TYPE CLOAD). Please report tapes where it picks the wrong mode or pages.
Earlier: louder sound with the chips at matched levels, the SR's dot scroll,
and software for the mkII, 6601 and mkIISR.

Install
-------
Unzip this at the root of the SD card (/media/fat/). It puts:
  _Computer/PC6001_20261113.rbf  the core
  games/PC6001/boot.rom           BASICROM.60 + CGROM60.60 + DISK.ROM (22528 bytes;
                                  DISK.ROM is the disk unit's firmware)
  games/PC6001/boot1.rom          the mkII's ROMs: BASICROM.62 + VOICEROM.62 +
                                  CGROM60.62 + CGROM60m.62 + KANJIROM.62 (98304 bytes)
  games/PC6001/boot2.rom          the PC-6601's: BASICROM.66 + VOICEROM.66 +
                                  CGROM60.66 + CGROM66.66 + KANJIROM.66 (98304 bytes)
  games/PC6001/boot3.rom          the PC-6001mkIISR's: SYSTEMROM1.64 + SYSTEMROM2.64 +
                                  CGROM68.64 (147456 bytes)
  games/PC6001/MAME/              tapes from the MAME software list
  games/PC6001/TOSEC/             tapes from the TOSEC set
  games/PC6001/Cartridges/        ROM cartridges
  games/PC6001/Disks/             a blank formatted disk and the disk format program
  games/PC6001/mkII/              mkII tapes (Neo Kobe names, mode 5) and disks
  games/PC6001/PC-6601/           6601 disks and a tape
  games/PC6001/mkIISR/            SR tapes (MAME list) and disks
No sub CPU (8049) ROM is needed.

MAME/ and TOSEC/ hold PC-6001 (mode 1 and 2) tapes. The name says how to start each one: {m2p3} or [Mode 2, Page 3] means
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
  answer y (it formats the disk in the drive). Disk 2 is the second
  drive. The core cannot make a disk image file bigger, so start a new
  disk from a full-size image (copy the blank one), not an empty file.
- Tapes: load one from the OSD (F12 > Tape). With Tape auto-start On the
  machine resets and the core types the mode, the pages, CLOAD and RUN.
  It reads them from the tape: a .p6t can say them; otherwise they come
  from where the BASIC program was saved and the pages its SCREEN
  statements use. Machine-code tapes (no BASIC header) are not typed:
  follow their instructions. A tape mounted while a program waits for it
  (a game asking for its second tape) just plays, without a reset.
- By hand (auto-start Off): at "How Many Pages?" type the number the
  corner shows, or the one in the tape's name: {m5p3} means mode 5 at the
  menu, then 3 pages. A wrong count often makes a tape fail without an
  error. Then CLOAD, and RUN when it says Ok.
- Cartridge (top of the OSD): pick a ROM; the machine resets and BASIC starts
  it. Machine > Remove cartridge takes it out and resets to BASIC. A
  cartridge is not remembered: the next core start goes to BASIC.
  Star Fire plays music on a blank screen for about 25 s before its first
  screen. Crowley Manor stops at an empty screen (it does in MAME too).
- Tape speed (Machine page): 7x by default while the tape plays, or Normal.
- Tape auto-start (Machine page): On (default) or Off, see Tapes above.
- Tape overlay (Video page): status bar while the tape plays; while it is
  stopped, what to type next (MODE 5  PAGES 3 / TYPE CLOAD, then TYPE RUN).
- Video (Video page): RGB (sharp), or Composite (TV): the picture as a TV
  shows it, with colour bleed and mode 4 artifact colours (fine stripes turn
  into colour, as many games expect). B/W colours picks what a TV makes of
  mode 4's black/white set: Red/Blue (default), Blue/Red, Pink/Green,
  Green/Pink, or None (grey, as on a TV that follows the standard).
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
GRAPH = Alt (or Win, see Input page), STOP = F9 / End, KANA = F7 or the
Japanese keyboard's kana key,
MODE = F8, PAGE = Page Up/Down, F1-F5 function keys (Shift: F6-F10).
Letters without Shift are lower case, as on the real machine.

Touch panel
-----------
The "[Utility] Touch Panel" cartridge draws with NEC's touch pad. Set
Input > Port 2 to "Touch panel (mouse)" and load the cartridge: the mouse is
the pen. A cross shows where it is; hold the left button to draw. The pen
follows the mouse at a limited speed (the cartridge drops fast jumps), so
the cross may trail a quick movement. Joystick 2 is off while this is set.

PC-6001mkII
-----------
Machine > Model: PC-6001mkII, then Apply and reset. It starts at the mkII's
"SELECT BASIC MODE" menu: 1-4 are N60 BASIC / Extended BASIC (16 or 32 KB),
5 is N60m-BASIC (64 KB, 40x20 text, 16 colours, SCREEN 2/3 graphics).
New and lightly tested: the menu, modes 1 and 5 run on a MiSTer.
mkII/Tapes - reached title in sim: 61 mode 5 tapes that got to their title,
game or first prompt in the simulator (picked from its last frame, so not
played). mkII/Tapes - not reached yet: the other 49 - mostly second and later
tapes of a multi-tape game (load the first one), {mon r-0} tapes (not CLOAD:
type mon Enter, then R-0 Enter; the simulator only tried CLOAD) and ones that stopped
at CLOAD or a blank screen. {m5p3} means mode 5 at the menu, 3 at "How Many
Pages?". mkII/Disks: mkII disks for the PC-6031 unit (untested). TALK speaks
(e.g. TALK"F2 KONNICHIWA." - the text ends with "." and starts F2-F6); the
chip's built-in phrases (F40.-F44.) are silent. Disks whose first program
is SYS boot at the menu.
mkII tapes and cartridges are welcome reports.

PC-6601
-------
Machine > Model: PC-6601, then Apply and reset (the core need not be
reloaded). It is a mkII with a built-in 1D drive: mount a .d88 with
Disk 1, pick 5 (N66-BASIC) at the menu, and FILES / LOAD / SAVE use
the built-in drive. The PC-6031 unit is not connected in this model.
New: tested with BASIC files only. PC-6601/: Hudson Soft Best Hit Game
Pack 3 and Bad Apple ({m4f1p1 run IPL.BAS}: mode 4, 1 file, 1 page, then
RUN"IPL.BAS") on disk, Mario Bros. Special on tape. All untested.

PC-6001mkIISR
-------------
Machine > Model: PC-6001mkIISR, then Apply and reset. Its menu offers the
older BASICs (1-5) and N66SR-BASIC (6). New and lightly tested: the menu and
N66SR-BASIC run on a MiSTer; SCREEN 2,2,2 graphics, LINE, ROLL and PLAY
work in the simulator. BASIC's colours are 1-16 (1 and 9 are black). PLAY's
first string plays on FM, the fourth on the SSG (PSG): the FM has not been
listened to on a MiSTer yet - please report how it sounds. The picture is
640 dots wide on this model.
mkIISR/Tapes: the MAME SR list; pick 6 (N66SR-BASIC) at the menu, then CLOAD
and RUN. In the simulator Jewels and Lizard Quest reach their title and Satan
loads its second part; the rest are untested.
mkIISR/Disks: SR disks. The SR's disk unit (PC-6031SR) takes 1DD disks
(80 tracks): Golf Island and Hydlide boot by themselves; for others pick 6
and type FILES. File names can be lower case (run"bp8510.bas" on The
Akunin).

What to test / report
---------------------
- Which tapes load and run, at 7x and at Normal tape speed. Name the file.
- Sound (PSG): does it sound right compared to an emulator or real hardware?
- Picture: wrong colours, glitches, sync problems on your display.
- Composite (TV): do mode 4 games look as you remember them on a TV?
- Joystick games (STICK / STRIG).
- Cartridges: does each one start and play?
- Touch Panel with a mouse: do strokes follow the pen?
- Disks: format, SAVE, FILES, LOAD with Extended BASIC, on both drives; SR
  disk software; any disk software for the plain PC-6001 you have.
Please include the tape name, the OSD settings, and a photo or screenshot.

Known issues
------------
- No CSAVE, no WAV tapes. A .p6t tape plays without its gaps.
- Disk: no 2D images; the PC-6601 cannot format disks.
- Only plain ROM cartridges (up to 16 KB); no RAM or bank-switched ones.
