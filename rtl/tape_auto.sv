//============================================================================
//  What to type for a tape, shown and (OSD Tape auto-start) typed.
//
//  Read from the image as it downloads:
//  - a BASIC header (ten D3h bytes, then a 6-character name) at its start: the tape is loaded with CLOAD
//  - the first program's start: its first line's link address less the line's length gives where BASIC kept the
//    text, which follows from the machine and mode it was saved on: C401h a 16 KB PC-6001 (mode 1), 8401h 32 KB
//    (mode 2), 8001h / 8801h / C801h N60m-BASIC (mode 5) with 2 / 3 / 4 pages (on the mkIISR 8001h is
//    N66SR-BASIC, mode 6)
//  - the highest page its SCREEN statements (token 9Fh) use: SCREEN mode,active page,display page
//  Against 404 tapes whose names give mode and pages, this gives the same mode and pages for 69% and more pages
//  for 14%. Pressing Return at "How Many Pages?" gives 4 pages, so more pages costs only free memory.
//
//  - a monitor tape: six 9Ch, 0Dh 0Ah, then Intel-hex-like text records (":LLAAAA00 data.. sum") that N60m-BASIC's MON
//    reads with R, ended by 1Ah. Mode 5 (4 pages), command MON then R0. Hudson Soft's loader (Babbulkund, Punch
//    Ball Mario Bros., Dezeni Land; 28 tapes here) loads over BASIC's stack: the word it writes at F89Fh replaces
//    the monitor's return address, so on a mkII without a disk unit the loader runs when R ends. A disk unit's
//    work area moves the stack (even with 0 files), and the monitor returns to READY; then "G" and that word,
//    typed after the load, starts it. Pages: 4, or what the loader checks (LD A,(FD8Ch) CP n: Enix's Zunou 4989
//    stops unless 3).
//
//  A .p6t's footer (P6T ver.2, PC6001VX p6t2.cpp) says it directly: BASIC mode, pages, and an auto-start flag
//  with the keys to type. Those win over the guesses (the G above is still added), except for a monitor tape
//  whose footer has no keys to type: its mode is then 5, whatever the footer says.
//
//  The key script is PC6001VX's (p6el.cpp EL6::SetAutoStart, GetAutoKey): a prefix that answers the BASIC menu
//  and "How Many Pages?" for the model, then the tape's command: its footer's, or CLOAD then RUN for a BASIC
//  tape. Codes: 17h n wait n frames, 0Ah Return then wait for the tape relay to close and open again, 0Dh
//  Return, 14h x GRAPH+x (skipped here). One key a frame, from 60 frames after a reset. Here a wait counts from
//  when the machine takes the key (a key typed before BASIC reads the keyboard waits in the sub CPU), and the
//  waits after the mode menu's answers are longer than PC6001VX's 30 frames: keys typed while N60m-BASIC starts
//  are lost. The first key also comes later: here the menu or "How Many Pages?" appears about 150 frames after
//  a reset, and a key typed much earlier than that is lost on the mkIISR.
//
//  Shown while the deck is stopped (the tape overlay): at the start of the tape the setup ("MODE 5  PAGES 3")
//  and "TYPE " the command up to its first 0Ah; after each stop of the motor the next part, until Return.
//
//  Typed (enable): mounting a tape with a command and a known setup resets the machine and types the script,
//  unless a program is waiting for the tape (the motor on, or the cassette open for loading): then the tape just
//  plays, as for a game's second tape. Any other reset with such a tape at its start types it too, as PC6001VX
//  does at power-on.
//============================================================================

