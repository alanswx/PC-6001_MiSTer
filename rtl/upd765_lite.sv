// uPD765 floppy controller, the commands the PC-80S31 / PC-6031 firmware (DISK.ROM) uses, on one drive whose disk
// is a .d88 image in RAM (rtl/d88_media.sv). Non-DMA mode: in the execution phase each data byte raises INT and
// waits for the CPU (no overrun); TC (the firmware reads port F8h) ends a transfer at the end of the sector.
//
// SPECIFY, SENSE DRIVE STATUS, RECALIBRATE, SEEK, SENSE INTERRUPT STATUS, READ DATA, WRITE DATA, READ ID and
// FORMAT A TRACK (on a track the image already has with that many sectors of that size); others are invalid.
// MT and SK are ignored; FM is not supported. Drives 1-3 are not connected: RECALIBRATE fails with an equipment
// check, as with no drive, so the firmware sees one drive.
//
// D88: the track table at 20h holds the offset of track cylinder*2+head (the head's position, not the command's
// C); each sector is a 16-byte header (C, H, R, N, sectors in the track, density, deleted, status, ..., data
// size at 14) and its data.

module upd765_lite
(
	input             clk,
	input             reset,

	input             a0,             // 0 main status, 1 data
	input             rd,             // one clk per access
	input             wr,
	input       [7:0] din,
	output      [7:0] dout,
	input             tc,             // one clk
	output            int_o,

	output reg [17:0] m_addr,
	input       [7:0] m_q,            // m_addr's byte, two clks after it is set
	output reg        m_we,
	output reg  [7:0] m_d,
	input             m_ready,
	input             m_wprot
);

localparam [12:0] T_BYTE = 13'd458;     // 16 us between data bytes
localparam [12:0] T_GAP  = 13'd5727;    // 200 us after a sector, for TC
localparam [15:0] T_SEEK = 16'd28636;   // 1 ms

// phases
localparam P_CMD = 2'd0, P_EXEC = 2'd1, P_RES = 2'd2;
reg  [1:0] phase;

reg  [7:0] cmd[0:8];
reg  [3:0] ncmd, cmd_len;
reg  [7:0] res[0:6];
reg  [2:0] nres, res_len;
reg        res_int;                // INT at the start of a result phase (read / write / ID / format)

reg  [5:0] pcn;                    // drive 0's cylinder
reg        seek_pend;
reg  [7:0] seek_st0, seek_pcn;
reg [15:0] seek_cnt;
reg        seeking;

