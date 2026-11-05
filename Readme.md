# NEC PC-6001 for MiSTer

Work in progress: a MiSTer core for the NEC PC-6001 (1981), the PC-6001mkII (1983), the PC-6601 (1983) and the
PC-6001mkIISR (1984).

## Status

| Part | State |
|---|---|
| Z80 at 3.9936 MHz, waits on M1 / ROM / PSG, display bus steal (BUSRQ) | done (CSCP, PC6001VX timing) |
| Memory: 16 KB BASIC ROM, CGROM at 6000h, 16 or 32 KB RAM (32 KB is what a PC-6006 ROM/RAM cartridge gives) | done |
| VDG (M5C6847P-1): text, semigraphics 4/6, all 8 graphics modes, CSS, internal font | done; mode 4 artifact colours through the Composite (TV) video option (below) |
| 8255 mode 2 + sub CPU (keyboard, STICK/STRIG game keys, cassette) | high-level, after PC6001VX |
| Timer interrupt (2.05 ms, first period half) | done |
| AY-3-8910 (jt49), joysticks on port A | done; tone pitch matches MAME exactly (SOUND 0,254: 492 Hz); jt49's volume steps are 3 dB, MAME's flatter |
| Cassette: .p6 / .cas / .p6t images, 100 bytes/s while the motor relay is on; 7x turbo; status bar; next-step hint | done: all 73 tester tapes load at 7x on a MiSTer (and at 3x in the simulator); 16 give the same result at Normal (docs/CASSETTE_STATUS.md) |
| Cartridge ROM at 4000-7FFF (up to 16 KB), booted by BASIC's "AB" check | done (12 of 14 carts start; Crowley Manor stops at the same blank screen as in MAME; Touch Panel draws with the mouse as its pad, below) |
| PC-6031 disk unit (one drive, .d88): its own Z80 running DISK.ROM, 16 KB RAM, a uPD765, the 8255 pair at D0h | done: N60 Extended BASIC formats, saves, lists and loads, in the simulator and on a MiSTer (below) |
| Touch panel on joystick port 2, worked by the mouse | done: draws in the simulator; on a MiSTer the cursor and taps work (drags not tried yet: the KVM used for testing cannot hold a button). The protocol is from the Touch Panel cartridge's code; no emulator has it |
| Printer, RS-232C, Senshi no Cartridge (banked) | not yet |
| PC-6001mkII (Machine > Model): 64 KB RAM, the F0-F3 memory map, the mode menu, modes 1-4 in its colours, mode 5 (N60m: 40x20 text, 320x200 and 160x200 graphics), 16-colour palette, kanji ROM | beta: the mode menu, N60 BASIC and N60m-BASIC match MAME and run on a MiSTer; 61 of 110 mode 5 tapes reach their title in the simulator, Chack'n Pop among them; TALK speaks (uPD7752, below); Composite (TV) is for the PC-6001 only |
| PC-6601 (Machine > Model): the mkII with a built-in floppy drive (a uPD765 the Z80 drives, a 1 KB buffer at D0h-D3h) and N66-BASIC | beta: the menu and N66-BASIC's disk commands (FILES, LOAD, SAVE) work in the simulator and on a MiSTer; no 6601 disk software tried yet |
| PC-6001mkIISR (Machine > Model): the SR mode's 8 KB memory map, 40/80-column text, 320x200x16 and 640x200x4 bitmaps, palette, its interrupt controller (VRTC), YM2203 (jt03), 3.58 MHz Z80 | beta: the menu and N66SR-BASIC run in the simulator and on a MiSTer; SR graphics, dot scroll (ROLL) and PLAY on FM and SSG work in the simulator; FM not yet heard on a MiSTer (below) |
| PC-6601SR | not possible: only homebrew replacements for its ROMs (SYSTEMROM*.68) exist |

