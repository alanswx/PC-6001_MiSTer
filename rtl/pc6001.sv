//============================================================================
//  NEC PC-6001 machine
//
//  clk_sys = 28.636 MHz (8 x the NTSC colour subcarrier). The VDG dot clock is clk_sys / 4 (7.16 MHz); the
//  Z80 runs at 3.9936 MHz (7.9872 MHz / 2) from a fractional enable, the AY-3-8910 at 1.9968 MHz.
//  Tape turbo: while the motor relay is on, the Z80 runs 3 times as fast (11.98 MHz, enables at least two
//  clocks apart). The tape, the timer and the sub CPU count Z80 states, so the loader sees the same timing;
//  the display's bus steal is off meanwhile (it does not scale, see busrq).
//
//  Memory (MAME pc6001_map, CSCP memory.cpp):
//    0000-3FFF  BASIC ROM (16 KB)
//    4000-7FFF  cartridge ROM (up to 16 KB; FFh past its end, all FFh without one)
//    6000-7FFF  CGROM (4 KB, mirrored) instead while 8255 port C bit 2 = 0; 7000-7FFF stays the cartridge
//               when one is in (PC6001V MEM60::AreaD60Read)
//    8000-FFFF  RAM: 32 KB, or 16 KB at C000-FFFF (OSD)
//  Waits (CSCP memory.cpp): one on each M1, one on each access below 8000h, one on ports A0h-AFh.
//
//  I/O: 90-93 8255 / sub CPU (mirrored to 9F), A0-A2 PSG (mirrored to AF), B0 system latch (mirrored to BF):
//    B0: b0 timer off, b2-1 VRAM page (C000h E000h 8000h A000h), b3 cassette motor.
//  Interrupts, IM 2: the timer (vector 06h, every 2048 x 4 Z80 states, the first period after B0 b0 goes low
//  is half) before the sub CPU (vector from port A) (PC6001VX intr.cpp).
//
//  ROM download (ioctl index 0, boot.rom or Load ROM): BASICROM.60 at 0, CGROM60.60 at 4000h.
//  Cartridge (ioctl index 2): a .rom/.bin image; BASIC boots it at reset when it starts with "AB".
//  Tape (ioctl index 1): a .p6/.cas byte image, or a .p6t (its byte image plays), up to 64 KB. While the motor
//  relay (B0 b3) is on, one byte goes to the sub CPU every 1/100 s (1200 baud, 1 start + 8 data + 3 stop bits), as
//  PC6001VX's tape.cpp.
//============================================================================

module pc6001 #(
	parameter int TURBO = 7            // tape turbo factor (Z80 x TURBO while the motor runs), at most 7
)
(
	input             clk_sys,
	input             reset,
	input       [1:0] model,           // OSD Model, taken at reset: 0 PC-6001, 1 PC-6001mkII (boot1.rom), 2 PC-6601 (boot2.rom),
	                                   // 3 PC-6001mkIISR (boot3.rom)
	input             ram16k,          // OSD: 16 KB RAM instead of 32 KB (PC-6001)
	input             tape_turbo,      // OSD: TURBO x while the motor relay is on
	input             tape_rewind,
	input             cart_eject,
	input             tape_autostart,  // OSD: mounting a tape types what it needs (rtl/tape_auto.sv)
	input       [2:0] m4col,           // OSD B/W colours: mode 4 in colour (rtl/pc6001_vdg.sv)

	input      [10:0] ps2_key,
	input             kbd_us,          // keyboard layout: 1 US symbols, 0 JIS positions
	input       [5:0] joy0,            // MiSTer: b0 right b1 left b2 down b3 up b4 fire1 b5 fire2
	input       [5:0] joy1,
	input             touch_en,        // OSD: a touch panel (rtl/touch_panel.sv) instead of joystick 2
	input       [7:0] touch_x,
	input       [7:0] touch_y,
	input             touch_pen,

	input             ioctl_download,
	input       [7:0] ioctl_index,
	input             ioctl_wr,
	input      [24:0] ioctl_addr,
	input       [7:0] ioctl_dout,
	output            ioctl_wait,      // the mkII's / PC-6601's ROMs going to DDR3 (rtl/rom_store.sv)

	output            ce_pix,
	output      [7:0] R,
	output      [7:0] G,
	output      [7:0] B,
	output            HSync,
	output            VSync,
	output            HBlank,
	output            VBlank,
	output            mono,          // no colour burst (rtl/pc6001_vdg.sv)
	output      [4:0] cidx,          // the dot's colour code

	output     [15:0] audio,

	output            tape_motor,
	output            tape_loaded,
	output            tape_too_big,    // the image was larger than 64 KB (cut off)
	output            tape_turbo_on,
	output     [16:0] tape_position,   // bytes played
	output     [16:0] tape_length,
	output            hint_show,       // what to type, while the deck is stopped (rtl/tape_auto.sv)
	output            hint_two,
	output    [383:0] hint_text,
	output            hint_force,      // "MOUNT THE NEXT TAPE" or the wrong-model hint: over the tape bar, and without
	                                   // a tape
	output            model_set,       // one clk: the game list switches OSD Model to model_req (rtl/tape_auto.sv)
	output      [1:0] model_req,
	output            cart_too_big,    // the image was larger than 16 KB (cut off)

	// PC-6031 disk unit (rtl/pc6031.sv): its firmware is DISK.ROM at 5000h in the ROM download
	input             img_mounted,
	input             img_readonly,
	input      [63:0] img_size,
	output     [31:0] sd_lba,
	output            sd_rd,
	output            sd_wr,
	input             sd_ack,
	input       [8:0] sd_buff_addr,
	input       [7:0] sd_buff_dout,
	output      [7:0] sd_buff_din,
	input             sd_buff_wr,
	// DDR3, the disk image (rtl/d88_media.sv)
	input             ddr_busy,
	output      [7:0] ddr_burstcnt,
	output     [28:0] ddr_addr,
	input      [63:0] ddr_dout,
	input             ddr_dout_ready,
	output            ddr_rd,
	output     [63:0] ddr_din,
	output      [7:0] ddr_be,
	output            ddr_we,
	output            disk_ready,
	output            disk_too_big,
	output            disk_motor,
	output            disk_unit,       // DISK.ROM was loaded: the unit is connected

	// debug / simulation
	output     [15:0] cpu_addr,
	output            cpu_ce,
	output            cpu_m1_n,
	output            dbg_io_wr,
	output            dbg_io_rd,
	output      [7:0] dbg_io_port,
	output      [7:0] dbg_io_data
);

// the mkII and the PC-6601 (a mkII with a built-in floppy drive, rtl/fdc66.sv); the mkIISR runs the mkII's
// BASICs too (with C8h b0 = 1) and adds its own mode (sr_mode)
wire mk2 = model != 2'd0;
wire p66 = model == 2'd2;
wire sr  = model == 2'd3;
wire sr_mode;

//----------------------------------------------------------------------------
// Clock enables
//----------------------------------------------------------------------------

reg [1:0] ph = 0;
always @(posedge clk_sys) ph <= ph + 1'd1;
// the mkIISR's 640-dot screens: dots at 14.32 MHz (the others' dots twice each)
assign ce_pix = sr ? ph[0] : ph == 2'd3;