wire [4:0] op = cmd[0][4:0];
wire [1:0] us = cmd[1][1:0];
wire       hd = cmd[1][2];
wire [7:0] hdus = {5'd0, cmd[1][2:0]};

function automatic [3:0] cmd_length(input [4:0] c);
	case (c)
	5'h03: cmd_length = 4'd3;       // specify
	5'h04: cmd_length = 4'd2;       // sense drive status
	5'h05, 5'h06, 5'h09, 5'h0c, 5'h11, 5'h19, 5'h1d: cmd_length = 4'd9;
	5'h07: cmd_length = 4'd2;       // recalibrate
	5'h08: cmd_length = 4'd1;       // sense interrupt status
	5'h0a: cmd_length = 4'd2;       // read ID
	5'h0d: cmd_length = 4'd6;       // format
	5'h0f: cmd_length = 4'd3;       // seek
	default: cmd_length = 4'd1;
	endcase
endfunction

// execution
localparam X_TRK = 4'd0, X_HDR = 4'd1, X_MATCH = 4'd2, X_DATA = 4'd3, X_GAP = 4'd4, X_FID = 4'd5,
           X_FILL = 4'd6, X_DONE = 4'd7;
reg  [3:0] xs;
reg  [2:0] bi;                     // byte index while reading the track table
reg  [3:0] hi;                     // header byte index
reg  [1:0] mw;                     // m_q wait
reg [17:0] toff, soff;             // track and sector offsets
reg  [7:0] h_c, h_h, h_r, h_n, h_dens, h_st;
reg [15:0] h_nsec, h_size;
reg [15:0] si;                     // sector index in the track
reg [15:0] di;                     // data byte index
reg  [7:0] r_cur;                  // the sector being transferred (READ / WRITE: R, R+1 ... EOT)
reg        drq;                    // a data byte is waiting for the CPU
reg  [7:0] dbuf;
reg [12:0] tmr;
reg        tc_seen;
reg  [7:0] st0, st1, st2;
reg  [7:0] fid[0:3];               // format: the sector ID the CPU sent
reg  [1:0] fi;

wire is_read  = op == 5'h06 || op == 5'h0c;
wire is_write = op == 5'h05 || op == 5'h09;
wire is_rid   = op == 5'h0a;
wire is_fmt   = op == 5'h0d;

wire rqm = phase == P_CMD || phase == P_RES || (phase == P_EXEC && drq);
wire dio = phase == P_RES || (phase == P_EXEC && is_read);
wire [7:0] msr = {rqm, dio, phase == P_EXEC, phase != P_CMD || ncmd != 0, 3'b000, seeking};

assign dout = a0 ? (phase == P_RES ? res[nres] : dbuf) : msr;
assign int_o = (phase == P_EXEC && drq) || res_int || seek_pend;

task automatic result7(input [7:0] s0, input [7:0] s1, input [7:0] s2, input [7:0] c, input [7:0] h,
                       input [7:0] r, input [7:0] n);
	res[0] <= s0; res[1] <= s1; res[2] <= s2; res[3] <= c; res[4] <= h; res[5] <= r; res[6] <= n;
	res_len <= 3'd7; nres <= 0; res_int <= 1'b1;
	phase <= P_RES;
endtask

always @(posedge clk) begin
	m_we <= 1'b0;
	if (reset) begin
		phase <= P_CMD;
		ncmd <= 0;
		res_int <= 0;
		pcn <= 0;
		seek_pend <= 0;
		seeking <= 0;
		drq <= 0;
	end
	else begin
		if (tc && phase == P_EXEC) tc_seen <= 1'b1;

		// a seek finishes after T_SEEK
		if (seeking) begin
			if (seek_cnt != 0) seek_cnt <= seek_cnt - 1'd1;
			else begin seeking <= 0; seek_pend <= 1'b1; end
		end

		case (phase)
		P_CMD:
			if (wr && a0) begin
				cmd[ncmd] <= din;
				if (ncmd == 0) cmd_len <= cmd_length(din[4:0]);
				if ((ncmd == 0 && cmd_length(din[4:0]) == 1) || (ncmd != 0 && ncmd + 1'd1 == cmd_len)) begin
					ncmd <= 0;
					phase <= P_EXEC;
					xs <= X_TRK; bi <= 0; mw <= 0;
					tc_seen <= 0; drq <= 0;
					st0 <= 0; st1 <= 0; st2 <= 0;
				end
				else ncmd <= ncmd + 1'd1;
			end

		P_RES:
			if (rd && a0) begin
				res_int <= 0;
				if (nres + 1'd1 == res_len) begin nres <= 0; phase <= P_CMD; end
				else nres <= nres + 1'd1;
			end

		P_EXEC:
			case (op)
			5'h03: phase <= P_CMD;                                   // specify: nothing to keep
			5'h04: begin                                             // sense drive status: ST3
				// a two-sided drive (TS): DISK.ROM waits for it before each transfer; the disk's sides are its own
				res[0] <= us == 0 ? {1'b0, m_wprot, 1'b1, pcn == 0, 1'b1, hd, us} : {5'd0, hd, us};
				res_len <= 3'd1; nres <= 0; phase <= P_RES;
			end
			5'h07, 5'h0f: begin                                      // recalibrate, seek
				if (us == 0) begin
					pcn <= op == 5'h07 ? 6'd0 : cmd[2][5:0];
					seek_st0 <= {8'h20 | {6'd0, us}};
					seek_pcn <= op == 5'h07 ? 8'd0 : cmd[2];
				end
				else begin
					seek_st0 <= op == 5'h07 ? 8'h70 | {6'd0, us} : 8'h68 | {6'd0, us};   // no drive
					seek_pcn <= 0;
				end
				seek_pend <= 0;
				seeking <= 1'b1; seek_cnt <= T_SEEK;
				phase <= P_CMD;
			end
			5'h08: begin                                             // sense interrupt status
				if (seek_pend) begin
					res[0] <= seek_st0; res[1] <= seek_pcn; res_len <= 3'd2;
					seek_pend <= 0;
				end
				else begin res[0] <= 8'h80; res_len <= 3'd1; end
				nres <= 0; phase <= P_RES;
			end
			default:
				if (!(is_read || is_write || is_rid || is_fmt)) begin   // invalid
					res[0] <= 8'h80; res_len <= 3'd1; nres <= 0; phase <= P_RES;
				end
				else if (us != 0 || !m_ready) begin
					result7(8'h48 | hdus, 8'h00, 8'h00, cmd[2], cmd[3], cmd[4], cmd[5]);   // not ready
				end
				else if ((is_write || is_fmt) && m_wprot) begin
					result7(8'h40 | hdus, 8'h02, 8'h00, cmd[2], cmd[3], cmd[4], cmd[5]);   // not writable
				end
				else case (xs)
				// the track's offset from the table at 20h
				X_TRK: begin
					m_addr <= 18'h20 + {pcn, hd, 2'b00} + bi;
					if (mw != 2) mw <= mw + 1'd1;
					else begin
						mw <= 0;
						case (bi)
						3'd0: toff[7:0]   <= m_q;
						3'd1: toff[15:8]  <= m_q;
						3'd2: toff[17:16] <= m_q[1:0];
						default: ;
						endcase
						if (bi == 3) begin
							soff <= {toff[17:16], toff[15:0]};
							si <= 0; hi <= 0;
							r_cur <= cmd[4];
							xs <= X_HDR;
						end
						bi <= bi + 1'd1;
					end
				end
				// the 16-byte header of sector si at soff
				X_HDR:
					if ({toff[17:16], toff[15:0]} == 0) begin
						result7(8'h40 | hdus, 8'h01, 8'h00, cmd[2], cmd[3], cmd[4], cmd[5]);   // no track
					end
					else begin
						m_addr <= soff + hi;
						if (mw != 2) mw <= mw + 1'd1;
						else begin
							mw <= 0;
							case (hi)
							4'd0: h_c <= m_q;
							4'd1: h_h <= m_q;
							4'd2: h_r <= m_q;
							4'd3: h_n <= m_q;
							4'd4: h_nsec[7:0] <= m_q;
							4'd5: h_nsec[15:8] <= m_q;
							4'd6: h_dens <= m_q;
							4'd8: h_st <= m_q;
							4'd14: h_size[7:0] <= m_q;
							4'd15: h_size[15:8] <= m_q;
							default: ;
							endcase
							hi <= hi + 1'd1;
							if (hi == 15) begin xs <= is_fmt ? X_FID : X_MATCH; fi <= 0; end
						end
					end
				X_MATCH:
					if (is_rid || (h_c == cmd[2] && h_h == cmd[3] && h_r == r_cur && h_n == cmd[5] && h_dens != 8'h40)) begin
						if (is_rid) begin
							result7(hdus, 8'h00, 8'h00, h_c, h_h, h_r, h_n);
						end
						else begin
							if (h_st != 0) begin st0 <= 8'h40; st1 <= 8'h20; st2 <= 8'h20; end   // data CRC error
							di <= 0; mw <= 0; drq <= 0;
							xs <= X_DATA;
							tmr <= 0;
						end
					end
					else if (si + 1'd1 >= h_nsec) begin
						result7(8'h40 | hdus, 8'h04, 8'h00, cmd[2], cmd[3], r_cur, cmd[5]);   // no data
					end
					else begin
						si <= si + 1'd1;
						soff <= soff + 18'd16 + h_size;
						hi <= 0;
						xs <= X_HDR;
					end
				// data bytes, one per CPU access
				X_DATA:
					if (is_read) begin
						if (!drq) begin
							if (tmr != 0) tmr <= tmr - 1'd1;
							else begin
								m_addr <= soff + 18'd16 + di;
								if (mw != 2) mw <= mw + 1'd1;
								else begin mw <= 0; dbuf <= m_q; drq <= 1'b1; end
							end
						end
						else if (rd && a0) begin
							drq <= 0;
							tmr <= T_BYTE;
							if (di + 1'd1 == h_size || tc_seen) begin xs <= X_GAP; tmr <= T_GAP; end
							di <= di + 1'd1;
						end
					end
					else begin
						if (!drq) begin
							if (tmr != 0) tmr <= tmr - 1'd1;
							else drq <= 1'b1;
						end
						else if (wr && a0) begin
							drq <= 0;
							m_addr <= soff + 18'd16 + di;
							m_d <= din; m_we <= 1'b1;
							tmr <= T_BYTE;
							if (di + 1'd1 == h_size || tc_seen) begin xs <= X_GAP; tmr <= T_GAP; end
							di <= di + 1'd1;
						end
					end
				// after a sector: TC ends the command; otherwise the next sector, up to EOT
				X_GAP:
					if (tc_seen || st0[6]) begin
						result7(st0 | hdus, st1, st2, cmd[2], cmd[3], r_cur + 1'd1, cmd[5]);
					end
					else if (tmr != 0) tmr <= tmr - 1'd1;
					else if (r_cur == cmd[6]) begin
						result7(8'h40 | hdus, 8'h80, 8'h00, cmd[2], cmd[3], r_cur, cmd[5]);   // end of cylinder
					end
					else begin
						r_cur <= r_cur + 1'd1;
						soff <= {toff[17:16], toff[15:0]};
						si <= 0; hi <= 0; mw <= 0;
						xs <= X_HDR;
					end
				// format: the CPU sends C, H, R, N for each sector; the sector keeps its place and size
				X_FID:
					if (si == 0 && (h_nsec != {8'd0, cmd[3]} || h_size != (16'd128 << cmd[2][2:0]))) begin
						result7(8'h40 | hdus, 8'h02, 8'h00, 8'd0, 8'd0, 8'd0, cmd[2]);   // not this geometry
					end
					else if (!drq) begin
						if (tmr != 0) tmr <= tmr - 1'd1;
						else drq <= 1'b1;
					end
					else if (wr && a0) begin
						drq <= 0;
						fid[fi] <= din;
						m_addr <= soff + fi;
						m_d <= din; m_we <= 1'b1;
						tmr <= T_BYTE;
						fi <= fi + 1'd1;
						if (fi == 3) begin di <= 0; xs <= X_FILL; end
					end
				X_FILL:
					if (di != h_size) begin
						m_addr <= soff + 18'd16 + di;
						m_d <= cmd[5]; m_we <= 1'b1;
						di <= di + 1'd1;
					end
					else if (si + 1'd1 == {8'd0, cmd[3]}) begin
						result7(hdus, 8'h00, 8'h00, fid[0], fid[1], fid[2], fid[3]);
					end
					else begin
						si <= si + 1'd1;
						soff <= soff + 18'd16 + h_size;
						hi <= 0; mw <= 0;
						xs <= X_HDR;
					end
				default: ;
				endcase
			endcase
		default: ;
		endcase
	end
end

endmodule
