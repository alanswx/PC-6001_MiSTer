#!/usr/bin/env bash
# Regression tests for the PC-6001 core (headless Verilator sim). Each test runs the sim and compares the hash
# of one frame (from --frame-log) with tests/expected/<test>.hash. UPDATE=1 ./run_tests.sh rewrites them
# (look at the PNGs in out/test/<test>/ first).
#
# ROMs: ../rom/BASICROM.60, ../rom/CGROM60.60 and, for the disk test, ../rom/DISK.ROM (not in the repository).
# TAPES=1 adds the tape, cartridge and disk tests, which use ../refs/software (not in the repository either).
set -u
cd "$(dirname "$0")"
SIM=${SIM:-./obj_dir_headless/Vtop}   # SIM=path: another build
OUT=out/test
mkdir -p "$OUT" tests/expected
[ -x "$SIM" ] || make headless >/dev/null || exit 1

fail=0
run() {   # name frame args...
	local name=$1 frame=$2; shift 2
	local dir=$OUT/$name
	rm -rf "$dir"; mkdir -p "$dir"
	"$SIM" --quiet --rom-dir ../rom --out "$dir" --frame-log "$dir/frames.csv" --stop-at-frame "$frame" \
		--screenshot "$frame" "$@" > "$dir/log.txt" 2>&1
	local h; h=$(awk -F, -v f="$frame" '$1==f {print $2}' "$dir/frames.csv")
	local exp=tests/expected/$name.hash
	if [ "${UPDATE:-0}" = 1 ]; then echo "$h" > "$exp"; echo "updated $name: $h"; return; fi
	if [ ! -f "$exp" ]; then echo "MISSING $name (hash $h; UPDATE=1 to record)"; fail=1
	elif [ "$(cat "$exp")" = "$h" ]; then echo "ok      $name"
	else echo "FAIL    $name: hash $h, expected $(cat "$exp") ($dir/frame_$(printf %06d "$frame").png)"; fail=1; fi
}