// 3.9936 MHz from 28.636364 MHz: 39936 / 286364; TURBO times that during tape turbo. 7.17x would be an enable
// on every clock; above 3x some enables fall on consecutive clocks, which the memories allow (a Z80 memory or
// I/O access spans at least three T-states, and BRAM data follows the address one clock later).
// The mkIISR's Z80 runs at 3.58 MHz (PC6001VX CPUM_CLOCK64).
localparam [18:0] CPU_TURBO_STEP = 19'(39936 * TURBO);
localparam [18:0] SR_TURBO_STEP = 19'(35795 * TURBO);
wire [18:0] cpu_step = tape_turbo_on ? (sr ? SR_TURBO_STEP : CPU_TURBO_STEP) : sr ? 19'd35795 : 19'd39936;
reg  [18:0] cpu_acc = 0;
reg         ce_cpu = 0;
// 20 bits: at 7x the sum reaches 286363 + 279552, past 19 bits
wire [19:0] cpu_sum = {1'b0, cpu_acc} + {1'b0, cpu_step};
always @(posedge clk_sys) begin
	if (cpu_sum >= 20'd286364) begin
		cpu_acc <= 19'(cpu_sum - 20'd286364);
		ce_cpu <= 1'b1;
	end
	else begin
		cpu_acc <= cpu_sum[18:0];
		ce_cpu <= 1'b0;
	end
end
// the PSG keeps its 1.9968 MHz in turbo, the mkIISR's YM2203 its 4 MHz
reg [18:0] psg_acc = 0;
reg        ce_psg = 0;
always @(posedge clk_sys) begin
	if (psg_acc + 19'd19968 >= 19'd286364) begin
		psg_acc <= psg_acc + 19'd19968 - 19'd286364;
		ce_psg <= 1'b1;
	end
	else begin
		psg_acc <= psg_acc + 19'd19968;
		ce_psg <= 1'b0;
	end
end
reg [18:0] opn_acc = 0;
reg        ce_opn = 0;
always @(posedge clk_sys) begin
	if (opn_acc + 19'd40000 >= 19'd286364) begin
		opn_acc <= opn_acc + 19'd40000 - 19'd286364;
		ce_opn <= 1'b1;
	end
	else begin
		opn_acc <= opn_acc + 19'd40000;
		ce_opn <= 1'b0;
	end
end
assign cpu_ce = ce_cpu;

//----------------------------------------------------------------------------
// CPU
//----------------------------------------------------------------------------

wire        mreq_n, iorq_n, rd_n, wr_n, m1_n, rfsh_n;
wire [15:0] A;
wire  [7:0] cpu_dout;
reg   [7:0] cpu_din;
wire        int_n;
wire        busrq;
// The display's bus steal runs on the video clock, so in turbo a 3.3 ms tape byte could fall all in the active
// picture with the Z80 at a third of its speed, where at 1x a byte's 10 ms averages over the frame: BASIC then
// misses the first byte after the name. In turbo the Z80 is not stopped (the VDG has its own RAM port).
reg         wait_n;

wire auto_reset;   // rtl/tape_auto.sv: a tape mounted with Tape auto-start on
wire reset_dl = reset | auto_reset | (ioctl_download & (ioctl_index[5:0] == 6'd0 | ioctl_index[5:0] == 6'd2));
wire rs_busy;
wire cpu_reset = reset_dl | rs_busy;
wire [2:0] rs_sets;   // and while the ROM store copies the model's ROMs

