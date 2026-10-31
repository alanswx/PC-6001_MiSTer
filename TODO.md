# TODO

## PC-6001
- Disk unit (rtl/pc6031.sv, runs DISK.ROM): a second drive; 2D / larger images; FORMAT of tracks the image lacks
  (an unformatted .d88); booting "SYS" disks such as Nyahacks 60 (how does a PC-6001 start one?); the PC-6031SR's
  extra commands. The firmware is the PC-80S31's: compare with a PC-6031 dump if one turns up.
- .p6t: play the footer's gaps (silence, carrier) and 600 baud blocks; only the byte image plays now.
- Cartridges: RAM and banked types (PC-6006 ROM/RAM, Senshi no Cartridge), Touch Panel pad; EXTROM.60.
- Mode 4 NTSC artifact colours (PC6001VX COL60_CG "にじみ" tables).
- PSG: pitch matches MAME; volume 15 -> 10 is 5.7x in jt49, 3.8x in MAME. Check against a real machine's
  recording before changing. Noise and envelopes not compared yet. (Joystick bits and the port B bit 6 select
  match PC6001VX; not tried with a real stick on a MiSTer.)
- Compare frames against a reference emulator. CSCP needs a good SUBCPU.60 dump; MAME boots (HLE sub CPU)
  and can be driven by `refs/work/mame_type.lua`, but its natural keyboard drops `(`, `)` and `:`.
- Printer (port B / C0), RS-232C (80-81).

## Later models
- mkII: 64 KB RAM, F0-F3 banking, N60m mode 5 screens, 15 colours, kanji ROM, uPD7752 voice (CSCP has a full
  model), 40x20 text.
- PC-6601: internal uPD765 floppy.
- SR: YM2203, SR video modes, programmable interrupt vectors (B8-BF, FA, FB).

## Last
- WAV tape input; CSAVE (command 38h bytes out).
