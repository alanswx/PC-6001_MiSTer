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
	input             ram16k,          // OSD: 16 KB RAM instead of 32 KB
	input             tape_turbo,      // OSD: TURBO x while the motor relay is on
	input             tape_rewind,
	input             cart_eject,

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
	output      [1:0] tape_hint,       // next step while the deck is stopped: 0 none, 1 CLOAD, 2 RUN
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

//----------------------------------------------------------------------------
// Clock enables
//----------------------------------------------------------------------------

reg [1:0] ph = 0;
always @(posedge clk_sys) ph <= ph + 1'd1;
assign ce_pix = ph == 2'd3;

// 3.9936 MHz from 28.636364 MHz: 39936 / 286364; TURBO times that during tape turbo. 7.17x would be an enable
// on every clock; above 3x some enables fall on consecutive clocks, which the memories allow (a Z80 memory or
// I/O access spans at least three T-states, and BRAM data follows the address one clock later).
localparam [18:0] CPU_TURBO_STEP = 19'(39936 * TURBO);
wire [18:0] cpu_step = tape_turbo_on ? CPU_TURBO_STEP : 19'd39936;
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
// the PSG keeps its 1.9968 MHz in turbo
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

wire cpu_reset = reset | (ioctl_download & (ioctl_index[5:0] == 6'd0 | ioctl_index[5:0] == 6'd2));

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