It boots N60-BASIC to "How Many Pages?", takes keyboard input, runs BASIC (including SCREEN 3/4 graphics) and
loads tapes and disks, in the Verilator simulation and on a MiSTer. The Quartus build fits (43% ALMs, 404 of 553
block RAMs, worst setup slack 0.494 ns), and the 28 simulator tests in `verilator/run_tests.sh` pass. The current
build is `releases/PC6001_20261105.rbf`.

## OSD

The menu follows the MiSTer computer-core OSD and tape standards:

| Row | Page | |
|---|---|---|
| Cartridge | top | a .rom / .bin / .60 ROM (up to 16 KB); resets the machine, which boots it; not remembered |
| Disk | top | a .d88 image (up to 512 KB; the PC-6031 is a 1D drive) in its drive 1; the drive's writes go back to the file. Needs DISK.ROM in boot.rom |
| Tape | top | a .p6 / .cas / .p6t image (up to 64 KB), rewound at each load; not remembered. A .p6t plays its byte image; its gaps are skipped |
| Load ROM | top | another boot.rom for this session; resets the machine |
| Memory | top | 32 KB or 16 KB (the PC-6001; the mkII has 64 KB) |
| Model | Machine | PC-6001 (default), PC-6001mkII (its ROMs in boot1.rom, below), PC-6601 (boot2.rom) or PC-6001mkIISR (boot3.rom) |
| Tape speed | Machine | 7x (default) or Normal; taken when the motor starts |
| Remove cartridge | Machine | button: takes the cartridge out and resets to BASIC |
| Rewind tape | Machine | button |
| Aspect ratio | Video | |
| Tape overlay | Video | On / Off: `TAPE ▶ m:ss/ m:ss x7` and a progress bar while the tape plays; the next step while it is stopped (below) |
| Video | Video | RGB (default): the VDG's colours, sharp; Composite (TV): the picture through an NTSC encoder and decoder, as a TV shows it (below) |
| B/W colours | Video | Composite only: what a TV makes of mode 4's black/white set (Red/Blue, Blue/Red, Pink/Green, Green/Pink, or None: grey) |
| Keyboard | Input | JP (default): US keys at the JIS key positions; US: the symbols printed on a US keyboard |
| Swap Alt/Win keys | Input | Yes: the Win keys are GRAPH |
| Port 2 | Input | joystick port 2: Joystick (default), or Touch panel (mouse): the pad the Touch Panel cartridge draws with (below) |

Model, Memory and Aspect ratio take effect at **Apply and reset** ("Changes pending" shows until then); the others act
at once.

Next-step hint: while the tape is stopped, the same box says what to type. A tape that starts with a BASIC
header (ten D3h bytes and a name) shows `TYPE CLOAD ↵` while it is rewound, and `TYPE RUN ↵` once that first
program has loaded, until Return is pressed. That second step assumes the program is started with RUN, which
held for every BASIC tape in the sweep. Later stops (a program loading its next parts) and tapes without the
header (machine code) show nothing; their instructions say what to do.

Turbo: while the motor relay is on, the Z80 runs 7 times as fast (27.96 MHz). The tape bytes, the 2 ms timer and
the sub CPU's delays all count Z80 states, so a loader sees the same timing it sees at 1x; the PSG and the video
keep their speed, and the machine is back at 3.99 MHz when the motor stops. 7x is the largest whole factor: 7.17x
would be a Z80 clock enable on every 28.6 MHz clock. There is no quick start: tapes are loaded with a typed
`CLOAD`.

## ROMs

Put `boot.rom` in `games/PC6001/`: `BASICROM.60` (16 KB) followed by `CGROM60.60` (4 KB), and for the disk unit
`DISK.ROM` (2 KB, the PC-80S31's firmware: MAME's `disk.rom` in the pc6001mk2sr / pc8001 sets, CRC 2158d307,
SHA1 bb7103a0818850a039c67ff666a31ce49a8d516f):

```
cat BASICROM.60 CGROM60.60 DISK.ROM > boot.rom
```

A 20 KB boot.rom (no DISK.ROM) has no disk unit: ports D0h-D3h read FFh, as with nothing connected, and a disk
mounted then gives "No disk unit".

