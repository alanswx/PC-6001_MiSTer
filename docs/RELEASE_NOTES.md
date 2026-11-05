# PC-6001 for MiSTer: first release (v0.9, beta)

A core for NEC's PC-6001 family. The PC-6001 is complete apart from the printer and RS-232C ports; the
PC-6001mkII, PC-6601 and PC-6001mkIISR (Machine > Model) are in beta.

## What works

- **PC-6001:** N60-BASIC, all eight VDG screen modes, the PSG and joysticks, tapes (.p6 / .cas / .p6t) at 1x or
  7x with a status bar and a "what to type next" hint, ROM cartridges, the PC-6031 disk unit (.d88, one drive,
  writes go back to the SD card), the Touch Panel worked by the mouse, and a Composite (TV) video option for
  mode 4's artifact colours.
- **PC-6001mkII (beta):** the mode menu, N60 and N60m-BASIC, its colours and screens, the kanji ROM, and TALK
  through the uPD7752 voice synthesiser. Most mode 5 tapes tried reach their title.
- **PC-6601 (beta):** the mkII with its built-in drive: N66-BASIC's FILES, LOAD and SAVE.
- **PC-6001mkIISR (beta):** its menu and N66SR-BASIC, 40/80-column text, the 320x200x16 and 640x200x4 bitmaps
  with dot scroll, the YM2203 (FM and SSG).

## Not yet

- Printer and RS-232C; CSAVE and WAV tape input; a second drive, 2D/1DD disks and booting "SYS" disks
- The banked Senshi no Cartridge; the mkII voice chip's built-in phrases (they need recordings)
- The SR's 8251 and voice interrupt; the PC-6601SR (its ROMs have not been dumped)

## Setup

No ROMs come with the core. Put `boot.rom` (and `boot1.rom` to `boot3.rom` for the later models) in
`games/PC6001/`; the Readme's ROMs section gives the files and the `cat` line for each. The sub CPU's ROM is
not needed.

## Tape tips

A tape's name often says how to start it: `{m2p3}` means mode 2 at the menu and 3 at "How Many Pages?". A wrong
page count often makes a tape fail with no error. Then `CLOAD`, and `RUN` when it says Ok.

Reports of software that does or does not work are welcome, especially for the mkII, 6601 and SR.