// Waits: one Z80 state on each M1, each memory access below 8000h and each PSG access
reg waited;
wire want_wait = (~mreq_n & rfsh_n & (~m1_n | ~A[15])) | (io_cyc & A[7:4] == 4'hA);
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
// Memory
//----------------------------------------------------------------------------

wire       rom_wr = ioctl_download && ioctl_wr && ioctl_index[5:0] == 6'd0;

// BASIC ROM
reg  [7:0] basic_rom[0:16383];
reg  [7:0] basic_q;
always @(posedge clk_sys) begin
	if (rom_wr && ioctl_addr[24:14] == 0) basic_rom[ioctl_addr[13:0]] <= ioctl_dout;
	basic_q <= basic_rom[A[13:0]];
end

// CGROM: the CPU at 6000h and the VDG
wire [11:0] cg_addr;
reg   [7:0] cg_rom[0:4095];
reg   [7:0] cg_q, cg_cpu_q;
always @(posedge clk_sys) begin
	if (rom_wr && ioctl_addr[24:12] == 13'h004) cg_rom[ioctl_addr[11:0]] <= ioctl_dout;
	cg_q <= cg_rom[cg_addr];
end
always @(posedge clk_sys) cg_cpu_q <= cg_rom[A[11:0]];

// RAM 32 KB at 8000h: port A the CPU, port B the VDG
wire [15:0] vaddr;
reg   [7:0] ram[0:32767];
reg   [7:0] ram_q, vram_q;
wire        ram_sel = A[15] & ~(ram16k & ~A[14]);
wire        ram_we  = ~mreq_n & ~wr_n & ram_sel & ce_cpu;
always @(posedge clk_sys) begin
	if (ram_we) ram[A[14:0]] <= cpu_dout;
	ram_q <= ram[A[14:0]];
end
always @(posedge clk_sys) vram_q <= ram[vaddr[14:0]];

// Cartridge ROM at 4000h, loaded through ioctl index 2
wire       cart_wr = ioctl_download && ioctl_wr && ioctl_index[5:0] == 6'd2;
reg  [7:0] cart_rom[0:16383];
reg  [7:0] cart_q;
reg [14:0] cart_len = 0;
reg        cart_big = 0, cart_dl = 0;
always @(posedge clk_sys) begin
	if (cart_wr && ioctl_addr[24:14] == 0) cart_rom[ioctl_addr[13:0]] <= ioctl_dout;
	cart_q <= cart_rom[A[13:0]];
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

wire cg_sel;
reg [7:0] mem_dout;
always @(*) begin
	if (!A[15]) begin
		if (!A[14]) mem_dout = basic_q;
		else if (A[13] && cg_sel && (!A[12] || !cart_in)) mem_dout = cg_cpu_q;
		else mem_dout = {1'b0, A[13:0]} < cart_len ? cart_q : 8'hff;
	end
	else mem_dout = ram_sel ? ram_q : 8'hff;
end

//----------------------------------------------------------------------------
// I/O
//----------------------------------------------------------------------------

wire       sel_ppi = A[7:4] == 4'h9;
wire       sel_psg = A[7:4] == 4'hA;
wire       sel_b0  = A[7:4] == 4'hB;

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
wire [7:0] sub_vector;
wire       crt_on;
reg        sub_ack;

pc6001_sub sub
(
	.clk(clk_sys),
	.reset(cpu_reset),
	.ce_cpu(ce_cpu),
	.addr(A[1:0]),
	.rd(io_rd & sel_ppi),
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
	.tape_strobe(tape_strobe),
	.tape_byte(tape_q),
	.tape_ready(tape_ready),
	.cmt_open()
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
// After a download the core reads the size from the last four bytes and checks for "P6" there; then only the
// image plays. The footer's gaps (silence, carrier) are not played. A .p6/.cas has no footer and plays whole.
reg  [31:0] tape_tail;
reg   [2:0] p6t_chk = 0;    // 1, 3: wait for tape_q; 2: check "P"; 4: check "6"
reg  [15:0] p6t_addr;
wire [15:0] tape_raddr = p6t_chk ? p6t_addr : tape_pos[15:0];
always @(posedge clk_sys) begin
	if (tape_wr) tape_mem[ioctl_addr[15:0]] <= ioctl_dout;
	tape_q <= tape_mem[tape_raddr];
end

always @(posedge clk_sys) begin
	tape_strobe <= 1'b0;
	tape_dl <= ioctl_download && ioctl_index[5:0] == 6'd1;
	if (ioctl_download && ioctl_index[5:0] == 6'd1) begin
		if (!tape_dl) begin tape_len <= 0; tape_big <= 0; end
		if (tape_wr && ioctl_addr[24:16] == 0) tape_len <= ioctl_addr[16:0] + 1'd1;
		if (tape_wr && ioctl_addr[24:16] != 0) tape_big <= 1'b1;
		if (tape_wr) tape_tail <= {ioctl_dout, tape_tail[31:8]};
		tape_pos <= 0;
		tape_tick <= 0;
		p6t_chk <= 0;
	end
	else if (tape_dl) begin
		// download just ended: look for a P6T footer at the size the last four bytes give
		if (tape_len >= 17'd6 && tape_tail[31:16] == 0 && tape_tail[15:0] != 0 && tape_tail[16:0] + 17'd6 <= tape_len) begin
			p6t_addr <= tape_tail[15:0];
			p6t_chk <= 3'd1;
		end
	end
	else if (p6t_chk != 0) begin
		case (p6t_chk)
		3'd2: if (tape_q == "P") p6t_addr <= p6t_addr + 1'd1; else p6t_chk <= 0;
		3'd4: if (tape_q == "6") tape_len <= {1'b0, tape_tail[15:0]};
		default: ;
		endcase
		if (p6t_chk == 3'd4) p6t_chk <= 0;
		else if (p6t_chk != 3'd2 || tape_q == "P") p6t_chk <= p6t_chk + 1'd1;
	end
	else if (tape_rewind) tape_pos <= 0;
	else if (ce_cpu && tape_motor) begin
		// 39936 Z80 states per byte (100 bytes/s; TURBO x 100 in turbo, where the Z80 runs TURBO x faster)
		if (tape_tick >= 16'd39935) begin
			tape_tick <= 0;
			if (tape_pos < tape_len && tape_ready) begin
				tape_strobe <= 1'b1;
				tape_pos <= tape_pos + 1'd1;
			end
		end
		else tape_tick <= tape_tick + 1'd1;
	end
end

// Next-step hint (tape standard rules 25-28), only from what the tape says: a tape that starts with a BASIC
// header (ten D3h bytes, then the name) is loaded with CLOAD, so at its start the hint is "TYPE CLOAD"; when the
// motor stops after that first file, "TYPE RUN" until Return is pressed. Later stops (a program loading its next
// parts) show nothing, nor does a tape without the header (machine code: its loading is in its instructions).
reg  tape_basic = 0, run_hint = 0, first_stop = 0, old_motor = 0, key_tgl = 0;
always @(posedge clk_sys) begin
	old_motor <= tape_motor;
	key_tgl <= ps2_key[10];
	if (tape_wr && ioctl_addr[24:4] == 0 && ioctl_addr[3:0] < 4'd10) begin
		if (ioctl_addr[3:0] == 0) tape_basic <= ioctl_dout == 8'hD3;
		else if (ioctl_dout != 8'hD3) tape_basic <= 1'b0;
	end
	if (tape_dl || tape_pos == 0) begin run_hint <= 0; first_stop <= 1'b1; end
	else if (old_motor && !tape_motor) begin run_hint <= first_stop && tape_basic; first_stop <= 0; end
	// Return or keypad Enter (both are RETURN in the key map)
	if (tape_motor || (ps2_key[10] != key_tgl && ps2_key[9] && ps2_key[7:0] == 8'h5A)) run_hint <= 0;
end
assign tape_hint = !tape_loaded || tape_motor ? 2'd0 : tape_pos == 0 && tape_basic ? 2'd1 : run_hint ? 2'd2 : 2'd0;

// PSG: port A reads the joystick picked by port B bit 6 (0: joystick 2), active low:
// b0 up b1 down b2 left b3 right b4 trigger 1 b5 trigger 2 (PC6001VX psgfm.cpp, joystick.cpp). The touch panel
// takes joystick 2's place when the OSD puts it there.
wire [7:0] psg_dout;
wire [9:0] psg_sound;
wire [7:0] psg_iob;
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
	.IOB_out(psg_iob),
	.IOB_oe()
);

assign audio = {1'b0, psg_sound, 5'd0};

//----------------------------------------------------------------------------
// PC-6031 disk unit at D0h-D3h
//----------------------------------------------------------------------------

wire       sel_fdd = A[7:2] == 6'b1101_00;
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
	.disk_ready(disk_ready),
	.disk_too_big(disk_too_big),
	.motor(disk_motor)
);

reg [7:0] io_dout;
always @(*) begin
	if (sel_ppi) io_dout = ppi_dout;
	else if (sel_fdd) io_dout = fdd_dout;
	else if (sel_psg && A[1:0] == 2'd2) io_dout = psg_dout;
	else io_dout = 8'hff;
end

//----------------------------------------------------------------------------
// Timer and interrupts
//----------------------------------------------------------------------------

localparam TIMER_PERIOD = 8192;   // Z80 states: 2048 x (3 + 1)

reg [12:0] timer_cnt;
reg        timer_req;
reg        timer_off_d;
reg        int_timer;     // the acknowledge goes to the timer

always @(posedge clk_sys) begin
	if (cpu_reset) begin
		timer_cnt <= TIMER_PERIOD - 1;
		timer_req <= 0;
		timer_off_d <= 1;
	end
	else begin
		timer_off_d <= timer_off;
		if (timer_off_d && !timer_off) timer_cnt <= TIMER_PERIOD / 2 - 1;   // the first period is half
		else if (ce_cpu) begin
			if (timer_cnt == 0) begin
				timer_cnt <= TIMER_PERIOD - 1;
				timer_req <= 1'b1;
			end
			else timer_cnt <= timer_cnt - 1'd1;
		end
		if (inta_s && int_timer) timer_req <= 1'b0;
	end
end

wire timer_pend = timer_req & ~timer_off;
assign int_n = ~(timer_pend | sub_irq);

// The vector is decided at the start of the acknowledge cycle and held for it.
reg [7:0] int_vec;
always @(posedge clk_sys) begin
	sub_ack <= 1'b0;
	if (inta_s) begin
		int_timer <= timer_pend;
		int_vec <= timer_pend ? 8'h06 : sub_vector;
		if (!timer_pend) sub_ack <= 1'b1;
	end
end

always @(*) begin
	if (inta) cpu_din = inta_d ? int_vec : (timer_pend ? 8'h06 : sub_vector);
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
	.ce_pix(ce_pix),
	.ph(ph),
	.vram_base(vram_base),
	.disp_on(crt_on),
	.vaddr(vaddr),
	.vdata(vram_q),
	.cg_addr(cg_addr),
	.cg_data(cg_q),
	.busrq(busrq),
	.R(R), .G(G), .B(B),
	.HSync(HSync), .VSync(VSync),
	.HBlank(HBlank), .VBlank(VBlank),
	.mono(mono),
	.cidx(cidx)
);

endmodule