For the PC-6001mkII, `boot1.rom` (96 KB) in the same folder, in MAME's order: `BASICROM.62` (32 KB),
`VOICEROM.62` (16 KB), `CGROM60.62`, `CGROM60m.62` (8 KB each), `KANJIROM.62` (32 KB):

```
cat BASICROM.62 VOICEROM.62 CGROM60.62 CGROM60m.62 KANJIROM.62 > boot1.rom
```

For the PC-6601, `boot2.rom` in the same order: `BASICROM.66`, `VOICEROM.66`, `CGROM60.66`, `CGROM66.66`,
`KANJIROM.66` (96 KB):

```
cat BASICROM.66 VOICEROM.66 CGROM60.66 CGROM66.66 KANJIROM.66 > boot2.rom
```

For the PC-6001mkIISR, `boot3.rom`: `SYSTEMROM1.64`, `SYSTEMROM2.64` (64 KB each), `CGROM68.64` (16 KB), 144 KB
(MAME's pc6001mk2sr set has them as systemrom1.64, systemrom2.64, cgrom68.64):

```
cat SYSTEMROM1.64 SYSTEMROM2.64 CGROM68.64 > boot3.rom
```

Main loads all of them at the core's start; Machine > Model picks which one runs. boot1.rom to boot3.rom are
kept in DDR3 and the model's set is copied into the core at each reset (rtl/rom_store.sv), so the model can
change without reloading the core. The PC-6031's DISK.ROM stays in boot.rom.

The sub CPU's 8049 ROM is not needed: the only public dump is bad (MAME marks it BAD_DUMP, and 60% of its
bytes equal their own address), so the core implements the sub CPU's behaviour, as MAME, PC6001V, PC6001VX and
PC6001VW do.

## Disk

The PC-6031 is a computer of its own, and the core runs it that way: a second Z80 at 4 MHz with the 2 KB
firmware, 16 KB of RAM, a uPD765 (rtl/upd765_lite.sv: the commands the firmware uses, in non-DMA mode) and an
8255 that faces the PC-6001's 8255 at D0h-D3h, wired as in CSCP. The firmware is the PC-80S31's (no PC-6031 dump
is known); PC-6001 software for the PC-8001's mini disk unit uses it, and it keeps a drive single sided (track =
cylinder) unless told otherwise, which is how the PC-6001's 1D disks are laid out.

On a PC-6001 disks are used through the **N60 Extended BASIC** cartridge (PCS-6001R): load it as the
cartridge, answer "How Many Files?" and "How Many Pages?", then `FILES`, `SAVE"NAME"`, `LOAD"NAME"`, `KILL`,
`DSKI$` / `DSKO$` and so on. A new disk is formatted with the PC-6001 Series Disk Format Program (a tape, run
under Extended BASIC). Tested in the simulator and on Mister 126: format, `SAVE`, `FILES`, `LOAD` and `RUN` after
a core reload, with the image on the SD card changed.

The image is held in DDR3 while it is mounted (up to 512 KB) and written back to the file 512 bytes at a time as
the drive changes it, unless it is mounted read-only or its D88 header says protected. Not done yet: a second
drive, disks larger than 1D, formatting a track the image does not already have (an "unformatted" .d88 with no
tracks), and booting "SYS" disks (Nyahacks 60).

## Keyboard

