// uPD7752 voice synthesiser (the PC-6001mkII's, ports E0h-E3h), after PC6001VX: the host side is voice.cpp (VCE6)
// and the synthesis is cisc's "uPD7752 flavoured" engine (device/pd7752.cpp, Copyright (c) 2004 cisc; this is a
// hardware rewrite of it, not the original). Only external phrases are made: TALK sends 7 parameter bytes a
// frame to E0h (command FEh). The chip's own phrases (commands 0-4) need recordings PC6001VX loads from WAV
// files; here they stay silent. With the same noise bits, the samples are those of the C engine, bit for bit.
//
//   E0h write: parameters; read: status b7 BSY, b6 REQ (wants the next frame), b5 EXT, b4 ERR
//   E2h write: mode (b2 20 ms frames, b1-0 speed): starts the synthesiser; E3h write: command
//
// Frames are 80-240 samples at 10 kHz. At each frame boundary the waiting parameters become the next frame's
// targets; the frame's samples move every coefficient linearly from where it is to there. A sample is a pulse
// (voiced) and/or noise, through five second-order filters with PC6001VX's coefficient tables, one multiplier
// used in turn. Integer division rounds toward zero, as in the C original.

module upd7752
(
	input                clk,          // 28.636 MHz
	input                reset,

	input          [1:0] addr,
	input                rd,
	input                wr,
	input          [7:0] din,
	output reg     [7:0] dout,

	output reg signed [13:0] sample     // 10 kHz
);

//----------------------------------------------------------------------------
// tables (pd7752.cpp)
//----------------------------------------------------------------------------

function automatic [6:0] amp_tbl(input [3:0] i);
	case (i)
	4'd0: amp_tbl = 0;  4'd1: amp_tbl = 1;  4'd2: amp_tbl = 1;  4'd3: amp_tbl = 2;
	4'd4: amp_tbl = 3;  4'd5: amp_tbl = 4;  4'd6: amp_tbl = 5;  4'd7: amp_tbl = 7;
	4'd8: amp_tbl = 9;  4'd9: amp_tbl = 13; 4'd10: amp_tbl = 17; 4'd11: amp_tbl = 23;
	4'd12: amp_tbl = 31; 4'd13: amp_tbl = 42; 4'd14: amp_tbl = 56; default: amp_tbl = 75;
	endcase
endfunction

reg signed [15:0] iir1[0:127];
reg signed [15:0] iir2[0:63];
initial begin
	iir1 = '{
	 11424, 11400, 11377, 11331, 11285, 11265, 11195, 11149, 11082, 11014, 10922, 10830, 10741, 10629, 10491, 10332,
	 10172,  9992,  9788,  9560,  9311,  9037,  8721,  8377,  8016,  7631,  7199,  6720,  6245,  5721,  5197,  4654,
	-11245,-11200,-11131,-11064,-10995,-10905,-10813,-10700,-10585,-10447,-10291,-10108, -9924, -9722, -9470, -9223,
	 -8928, -8609, -8247, -7881, -7472, -7019, -6566, -6068, -5545, -4999, -4452, -3902, -3363, -2844, -2316, -1864,
	 11585, 11561, 11561, 11561, 11561, 11540, 11540, 11540, 11515, 11515, 11494, 11470, 11470, 11448, 11424, 11400,
	 11377, 11356, 11307, 11285, 11241, 11195, 11149, 11082, 11014, 10943, 10874, 10784, 10695, 10583, 10468, 10332,
	 10193, 10013,  9833,  9628,  9399,  9155,  8876,  8584,  8218,  7857,  7445,  6970,  6472,  5925,  5314,  4654,
	  3948,  3178,  2312,  1429,   450,  -543, -1614, -2729, -3883, -5066, -6250, -7404, -8500, -9497,-10359,-11038};
	iir2 = '{
	  8192,  8105,  7989,  7844,  7670,  7424,  7158,  6803,  6370,  5860,  5252,  4579,  3824,  3057,  2307,  1623,
	  8193,  8100,  7990,  7844,  7672,  7423,  7158,  6802,  6371,  5857,  5253,  4576,  3825,  3057,  2309,  1617,
	 -6739, -6476, -6141, -5738, -5225, -4604, -3872, -2975, -1930,  -706,   686,  2224,  3871,  5518,  6992,  8085,
	 -6746, -6481, -6140, -5738, -5228, -4602, -3873, -2972, -1931,  -705,   685,  2228,  3870,  5516,  6993,  8084};
