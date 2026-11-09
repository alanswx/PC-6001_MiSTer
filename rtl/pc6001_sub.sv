//============================================================================
//  PC-6001 8255 (ports 90h-93h) and the sub CPU behind it, high-level.
//
//  The real sub CPU is a uPD8049 that scans the keyboard, runs the cassette and passes STICK/STRIG requests.
//  The only public dump of its ROM is bad (MAME BAD_DUMP: 60% of the bytes equal their own address), so like
//  MAME, PC6001V, PC6001VX and PC6001VW the core models what it does. This follows PC6001VX (src/cpus.cpp,
//  src/pio.cpp, src/device/pd8255.cpp, src/keyboard.cpp; LGPL-2.1):
//
//  - 8255 port A in mode 2 is the channel. The Z80 writes a command (OBF low); the sub CPU takes it at once
//    (OBF high). The sub CPU answers with an interrupt vector byte (IBF high, Z80 INT), then for most requests a
//    data byte, each only once IBF is low again. The Z80's IM 2 acknowledge reads port A.
//  - Every 300 us the sub CPU checks its requests in priority order: game keys (command 06h), key 1 (STOP
//    with the cassette open), cassette data, key 2 (STOP/GRAPH/function keys), key 3 (other keys).
//  - Port C bits 0-2 are outputs: 0 printer strobe, 1 CRTKILL (1 = display on), 2 CGSW (0 = CGROM at 6000h).
//
//  Vectors: 02h key 3, 08h cassette data, 0Eh key 1, 12h cassette error, 14h key 2, 16h game keys.
//============================================================================

module pc6001_sub
(
	input             clk,
	input             reset,
	input             ce_cpu,          // Z80 clock enable (3.99 MHz): the sub CPU's delays count Z80 states
	input             mk2,             // the mkII's sub CPU: commands 04h / 05h switch kana (PC6001VX SUB62)

	// Z80 side
	input       [1:0] addr,
	input             rd,              // one clk per access
	input             rd_act,          // a read is on (RD low), for its end
	input             wr,
	input       [7:0] din,
	output reg  [7:0] dout,

	output            irq,             // sub CPU interrupt request (to the interrupt logic)
	input             int_ack,         // one clk: the Z80 acknowledged it; vector = int_vector
	output      [7:0] int_vector,      // port A as the acknowledge reads it

	output            crt_on,          // port C bit 1
	output            cg_sel,          // CGROM at 6000h (port C bit 2 = 0)

	// keyboard
	input      [10:0] ps2_key,
	input             kbd_us,          // 1: symbols as printed on a US keyboard; 0: JIS key positions
	input             inj_strobe,      // a key code typed for the user (rtl/tape_auto.sv), as key 3
	input       [7:0] inj_code,
	output            inj_ready,       // no key waiting

	// cassette: one byte at a time from the tape (rtl/pc6001.sv), taken while the cassette is open for loading
	input             tape_strobe,
	input       [7:0] tape_byte,
	output            tape_ready,      // the sub CPU takes a cassette byte now (else the tape waits)
	output            cmt_open
);