Input > Keyboard picks the layout. JP (the default) puts US keys at the positions of the PC-6001's JIS keys:
`'` is `:`, `[` is `@`, `]` is `[`, `\` is `]`, `=` is `^`, `` ` `` is the yen key. US types the symbols printed on
a US keyboard (Shift+2 is `@`, Shift+8 is `*`, `'` is `'`, `\` is the yen key); `` ` `` `{` `}` `|` `~` have no
PC-6001 key and stay as in JP. Kana, GRAPH and CTRL always use the JIS positions, and games that read the keys as
a joystick see the same keys in both. Held keys repeat after 500 ms, every 50 ms (the sub CPU does this on the
real machine), except KANA, PAGE, MODE, CAPS, STOP and F1-F5. GRAPH is Alt, STOP is F9 / Pause / End, KANA is F7, MODE is F8, PAGE is Page Up/Down,
HOME is Home, INS / DEL are Insert / Delete (and Backspace). F1-F5 are the function keys (with Shift: F6-F10).
Letters without Shift are lower case, as on the real keyboard.

## Touch panel

NEC's Touch Panel cartridge draws with a pad on joystick port 2. Set Input > Port 2 to Touch panel
(mouse), load the cartridge, and the mouse is the pen: move it to place the cross, hold the left button to
draw. The pad answers the way the cartridge's code asks (PSG port B bit 4 latches X or Y, bit 0 clocks it out
MSB first on port A bit 2, port A bit 0 is the pen). The cartridge ignores jumps of 5 steps or more between two
samples (a real pen moves smoothly; it samples about every 6 ms while drawing), so the pen point follows the
mouse on a straight line at 333 steps a second, and the pen goes down only once it has caught up. While the option is on, joystick 2 is not connected.

## PC-6001mkII

Machine > Model = PC-6001mkII (then Apply and reset) runs the mkII's ROMs from boot1.rom. It starts at the
"SELECT BASIC MODE" menu: modes 1-4 are N60 BASIC and N60 Extended BASIC in 16 or 32 KB, mode 5 is N60m-BASIC
with 64 KB. The memory map follows PC6001VX (MEM62): ports F0/F1 pick what each 8 KB block reads (BASIC, the
kanji or voice ROM as port C2 selects, the cartridge, RAM), F2 where each 16 KB writes, F3 the waits and
interrupt masks, F4 the sub CPU's vector, F6 the timer (2048 x (F6+1) Z80 states), F8 where the CG ROM appears.
The mkII draws modes 1-4 in its own colours (white text on black, a black border), and port C1 switches to the
N60m screens: 40x20 text in 16 colours, 320x200 in 4 and 160x200 in 16. MAME draws mode 5 text in 12-line rows
over 240 lines; the core uses 10-line rows over 200, as PC6001VX and CSCP do. The display holds the Z80 off for
336 dots of each mode 5 line, not the 368 both emulators give: with 368, tapes load wrongly at Normal speed
and Jelda crashes (docs/CASSETTE_STATUS.md).