run boot_pages 300
run basic_print 520 --type '155:\n' --type '200:print 12*3\n' --type '330:PRINT "Hi"\n'
run screen3_lines 1400 --type '155:2\n{WAIT30}10 SCREEN 3,2,2:CLS\n{WAIT20}20 LINE (0,0)-(127,191),2:LINE (127,0)-(0,191),3\n{WAIT20}30 LINE (10,90)-(120,100),4,BF\n{WAIT20}40 GOTO 40\n{WAIT20}RUN\n'
run screen4_lines 1400 --type '155:2\n{WAIT30}10 SCREEN 4,2,2:CLS\n{WAIT20}20 LINE (0,0)-(127,191)\n{WAIT20}30 LINE (10,10)-(60,40),,BF\n{WAIT20}40 GOTO 40\n{WAIT20}RUN\n'
# Keyboard = US: every US symbol the P6 has, as printed on the keys
run kbd_us 900 --kbd-us --type '155:1\n{WAIT40}PRINT "!@#$%^&*()-_=+[]\\;:'"'"',.<>/?"\n'
# OSD Video = Composite (rtl/pc6001_composite.sv): the boot screen through the NTSC encoder and decoder
run composite_boot 300 --composite 0
# PC-6001mkII (--mk2: OSD Model, boot1.rom from ../rom/*.62): the mode menu, mode 1 (N60 BASIC, 16 KB) and mode 5
# (N60m-BASIC, 40x20 text), without the disk unit as in MAME
run mk2_menu 300 --mk2
run mk2_mode1 800 --mk2 --no-disk-unit --type '300:1{WAIT100}\n'
run mk2_mode5 900 --mk2 --no-disk-unit --type '300:5{WAIT100}\n{WAIT100}\n'
# PC-6601 (--p66: boot2.rom from ../rom/*.66): the mode menu, through the ROM store (rtl/rom_store.sv, DDR3)
run p66_menu 300 --p66
# the uPD7752 (rtl/upd7752.sv): TALK speaks "geimu o-ba-" (external frames, the voice ROM's code) and returns Ok
run mk2_talk 900 --mk2 --no-disk-unit --type '300:5{WAIT100}\n{WAIT100}\nTALK"F2 GEIMUO-BA-."\n'
# PC-6001mkIISR (--sr: boot3.rom from ../rom/SYSTEMROM1.64, SYSTEMROM2.64, CGROM68.64): its menu in the SR mode,
# and N66SR-BASIC (80 columns)
run sr_menu 300 --sr --no-disk-unit
run sr_basic 700 --sr --no-disk-unit --type '300:6' --type '500:PRINT "HELLO SR"\n'
if [ "${TAPES:-0}" = 1 ]; then
	run tape_lights_proto 1500 --tape "../refs/software/pc6001/cas/Lights_Out_Hiroshi_Ishioka_/Lights Out (BASIC prototype) {m1p1}.cas" \
		--type '155:1\n{WAIT30}CLOAD\n' --type '1250:LIST\n'
	run tape_lights_turbo 3600 --tape "../refs/software/pc6001/cas/Lights_Out_Hiroshi_Ishioka_/Lights Out {m1p1}.cas" --tape-turbo \
		--type '155:1\n{WAIT30}CLOAD\n' --type '1300:RUN\n'
	# mid-load: the status bar shows x7 and the elapsed tape time, so a wrong turbo factor changes the frame
	run tape_turbo_bar 400 --tape "../refs/software/pc6001/cas/Lights_Out_Hiroshi_Ishioka_/Lights Out {m1p1}.cas" --tape-turbo \
		--type '155:1\n{WAIT30}CLOAD\n'
	C=../refs/software/pc6001/cart
	run cart_frogger 600 --cart "$C/frogger/Frogger (Konami) (Japan) [_].rom"
	# Star Fire plays its intro music on a blank screen first; 7000-7FFF is the cartridge while CGROM is on
	run cart_starfire 1800 --cart "$C/star-fire/Star Fire (SystemSoft) (Japan) [_].rom"
	run cart_canyon 1200 --cart "$C/Canyon_Climber_Datasoft_/Canyon Climber (ROM cart).bin"
	# PC-6031 disk unit (DISK.ROM in ../rom): N60 Extended BASIC lists and loads TEST from tests/disk/test.d88, a disk
	# formatted in the simulator by the PC-6001 Series Disk Format Program, with TEST saved on it
	run disk_extbasic 1200 --cart "$C/_OS_N60_Extended_BASIC_Microsoft_/[OS] N60 Extended BASIC (ROM cart).bin" \
		--disk tests/disk/test.d88 --type '300:\n{WAIT60}\n{WAIT60}FILES\n{WAIT200}LOAD"TEST"\n{WAIT250}LIST 10-30\n'
	# touch panel (rtl/touch_panel.sv): the Touch Panel cartridge draws a diagonal then a line back, the pen moving
	# 2-3 steps a frame (it ignores jumps of 5 or more); the cross is the pen
	t=(--touch 400:0,0,0); f=500
	for i in $(seq 0 60); do t+=(--touch $f:$((40 + i * 3)),$((40 + i * 2)),1); f=$((f + 1)); done
	for i in $(seq 0 50); do t+=(--touch $f:$((220 - i * 3)),160,1); f=$((f + 1)); done
	t+=(--touch $f:70,160,0)
	# mode 4 stripes one dot apart through the composite path: green from an even dot, brownish orange from an odd
	# one (colour set 1); the same in colour set 2 as Red/Blue (slow: the decoder runs every clock)
	m=(--type '155:2\n{WAIT30}10 SCREEN 4,2,2:COLOR 1,0,1:CLS\n{WAIT20}20 FOR X=0 TO 62 STEP 2:LINE(X,0)-(X,80):NEXT\n{WAIT20}30 FOR X=129 TO 191 STEP 2:LINE(X,0)-(X,80):NEXT\n{WAIT20}40 LINE(0,100)-(255,150),,BF:FOR I=1 TO 900:NEXT:COLOR 1,0,2\n{WAIT20}50 GOTO 50\n{WAIT20}RUN\n')
	run composite_mode4 2200 --composite 0 "${m[@]}"
	run composite_mode4_bw 2500 --composite 0 "${m[@]}"
	# mkII mode 5 160x200 in 16 colours (SCREEN 3, C1 = 09h): bars of colours 1-16, 10 dots each
	m=(--type '300:5{WAIT100}\n{WAIT60}\n10 SCREEN 3,2,2:CLS\n{WAIT20}20 FOR I=0 TO 15:LINE(I*10,0)-(I*10+9,99),I+1,BF:NEXT\n{WAIT20}30 GOTO 30\n{WAIT20}RUN\n')
	run mk2_screen3 3300 --mk2 --no-disk-unit "${m[@]}"
	# the PC-6601's built-in drive (rtl/fdc66.sv): N66-BASIC lists and loads TEST from the PC-6031 test disk
	run p66_disk 1700 --p66 --disk tests/disk/test.d88 \
		--type '320:5{WAIT100}\n{WAIT100}\n{WAIT100}\n{WAIT60}FILES\n{WAIT150}LOAD"TEST"\n{WAIT250}LIST 10-30\n'
	# a mkII game: Chack'n Pop (mode 5, 1 page; Neo Kobe set) loads at 7x and shows its title screen
	CP="../refs/software/pc6001/neokobe_full_unzipped/NEC PC-6001/Chack'n Pop (Carry lab)/Chack'n Pop [CT]/Chack'n Pop {m5p1}.cas"
	run mk2_chackpop 5100 --mk2 --no-disk-unit --tape "$CP" --tape-turbo --type '300:5{WAIT100}1\n{WAIT80}CLOAD\n' \
		--after-motor 'RUN\n'
	run touch_draw 700 --cart "$C/_Utility_Touch_Panel_NEC_/[Utility] Touch Panel (ROM cart).bin" "${t[@]}"
	# the same through the mouse (rtl/touch_mouse.sv): a fast drag, 60 counts a frame; the point follows on a
	# straight line, slowly enough for the cartridge to draw all of it
	t=(--mouse 450:-120,-120,0 --mouse 520:0,0,1); f=530
	for i in $(seq 1 6); do t+=(--mouse $f:60,30,1); f=$((f + 1)); done
	t+=(--mouse 700:0,0,0)
	run touch_mouse 760 --cart "$C/_Utility_Touch_Panel_NEC_/[Utility] Touch Panel (ROM cart).bin" "${t[@]}"
fi
exit $fail