`include "pc6001_keytable.svh"

//----------------------------------------------------------------------------
// 8255
//----------------------------------------------------------------------------

reg       mode2;          // group A mode 2
reg [7:0] porta, porta_buf, portb, portc;
reg       ibf, obf;       // obf = 1: output buffer empty (the signal is high)
reg       rd_pend;        // port A is being read: it empties when RD goes high
reg       rie, wie;

wire      pc_int = (obf & wie) | (ibf & rie);
wire [7:0] portc_rd = mode2 ? {obf, wie, ibf, rie, pc_int, portc[2:0]} : portc;

// The display is on from power-on until port C bit 1 is written low (PC6001VX MC6847core: CrtDisp starts true);
// a mode set does not turn it off. Cartridges such as Star Fire never turn it on themselves.
reg crt = 1'b1;
assign crt_on = crt;
assign cg_sel = ~portc[2];
assign int_vector = ibf ? porta_buf : porta;

// sub CPU -> port A (STB pulse)
reg       sub_wr;
reg [7:0] sub_wdata;
// command from the Z80, taken by the sub CPU at once
reg       cmd_strobe;
reg [7:0] cmd_byte;

always @(*) begin
	case (addr)
	2'd0: dout = ibf ? porta_buf : porta;
	2'd1: dout = portb;
	2'd2: dout = portc_rd;
	default: dout = 8'hff;
	endcase
end

always @(posedge clk) begin
	cmd_strobe <= 1'b0;
	if (reset) begin
		mode2 <= 0;
		porta <= 0; porta_buf <= 0; portb <= 0; portc <= 0;
		crt <= 1'b1;
		ibf <= 0; obf <= 1; rd_pend <= 0;
		rie <= 0; wie <= 0;
	end
	else begin
		if (sub_wr && mode2) begin
			porta_buf <= sub_wdata;
			ibf <= 1'b1;
		end
		// IBF falls at the end of the read (8255): cleared at its start, the sub CPU's next byte could reach the
		// bus before the Z80 takes the data, and the byte read would be lost
		if (rd && addr == 2'd0) rd_pend <= 1'b1;
		if ((rd_pend && !rd_act) || int_ack) begin
			rd_pend <= 1'b0;
			if (mode2) begin
				if (ibf) porta <= porta_buf;
				ibf <= 1'b0;
			end
		end
		if (wr) begin
			case (addr)
			2'd0: begin
				porta <= din;
				if (mode2) begin
					// the sub CPU reads it at once: OBF goes low and back high
					obf <= 1'b1;
					cmd_strobe <= 1'b1;
					cmd_byte <= din;
				end
			end
			2'd1: portb <= din;
			2'd2: begin portc[2:0] <= din[2:0]; crt <= din[1]; end
			2'd3: begin
				if (din[7]) begin
					mode2 <= din[6];
					porta <= 0; portb <= 0; portc <= 0;
				end
				else if (mode2) begin
					case (din[3:1])
					3'd4: rie <= din[0];
					3'd6: wie <= din[0];
					3'd3, 3'd5, 3'd7: ;
					default: begin
						portc[din[3:1]] <= din[0];
						if (din[3:1] == 3'd1) crt <= din[0];
					end
					endcase
				end
				else begin
					portc[din[3:1]] <= din[0];
					if (din[3:1] == 3'd1) crt <= din[0];
				end
			end
			endcase
		end
	end
end

//----------------------------------------------------------------------------
// Keyboard: PS/2 set 2 -> P6 key matrix position (PC6001VX P6KeyMx), JIS keys by US position
//----------------------------------------------------------------------------

// {valid, y, x}
function automatic [7:0] ps2_to_p6(input [8:0] code);
	case (code)
	9'h014, 9'h114: ps2_to_p6 = {1'b1, 4'd0, 3'd1};   // CTRL
	9'h012, 9'h059: ps2_to_p6 = {1'b1, 4'd0, 3'd2};   // SHIFT
	9'h011, 9'h111: ps2_to_p6 = {1'b1, 4'd0, 3'd3};   // GRAPH = Alt
	9'h016: ps2_to_p6 = {1'b1, 4'd1, 3'd0};   // 1
	9'h015: ps2_to_p6 = {1'b1, 4'd1, 3'd1};   // Q
	9'h01c: ps2_to_p6 = {1'b1, 4'd1, 3'd2};   // A
	9'h01a: ps2_to_p6 = {1'b1, 4'd1, 3'd3};   // Z
	9'h042: ps2_to_p6 = {1'b1, 4'd1, 3'd4};   // K
	9'h043: ps2_to_p6 = {1'b1, 4'd1, 3'd5};   // I
	9'h03e: ps2_to_p6 = {1'b1, 4'd1, 3'd6};   // 8
	9'h041: ps2_to_p6 = {1'b1, 4'd1, 3'd7};   // ,
	9'h01e: ps2_to_p6 = {1'b1, 4'd2, 3'd0};   // 2
	9'h01d: ps2_to_p6 = {1'b1, 4'd2, 3'd1};   // W
	9'h01b: ps2_to_p6 = {1'b1, 4'd2, 3'd2};   // S
	9'h022: ps2_to_p6 = {1'b1, 4'd2, 3'd3};   // X
	9'h04b: ps2_to_p6 = {1'b1, 4'd2, 3'd4};   // L
	9'h044: ps2_to_p6 = {1'b1, 4'd2, 3'd5};   // O
	9'h046: ps2_to_p6 = {1'b1, 4'd2, 3'd6};   // 9
	9'h049: ps2_to_p6 = {1'b1, 4'd2, 3'd7};   // .
	9'h026: ps2_to_p6 = {1'b1, 4'd3, 3'd0};   // 3
	9'h024: ps2_to_p6 = {1'b1, 4'd3, 3'd1};   // E
	9'h023: ps2_to_p6 = {1'b1, 4'd3, 3'd2};   // D
	9'h021: ps2_to_p6 = {1'b1, 4'd3, 3'd3};   // C
	9'h04c: ps2_to_p6 = {1'b1, 4'd3, 3'd4};   // ;
	9'h04d: ps2_to_p6 = {1'b1, 4'd3, 3'd5};   // P
	9'h005: ps2_to_p6 = {1'b1, 4'd3, 3'd6};   // F1
	9'h04a: ps2_to_p6 = {1'b1, 4'd3, 3'd7};   // /
	9'h025: ps2_to_p6 = {1'b1, 4'd4, 3'd0};   // 4
	9'h02d: ps2_to_p6 = {1'b1, 4'd4, 3'd1};   // R
	9'h02b: ps2_to_p6 = {1'b1, 4'd4, 3'd2};   // F
	9'h02a: ps2_to_p6 = {1'b1, 4'd4, 3'd3};   // V
	9'h052: ps2_to_p6 = {1'b1, 4'd4, 3'd4};   // : = US '
	9'h054: ps2_to_p6 = {1'b1, 4'd4, 3'd5};   // @ = US [
	9'h006: ps2_to_p6 = {1'b1, 4'd4, 3'd6};   // F2
	9'h051: ps2_to_p6 = {1'b1, 4'd4, 3'd7};   // _ (JIS ro)
	9'h02e: ps2_to_p6 = {1'b1, 4'd5, 3'd0};   // 5
	9'h02c: ps2_to_p6 = {1'b1, 4'd5, 3'd1};   // T
	9'h034: ps2_to_p6 = {1'b1, 4'd5, 3'd2};   // G
	9'h032: ps2_to_p6 = {1'b1, 4'd5, 3'd3};   // B
	9'h05d: ps2_to_p6 = {1'b1, 4'd5, 3'd4};   // ] = US backslash
	9'h05b: ps2_to_p6 = {1'b1, 4'd5, 3'd5};   // [ = US ]
	9'h004: ps2_to_p6 = {1'b1, 4'd5, 3'd6};   // F3
	9'h029: ps2_to_p6 = {1'b1, 4'd5, 3'd7};   // SPACE
	9'h036: ps2_to_p6 = {1'b1, 4'd6, 3'd0};   // 6
	9'h035: ps2_to_p6 = {1'b1, 4'd6, 3'd1};   // Y
	9'h033: ps2_to_p6 = {1'b1, 4'd6, 3'd2};   // H
	9'h031: ps2_to_p6 = {1'b1, 4'd6, 3'd3};   // N
	9'h04e: ps2_to_p6 = {1'b1, 4'd6, 3'd4};   // -
	9'h055: ps2_to_p6 = {1'b1, 4'd6, 3'd5};   // ^ = US =
	9'h00c: ps2_to_p6 = {1'b1, 4'd6, 3'd6};   // F4
	9'h045: ps2_to_p6 = {1'b1, 4'd6, 3'd7};   // 0
	9'h03d: ps2_to_p6 = {1'b1, 4'd7, 3'd0};   // 7
	9'h03c: ps2_to_p6 = {1'b1, 4'd7, 3'd1};   // U
	9'h03b: ps2_to_p6 = {1'b1, 4'd7, 3'd2};   // J
	9'h03a: ps2_to_p6 = {1'b1, 4'd7, 3'd3};   // M
	9'h00e, 9'h06a: ps2_to_p6 = {1'b1, 4'd7, 3'd5};   // yen = US ` / JIS yen
	9'h003: ps2_to_p6 = {1'b1, 4'd7, 3'd6};   // F5
	9'h05a, 9'h15a: ps2_to_p6 = {1'b1, 4'd8, 3'd0};   // RETURN
	9'h001, 9'h177, 9'h169: ps2_to_p6 = {1'b1, 4'd8, 3'd1};   // STOP = F9 / Pause / End
	9'h175: ps2_to_p6 = {1'b1, 4'd8, 3'd2};   // up
	9'h172: ps2_to_p6 = {1'b1, 4'd8, 3'd3};   // down
	9'h174: ps2_to_p6 = {1'b1, 4'd8, 3'd4};   // right
	9'h16b: ps2_to_p6 = {1'b1, 4'd8, 3'd5};   // left
	9'h00d: ps2_to_p6 = {1'b1, 4'd8, 3'd6};   // TAB
	9'h076: ps2_to_p6 = {1'b1, 4'd8, 3'd7};   // ESC
	9'h083: ps2_to_p6 = {1'b1, 4'd9, 3'd0};   // KANA = F7
	9'h170: ps2_to_p6 = {1'b1, 4'd9, 3'd1};   // INS
	9'h171, 9'h066: ps2_to_p6 = {1'b1, 4'd9, 3'd2};   // DEL = Delete / Backspace
	9'h17d, 9'h17a: ps2_to_p6 = {1'b1, 4'd9, 3'd3};   // PAGE = PgUp / PgDn
	9'h16c: ps2_to_p6 = {1'b1, 4'd9, 3'd4};   // HOME
	9'h00a: ps2_to_p6 = {1'b1, 4'd9, 3'd5};   // MODE = F8
	9'h058: ps2_to_p6 = {1'b1, 4'd9, 3'd6};   // CAPS
	default: ps2_to_p6 = 8'd0;
	endcase