`ifdef VERILATOR
T80s cpu
`else
T80s #(.Mode(0), .T2Write(1), .IOWait(1)) cpu
`endif
(
	.RESET_n(~cpu_reset),
	.CLK(clk_sys),
	.CEN(ce_cpu),
	.OUT0(1'b0),
	.WAIT_n(wait_n),
	.INT_n(int_n),
	.NMI_n(1'b1),
	.BUSRQ_n(~(busrq & ~tape_turbo_on)),
	.M1_n(m1_n),
	.MREQ_n(mreq_n),
	.IORQ_n(iorq_n),
	.RD_n(rd_n),
	.WR_n(wr_n),
	.RFSH_n(rfsh_n),
	.HALT_n(),
	.BUSAK_n(),
	.A(A),
	.DI(cpu_din),
	.DO(cpu_dout)
);

assign cpu_addr = A;
assign cpu_m1_n = m1_n;

wire io_cyc = ~iorq_n & m1_n;
wire inta   = ~iorq_n & ~m1_n;

// one clk strobes for I/O (the first clk of the access)
reg io_rd_d, io_wr_d, inta_d;
always @(posedge clk_sys) begin
	io_rd_d <= io_cyc & ~rd_n;
	io_wr_d <= io_cyc & ~wr_n;
	inta_d  <= inta;
end
wire io_rd  = io_cyc & ~rd_n & ~io_rd_d;
wire io_wr  = io_cyc & ~wr_n & ~io_wr_d;
wire inta_s = inta & ~inta_d;

assign dbg_io_wr   = io_wr;
assign dbg_io_rd   = io_rd;
assign dbg_io_port = A[7:0];
assign dbg_io_data = io_wr ? cpu_dout : io_dout;


//----------------------------------------------------------------------------
// Memory
//----------------------------------------------------------------------------

wire       rom_wr = ioctl_download && ioctl_wr && ioctl_index == 8'h00;   // boot0.rom (boot1.rom, the mkII's, is index 40h)

// BASIC ROM
reg  [7:0] basic_rom[0:16383];
reg  [7:0] basic_q;
always @(posedge clk_sys) begin
	if (rom_wr && ioctl_addr[24:14] == 0) basic_rom[ioctl_addr[13:0]] <= ioctl_dout;
	basic_q <= basic_rom[A[13:0]];
end

// CGROM: the CPU at 6000h and the VDG
wire [13:0] cg_addr;
reg   [7:0] cg_rom[0:4095];
reg   [7:0] cg_q, cg_cpu_q;
always @(posedge clk_sys) begin
	if (rom_wr && ioctl_addr[24:12] == 13'h004) cg_rom[ioctl_addr[11:0]] <= ioctl_dout;
	cg_q <= cg_rom[cg_addr[11:0]];
end
always @(posedge clk_sys) cg_cpu_q <= cg_rom[A[11:0]];

// The mkII's or the PC-6601's ROMs (boot1.rom / boot2.rom, in MAME's order): BASIC 00000h (32 KB), voice
// 08000h (16 KB), CGROM60 0C000h and CGROM60m / CGROM66 0E000h (8 KB each), kanji 10000h (32 KB); the
// mkIISR's (boot3.rom): SYSTEMROM1 00000h (64 KB), SYSTEMROM2 10000h (64 KB), CGROM68 20000h (16 KB). Copied
// in from DDR3 at each reset (rtl/rom_store.sv). Port A the copy and the CPU, port B the VDG's font: CGROM60 /
// CGROM68 0000h for cg_addr 0000h, CGROM60m / CGROM68 2000h for 2000h.
wire        rs_we;
wire [17:0] rs_a;
wire  [7:0] rs_d;
wire  [7:0] rom62_q, cg62_q;
reg  [17:0] rom62_cpu;
wire [17:0] rom62_a = rs_we ? rs_a : rom62_cpu;
dpram_tdp #(.WORDS(147456), .AW(18)) rom62
(
	.clk(clk_sys),
	.addr_a(rom62_a), .we_a(rs_we), .d_a(rs_d), .q_a(rom62_q),
	.addr_b(sr ? {4'b1000, cg_addr} : {4'b0011, cg_addr}), .we_b(1'b0), .d_b(8'h00), .q_b(cg62_q)
);

// RAM 64 KB: port A the CPU, port B the VDG. The PC-6001 has 32 KB at 8000h (16 KB at C000h). The mkIISR's
// map moves its 16 KB blocks, and its bitmap access writes a nibble (from ram_q, the same address).
wire [15:0] vaddr;
wire  [7:0] ram_q, vram_q;
wire        ram_sel = A[15] & ~(ram16k & ~A[14]);
wire [15:0] ram_a;
wire  [7:0] ram_d;
wire        ram_wsel;
wire        ram_we  = ~mreq_n & ~wr_n & ram_wsel & ce_cpu;
dpram_tdp #(.WORDS(65536), .AW(16)) ram
(
	.clk(clk_sys),
	.addr_a(ram_a), .we_a(ram_we), .d_a(ram_d), .q_a(ram_q),
	.addr_b(vaddr), .we_b(1'b0), .d_b(8'h00), .q_b(vram_q)
);

// Cartridge ROM at 4000h, loaded through ioctl index 2 (the mkII: EXTROM, at whichever block F0/F1 map it)
wire       cart_wr = ioctl_download && ioctl_wr && ioctl_index[5:0] == 6'd2;
reg  [7:0] cart_rom[0:16383];
reg  [7:0] cart_q;
reg [14:0] cart_len = 0;
reg        cart_big = 0, cart_dl = 0;
wire [13:0] cart_a;
always @(posedge clk_sys) begin
	if (cart_wr && ioctl_addr[24:14] == 0) cart_rom[ioctl_addr[13:0]] <= ioctl_dout;
	cart_q <= cart_rom[cart_a];
end
always @(posedge clk_sys) begin
	cart_dl <= ioctl_download && ioctl_index[5:0] == 6'd2;
	if (ioctl_download && ioctl_index[5:0] == 6'd2) begin
		if (!cart_dl) begin cart_len <= 0; cart_big <= 0; end
		if (cart_wr && ioctl_addr[24:14] == 0) cart_len <= ioctl_addr[14:0] + 1'd1;
		if (cart_wr && ioctl_addr[24:14] != 0) cart_big <= 1'b1;
	end
	else if (cart_eject) cart_len <= 0;
end
wire cart_in = cart_len != 0;
assign cart_too_big = cart_big;

//----------------------------------------------------------------------------
// The mkII's memory map (PC6001VX memory.cpp MEM62)
//----------------------------------------------------------------------------
// F0: what 0000h-3FFFh (low nibble) and 4000h-7FFFh (high) read; F1: 8000h-BFFFh and C000h-FFFFh. Each value
// picks the source of the two 8 KB blocks. F2: what each 16 KB writes to, 2 bits each (1 or 3: the internal
// RAM). F8: the CG ROM in place of one 8 KB block while port C bit 2 (cg_sel) allows it: b6 on, b5-3 address
// bits to ignore, b2-0 A15-A13. C1 b1 picks the font there: 1 CGROM60, 0 CGROM60m. C2: b0 1 the kanji ROM,
// 0 the voice ROM, where a block reads "kanji"; b1 its left / right 16 KB. C3: which C2 bits take writes.

reg [7:0] rf0, rf1, rf2, f3, f4, f5, f6, f8;
wire      cg_sel;
reg [7:0] c0, c1;
reg       kj_rom, kj_lr;
reg [1:0] c2acc;

localparam S_NONE = 3'd0, S_MAIN = 3'd1, S_KNJ = 3'd2, S_EXT0 = 3'd3, S_EXT1 = 3'd4, S_RAM = 3'd5;
wire [3:0] nib = A[15] ? (A[14] ? rf1[7:4] : rf1[3:0]) : (A[14] ? rf0[7:4] : rf0[3:0]);
wire       hb  = A[13];   // the second 8 KB of the 16 KB
reg  [2:0] src;
always @(*) begin
	case (nib)
	4'h1: src = S_MAIN;
	4'h2: src = S_KNJ;
	4'h3: src = S_EXT1;
	4'h4: src = S_EXT0;
	4'h5: src = hb ? S_MAIN : S_KNJ;
	4'h6: src = hb ? S_KNJ  : S_MAIN;
	4'h7: src = hb ? S_EXT1 : S_EXT0;
	4'h8: src = hb ? S_EXT0 : S_EXT1;
	4'h9: src = hb ? S_MAIN : S_EXT1;
	4'ha: src = hb ? S_EXT1 : S_MAIN;
	4'hb: src = hb ? S_KNJ  : S_EXT0;
	4'hc: src = hb ? S_EXT0 : S_KNJ;
	4'hd: src = S_RAM;
	default: src = S_NONE;   // 0, F; E is RAM in a cartridge
	endcase
end
wire src_ram = src == S_RAM;

wire [1:0] wsel = rf2[{A[15:14], 1'b0} +: 2];
wire       wr_int = wsel[0];
// the mkIISR: the CG ROM window is 16 KB (PC6001VX MEM64::SetCGrom)
wire [7:0] f8x = sr ? f8 | 8'h09 : f8;
wire       cg_on = cg_sel && f8x[6] && ((A[15:13] | f8x[5:3]) == (f8x[2:0] | f8x[5:3]));

//----------------------------------------------------------------------------
// The mkIISR's map (PC6001VX MEM64, VDG64)
//----------------------------------------------------------------------------
// In the SR mode (C8h b0 = 0, from reset) memory is mapped in 8 KB blocks, ports 60h-67h for reads and
// 68h-6Fh for writes: b7-4 the source, b3-1 its 8 KB block. 0 the RAM (in 16 KB: b3-2 and A13), Bh / Ch the
// cartridge's two halves, Dh CGROM68 (b1), Eh SYSTEMROM2, Fh SYSTEMROM1; others read FFh. With C8h b3 = 0 a
// block mapped as 00h reaches the bitmap a dot at a time instead: A9-0 is x, ports CEh / CFh y, the data its
// low nibble (rtl/pc6001_sr.svh); C8h b4 picks the upper 32 KB.
// With C8h b0 = 1 the older BASICs run with the mkII's map above: SYSTEMROM1 0000h-7FFFh is their BASIC,
// SYSTEMROM2 holds the menu (0000h), voice (4000h) and kanji (8000h) ROMs.

`include "pc6001_sr.svh"