end

//----------------------------------------------------------------------------
// 10 kHz
//----------------------------------------------------------------------------

reg [24:0] tacc = 0;
reg        tick = 0;
always @(posedge clk) begin
	if (tacc + 25'd10000 >= 25'd28636364) begin tacc <= tacc + 25'd10000 - 25'd28636364; tick <= 1'b1; end
	else begin tacc <= tacc + 25'd10000; tick <= 1'b0; end
end

//----------------------------------------------------------------------------
// host side (VCE6)
//----------------------------------------------------------------------------

localparam BSY = 3, REQ = 2, EXT = 1, ERR = 0;   // vstat bits = status b7-b4
reg  [3:0] vstat;
reg  [7:0] io_e2, io_e3;
reg  [7:0] pbuf[0:6];
reg  [2:0] pnum;
reg  [4:0] fnum;
reg        pready;
reg        running;                  // frame boundaries are being counted (command FEh)
reg  [7:0] fsize;                    // samples a frame
reg  [7:0] fpos;                     // sample within the frame: a boundary on the tick it is 0
reg        tick_d, pend;             // a sample is due (a clk after the tick, so a boundary's set-up starts first)

always @(*) case (addr)
	2'd0: dout = {vstat, 4'd0};
	2'd2: dout = io_e2;
	2'd3: dout = io_e3;
	default: dout = 8'hff;
endcase

// fixed point 16.16, as the original
reg signed [31:0] cf[0:4], cb[0:4], camp, cpitch;      // current
reg signed [31:0] nf[0:4], nb[0:4], namp, npitch;      // the frame's targets
reg signed [31:0] df[0:4], db[0:4], damp, dpitch;      // per sample
reg signed [13:0] y0[0:4], y1[0:4];
reg        [8:0] pcount;
reg        [1:0] vu;
reg              playing;            // a frame's samples are going out

