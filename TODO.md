# TODO

## PC-6001
- Disk unit (rtl/pc6031.sv, runs DISK.ROM): a second drive; 2D / larger images; FORMAT of tracks the image lacks
  (an unformatted .d88); booting "SYS" disks such as Nyahacks 60 (how does a PC-6001 start one?); the PC-6031SR's
  extra commands. The firmware is the PC-80S31's: compare with a PC-6031 dump if one turns up.
- .p6t: play the footer's gaps (silence, carrier) and 600 baud blocks; only the byte image plays now.
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
  interrupt (INT2); composite for its colours; the PSG port A2 sync bits PC6001VX gives it.
- PC-6001mkIISR: 25-line text, the voice interrupt (INT4), SR software
  (tapes, disks); the 6601SR (SYSTEMROM*.68 are not here); the 8251 at 80h-81h.

## Last
- WAV tape input; CSAVE (command 38h bytes out).