Checked against MAME in the simulator: the menu, mode 1 ("7100 Bytes free") and mode 5 ("N60m-BASIC Ver.1.7,
12436 Bytes free") match. Not done yet: the joystick interrupt, and composite video for the mkII's colours.

Voice: `rtl/upd7752.sv` is the uPD7752 at E0h-E3h, a hardware rewrite of the synthesis engine PC6001VX uses
(cisc's "uPD7752 flavoured" engine, device/pd7752.cpp): frames of 7 parameter bytes, linear interpolation, a
pulse and noise source and five second-order filters, at 10 kHz, mixed with the PSG. Fed the same frames and
noise bits it gives the C engine's samples exactly (13800 of 13800 for `TALK"F2 GEIMUO-BA-."`). BASIC's TALK
reads its phonemes from VOICEROM.62 and sends them as external frames, so TALK with romaji works; the string
ends with "." or "?", and N60m-BASIC takes F2-F6 (not F1). The chip's built-in phrases (`TALK"F40."` to
`"F44."`, commands 0-4) are recordings PC6001VX plays from WAV files, so here they are silent.

## PC-6601

Machine > Model = PC-6601 is the mkII with a built-in floppy drive. Its menu offers N66-BASIC as mode 5, with
disk commands. The drive (rtl/fdc66.sv, after PC6001VX's DSK66) is a uPD765 the Z80 drives at DCh / DDh, and a
1 KB buffer at D0h-D3h that the CPU copies sectors in and out of with INIR / OTIR (the buffer address is the
port's low bits and the B register); DAh sets how many bytes a read or write moves. It uses the Disk slot's
image (1D, as the PC-6031's), so the same .d88 works on both. In the simulator N66-BASIC finds the drive, and
FILES, LOAD, SAVE and the write-back to the image work. The external PC-6031 port (B1h b2) reads as nothing
connected.

## PC-6001mkIISR

Machine > Model = PC-6001mkIISR. Its menu offers the older BASICs (1-5, with the mkII's memory map; SYSTEMROM1
holds their BASIC) and N66SR-BASIC (6). After PC6001VX (memory.cpp MEM64, mc6847.cpp PCZ80_12, intr.cpp IRQ64),
as MAME's driver does not run N66SR-BASIC:

- the SR mode (port C8h b0 = 0, from reset): memory in 8 KB blocks by ports 60h-6Fh (RAM, SYSTEMROM1/2,
  CGROM68, the cartridge), and the bitmap a dot at a time through a block mapped as 00h (x from the address,
  y from CEh/CFh)
- text 40 or 80 columns by 20 or 25 rows (character and attribute bytes, 16 colours), bitmaps of 320x200 in 16
  colours or 640x200 in 4, scrolled by CAh-CCh (the bitmaps by single dots); ports 40h-43h recolour four colours. The 640-dot screens need a
  14.32 MHz dot clock, so on this model every screen goes out at 14.32 MHz (the others' dots twice).
- interrupts by FAh/FBh and vectors B8h-BFh, with VRTC; the timer at 56 x (F6h + 1) states
- the YM2203 (jt03, 4 MHz) instead of the AY-3-8910; the Z80 at 3.58 MHz (28.636 MHz / 8)

On the MiSTer and in the simulator the menu appears and N66SR-BASIC starts; SCREEN 2,2,2 with LINE, ROLL and PLAY
work (BASIC's colours are 1-16, 1 and 9 black). The menu's colours follow PC6001VX's palette (MAME's driver
ignores ports 40h-43h). Not done: the 8251 serial port, the voice interrupt. The 6601SR cannot be done: only homebrew replacements for its
ROMs exist.

## Composite video

The PC-6001 was built for a TV, and its games use that: in mode 4 (SCREEN 4, 128 x 192 in four colours or
256 x 192 in two) a pattern of dots one apart turns into colour. Video > Composite (TV) shows that.
`rtl/pc6001_composite.sv` makes an NTSC signal from each dot as the VDG sends it (the MC6847 data sheet's luma
levels and its two colour difference outputs, low, centred or high), at 8 samples per subcarrier cycle, and
decodes it with Jamie Blanks' composite decoder from the NES core (`rtl/composite_decoder.sv`, MIT licence,
only its line store changed). The subcarrier is set against the dots to give what a real PC-6001 measured at
its video output: the two greens of the green set differ only in brightness, and stripes one dot apart are
green from an even dot and a brownish orange from an odd one.

The black/white set (`COLOR ,,2` in mode 4) has no colour burst, so a TV that follows the standard shows grey,
which is B/W colours = None. Many TVs, and the RF output, colour it anyway, at whatever phase they lock to;
games such as Orion and EGGY were drawn for that. The four other settings give such a burst, named (as in
PC6001VX) by the colours of stripes from an even dot and from an odd dot. Red/Blue is the default.

## Simulation

`verilator/` has a headless simulator (from SMC777_MiSTer's harness): `make`, then for example

```
./obj_dir_headless/Vtop --rom-dir ../rom --stop-at-frame 300 --screenshot 300
./obj_dir_headless/Vtop --rom-dir ../rom --tape game.cas --tape-turbo --stop-at-frame 1500 --type '155:1\n{WAIT30}CLOAD\n'
./run_tests.sh
```

`./obj_dir_headless/Vtop --help` lists the options. It needs verilator 5, ghdl 5 and python3.

## References

`refs/` (not in the repository) holds the emulators and documents this core follows: MAME's pc6001 driver,
the Common Source Code Project, PC6001VX (the sub CPU, 8255, keyboard, tape and palette), PC6001VW's history
notes, and datasheets. `refs/HARDWARE_NOTES.md` summarises the hardware with source references.