function automatic signed [31:0] i2f(input signed [15:0] a); i2f = {a, 16'd0}; endfunction
function automatic signed [15:0] f2i(input signed [31:0] a); f2i = a[31:16]; endfunction

// frame set-up: targets from the parameters, then 12 divisions by the frame size
reg        setup;                    // working on it
reg  [3:0] sidx;                     // 0-4 f, 5-9 b, 10 amp, 11 pitch
reg  [5:0] dstep;
reg [31:0] dnum, dquo, drem;         // magnitude division
reg        dneg;

wire       qmag = pbuf[0][2];
function automatic signed [31:0] fdelta(input [7:0] p, input q);   // f: bits 7-3, signed
	reg signed [5:0] v;
	v = {p[7], p[7:3]};
	fdelta = i2f(16'(v) <<< q);
endfunction
function automatic signed [31:0] bdelta(input [7:0] p, input q);   // b: bits 2-0, signed
	reg signed [3:0] v;
	v = {p[2], p[2:0]};
	bdelta = i2f(16'(v) <<< q);
endfunction

reg signed [31:0] diff;
always @(*) begin
	if (sidx < 5) diff = nf[sidx[2:0]] - cf[sidx[2:0]];
	else if (sidx < 10) diff = nb[sidx - 4'd5] - cb[sidx - 4'd5];
	else if (sidx == 10) diff = namp - camp;
	else diff = npitch - cpitch;
end

// sample engine
localparam E_IDLE = 4'd0, E_SRC = 4'd1, E_M1 = 4'd2, E_M2 = 4'd3, E_M3 = 4'd4, E_STEP = 4'd5;
reg  [3:0] es;
reg  [2:0] j;
reg signed [15:0] ma, mb;
wire signed [31:0] mp = ma * mb;
// C's x / 8192 (toward zero)
function automatic signed [31:0] d8k(input signed [31:0] x);
	d8k = (x + (x < 0 ? 32'sd8191 : 32'sd0)) >>> 13;
endfunction
reg signed [31:0] y, t;
reg [15:0] lfsr = 16'hace1;

integer i;

always @(posedge clk) begin
	if (reset) begin
		vstat <= 4'd0; pnum <= 0; fnum <= 0; pready <= 0; running <= 0; playing <= 0; setup <= 0;
		es <= E_IDLE; fsize <= 8'd100; fpos <= 0; sample <= 0; io_e2 <= 0; io_e3 <= 0; pend <= 0;
	end
	else begin
		// E2h: mode, the synthesiser restarts (cD7752::Start)
		if (wr && addr == 2'd2) begin
			io_e2 <= din;
			case (din[2:0])
				3'd1: fsize <= 8'd120;  3'd2: fsize <= 8'd80;
				3'd4: fsize <= 8'd200;  3'd5: fsize <= 8'd240;  3'd6: fsize <= 8'd160;  3'd7: fsize <= 8'd200;
				default: fsize <= 8'd100;
			endcase
			cf[0] <= i2f(126); cf[1] <= i2f(64); cf[2] <= i2f(121); cf[3] <= i2f(111); cf[4] <= i2f(96);
			cb[0] <= i2f(9);   cb[1] <= i2f(4);  cb[2] <= i2f(9);   cb[3] <= i2f(9);   cb[4] <= i2f(11);
			for (i = 0; i < 5; i = i + 1) begin y0[i] <= 0; y1[i] <= 0; end
			pcount <= 0; camp <= 0; cpitch <= i2f(30);
			vstat <= 4'd0;
		end
		// E3h: command; whatever was speaking stops (AbortVoice)
		if (wr && addr == 2'd3) begin
			io_e3 <= din;
			running <= 0; pnum <= 0; fnum <= 0; pready <= 0;
			vstat[BSY] <= 1'b0;
			if (din == 8'hfe) begin
				running <= 1'b1; fpos <= 8'd1;        // the first boundary a frame from now
				vstat <= 4'b1110;                     // BSY EXT REQ
			end
			else if (din > 8'h04 && din != 8'hff) vstat <= 4'b0001;   // ERR
		end
		// E0h: parameters (VSetData)
		if (wr && addr == 2'd0 && vstat[BSY] && vstat[REQ]) begin
			if (fnum == 0 || pnum != 0) begin
				if (pnum == 0) fnum <= din[7:3];
				pbuf[pnum] <= din;
				if (pnum == 3'd6) begin
					vstat[REQ] <= 1'b0; pnum <= 0; pready <= 1'b1;
					if (fnum != 0) fnum <= fnum - 1'd1;
				end
				else pnum <= pnum + 1'd1;
			end
			else begin                                  // a repeated frame: only amplitude and pitch
				for (i = 1; i < 6; i = i + 1) pbuf[i] <= 8'd0;
				pbuf[6] <= din;
				vstat[REQ] <= 1'b0; pnum <= 0; fnum <= fnum - 1'd1; pready <= 1'b1;
			end
		end

		// frame boundaries (EID_FRAME), counted in samples
		if (tick && running) begin
			fpos <= fpos + 1'd1 >= fsize ? 8'd0 : fpos + 1'd1;
			if (fpos == 0) begin
				// the frame just played ends exactly on its targets
				if (playing) begin
					for (i = 0; i < 5; i = i + 1) begin cf[i] <= nf[i]; cb[i] <= nb[i]; end
					camp <= namp; cpitch <= npitch;
				end
				playing <= 0;
				if (pready) begin
					if (pbuf[0][7:3] == 0) begin                 // no frames: done
						running <= 0; pnum <= 0; fnum <= 0; pready <= 0; vstat[BSY] <= 1'b0;
					end
					else begin
						setup <= 1'b1; sidx <= 0; dstep <= 0;
						pready <= 0; vstat[REQ] <= 1'b1;
					end
				end
				else begin
					running <= 0; pnum <= 0; fnum <= 0; vstat <= 4'b0001;   // ERR
				end
			end
		end

		// set-up: targets, then (target - current) / frame size for each of the 12
		if (setup) begin
			if (sidx == 0 && dstep == 0) begin
				for (i = 0; i < 5; i = i + 1) begin
					nf[i] <= cf[i] + fdelta(pbuf[i + 1], qmag);
					nb[i] <= cb[i] + bdelta(pbuf[i + 1], qmag);
				end
				namp <= i2f({12'd0, pbuf[6][7:4]});
				npitch <= cpitch + i2f(16'(signed'({pbuf[6][2], pbuf[6][2:0]})));
				vu <= (pbuf[0][0] ? 2'd1 : 2'd2) | (pbuf[6][2] ? 2'd3 : 2'd0);
				dstep <= 1;
			end
			else if (dstep == 1) begin
				dneg <= diff < 0;
				dnum <= diff < 0 ? -diff : diff;
				dquo <= 0; drem <= 0;
				dstep <= 2;
			end
			else if (dstep < 34) begin                         // 32 steps of restoring division
				if ({drem[30:0], dnum[31]} >= {24'd0, fsize}) begin
					drem <= {drem[30:0], dnum[31]} - {24'd0, fsize};
					dquo <= {dquo[30:0], 1'b1};
				end
				else begin
					drem <= {drem[30:0], dnum[31]};
					dquo <= {dquo[30:0], 1'b0};
				end
				dnum <= {dnum[30:0], 1'b0};
				dstep <= dstep + 1'd1;
			end
			else begin
				if (sidx < 5) df[sidx[2:0]] <= dneg ? -dquo : dquo;
				else if (sidx < 10) db[sidx - 4'd5] <= dneg ? -dquo : dquo;
				else if (sidx == 10) damp <= dneg ? -dquo : dquo;
				else dpitch <= dneg ? -dquo : dquo;
				if (sidx == 11) begin setup <= 0; playing <= 1'b1; end
				sidx <= sidx + 1'd1;
				dstep <= 1;
			end
		end

		// one sample on each tick of a frame being played, once its set-up is done
		tick_d <= tick;
		if (tick_d) pend <= 1'b1;
		case (es)
		E_IDLE:
			if (pend && !setup) begin
				pend <= 0;
				if (playing) es <= E_SRC;
				else sample <= 0;
			end
		E_SRC: begin
			// the pulse, then the noise (rand() & 1: an LFSR bit here)
			y = 0;
			if ({7'd0, pcount} > (f2i(cpitch) > 0 ? {16'd0, f2i(cpitch)} : 32'd128)) begin
				if (vu[0]) y = $signed({1'b0, amp_tbl(camp[19:16]), 4'd0}) - 1;
				pcount <= 9'd1;
			end
			else pcount <= pcount + 1'd1;
			lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
			if (vu[1] && lfsr[0]) y = y + $signed({1'b0, amp_tbl(camp[19:16]), 2'd0}) - 1;
			j <= 0;
			ma <= y0[0]; mb <= iir1[cf[0][22:16]];
			es <= E_M1;
		end
		E_M1: begin                                   // t = y0 * iir1[f] / 8192
			t = d8k(mp);
			ma <= t[15:0]; mb <= iir1[{cb[j][21:16], 1'b1}];
			es <= E_M2;
		end
		E_M2: begin                                   // y += t * iir1[b * 2 + 1] / 8192
			y = y + d8k(mp);
			ma <= y1[j]; mb <= iir2[cb[j][21:16]];
			es <= E_M3;
		end
		E_M3: begin                                   // y -= y1 * iir2[b] / 8192, clipped to 14 bits
			y = y - d8k(mp);
			y = y > 8191 ? 32'sd8191 : y < -8192 ? -32'sd8192 : y;
			y1[j] <= y0[j];
			y0[j] <= y[13:0];
			if (j == 3'd4) es <= E_STEP;
			else begin
				j <= j + 1'd1;
				ma <= y0[j + 1'd1]; mb <= iir1[cf[j + 1'd1][22:16]];
				es <= E_M1;
			end
		end
		E_STEP: begin
			sample <= y[13:0];
			for (i = 0; i < 5; i = i + 1) begin cf[i] <= cf[i] + df[i]; cb[i] <= cb[i] + db[i]; end
			camp <= camp + damp; cpitch <= cpitch + dpitch;
			es <= E_IDLE;
		end
		default: es <= E_IDLE;
		endcase
	end
end

endmodule