module tape_auto
(
	input             clk,
	input             reset,          // the machine's reset (including auto_reset)
	input       [1:0] model,          // 0 PC-6001, 1 mkII, 2 PC-6601, 3 mkIISR
	input             ram16k,
	input             drives,         // a disk unit: modes 3-5 (and 6) ask "How Many Files?"
	input             enable,         // OSD Tape auto-start

	// the image as it downloads (addresses from 0, one after another)
	input             dl,
	input             wr,
	input      [16:0] addr,
	input       [7:0] data,
	input      [16:0] len,            // bytes downloaded

	// reading the image after the download (the footer)
	output reg        rd_busy,
	output reg [15:0] rd_addr,
	input       [7:0] rd_data,        // the byte at rd_addr, two clocks later
	output reg        img_len_set,    // a P6T: only its byte image plays
	output reg [15:0] img_len,

	input      [16:0] pos,            // tape position
	input             motor,
	input             cmt_open,
	input             vblank,
	input      [10:0] ps2_key,

	// typing (rtl/pc6001_sub.sv)
	input             inj_ready,
	output reg        inj_strobe,
	output reg  [7:0] inj_code,
	output reg        auto_reset,

	// the hint (rtl/tape_overlay.sv): two lines of 24 characters, the first in [383:376]; 01h is a Return sign
	output            hint_show,
	output            hint_two,
	output    [383:0] hint_text
);

//----------------------------------------------------------------------------
// While downloading: the BASIC header, the first program's start and its SCREEN pages
//----------------------------------------------------------------------------

reg        basic;                 // ten D3h bytes at the start
reg  [2:0] ps;                    // parse state
localparam P_SKIP = 3'd0, P_LINK1 = 3'd1, P_NUM0 = 3'd2, P_NUM1 = 3'd3, P_LINE1 = 3'd4, P_BODY = 3'd5,
           P_END = 3'd6;
reg [16:0] line_at;               // where the first line starts in the image
reg [15:0] link;
reg [15:0] text_start;
reg        have_start;
reg  [1:0] zrun;
reg  [2:0] ss;                    // SCREEN statement state
reg  [2:0] scr_pages;             // the highest page SCREEN names (1 if none)
reg [31:0] tail;                  // the last four bytes

// monitor tape records
reg        hex;                   // six 9Ch at the start, then a record
reg        h_in, h_lo, h_end;     // in a record, the low nibble is next, the records ended
reg  [3:0] h_hi;
reg  [8:0] h_i;                   // byte in the record: 0 length, 1-2 address, 3 type, then data
reg  [7:0] h_len;
reg [15:0] h_addr;
reg [15:0] ent;                   // the word written at F89Fh
reg  [1:0] ent_ok;
reg [31:0] h_win;                 // the last four data bytes
reg  [2:0] h_pages;               // a loader's page check (LD A,(FD8Ch) CP n), 0 if none
wire       h_dig = data >= "0" && data <= "9" || data >= "A" && data <= "F" || data >= "a" && data <= "f";
wire [3:0] h_nib = data <= "9" ? data[3:0] : data[3:0] + 4'd9;
wire [7:0] h_byte = {h_hi, h_nib};
wire [15:0] h_at = h_addr + 16'(h_i - 9'd4);

