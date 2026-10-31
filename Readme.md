# NEC PC-6001 for MiSTer

Work in progress: a MiSTer core for the NEC PC-6001 (1981), with the mkII, PC-6601 and SR models as later goals.

## Status

| Part | State |
|---|---|
| Z80 at 3.9936 MHz, waits on M1 / ROM / PSG, display bus steal (BUSRQ) | done (CSCP, PC6001VX timing) |
| Memory: 16 KB BASIC ROM, CGROM at 6000h, 16 or 32 KB RAM (32 KB is what a PC-6006 ROM/RAM cartridge gives) | done |
| VDG (M5C6847P-1): text, semigraphics 4/6, all 8 graphics modes, CSS, internal font | done; NTSC artifact colours in mode 4 not yet |
| 8255 mode 2 + sub CPU (keyboard, STICK/STRIG game keys, cassette) | high-level, after PC6001VX |
| Timer interrupt (2.05 ms, first period half) | done |
| AY-3-8910 (jt49), joysticks on port A | done; tone pitch matches MAME exactly (SOUND 0,254: 492 Hz); jt49's volume steps are 3 dB, MAME's flatter |
| Cassette: .p6 / .cas / .p6t images, 100 bytes/s while the motor relay is on; 7x turbo; status bar; next-step hint | done: all 73 tester tapes load at 7x on a MiSTer (and at 3x in the simulator); 16 give the same result at Normal (docs/CASSETTE_STATUS.md) |
| Cartridge ROM at 4000-7FFF (up to 16 KB), booted by BASIC's "AB" check | done (12 of 14 carts start; Crowley Manor stops at the same blank screen as in MAME; Touch Panel draws with the mouse as its pad, below) |
| PC-6031 disk unit (one drive, .d88): its own Z80 running DISK.ROM, 16 KB RAM, a uPD765, the 8255 pair at D0h | done: N60 Extended BASIC formats, saves, lists and loads, in the simulator and on a MiSTer (below) |
| Touch panel on joystick port 2, worked by the mouse | done: draws in the simulator; on a MiSTer the cursor and taps work (drags not tried yet: the KVM used for testing cannot hold a button). The protocol is from the Touch Panel cartridge's code; no emulator has it |
| Printer, RS-232C, voice, Senshi no Cartridge (banked) | not yet |
| mkII / 6601 / SR | not yet |

It boots N60-BASIC to "How Many Pages?", takes keyboard input, runs BASIC (including SCREEN 3/4 graphics) and
loads tapes and disks, in the Verilator simulation and on a MiSTer. The Quartus build fits (30% ALMs, 76% of the
block RAMs, timing met).

## OSD

The menu follows the MiSTer computer-core OSD and tape standards:

| Row | Page | |
|---|---|---|
| Cartridge | top | a .rom / .bin / .60 ROM (up to 16 KB); resets the machine, which boots it; not remembered |
| Disk | top | a .d88 image (up to 176 KB: a 1D disk) in the PC-6031's drive 1; the drive's writes go back to the file. Needs DISK.ROM in boot.rom |
| Tape | top | a .p6 / .cas / .p6t image (up to 64 KB), rewound at each load; not remembered. A .p6t plays its byte image; its gaps are skipped |
| Load ROM | top | another boot.rom for this session; resets the machine |
| Memory | top | 32 KB or 16 KB |
| Tape speed | Machine | 7x (default) or Normal; taken when the motor starts |
| Remove cartridge | Machine | button: takes the cartridge out and resets to BASIC |
| Rewind tape | Machine | button |
| Aspect ratio | Video | |
| Tape overlay | Video | On / Off: `TAPE ▶ m:ss/ m:ss x7` and a progress bar while the tape plays; the next step while it is stopped (below) |
| Keyboard | Input | JP (default): US keys at the JIS key positions; US: the symbols printed on a US keyboard |
| Swap Alt/Win keys | Input | Yes: the Win keys are GRAPH |
| Port 2 | Input | joystick port 2: Joystick (default), or Touch panel (mouse): the pad the Touch Panel cartridge draws with (below) |

Memory and Aspect ratio take effect at **Apply and reset** ("Changes pending" shows until then); the others act
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

The image is held in block RAM while it is mounted (176 KB) and written back to the file 512 bytes at a time as
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