reg  [7:0] srm[0:15];
reg  [7:0] c8;
reg  [3:0] c9;
reg  [9:0] sr_rollx;
reg  [7:0] sr_rolly;
reg  [8:0] sr_y;
reg  [3:0] sr_pal[0:3];       // colours 12-15: ports 43h-40h, 15 - the value written
reg  [3:0] sr_palw;           // ... written since reset
reg  [7:0] sr_ien;            // interrupts (below): 1 enabled
reg  [7:0] sr_vout;
reg  [7:0] sr_vec[0:7];
wire       hsync_s, vsync_s;  // port A2h's b6, b7
assign sr_mode = sr & ~c8[0];
wire        sr_bitmap = sr_mode & ~c8[3];
wire  [7:0] srr = srm[{1'b0, A[15:13]}];
wire  [7:0] srw = srm[{1'b1, A[15:13]}];
wire  [7:0] srv = rd_n ? srw : srr;           // a write keeps RD_n high from its start
wire        sr_bm = sr_bitmap && srv == 8'h00;
wire [15:0] sr_gva = {c8[4], sr_gv({1'b0, A[9:0]}, sr_y)};

assign ram_a    = !sr_mode ? A : sr_bm ? sr_gva : {srv[3:2], A[13:0]};
assign ram_d    = !sr_bm ? cpu_dout : A[0] ? {cpu_dout[3:0], ram_q[3:0]} : {ram_q[7:4], cpu_dout[3:0]};
assign ram_wsel = sr_mode ? sr_bm || srw[7:4] == 4'h0 : mk2 ? wr_int : ram_sel;

always @(*) begin
	if (sr_mode) case (srr[7:4])
		4'hf: rom62_cpu = {2'b00, srr[3:1], A[12:0]};
		4'he: rom62_cpu = {2'b01, srr[3:1], A[12:0]};
		default: rom62_cpu = {4'b1000, srr[1], A[12:0]};
	endcase
	else if (cg_on) rom62_cpu = sr ? {4'b1000, ~c1[1], A[12:0]} : {4'b0011, ~c1[1], A[12:0]};
	else if (src == S_KNJ) begin
		if (sr) rom62_cpu = kj_rom ? {3'b011, kj_lr, A[13:0]} : {3'b010, A[15:14] != 2'd0, A[13:0]};
		else rom62_cpu = kj_rom ? {3'b010, kj_lr, A[13:0]} : {4'b0010, A[13:0]};
	end
	else rom62_cpu = {3'b000, A[14:0]};
end
assign cart_a = sr_mode ? {srr[7:4] == 4'hb, A[12:0]} : mk2 ? {src == S_EXT1, A[12:0]} : A[13:0];

reg [7:0] mem_dout;
always @(*) begin
	if (sr_mode) begin
		if (sr_bm) mem_dout = {4'h0, A[0] ? ram_q[7:4] : ram_q[3:0]};
		else case (srr[7:4])
			4'h0: mem_dout = ram_q;
			4'hb, 4'hc: mem_dout = {1'b0, cart_a} < cart_len ? cart_q : 8'hff;
			4'hd, 4'he, 4'hf: mem_dout = rom62_q;
			default: mem_dout = 8'hff;
		endcase
	end
	else if (mk2) begin
		if (cg_on) mem_dout = rom62_q;
		else case (src)
			S_MAIN, S_KNJ: mem_dout = rom62_q;
			S_EXT0, S_EXT1: mem_dout = {1'b0, cart_a} < cart_len ? cart_q : 8'hff;
			S_RAM: mem_dout = ram_q;
			default: mem_dout = 8'hff;
		endcase
	end
	else if (!A[15]) begin
		if (!A[14]) mem_dout = basic_q;
		else if (A[13] && cg_sel && (!A[12] || !cart_in)) mem_dout = cg_cpu_q;
		else mem_dout = {1'b0, A[13:0]} < cart_len ? cart_q : 8'hff;
	end
	else mem_dout = ram_sel ? ram_q : 8'hff;
end

// Waits: one Z80 state on each M1, each memory access below 8000h and each PSG access. The mkII: port F3 b7 on
// M1, b6 on ROM, b5 on RAM (PC6001VX MEM62::SetWait). The mkIISR with C8h b1 = 1: one on each access while the
// display reads (the VDG's bus_slow) instead of the Z80 stopping.
reg waited;
wire is_ram = sr_mode ? srv[7:4] == 4'h0 : src_ram;
wire bus_slow;
wire mem_wait = mk2 ? (~m1_n & f3[7]) | (~wr_n | is_ram ? f3[5] : f3[6]) | bus_slow : ~m1_n | ~A[15];
wire want_wait = (~mreq_n & rfsh_n & mem_wait) | (io_cyc & A[7:4] == 4'hA);
always @(posedge clk_sys) begin
	if (cpu_reset) begin
		waited <= 0;
	end
	else if (ce_cpu) begin
		if (want_wait && !waited) waited <= 1'b1;
		else if (!want_wait) waited <= 1'b0;
	end
end
always @(*) wait_n = ~(want_wait & ~waited);

//----------------------------------------------------------------------------
// I/O
//----------------------------------------------------------------------------

wire       sel_ppi = A[7:4] == 4'h9;
wire       sel_psg = A[7:4] == 4'hA;
// the PC-6601: B1h-B3h are the floppy's; the mkIISR: B0h only, B8h-BFh its interrupt vectors
wire       sel_b0  = sr ? A[7:0] == 8'hb0 : A[7:4] == 4'hB && !(p66 && A[3:0] != 4'h0);
wire       sel_66  = p66 && (A[7:4] == 4'hD || A[7:0] == 8'hb1 || A[7:0] == 8'hb2 || A[7:0] == 8'hb3);
wire       sel_c   = mk2 && A[7:2] == 6'b1100_00;   // C0-C3
wire       sel_f   = mk2 && A[7:4] == 4'hF;         // F0-F8
wire       sel_e   = mk2 && A[7:2] == 6'b1110_00;   // E0-E3: the uPD7752
wire       sel_40  = sr && A[7:2] == 6'b0100_00;    // the mkIISR: 40-43 the palette
wire       sel_6x  = sr && A[7:4] == 4'h6;          // 60-6F the map
wire       sel_bv  = sr && A[7:3] == 5'b10111;      // B8-BF interrupt vectors
wire       sel_c8  = sr && A[7:3] == 5'b11001;      // C8-CF the SR screens

always @(posedge clk_sys) begin
	if (cpu_reset) begin
		rf0 <= 8'h71; rf1 <= 8'hdd; rf2 <= 8'h50;    // BASIC, the cartridge, RAM above 8000h (PC6001VX INIT_RF)
		f3 <= 8'h00; f4 <= 8'h00; f5 <= 8'h00; f6 <= sr ? 8'h7f : 8'h03;
		f8 <= 8'h43;                                // the CG ROM at 6000h
		c0 <= 8'h00; c1 <= 8'h06;
		kj_rom <= 1'b1; kj_lr <= 1'b1; c2acc <= 2'b11;
	end
	else if (io_wr && sel_f) case (A[3:0])
		4'h0: rf0 <= cpu_dout;
		4'h1: rf1 <= cpu_dout;
		4'h2: rf2 <= cpu_dout;
		4'h3: f3 <= cpu_dout;
		4'h4: f4 <= cpu_dout;
		4'h5: f5 <= cpu_dout;
		4'h6: f6 <= cpu_dout;
		4'h8: f8 <= cpu_dout;
		default: ;
	endcase
	else if (io_wr && sel_c) case (A[1:0])
		2'd0: c0 <= cpu_dout;
		2'd1: c1 <= cpu_dout;
		2'd2: begin
			if (c2acc[1]) kj_lr <= cpu_dout[1];
			if (c2acc[0]) kj_rom <= cpu_dout[0];
		end
		default: c2acc <= cpu_dout[1:0];
	endcase
end

// the mkIISR's registers (PC6001VX MEM64::Reset, VDG64, mc6847.cpp PCZ80_12): C8h b0 0 the SR mode, b1 1 waits
// instead of the display stopping the Z80, b2 1 text in 20 lines (else 25), b3 0 the bitmap access, b4 its
// upper 32 KB; C9h the text page (4 KB units; b3 the bitmap's 32 KB); CAh-CBh, CCh the bitmap's scroll x, y;
// CEh-CFh the bitmap access's y.
function automatic [7:0] srm_init(input [3:0] i);   // SYSTEMROM1 4000h-BFFFh at 0000h, RAM above; RAM for writes
	srm_init = i[3] ? {4'h0, i[2:0], 1'b0} : i[2] ? {5'b00001, i[1:0], 1'b0} : {5'b11111, i[1:0], 1'b0};
endfunction
integer k;
always @(posedge clk_sys) begin
	if (cpu_reset) begin
		for (k = 0; k < 16; k = k + 1) srm[k] <= srm_init(4'(k));
		for (k = 0; k < 4; k = k + 1) sr_pal[k] <= 4'(12 + k);
		sr_palw <= 0;
		c8 <= 8'h0c; c9 <= 0; sr_rollx <= 0; sr_rolly <= 0; sr_y <= 0;
	end
	else if (io_wr) begin
		if (sel_6x) srm[A[3:0]] <= cpu_dout;
		if (sel_40) begin
			sr_pal[2'd3 - A[1:0]] <= 4'hf - cpu_dout[3:0];
			sr_palw[2'd3 - A[1:0]] <= 1'b1;
		end
		if (sel_c8) case (A[2:0])
			3'd0: c8 <= cpu_dout;
			3'd1: c9 <= cpu_dout[3:0];
			3'd2: sr_rollx[7:0] <= cpu_dout;
			3'd3: sr_rollx[9:8] <= cpu_dout[1:0];
			3'd4: sr_rolly <= cpu_dout;
			3'd6: sr_y[7:0] <= cpu_dout;
			3'd7: sr_y[8] <= cpu_dout[0];
			default: ;
		endcase
	end
end

reg  [7:0] sys_latch;
always @(posedge clk_sys) begin
	if (cpu_reset) sys_latch <= 8'h00;
	else if (io_wr && sel_b0) sys_latch <= cpu_dout;
end
wire        timer_off = sys_latch[0];
reg  [15:0] vram_base;
always @(*) begin
	case (sys_latch[2:1])
	2'd0: vram_base = 16'hC000;
	2'd1: vram_base = 16'hE000;
	2'd2: vram_base = 16'h8000;
	default: vram_base = 16'hA000;
	endcase
end
assign tape_motor = sys_latch[3];

// 8255 and the sub CPU
wire [7:0] ppi_dout;
wire       sub_irq;
wire       cmt_open;
wire [7:0] sub_vector;
wire       crt_on;
reg        sub_ack;

pc6001_sub sub
(
	.clk(clk_sys),
	.reset(cpu_reset),
	.ce_cpu(ce_cpu),
	.mk2(mk2),
	.addr(A[1:0]),
	.rd(io_rd & sel_ppi),
	.rd_act(io_cyc & ~rd_n),
	.wr(io_wr & sel_ppi),
	.din(cpu_dout),
	.dout(ppi_dout),
	.irq(sub_irq),
	.int_ack(sub_ack),
	.int_vector(sub_vector),
	.crt_on(crt_on),
	.cg_sel(cg_sel),
	.ps2_key(ps2_key),
	.kbd_us(kbd_us),
	.inj_strobe(inj_strobe),
	.inj_code(inj_code),
	.inj_ready(inj_ready),
	.tape_strobe(tape_strobe),
	.tape_byte(tape_q),
	.tape_ready(tape_ready),
	.cmt_open(cmt_open)
);

// Tape
wire        tape_wr = ioctl_download && ioctl_wr && ioctl_index[5:0] == 6'd1;
reg   [7:0] tape_mem[0:65535];
reg   [7:0] tape_q;
reg  [16:0] tape_len = 0, tape_pos = 0;
reg  [15:0] tape_tick = 0;
reg         tape_strobe;
wire        tape_ready;
reg         tape_dl;
reg         tape_big = 0;
assign tape_loaded   = tape_len != 0;
assign tape_too_big  = tape_big;
// Tape speed is taken when the motor starts (tape standard rule 1), not in the middle of a load
reg tape_turbo_l = 0;
always @(posedge clk_sys) if (!tape_motor) tape_turbo_l <= tape_turbo;
assign tape_turbo_on = tape_turbo_l && tape_motor && tape_loaded;
assign tape_position = tape_pos;
assign tape_length   = tape_len;

// .p6t (P6T2): the byte image, a footer starting "P6", and the image size (4 bytes, little-endian) at the end.
// After a download rtl/tape_auto.sv reads the footer; then only the image plays. The footer's gaps (silence,
// carrier) are not played. A .p6/.cas has no footer and plays whole.
// A machine-code block's sync (six or more 9Ch) after the tape's start waits GAP byte times first, as the carrier
// before a block on a real tape: a loader that reads a header, waits and closes the cassette (ROM 1B06), then
// opens it again for the data loses the bytes that come in the wait, and with no gap those are the sync's first
// (Space Mouse 2's loader: two of six 9Ch gone, the data never found)
wire        ta_busy, ta_len_set, ta_app;
wire  [7:0] ta_app_d;
wire [15:0] ta_addr, ta_len;
// When the motor stops with only 00h/FFh left (a BASIC tape's padding), the tape is at its end: a loader started
// by RUN then waits for the next tape instead of taking the padding as data (Slender Island: CLOAD part 1, swap,
// RUN reads part 2 raw, with no sync)
localparam   GAP = 7'd50;
reg         trim = 0, trim_ph, tape_motor_l;
reg  [16:0] trim_a;
reg         look = 0, need_look = 0, q_pos;
reg   [2:0] look_n;
reg   [6:0] gap = 0;
wire [15:0] tape_raddr = ta_busy ? ta_addr : trim | look ? trim_a[15:0] : tape_pos[15:0];
always @(posedge clk_sys) begin
	if (tape_wr) tape_mem[ioctl_addr[15:0]] <= ioctl_dout;
	else if (ta_app) tape_mem[tape_len[15:0]] <= ta_app_d;   // the game list's byte after the image
	tape_q <= tape_mem[tape_raddr];
	q_pos <= tape_raddr == tape_pos[15:0];   // tape_q is the byte at tape_pos
end

always @(posedge clk_sys) begin
	tape_strobe <= 1'b0;
	tape_dl <= ioctl_download && ioctl_index[5:0] == 6'd1;
	tape_motor_l <= tape_motor;
	if (ioctl_download && ioctl_index[5:0] == 6'd1) begin
		trim <= 0; look <= 0; need_look <= 0; gap <= 0;
		if (!tape_dl) begin tape_len <= 0; tape_big <= 0; end
		if (tape_wr && ioctl_addr[24:16] == 0) tape_len <= ioctl_addr[16:0] + 1'd1;
		if (tape_wr && ioctl_addr[24:16] != 0) tape_big <= 1'b1;
		tape_pos <= 0;
		tape_tick <= 0;
	end
	else if (ta_len_set) tape_len <= {1'b0, ta_len};
	else if (ta_app) tape_len <= tape_len + 1'd1;
	else if (ta_busy) ;
	else if (tape_rewind) begin tape_pos <= 0; trim <= 0; look <= 0; need_look <= 0; gap <= 0; end
	else if (trim) begin
		// a byte read at trim_a reaches tape_q a clock later
		trim_ph <= ~trim_ph;
		if (tape_motor || (trim_ph && tape_q != 8'h00 && tape_q != 8'hFF)) trim <= 0;
		else if (trim_ph) begin
			if (trim_a + 1'd1 >= tape_len) begin tape_pos <= tape_len; trim <= 0; end
			trim_a <= trim_a + 1'd1;
		end
	end
	else if (tape_motor_l && !tape_motor && tape_pos < tape_len) begin
		trim <= 1'b1; trim_ph <= 0; trim_a <= tape_pos; look <= 0;
	end
	else if (look) begin
		// the byte before tape_pos is not 9Ch, the six from tape_pos are: a sync starts
		trim_ph <= ~trim_ph;
		if (trim_ph) begin
			if (look_n == 0 ? tape_q == 8'h9C : tape_q != 8'h9C) look <= 0;
			else if (look_n == 3'd6) begin look <= 0; gap <= GAP; end
			look_n <= look_n + 1'd1;
			trim_a <= trim_a + 1'd1;
		end
	end
	else if (need_look) begin
		need_look <= 0;
		if (tape_pos != 0 && tape_pos + 17'd6 <= tape_len) begin
			look <= 1'b1; trim_ph <= 0; look_n <= 0; trim_a <= tape_pos - 1'd1;
		end
	end
	else if (ce_cpu && tape_motor) begin
		// 39936 Z80 states per byte (100 bytes/s; TURBO x 100 in turbo, where the Z80 runs TURBO x faster)
		if (tape_tick >= 16'd39935) begin
			tape_tick <= 0;
			if (gap != 0) gap <= gap - 1'd1;
			else if (tape_pos < tape_len && tape_ready && q_pos) begin
				tape_strobe <= 1'b1;
				tape_pos <= tape_pos + 1'd1;
				need_look <= 1'b1;
			end
		end
		else tape_tick <= tape_tick + 1'd1;
	end
end

// The wrong-model hint (rtl/tape_auto.sv): a write to a port the running model lacks. On the PC-6001 the mkII's
// map (F0-F3), C1-C3 and the voice (E0-E3; C0 is the PC-6001's printer). On the mkII and PC-6601 the mkIISR's
// palette (40-43), map (60-6F), and C8h turning the SR screens on (b0 = 0): the mkII's N60m-BASIC writes FFh
// there itself (Legends of Star Arthur 3's BLOAD, PC 0DE1h).
wire need_mk2 = io_wr && !mk2 && (A[7:2] == 6'b1111_00 || A[7:2] == 6'b1110_00 || A[7:2] == 6'b1100_00 && A[1:0] != 0);
wire need_sr  = io_wr && mk2 && !sr && (A[7:0] == 8'hC8 && !cpu_dout[0] || A[7:2] == 6'b0100_00 || A[7:4] == 4'h6);
// synthesis translate_off
reg [15:0] cpu_pc_dbg;   // the last opcode fetch
always @(posedge clk_sys) if (!m1_n && !mreq_n) cpu_pc_dbg <= A;
always @(posedge clk_sys) if (need_mk2 || need_sr)
	$display("[pc6001] a later model's port: OUT %02Xh, %02Xh at PC %04Xh", A[7:0], cpu_dout, cpu_pc_dbg);
// synthesis translate_on

// What to type for the tape: shown while the deck is stopped, typed after a reset with Tape auto-start on
// (tape standard rules 25-28)
wire       inj_strobe, inj_ready;
wire [7:0] inj_code;
tape_auto tape_auto
(
	.clk(clk_sys),
	.reset(cpu_reset),
	.model(model),
	.ram16k(ram16k),
	.drives(disk_unit | p66),
	.enable(tape_autostart),
	.models({rs_sets, 1'b1}),
	.model_set(model_set),
	.model_req(model_req),
	.dl(ioctl_download && ioctl_index[5:0] == 6'd1),
	.wr(tape_wr && ioctl_addr[24:16] == 0),
	.addr(ioctl_addr[16:0]),
	.data(ioctl_dout),
	.len(tape_len),
	.rd_busy(ta_busy),
	.rd_addr(ta_addr),
	.rd_data(tape_q),
	.img_len_set(ta_len_set),
	.img_len(ta_len),
	.app_we(ta_app),
	.app_data(ta_app_d),
	.pos(tape_pos),
	.motor(tape_motor),
	.cmt_open(cmt_open),
	.vblank(VBlank),
	.ps2_key(ps2_key),
	.inj_ready(inj_ready),
	.inj_strobe(inj_strobe),
	.inj_code(inj_code),
	.auto_reset(auto_reset),
	.hint_show(hint_show),
	.hint_two(hint_two),
	.hint_text(hint_text),
	.hint_force(hint_force),
	.need_mk2(need_mk2),
	.need_sr(need_sr)
);

// PSG: port A reads the joystick picked by port B bit 6 (0: joystick 2), active low:
// b0 up b1 down b2 left b3 right b4 trigger 1 b5 trigger 2 (PC6001VX psgfm.cpp, joystick.cpp). The touch panel
// takes joystick 2's place when the OSD puts it there.
wire [7:0] psg_dout;
wire [9:0] psg_sound;
wire [7:0] psg_iob, ay_iob, opn_iob;
assign     psg_iob = sr ? opn_iob : ay_iob;
wire [5:0] joy_sel = psg_iob[6] ? joy0 : joy1;
wire [7:0] touch_pa;
wire [7:0] joy_bits = touch_en && !psg_iob[6] ? touch_pa :
                      ~{2'b00, joy_sel[5], joy_sel[4], joy_sel[0], joy_sel[1], joy_sel[2], joy_sel[3]};

touch_panel touch_panel
(
	.clk(clk_sys),
	.reset(cpu_reset),
	.pb(psg_iob),
	.x(touch_x),
	.y(touch_y),
	.pen(touch_pen),
	.pa(touch_pa)
);

jt49_bus psg
(
	.rst_n(~cpu_reset),
	.clk(clk_sys),
	.clk_en(ce_psg),
	.bdir(io_cyc & ~wr_n & sel_psg & ~A[1]),
	.bc1(io_cyc & sel_psg & (A[1:0] == 2'd0 ? ~wr_n : A[1:0] == 2'd2 ? ~rd_n : 1'b0)),
	.din(cpu_dout),
	.sel(1'b1),
	.dout(psg_dout),
	.sound(psg_sound),
	.A(), .B(), .C(),
	.sample(),
	.IOA_in(joy_bits),
	.IOA_out(),
	.IOA_oe(),
	.IOB_in(8'hff),
	.IOB_out(ay_iob),
	.IOB_oe()
);

// the mkIISR's YM2203 (jt03) in its place: A0h the register, A1h data, A2h reads the register (the SSG's),
// A3h the status
wire        [7:0] opn_dout;
wire        [9:0] opn_psg;
wire signed [15:0] opn_fm;
jt03 opn
(
	.rst(cpu_reset | ~sr),
	.clk(clk_sys),
	.cen(ce_opn),
	.din(cpu_dout),
	.addr(A[0] ^ A[1]),
	.cs_n(1'b0),
	.wr_n(~(io_wr & sel_psg & ~A[1])),
	.dout(opn_dout),
	.irq_n(),
	.IOA_in(joy_bits),
	.IOB_in(8'hff),
	.IOA_out(),
	.IOB_out(opn_iob),
	.IOA_oe(),
	.IOB_oe(),
	.psg_A(), .psg_B(), .psg_C(),
	.fm_snd(opn_fm),
	.psg_snd(opn_psg),
	.snd(),
	.snd_sample(),
	.debug_view()
);

// the mkII's uPD7752 (rtl/upd7752.sv), ports E0h-E3h
wire        [7:0] voice_dout;
wire signed [13:0] voice;
upd7752 vsp
(
	.clk(clk_sys),
	.reset(cpu_reset | ~mk2),
	.addr(A[1:0]),
	.rd(io_rd & sel_e),
	.wr(io_wr & sel_e),
	.din(cpu_dout),
	.dout(voice_dout),
	.sample(voice)
);

// Signed output from -16384, clamped. The PSG (jt49) or the SR's SSG: 0..1023 x 64, a channel at full
// volume (0..255) gives 16320 peak to peak, all three just under +32767. The SR's FM (jt03) x 2, in jt12's
// SSG/FM balance (fm + psg x 32) doubled; the mkII's / SR's voice x 8, about one PSG channel's level.
wire signed [19:0] snd_psg = {4'd0, sr ? opn_psg : psg_sound, 6'd0};
wire signed [19:0] snd_fm  = sr ? {{3{opn_fm[15]}}, opn_fm, 1'b0} : 20'sd0;
wire signed [19:0] snd_vox = sr | mk2 ? {{3{voice[13]}}, voice, 3'd0} : 20'sd0;
wire signed [19:0] snd_mix = snd_psg + snd_fm + snd_vox - 20'sd16384;
assign audio = snd_mix > 20'sd32767 ? 16'h7fff : snd_mix < -20'sd32768 ? 16'h8000 : snd_mix[15:0];

//----------------------------------------------------------------------------
// PC-6031 disk unit at D0h-D3h
//----------------------------------------------------------------------------

wire       sel_fdd = A[7:2] == 6'b1101_00 && !p66;
wire [7:0] fdd_dout;
// DISK.ROM is 5000h-57FFh of the ROM download (after BASICROM.60 and CGROM60.60); a 20 KB boot.rom has no unit
reg        disk_rom_ok = 0;
always @(posedge clk_sys) begin
	if (rom_wr && ioctl_addr == 0) disk_rom_ok <= 0;
	else if (rom_wr && ioctl_addr[24:0] == 25'h57ff) disk_rom_ok <= 1'b1;
end
assign disk_unit = disk_rom_ok;

pc6031 fdd
(
	.clk(clk_sys),
	.reset(cpu_reset),
	.rom_wr(rom_wr && ioctl_addr[24:11] == 14'h00a),
	.rom_addr(ioctl_addr[10:0]),
	.rom_d(ioctl_dout),
	.rom_ok(disk_rom_ok),
	.addr(A[1:0]),
	.rd(io_rd & sel_fdd),
	.wr(io_wr & sel_fdd),
	.din(cpu_dout),
	.dout(fdd_dout),
	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),
	.sd_lba(sd_lba),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr),
	.ddr_busy(da_busy),
	.ddr_burstcnt(),
	.ddr_addr(da_addr),
	.ddr_dout(ddr_dout),
	.ddr_dout_ready(da_dout_ready),
	.ddr_rd(da_rd),
	.ddr_din(da_din),
	.ddr_be(da_be),
	.ddr_we(da_we),
	.ext_sel(p66),
	.ext_m_addr(m66_addr),
	.ext_m_rd(m66_rd),
	.ext_m_we(m66_we),
	.ext_m_d(m66_d),
	.ext_m_q(m66_q),
	.ext_m_done(m66_done),
	.ext_m_ready(m66_ready),
	.ext_m_wprot(m66_wprot),
	.disk_ready(disk_ready),
	.disk_too_big(disk_too_big),
	.motor(disk_motor)
);

// DDR3: the disk image (client a) and the ROM store (client b)
wire        da_busy, da_dout_ready, da_rd, da_we, db_busy, db_dout_ready, db_rd, db_we;
wire [28:0] da_addr, db_addr;
wire [63:0] da_din, db_din;
wire  [7:0] da_be, db_be;
assign ddr_burstcnt = 8'd1;
ddr_arb ddr_arb
(
	.clk(clk_sys),
	.a_rd(da_rd), .a_we(da_we), .a_addr(da_addr), .a_din(da_din), .a_be(da_be), .a_busy(da_busy),
	.a_dout_ready(da_dout_ready),
	.b_rd(db_rd), .b_we(db_we), .b_addr(db_addr), .b_din(db_din), .b_be(db_be), .b_busy(db_busy),
	.b_dout_ready(db_dout_ready),
	.ddr_busy(ddr_busy), .ddr_dout_ready(ddr_dout_ready),
	.ddr_rd(ddr_rd), .ddr_we(ddr_we), .ddr_addr(ddr_addr), .ddr_din(ddr_din), .ddr_be(ddr_be)
);

rom_store rom_store
(
	.clk(clk_sys),
	.reset(reset_dl),
	.model(model),
	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),
	.busy(rs_busy),
	.sets(rs_sets),
	.rom_a(rs_a),
	.rom_d(rs_d),
	.rom_we(rs_we),
	.ddr_busy(db_busy),
	.ddr_burstcnt(),
	.ddr_addr(db_addr),
	.ddr_dout(ddr_dout),
	.ddr_dout_ready(db_dout_ready),
	.ddr_rd(db_rd),
	.ddr_din(db_din),
	.ddr_be(db_be),
	.ddr_we(db_we)
);

// the PC-6601's built-in drive, on the same disk image
wire [19:0] m66_addr;
wire  [7:0] m66_d, m66_q, fdc66_dout;
wire        m66_rd, m66_we, m66_done, m66_ready, m66_wprot;
fdc66 fdc66
(
	.clk(clk_sys),
	.reset(cpu_reset | ~p66),
	.addr(A),
	.sel(sel_66),
	.rd(io_rd & sel_66),
	.rd_lvl(io_cyc & ~rd_n & sel_66),
	.wr(io_wr & sel_66),
	.din(cpu_dout),
	.dout(fdc66_dout),
	.m_addr(m66_addr),
	.m_rd(m66_rd),
	.m_q(m66_q),
	.m_done(m66_done),
	.m_we(m66_we),
	.m_d(m66_d),
	.m_ready(m66_ready),
	.m_wprot(m66_wprot)
);

reg [7:0] io_dout;
always @(*) begin
	if (sel_f) case (A[3:0])
		4'h0: io_dout = rf0;
		4'h1: io_dout = rf1;
		4'h2: io_dout = rf2;
		4'h3: io_dout = sr ? 8'hff : f3;
		4'h4: io_dout = sr ? sr_vec[0] : f4;
		4'h5: io_dout = sr ? sr_vec[1] : f5;
		4'h6: io_dout = f6;
		4'h7: io_dout = sr ? sr_vec[2] : 8'hff;
		4'ha: io_dout = sr ? ~sr_ien : 8'hff;
		4'hb: io_dout = sr ? sr_vout : 8'hff;
		default: io_dout = 8'hff;
	endcase
	else if (sel_c && A[1:0] == 2'd2) io_dout = {6'b111111, kj_lr, kj_rom};
	else if (sel_6x) io_dout = srm[A[3:0]];
	else if (sr && A[7:0] == 8'hb2) io_dout = 8'hfd;              // b1 0: the mkIISR (1 the 6601SR)
	else if (sr && sel_psg && A[1:0] == 2'd2) io_dout = opn_dout & {~vsync_s, ~hsync_s, 6'h3f};
	else if (sr && sel_psg && A[1:0] == 2'd3) io_dout = opn_dout;
	else if (sel_e) io_dout = voice_dout;
	else if (sel_66) io_dout = fdc66_dout;
	else if (sel_ppi) io_dout = ppi_dout;
	else if (sel_fdd) io_dout = fdd_dout;
	else if (sel_psg && A[1:0] == 2'd2) io_dout = psg_dout;
	else io_dout = 8'hff;
end

//----------------------------------------------------------------------------
// Timer and interrupts
//----------------------------------------------------------------------------

localparam TIMER_PERIOD = 8192;   // Z80 states: 2048 x (3 + 1); the mkII 2048 x (F6 + 1)
// the mkIISR (PC6001VX IRQ64::SetTimerIntrHz): 56 x (F6 + 1) in the SR mode, 1792 x (F6 + 1) otherwise
wire  [8:0] f6p = {1'b0, f6} + 9'd1;
wire [19:0] timer_period = sr ? (sr_mode ? {5'd0, f6p, 6'd0} - {8'd0, f6p, 3'd0} : {f6p, 11'd0} - {3'd0, f6p, 8'd0})
                         : mk2 ? {f6p, 11'd0} : 20'(TIMER_PERIOD);

// The mkIISR's interrupt controller (PC6001VX IRQ64): FAh masks (b0 the sub CPU, b2 the timer, b4 VRTC;
// 1 masked), FBh sends the vector from B8h-BFh (b0-b7) instead of the default. F3h-F5h, F7h do the mkII's
// part of that outside the SR mode. All are masked from reset.
always @(posedge clk_sys) begin
	if (cpu_reset) begin
		sr_ien <= 0; sr_vout <= 0;
		for (k = 0; k < 8; k = k + 1) sr_vec[k] <= 0;
	end
	else if (io_wr) begin
		if (sel_bv) sr_vec[A[2:0]] <= cpu_dout;
		if (sr && sel_f) case (A[3:0])
			4'h3: if (!sr_mode) begin sr_ien[2:0] <= ~cpu_dout[2:0]; sr_vout[1:0] <= cpu_dout[4:3]; end
			4'h4: if (!sr_mode) sr_vec[0] <= cpu_dout;
			4'h5: if (!sr_mode) sr_vec[1] <= cpu_dout;
			4'h7: if (!sr_mode) sr_vec[2] <= cpu_dout;
			4'ha: sr_ien <= ~cpu_dout;
			4'hb: sr_vout <= cpu_dout;
			default: ;
		endcase
	end
end
wire timer_en = sr ? sr_ien[2] : ~(mk2 & f3[2]);

reg [19:0] timer_cnt;
reg        timer_req;
reg        timer_off_d;
reg  [1:0] int_src;           // the acknowledged interrupt: 0 the timer, 1 the sub CPU, 2 VRTC
wire [1:0] int_pick;

always @(posedge clk_sys) begin
	if (cpu_reset) begin
		timer_cnt <= 20'(TIMER_PERIOD - 1);
		timer_req <= 0;
		timer_off_d <= 1;
	end
	else begin
		timer_off_d <= timer_off;
		if (timer_off_d && !timer_off) timer_cnt <= (timer_period >> 1) - 1'd1;   // the first period is half
		else if (ce_cpu) begin
			if (timer_cnt == 0) begin
				timer_cnt <= timer_period - 1'd1;
				if (timer_en) timer_req <= 1'b1;   // the mkII drops it while F3 b2 masks the timer
			end
			else timer_cnt <= timer_cnt - 1'd1;
		end
		if (inta_s && int_pick == 2'd0) timer_req <= 1'b0;
	end
end

// VRTC (the mkIISR's SR mode): asked at the end of vertical sync, withdrawn a line later if not taken
// (PC6001VX VDG64::EventCallback)
wire vrtc_set, vrtc_clr;
reg  vrtc_req;
always @(posedge clk_sys) begin
	if (cpu_reset) vrtc_req <= 0;
	else if (vrtc_set) vrtc_req <= sr_mode & sr_ien[4] & ~timer_off;
	else if (vrtc_clr || (inta_s && int_pick == 2'd2)) vrtc_req <= 0;
end

// the mkII: F3 b0 masks the sub CPU, b2 the timer; b3 sends F4 as the sub CPU's vector (PC6001VX IRQ62)
wire timer_pend = timer_req & ~timer_off & timer_en;
wire sub_pend   = sub_irq & (sr ? sr_ien[0] : ~(mk2 & f3[0]));
wire vrtc_pend  = vrtc_req & sr_mode & sr_ien[4] & ~timer_off;
wire [7:0] timer_vec = sr && sr_vout[2] ? sr_vec[2] : 8'h06;
wire [7:0] sub_vec   = sr ? (sr_vout[0] ? sr_vec[0] : sub_vector) : mk2 && f3[3] ? f4 : sub_vector;
wire [7:0] vrtc_vec  = sr_vout[4] ? sr_vec[4] : 8'h22;
assign int_pick = timer_pend ? 2'd0 : sub_pend ? 2'd1 : 2'd2;
wire [7:0] vec_now = timer_pend ? timer_vec : sub_pend ? sub_vec : vrtc_vec;
assign int_n = ~(timer_pend | sub_pend | vrtc_pend);

// The vector is decided at the start of the acknowledge cycle and held for it.
reg [7:0] int_vec;
always @(posedge clk_sys) begin
	sub_ack <= 1'b0;
	if (inta_s) begin
		int_src <= int_pick;
		int_vec <= vec_now;
		if (int_pick == 2'd1) sub_ack <= 1'b1;
	end
end

always @(*) begin
	if (inta) cpu_din = inta_d ? int_vec : vec_now;
	else if (~mreq_n) cpu_din = mem_dout;
	else cpu_din = io_dout;
end


//----------------------------------------------------------------------------
// Video
//----------------------------------------------------------------------------

pc6001_vdg vdg
(
	.clk(clk_sys),
	.reset(reset),
	.ce_pix(ph == 2'd3),
	.ph(ph),
	.vram_base(vram_base),
	.disp_on(crt_on),
	.mk2(mk2),
	.page(sys_latch[2:1]),
	.crt_mode(c1[3:0]),
	.css(c0[2:0]),
	.sr(sr),
	.sr_mode(sr_mode),
	.c8(c8),
	.c9(c9),
	.rollx(sr_rollx),
	.rolly(sr_rolly),
	.pal({sr_palw, sr_pal[3], sr_pal[2], sr_pal[1], sr_pal[0]}),
	.m4col(m4col),
	.vrtc_set(vrtc_set),
	.vrtc_clr(vrtc_clr),
	.bus_slow(bus_slow),
	.vaddr(vaddr),
	.vdata(vram_q),
	.cg_addr(cg_addr),
	.cg_data(mk2 ? cg62_q : cg_q),
	.busrq(busrq),
	.R(R), .G(G), .B(B),
	.HSync(HSync), .VSync(VSync),
	.HBlank(HBlank), .VBlank(VBlank),
	.hsync_s(hsync_s), .vsync_s(vsync_s),
	.mono(mono),
	.cidx(cidx)
);

endmodule