always @(posedge clk) begin
	if (dl && wr) begin
		tail <= {data, tail[31:8]};
		if (addr == 0) begin
			basic <= data == 8'hD3;
			hex <= data == 8'h9C;
			h_in <= 0; h_end <= 0; ent_ok <= 0; h_pages <= 0;
			ps <= P_SKIP; have_start <= 0; zrun <= 0; ss <= 0; scr_pages <= 3'd1;
		end
		else if (addr < 17'd10) begin
			if (data != 8'hD3) basic <= 1'b0;
			// six 9Ch, then the first record's line: 0Dh 0Ah ':'
			if (addr < 17'd6 ? data != 8'h9C : addr == 17'd6 ? data != 8'h0D : addr == 17'd7 ? data != 8'h0A :
			    addr == 17'd8 ? data != ":" : 1'b0) hex <= 1'b0;
		end
		else if (addr >= 17'd16 && basic) begin
			case (ps)
			P_SKIP:  if (data != 0) begin link[7:0] <= data; line_at <= addr; ps <= P_LINK1; end
			P_LINK1: begin link[15:8] <= data; ps <= P_NUM0; end
			P_NUM0:  ps <= P_NUM1;
			P_NUM1:  ps <= P_LINE1;
			P_LINE1: if (data == 0) begin
				// the line ends here: its length is addr + 1 - line_at
				text_start <= link - 16'(addr + 17'd1 - line_at);
				have_start <= 1'b1;
				zrun <= 2'd1;
				ps <= P_BODY;
			end
			else scan(data);
			P_BODY: begin
				// the program ends with a line's 00h and a zero link (three zeros)
				if (data == 0) begin zrun <= zrun + 1'd1; if (zrun == 2'd2) ps <= P_END; end
				else zrun <= 0;
				scan(data);
			end
			default: ;
			endcase
		end
		if (addr >= 17'd6 && hex && !h_end) begin
			if (data == ":") begin h_in <= 1'b1; h_lo <= 0; h_i <= 0; end
			else if (data == 8'h1A) h_end <= 1'b1;
			else if (h_in && h_dig) begin
				h_lo <= !h_lo;
				if (!h_lo) h_hi <= h_nib;
				else begin
					h_i <= h_i + 1'd1;
					case (h_i)
					9'd0: begin h_len <= h_byte; if (h_byte == 0) h_end <= 1'b1; end
					9'd1: h_addr[15:8] <= h_byte;
					9'd2: h_addr[7:0] <= h_byte;
					9'd3: ;
					default: if (h_i - 9'd4 < {1'b0, h_len}) begin
						h_win <= {h_win[23:0], h_byte};
						if (h_win == 32'h3A8CFDFE && h_byte >= 8'd1 && h_byte <= 8'd4) h_pages <= h_byte[2:0];
						if (h_at == 16'hF89F) begin ent[7:0] <= h_byte; ent_ok[0] <= 1'b1; end
						if (h_at == 16'hF8A0) begin ent[15:8] <= h_byte; ent_ok[1] <= 1'b1; end
					end
					endcase
				end
			end
			else h_in <= 1'b0;
		end
	end
end

// SCREEN a[,b[,c]] with digits 1-4: the pages b and c
task scan(input [7:0] c);
	if (c == 8'h9F) ss <= 3'd1;
	else if (c != " ") case (ss)
	3'd1: ss <= c >= "1" && c <= "4" ? 3'd2 : 3'd0;
	3'd2: ss <= c == "," ? 3'd3 : 3'd0;
	3'd3: begin
		if (c >= "1" && c <= "4") begin ss <= 3'd4; if (c[2:0] > scr_pages) scr_pages <= c[2:0]; end
		else ss <= 3'd0;
	end
	3'd4: ss <= c == "," ? 3'd5 : 3'd0;
	3'd5: begin
		if (c >= "1" && c <= "4" && c[2:0] > scr_pages) scr_pages <= c[2:0];
		ss <= 3'd0;
	end
	default: ;
	endcase
endtask

//----------------------------------------------------------------------------
// After the download: the P6T footer
//----------------------------------------------------------------------------

reg        old_dl;
reg  [2:0] fs;                    // footer state
localparam F_IDLE = 3'd0, F_ADDR = 3'd1, F_WAIT = 3'd2, F_TAKE = 3'd3, F_DONE = 3'd4;
reg  [6:0] fi;                    // footer byte index
reg        p6t, f_start;
reg  [7:0] f_basic, f_page;
reg [15:0] f_ask;
reg  [7:0] ask[0:63];
reg  [6:0] ask_len;
reg        info_new, info_done;   // one clk: a new tape's information is complete (info_done a clk later)

// the footer's last byte for us: not "P6", no command, the command's last byte (up to 64)
wire f_last = fi == 7'd0 && rd_data != "P" || fi == 7'd1 && rd_data != "6" ||
              fi == 7'd8 && {rd_data, f_ask[7:0]} == 0 || fi >= 7'd9 && ({9'd0, fi - 7'd8} == f_ask || fi == 7'd72);

always @(posedge clk) begin
	old_dl <= dl;
	img_len_set <= 1'b0;
	info_new <= 1'b0;
	info_done <= info_new;
	if (dl) begin
		fs <= F_IDLE; rd_busy <= 0; p6t <= 0; f_start <= 0; ask_len <= 0;
	end
	else if (old_dl) begin
		// the download just ended: a footer at the place the last four bytes give?
		if (len >= 17'd13 && tail[31:16] == 0 && tail[15:0] != 0 && {1'b0, tail[15:0]} + 17'd9 <= len) begin
			rd_addr <= tail[15:0]; rd_busy <= 1'b1; fi <= 0; fs <= F_WAIT;
		end
		else begin fs <= F_DONE; info_new <= 1'b1; end
	end
	else case (fs)
	F_ADDR: begin rd_addr <= rd_addr + 1'd1; fs <= F_WAIT; end
	F_WAIT: fs <= F_TAKE;
	F_TAKE: begin
		fi <= fi + 1'd1;
		case (fi)
		7'd1: if (rd_data == "6") begin p6t <= 1'b1; img_len_set <= 1'b1; img_len <= tail[15:0]; end
		7'd4: f_start <= rd_data != 0;
		7'd5: f_basic <= rd_data;
		7'd6: f_page <= rd_data;
		7'd7: f_ask[7:0] <= rd_data;
		7'd8: f_ask[15:8] <= rd_data;
		default: if (fi >= 7'd9) begin ask[6'(fi - 7'd9)] <= rd_data; ask_len <= fi - 7'd8; end
		endcase
		if (f_last) begin fs <= F_DONE; rd_busy <= 1'b0; info_new <= 1'b1; end
		else fs <= F_ADDR;
	end
	default: ;
	endcase
end

//----------------------------------------------------------------------------
// Mode, pages and the command
//----------------------------------------------------------------------------

// the guess from the first program
wire       g_m5  = text_start == 16'h8801 || text_start == 16'hC801 || (text_start == 16'h8001 && model != 2'd0);
wire [3:0] g_mode = !have_start ? 4'd0 :
                    text_start == 16'hC401 ? 4'd1 :
                    text_start == 16'h8401 || (text_start == 16'h8001 && model == 2'd0) ? 4'd2 :
                    text_start == 16'h8001 && model == 2'd3 ? 4'd6 :
                    g_m5 ? 4'd5 : 4'd0;
wire [2:0] g_min = text_start == 16'hC801 ? 3'd4 : text_start == 16'h8801 ? 3'd3 :
                   g_mode == 4'd5 || g_mode == 4'd2 ? 3'd2 : 3'd1;
wire [2:0] g_pages = scr_pages > g_min ? scr_pages : g_min;

// a monitor tape needs N60m-BASIC's MON (not the PC-6001's BASIC)
wire       mon   = hex && model != 2'd0;
// the footer's mode and pages, unless it is a monitor tape the footer gives no command for: MON is only in mode 5
// (Dr. Slump Bubble Daisakusen's footer: auto-start off, mode 2, 2 pages)
wire       use_f = p6t && f_basic != 0 && f_basic <= 8'd6 && f_page != 0 && f_page <= 8'd4 &&
                   !(mon && !(f_start && ask_len != 0));
wire [3:0] mode  = use_f ? f_basic[3:0] : mon ? 4'd5 : g_mode;
wire [2:0] pages = use_f ? f_page[2:0] : mon ? (h_pages != 0 ? h_pages : 3'd4) : g_pages;
wire       need32 = model == 2'd0 && have_start && text_start < 16'hC000 && !use_f;

// the command: the footer's, MON 0Dh R0 0Ah for a monitor tape, or CLOAD 0Ah RUN 0Dh for a BASIC tape; then
// with a disk unit and Hudson's loader: a wait, G and the word at F89Fh, 0Dh
wire       own_cmd = p6t && f_start && ask_len != 0;
wire       has_cmd = own_cmd || basic || mon;
wire       g_on    = mon && ent_ok == 2'b11 && drives;
wire [6:0] base_len = own_cmd ? ask_len : mon ? 7'd7 : 7'd10;
wire [6:0] cmd_len = base_len + (g_on ? 7'd8 : 7'd0);
function automatic [7:0] hx(input [3:0] n);
	hx = n < 4'd10 ? 8'h30 + n : 8'h37 + n;
endfunction
function automatic [7:0] cmd_at(input [6:0] i);
	if (i >= base_len) case (7'(i - base_len))
	7'd0: cmd_at = 8'h17; 7'd1: cmd_at = 8'd30; 7'd2: cmd_at = "G";
	7'd3: cmd_at = hx(ent[15:12]); 7'd4: cmd_at = hx(ent[11:8]); 7'd5: cmd_at = hx(ent[7:4]);
	7'd6: cmd_at = hx(ent[3:0]);
	default: cmd_at = 8'h0D;
	endcase
	else if (own_cmd) cmd_at = ask[i[5:0]];
	else if (mon) case (i)
	7'd0: cmd_at = "M"; 7'd1: cmd_at = "O"; 7'd2: cmd_at = "N"; 7'd3: cmd_at = 8'h0D;
	7'd4: cmd_at = "R"; 7'd5: cmd_at = "0"; default: cmd_at = 8'h0A;
	endcase
	else case (i)
	7'd0: cmd_at = "C"; 7'd1: cmd_at = "L"; 7'd2: cmd_at = "O"; 7'd3: cmd_at = "A"; 7'd4: cmd_at = "D";
	7'd5: cmd_at = 8'h0A; 7'd6: cmd_at = "R"; 7'd7: cmd_at = "U"; 7'd8: cmd_at = "N";
	default: cmd_at = 8'h0D;
	endcase
endfunction

// the prefix (PC6001VX EL6::SetAutoStart): {use, byte}
wire       files = drives && mode >= 4'd3;
wire       sr6 = model == 2'd3 && mode == 4'd6;
wire [7:0] pg = 8'h30 + pages;
wire [7:0] md = 8'h30 + mode;
function automatic [8:0] pre_at(input [3:0] i);
	if (model == 2'd0) case (i)
		4'd0: pre_at = {1'b1, 8'h17}; 4'd1: pre_at = {1'b1, 8'd100};
		4'd2: pre_at = {1'b1, pg};    4'd3: pre_at = {1'b1, 8'h0D};
		default: pre_at = 9'd0;
	endcase
	else if (sr6) case (i)
		4'd0: pre_at = {1'b1, 8'h17}; 4'd1: pre_at = {1'b1, 8'd120}; 4'd2: pre_at = {1'b1, md};
		4'd3: pre_at = {1'b1, 8'h17}; 4'd4: pre_at = {1'b1, 8'd100}; 4'd5: pre_at = {files, 8'h0D};
		4'd6: pre_at = {1'b1, 8'h17}; 4'd7: pre_at = {1'b1, 8'd60};
		default: pre_at = 9'd0;
	endcase
	else case (i)
		4'd0: pre_at = {1'b1, 8'h17}; 4'd1: pre_at = {1'b1, 8'd120}; 4'd2: pre_at = {1'b1, md};
		4'd3: pre_at = {1'b1, 8'h17}; 4'd4: pre_at = {1'b1, 8'd100};
		4'd5: pre_at = {files, 8'h0D}; 4'd6: pre_at = {files, 8'h17}; 4'd7: pre_at = {files, 8'd30};
		4'd8: pre_at = {1'b1, pg};    4'd9: pre_at = {1'b1, 8'h0D}; 4'd10: pre_at = {1'b1, 8'h17};
		4'd11: pre_at = {1'b1, mode >= 4'd3 ? (model == 2'd2 ? 8'd110 : 8'd120) : (model == 2'd2 ? 8'd10 : 8'd20)};
		default: pre_at = 9'd0;
	endcase
endfunction
wire [3:0] pre_len = model == 2'd0 ? 4'd4 : sr6 ? 4'd8 : 4'd12;

// typing needs the answers: the pages (the PC-6001) or the mode (the others; mode 6 only on the mkIISR)
wire known = model == 2'd0 ? pages != 0 : (mode != 0 && (mode != 4'd6 || model == 2'd3) && (sr6 || pages != 0));
// a monitor tape that does not start itself (no F89Fh word; its G address is unknown) is only shown
wire auto_ok = has_cmd && known && (own_cmd || !mon || ent_ok == 2'b11);

// synthesis translate_off
always @(posedge clk) if (info_done) $display("[tape_auto] hex %0d ent %h/%0d hpg %0d basic %0d start %h scr %0d p6t %0d fb %0d fp %0d st %0d ask %0d mode %0d pages %0d cmd %0d ok %0d", hex, ent, ent_ok, h_pages, basic, text_start, scr_pages, p6t, f_basic, f_page, f_start, ask_len, mode, pages, has_cmd, auto_ok);
// synthesis translate_on

//----------------------------------------------------------------------------
// Typing
//----------------------------------------------------------------------------

reg        old_reset, old_vb;
reg        typing;
reg  [7:0] ip;                    // script index: the prefix, then the command
reg  [8:0] twait;
reg        rel_on, rel_off;
reg        pend;                  // a typed key not taken yet
reg  [4:0] rst_cnt;
wire       frame = vblank && !old_vb;
wire [8:0] cur  = ip < pre_len ? pre_at(ip[3:0]) : {1'b1, cmd_at(7'(ip - pre_len))};
wire [7:0] nxt  = ip + 1'd1 < pre_len ? pre_at(4'(ip + 1'd1)) : cmd_at(7'(ip + 1'd1 - pre_len));
wire       at_end = ip >= pre_len + cmd_len;
wire [7:0] up = cur[7:0] >= "a" && cur[7:0] <= "z" ? cur[7:0] - 8'h20 : cur[7:0];

always @(posedge clk) begin
	old_reset <= reset;
	old_vb <= vblank;
	inj_strobe <= 1'b0;
	auto_reset <= rst_cnt != 0;
	if (rst_cnt != 0) rst_cnt <= rst_cnt - 1'd1;

	// a new tape: reset and type, unless a program waits for it
	if (info_done && enable && auto_ok && !motor && !cmt_open) rst_cnt <= 5'd31;
	if (dl) typing <= 1'b0;

	if (reset) typing <= 1'b0;
	else if (old_reset) begin
		// after a reset, a tape at its start that can be typed is
		if (enable && auto_ok && pos == 0 && fs == F_DONE) begin
			typing <= 1'b1; ip <= 0; twait <= 9'd60; rel_on <= 0; rel_off <= 0; pend <= 0;
		end
	end
	else if (typing && frame) begin
		if (pend) begin if (inj_ready) pend <= 1'b0; end
		else if (rel_on) begin if (motor) rel_on <= 1'b0; end
		else if (rel_off) begin if (!motor) rel_off <= 1'b0; end
		else if (twait != 0) twait <= twait - 1'd1;
		else if (at_end) typing <= 1'b0;
		else if (!cur[8]) ip <= ip + 1'd1;
		else case (cur[7:0])
		8'h17: begin twait <= {1'b0, nxt}; ip <= ip + 2'd2; end
		8'h14: ip <= ip + 2'd2;
		default: if (inj_ready) begin
			inj_strobe <= 1'b1;
			pend <= 1'b1;
			inj_code <= cur[7:0] == 8'h0A ? 8'h0D : up;
			ip <= ip + 1'd1;
			twait <= cur[7:0] == 8'h0A || cur[7:0] == 8'h0D ? 9'd9 : 9'd1;
			if (cur[7:0] == 8'h0A) begin rel_on <= 1'b1; rel_off <= 1'b1; end
		end
		endcase
	end
end

//----------------------------------------------------------------------------
// The hint
//----------------------------------------------------------------------------

// seg: which part of the command is next (0 at the start; one more at each stop of the motor). After a stop the
// hint shows until Return is pressed or typed.
reg  [3:0] seg;
reg        hide, old_motor, key_tgl;
always @(posedge clk) begin
	old_motor <= motor;
	key_tgl <= ps2_key[10];
	if (dl || pos == 0) begin seg <= 0; hide <= 0; end
	else if (old_motor && !motor) begin seg <= seg + 1'd1; hide <= 0; end
	if (motor) hide <= 1'b1;
	else if (seg != 0 && ((ps2_key[10] != key_tgl && ps2_key[9] && ps2_key[7:0] == 8'h5A) ||
	         (inj_strobe && inj_code == 8'h0D))) hide <= 1'b1;
end

// The text, rebuilt when what it says changes: line 1 the setup, line 2 "TYPE " and the command's part seg
reg  [7:0] l1[0:23], l2[0:23];
reg  [4:0] bi;                    // character being written
reg  [6:0] ci;                    // command byte being read
reg  [3:0] cs;                    // its part
reg  [1:0] bs;                    // 0 idle, 1 line 1, 2 line 2
reg        seg_ok;                // the part exists
reg [19:0] key, built;
wire [19:0] key_now = {seg, mode, pages, has_cmd, own_cmd, model, need32 & ram16k, fs == F_DONE, basic, mon, g_on};
wire  [3:0] kseg = key[19:16];   // the part being written

// line 1: "PAGES 2", "MODE 5  PAGES 3", "MODE 6", and "  32 KB" when a 16 KB PC-6001 needs 32 KB
function automatic [7:0] l1_at(input [4:0] i);
	reg [7:0] c;
	c = " ";
	if (model == 2'd0) begin
		case (i)
		5'd0: c = "P"; 5'd1: c = "A"; 5'd2: c = "G"; 5'd3: c = "E"; 5'd4: c = "S"; 5'd6: c = pg;
		5'd9: c = need32 && ram16k ? "3" : " "; 5'd10: c = need32 && ram16k ? "2" : " ";
		5'd12: c = need32 && ram16k ? "K" : " "; 5'd13: c = need32 && ram16k ? "B" : " ";
		default: ;
		endcase
	end
	else begin
		case (i)
		5'd0: c = "M"; 5'd1: c = "O"; 5'd2: c = "D"; 5'd3: c = "E"; 5'd5: c = md;
		default: ;
		endcase
		if (!sr6) case (i)
		5'd8: c = "P"; 5'd9: c = "A"; 5'd10: c = "G"; 5'd11: c = "E"; 5'd12: c = "S"; 5'd14: c = pg;
		default: ;
		endcase
	end
	l1_at = c;
endfunction
wire l1_on = model == 2'd0 ? pages != 0 : mode != 0;

always @(posedge clk) begin
	case (bs)
	2'd0: if (key_now != built) begin
		key <= key_now;
		bs <= 2'd1; bi <= 0;
	end
	2'd1: begin
		l1[bi] <= l1_on ? l1_at(bi) : " ";
		bi <= bi + 1'd1;
		if (bi == 5'd23) begin
			bs <= 2'd2; bi <= 0; ci <= 0; cs <= 0; seg_ok <= 0;
		end
	end
	2'd2: begin
		// "TYPE ", then part seg of the command: Return (0Dh, 0Ah) as a sign and a space, waits and GRAPH skipped
		if (bi < 5'd5) begin
			l2[bi] <= bi == 0 ? "T" : bi == 1 ? "Y" : bi == 2 ? "P" : bi == 3 ? "E" : " ";
			bi <= bi + 1'd1;
		end
		else if (bi >= 5'd24) begin bs <= 0; built <= key; end
		else if (ci >= cmd_len || cs > kseg) begin l2[bi] <= " "; bi <= bi + 1'd1; end
		else begin
			ci <= ci + 1'd1;
			if (cs == kseg) seg_ok <= 1'b1;
			case (cmd_at(ci))
			8'h17, 8'h14: ci <= ci + 2'd2;
			8'h0A, 8'h0D: begin
				if (cs == kseg) begin
					l2[bi] <= 8'h01; bi <= bi + 1'd1;
					if (bi != 5'd23) begin l2[bi + 1'd1] <= " "; bi <= bi + 2'd2; end
				end
				if (cmd_at(ci) == 8'h0A) cs <= cs + 1'd1;
			end
			default: if (cs == kseg) begin
				l2[bi] <= cmd_at(ci) >= "a" && cmd_at(ci) <= "z" ? cmd_at(ci) - 8'h20 : cmd_at(ci);
				bi <= bi + 1'd1;
			end
			endcase
		end
	end
	default: ;
	endcase
	// a key change restarts the text
	if (bs != 0 && key_now != key) bs <= 0;
end

wire ready = bs == 0 && built == key_now;
assign hint_show = ready && fs == F_DONE && has_cmd && seg_ok && !motor && (seg == 0 ? pos == 0 : !hide);
assign hint_two  = seg == 0 && l1_on;

genvar g;
generate
	for (g = 0; g < 24; g = g + 1) begin : txt
		assign hint_text[383 - 8 * g -: 8] = hint_two ? l1[g] : l2[g];
		assign hint_text[191 - 8 * g -: 8] = l2[g];
	end
endgenerate

endmodule