endfunction

reg  [7:0] mat[0:9];          // 1 = pressed
reg        ps2_tog;
wire [7:0] kpos = ps2_to_p6(ps2_key[8:0]);

reg        kana, kkana;
reg        cmd_kana = 0, cmd_kkana = 0;   // commands 04h / 05h (the mkII)
reg        key_ev;            // a new key pressed (or repeated) this clk
reg  [6:0] key_pos;           // {y, x} for its code
reg        key_ovr, key_osh;  // US layout: the code uses key_osh in place of SHIFT

// US layout: the key and Shift give the P6 key and Shift of the symbol printed on a US keyboard. Letters, digits
// and the keys that match keep their positions; ` { } | ~ have no P6 key and stay as JIS.
function automatic [8:0] us_map(input [7:0] code, input sh);   // {valid, y, x, shift}
	case ({code, sh})
	{8'h1e, 1'b1}: us_map = {1'b1, 4'd4, 3'd5, 1'b0};   // @
	{8'h36, 1'b1}: us_map = {1'b1, 4'd6, 3'd5, 1'b0};   // ^
	{8'h3d, 1'b1}: us_map = {1'b1, 4'd6, 3'd0, 1'b1};   // &
	{8'h3e, 1'b1}: us_map = {1'b1, 4'd4, 3'd4, 1'b1};   // *
	{8'h46, 1'b1}: us_map = {1'b1, 4'd1, 3'd6, 1'b1};   // (
	{8'h45, 1'b1}: us_map = {1'b1, 4'd2, 3'd6, 1'b1};   // )
	{8'h4e, 1'b1}: us_map = {1'b1, 4'd4, 3'd7, 1'b1};   // _
	{8'h55, 1'b0}: us_map = {1'b1, 4'd6, 3'd4, 1'b1};   // =
	{8'h55, 1'b1}: us_map = {1'b1, 4'd3, 3'd4, 1'b1};   // +
	{8'h54, 1'b0}, {8'h54, 1'b1}: us_map = {1'b1, 4'd5, 3'd5, 1'b0};   // [
	{8'h5b, 1'b0}, {8'h5b, 1'b1}: us_map = {1'b1, 4'd5, 3'd4, 1'b0};   // ]
	{8'h5d, 1'b0}, {8'h5d, 1'b1}: us_map = {1'b1, 4'd7, 3'd5, 1'b0};   // backslash (yen)
	{8'h4c, 1'b1}: us_map = {1'b1, 4'd4, 3'd4, 1'b0};   // :
	{8'h52, 1'b0}: us_map = {1'b1, 4'd7, 3'd0, 1'b1};   // '
	{8'h52, 1'b1}: us_map = {1'b1, 4'd2, 3'd0, 1'b1};   // "
	default: us_map = 9'd0;
	endcase
