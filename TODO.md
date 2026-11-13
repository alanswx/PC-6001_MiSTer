# TODO

## PC-6001
- Disk unit (rtl/pc6031.sv, runs DISK.ROM; two drives and the SR's 1DD done 2026-11-10, both tried on a
  MiSTer): more SR disk software; saving to drive 2 and to a 1DD disk on a MiSTer; a PC-6001 1D disk on the SR (read as 1DD there, as N66SR-BASIC does).
  The firmware is the PC-80S31's: compare with a PC-6031 / PC-6031SR dump if one turns up. Unformatted images
  cannot grow (Main keeps the file size): tools/blank_d88.py writes full-size blanks.
- .p6t: play the footer's gaps (silence, carrier) and 600 baud blocks; only the byte image plays now (with a
  half-second gap before each machine-code sync, six 9Ch, after the start).
- Cartridges: Senshi no Cartridge (PC6001VX EXCSOL1 on a PC-6001: 128 KB ROM in 8 KB banks at 4000h, picked by
  OUT 7Fh, and 32 KB RAM at 6000h-BFFF): nothing dumped here needs it, so wait for software to test with. (The
  PC-6006 ROM/RAM cartridge is the 32 KB setting; EXTROM.60 is only CSCP's name for the cartridge file.)
- Touch panel: try a drag on a MiSTer with a real mouse (the KVM's button does not stay down); check the pad's
  real range (0-255 is assumed).
- Composite video: compare B/W colours with photos of real TVs.
- PSG: pitch matches MAME; volume 15 -> 10 is 5.7x in jt49, 3.8x in MAME. Check against a real machine's
  recording before changing. Noise and envelopes not compared yet. (Joystick bits and the port B bit 6 select
  match PC6001VX; not tried with a real stick on a MiSTer.)
- Compare frames against a reference emulator. CSCP needs a good SUBCPU.60 dump; MAME boots (HLE sub CPU)
  and can be driven by `refs/work/mame_type.lua`, but its natural keyboard drops `(`, `)` and `:`.
- Printer (port B / C0), RS-232C (80-81).

## Later models
- PC-6601: format (Write ID is not in PC6001VX either); booting disks; the external
  PC-6031 port; 6601 software.
- mkII (started 2026-10-31: memory map, mode 5, palette, mode menu): check on a MiSTer; tapes and cartridges
  made for the mkII; uPD7752 built-in phrases (F40-F44: PC6001VX plays WAV files, no data here); the joystick
  interrupt (INT2); the PSG port A2 sync bits PC6001VX gives it.
- PC-6001mkIISR: 25-line text, the voice interrupt (INT4), SR software
  (tapes, disks); the 6601SR (SYSTEMROM*.68 are not here); the 8251 at 80h-81h.

## Next
- Testers' report 2026-11-10 (fixed in the next build): a later model saved in the cfg froze Main at the core's
  start (rtl/rom_store.sv: the ROM copy's DDR3 read went out with boot*.rom's write); Pause left STOP held; the
  JIS kana key was not KANA. Check the PC-8001 core's same fix on a MiSTer.
- Wrong-model hint (done: rtl/tape_auto.sv): watch the testers' reports for false alarms (C1-C3, F0-F3, E0-E3
  written on a PC-6001; C8 with b0 = 0, 40-43, 60-6F on a mkII).
- Game list (done: rtl/pc6001_gamelist.svh from tools/gamelist.py, 571 tapes): more collections and testers'
  notes; a disk list (.d88) the same way; the hint for Tape auto-start Off (shown only once typing ends now).
- Testers' report 2026-11-12 (Danjuro): the model follows the tape both ways (the list's model, or N60m-BASIC
  seen in the tape); a new tape resets unless a game waits for it at the last tape's end; tapes up to 128 KB
  (the two Yokai Tantei Chima Chima .p6t, 132 KB, are still too large); Tiny Druaga MkII is mode 5. Open: Tiny
  Xevious 2 "stretched vertically" (every screen has the same dot shape here: ask for a photo). Door Door's
  PC-6001 version showed "made for the mkII": it writes the mkII's port F3h (PC 803Fh) once a game starts; no
  port hint now for a tape the list gives the running model.
- Testers' report 2026-11-12 (zivago): Umibe no Monogatari's part 2 gave ?FC Error (the reset at its mount lost
  part 1's machine code): the list's {next} mark, no reset. 34 two-part sets then run on Mister 126
  (runs/parts): marked {next} White Day Happening!, Tanabata, Magnet Bead (?FC Error before); marked {next}\nRUN
  (part 1 CLOADs part 2 and stops at Ok: RUN typed when the tape stops) Orkanoid II, Cube Puzzle, Watashi no Kare
  wa Pilot Game, Slayer and its T-En. Slayer lost the first bytes after part 2's header (part 1 CLOADs it in
  SCREEN 3, "Found:" is slow to draw): a BASIC header is now followed by 50 byte times of gap. Worked unmarked:
  White Road, Kirei ni Naritai, Forts, Ichigo no Utage, Kyoufu - Toukousha no Noroi, Save Me, Cyber Village,
  Slender Island, Prohibition Island, UFO vs. You, Living Armor. Runner and Circumference - Onion House
  begin with noise before the D3 header: the header is found after up to 118 bytes of it. Circumference's part 1
  holds the gap's noise as bytes before the raw machine code its RUN reads: the list types only CLOAD, and RUN at
  part 2's mount. Windy Wolf: {next}. Slayer II's part 2 runs with the gap (part 3, loaded at the game's end, not
  run). AX-8 Galaxy Mission's two parts each start alone. All on Mister 126. Open: the hint "AT OK: MOUNT PART 2"
  did not show for Circumference's part 1 there; Legends of Star Arthur and Ankoku not run.
- Composite for the mkII, PC-6601 and SR (done: their RGB as NTSC into the same decoder): tune against PC6001VX's
  NTSC filter and photos of real machines; the SR's 640-dot modes.

## Last
- WAV tape input; CSAVE (command 38h bytes out).