endfunction
wire [8:0] us = us_map(ps2_key[7:0], mat[0][2]);
wire       us_on = kbd_us && !ps2_key[8] && us[8] && !kana && !mat[0][3] && !mat[0][1];

// Key repeat (the sub CPU's on the real machine; PS/2 typematic does not reach the core): the last key pressed
// repeats after 500 ms, every 50 ms, while it is held. Not the mode keys (KANA, PAGE, MODE, CAPS), STOP or F1-F5.
localparam [23:0] REP_DELAY = 24'd14318182;   // 500 ms of the 28.636 MHz clock
localparam [23:0] REP_RATE  = 24'd1431818;    // 50 ms
reg [23:0] rep_cnt;
reg        rep_on, rep_ovr, rep_osh;
reg  [6:0] rep_phys, rep_pos;  // the key held (matrix) and the one its code comes from
wire       rep_ok = !(kpos[6:3] == 4'd9 && (kpos[2:0] == 3'd0 || kpos[2:0] == 3'd3 || kpos[2:0] == 3'd5 ||
                     kpos[2:0] == 3'd6)) && kpos[6:0] != {4'd8, 3'd1} &&
                     !(kpos[2:0] == 3'd6 && kpos[6:3] >= 4'd3 && kpos[6:3] <= 4'd7);

integer i;
always @(posedge clk) begin
	key_ev <= 1'b0;
	if (reset) begin
		for (i = 0; i < 10; i = i + 1) mat[i] <= 8'd0;
		ps2_tog <= ps2_key[10];
		kana <= 0; kkana <= 0;
		rep_on <= 0;
	end
	else begin
		// KANA and SHIFT+PAGE toggle the kana modes (after their own key code is taken); on the mkII the main CPU
		// can also, by commands 04h and 05h
		if ((key_ev && key_pos == {4'd9, 3'd0}) ^ cmd_kana) kana <= ~kana;
		if ((key_ev && key_pos == {4'd9, 3'd3} && on_shift) ^ cmd_kkana) kkana <= ~kkana;

		if (rep_on) begin
			if (!mat[rep_phys[6:3]][rep_phys[2:0]]) rep_on <= 1'b0;
			else if (rep_cnt != 0) rep_cnt <= rep_cnt - 1'd1;
			else begin
				rep_cnt <= REP_RATE;
				key_ev <= 1'b1;
				key_pos <= rep_pos;
				key_ovr <= rep_ovr; key_osh <= rep_osh;
			end
		end
	end
	if (!reset && ps2_key[10] != ps2_tog) begin
		ps2_tog <= ps2_key[10];
		if (kpos[7]) begin
			mat[kpos[6:3]][kpos[2:0]] <= ps2_key[9];
			if (ps2_key[9] && !mat[kpos[6:3]][kpos[2:0]] && kpos[6:3] != 4'd0) begin
				key_ev <= 1'b1;
				key_pos <= us_on ? us[7:1] : kpos[6:0];
				key_ovr <= us_on; key_osh <= us[0];
				rep_on <= rep_ok;
				rep_cnt <= REP_DELAY;
				rep_phys <= kpos[6:0];
				rep_pos <= us_on ? us[7:1] : kpos[6:0];
				rep_ovr <= us_on; rep_osh <= us[0];
			end
		end
	end
end

wire on_ctrl  = mat[0][1];
wire on_shift = mat[0][2];
wire on_graph = mat[0][3];

// the key code of a newly pressed key (PC6001VX KEY6::ScanMatrix)
wire is_fkey = key_pos[2:0] == 3'd6 && key_pos[6:3] >= 4'd3 && key_pos[6:3] <= 4'd7;
wire is_func = is_fkey || key_pos == {4'd9, 3'd6} || key_pos == {4'd9, 3'd5} || key_pos == {4'd9, 3'd0} ||
               (key_pos == {4'd9, 3'd3} && on_shift);
wire is_stop = key_pos == {4'd8, 3'd1};
wire [2:0] kgroup = is_func ? (is_fkey && on_shift ? 3'd1 : 3'd2) :
                    kana ? (kkana ? (on_shift ? 3'd6 : 3'd5) : (on_shift ? 3'd4 : 3'd3)) :
                    on_graph ? 3'd2 : on_ctrl ? 3'd7 : (key_ovr ? key_osh : on_shift) ? 3'd1 : 3'd0;
wire [7:0] kcode = key_code(key_pos[6:3], key_pos[2:0], kgroup);

// game keys for command 06h (PC6001VX KEY6::GetKeyJoy): b7 space, b5 left, b4 right, b3 down, b2 up,
// b1 STOP, b0 SHIFT
wire [7:0] joy_code = {mat[5][7], 1'b0, mat[8][5], mat[8][4], mat[8][3], mat[8][2], mat[8][1], mat[0][2]};

//----------------------------------------------------------------------------
// Sub CPU requests
//----------------------------------------------------------------------------

localparam INTCHK  = 1198;    // 300 us of Z80 states
localparam W_DATA  = 15;
localparam W_JOY   = 9225;

localparam S_IDLE = 4'd0, S_JOY = 4'd1, S_KEY1 = 4'd2, S_CMTR = 4'd3, S_CMTE = 4'd4, S_KEY2 = 4'd5,
           S_KEY3 = 4'd6;

reg  [3:0] st;
reg        req_joy, req_key1, req_cmtr, req_cmte, req_key2, req_key3;
reg  [7:0] key_data, cmt_data;
reg  [1:0] cmt_st;            // 0 closed, 1 load open, 2 save open
reg        cmto;              // the next command byte is a cassette output byte
reg [10:0] chk_cnt;
reg [13:0] ev_cnt;
reg        ev_vec, ev_dat;    // waiting to send the vector / the data
reg [13:0] ev_wait;
reg        irq_r;

assign irq = irq_r;
assign cmt_open = cmt_st != 2'd0;
assign inj_ready = !(req_key1 | req_key2 | req_key3) && !key_ev;
// PC6001VX SUB6::IsCmtIntrReady: the tape only advances when the sub CPU can pass a byte on at once
assign tape_ready = st == S_IDLE && cmt_st == 2'd1 && !req_cmtr && !ibf;

always @(posedge clk) begin
	sub_wr <= 1'b0;
	cmd_kana <= 1'b0;
	cmd_kkana <= 1'b0;
	if (reset) begin
		st <= S_IDLE;
		{req_joy, req_key1, req_cmtr, req_cmte, req_key2, req_key3} <= 0;
		cmt_st <= 0;
		cmto <= 0;
		cmt_data <= 0;
		chk_cnt <= 0;
		ev_vec <= 0; ev_dat <= 0;
		irq_r <= 0;
	end
	else begin
		if (int_ack) irq_r <= 1'b0;

		// commands
		if (cmd_strobe) begin
			if (cmto) cmto <= 1'b0;   // cassette output byte (not yet)
			else case (cmd_byte)
			8'h04: cmd_kana <= mk2;
			8'h05: cmd_kkana <= mk2;
			8'h06: req_joy <= 1'b1;
			8'h19: cmt_st <= 2'd1;
			8'h1a: cmt_st <= 2'd0;
			8'h38: cmto <= 1'b1;
			8'h39: cmt_st <= 2'd2;
			8'h3a: cmt_st <= 2'd0;
			default: ;
			endcase
		end

		// cassette data (PC6001VX SUB6::ReqCmtIntr: only while open for loading)
		if (tape_strobe && cmt_st == 2'd1 && !req_cmtr) begin
			req_cmtr <= 1'b1;
			cmt_data <= tape_byte;
		end

		// key presses (a pending key request drops new ones)
		if (key_ev && kcode != 8'd0 && !(req_key1 | req_key2 | req_key3)) begin
			if (is_stop) begin
				if (cmt_open) begin req_key1 <= 1'b1; key_data <= 8'h03; end
				else begin req_key2 <= 1'b1; key_data <= 8'hfa; end
			end
			else if (on_graph || is_func) begin req_key2 <= 1'b1; key_data <= kcode; end
			else begin req_key3 <= 1'b1; key_data <= kcode; end
		end
		else if (inj_strobe && !(req_key1 | req_key2 | req_key3)) begin req_key3 <= 1'b1; key_data <= inj_code; end

		if (ce_cpu) begin
			// every 300 us, when idle, take the highest priority request
			chk_cnt <= chk_cnt == INTCHK - 1 ? 11'd0 : chk_cnt + 1'd1;
			if (chk_cnt == 0 && st == S_IDLE) begin
				ev_wait <= W_DATA;
				if (req_joy) begin st <= S_JOY; ev_wait <= W_DATA + W_JOY; ev_cnt <= W_DATA + W_JOY; ev_vec <= 1; end
				else if (req_key1) begin st <= S_KEY1; ev_cnt <= W_DATA; ev_vec <= 1; end
				else if (req_cmtr) begin st <= S_CMTR; ev_cnt <= W_DATA; ev_vec <= 1; end
				else if (req_cmte) begin st <= S_CMTE; ev_cnt <= W_DATA; ev_vec <= 1; end
				else if (req_key2) begin st <= S_KEY2; ev_cnt <= W_DATA; ev_vec <= 1; end
				else if (req_key3) begin st <= S_KEY3; ev_cnt <= W_DATA; ev_vec <= 1; end
			end

			if (ev_vec || ev_dat) begin
				if (ev_cnt > 1) ev_cnt <= ev_cnt - 1'd1;
				else if (ibf) ev_cnt <= ev_wait;          // port A still full: try again
				else if (ev_vec) begin
					ev_vec <= 1'b0;
					sub_wr <= 1'b1;
					irq_r <= 1'b1;
					case (st)
					S_JOY:  sub_wdata <= 8'h16;
					S_KEY1: begin sub_wdata <= 8'h0e; req_key1 <= 0; st <= S_IDLE; end
					S_CMTR: sub_wdata <= 8'h08;
					S_CMTE: begin sub_wdata <= 8'h12; req_cmte <= 0; st <= S_IDLE; end
					S_KEY2: sub_wdata <= 8'h14;
					default: sub_wdata <= 8'h02;
					endcase
					if (st != S_KEY1 && st != S_CMTE) begin ev_dat <= 1'b1; ev_cnt <= W_DATA; ev_wait <= W_DATA; end
				end
				else begin
					// the data is out: withdraw the request, for programs that poll with interrupts off (PC6001VX
					// SUB6::OutData). Left up, it is taken later, out of turn, and empties port A.
					ev_dat <= 1'b0;
					sub_wr <= 1'b1;
					irq_r <= 1'b0;
					st <= S_IDLE;
					case (st)
					S_JOY:  begin sub_wdata <= joy_code; req_joy <= 0; end
					S_CMTR: begin sub_wdata <= cmt_data; req_cmtr <= 0; end
					S_KEY2: begin sub_wdata <= key_data; req_key2 <= 0; end
					default: begin sub_wdata <= key_data; req_key3 <= 0; end
					endcase
				end
			end
		end
	end
end

endmodule
