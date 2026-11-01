// A .d88 disk image held in DDR3: read in whole from the SD image when Main mounts it (S0), served to the FDC a
// byte at a time, and written back to the image block by block after the FDC changes it.
//
// Up to 512 KB (a 1D disk is 174768 bytes, a 2D disk 348848). A larger image is not loaded (too_big). Writes go
// back unless Main mounted the image read-only or its D88 header says protected.
//
// SD blocks pass through a 512-byte buffer (64 words of 64 bits) on their way to or from DDR3. The FDC side is a
// request and a done pulse: a read's byte is in q at done, from the last word read when it is the same word.

module d88_media #(parameter int SIZE = 524288, parameter [28:0] BASE = 29'h06000000)   // bytes; DDR3 word address
(
	input             clk,
	input             reset,

	// hps_io, one virtual disk with 512-byte blocks
	input             img_mounted,
	input             img_readonly,
	input      [63:0] img_size,
	output reg [31:0] sd_lba,
	output reg        sd_rd = 0,
	output reg        sd_wr = 0,
	input             sd_ack,
	input       [8:0] sd_buff_addr,
	input       [7:0] sd_buff_dout,
	output      [7:0] sd_buff_din,
	input             sd_buff_wr,

	// the FDC: rd or we for one clk, then wait for done
	input      [19:0] addr,
	input             rd,
	input             we,
	input       [7:0] d,
	output reg  [7:0] q,
	output reg        done,

	output            ready,          // an image is loaded
	output            wprot,          // write protected (Main's read-only, or the D88 header)
	output reg        too_big = 0,

	// DDR3 (sys/ddr_svc style, 64-bit words)
	input             ddr_busy,
	output      [7:0] ddr_burstcnt,
	output reg [28:0] ddr_addr,
	input      [63:0] ddr_dout,
	input             ddr_dout_ready,
	output reg        ddr_rd = 0,
	output reg [63:0] ddr_din,
	output reg  [7:0] ddr_be,
	output reg        ddr_we = 0
);

localparam int NBLK = SIZE / 512;

assign ddr_burstcnt = 8'd1;

reg        loaded = 0, ro = 0, hdr_wp = 0;
reg [10:0] nblk;                  // blocks in the image
reg [10:0] blk;                   // block being loaded / written back
reg        old_ack;
reg  [NBLK-1:0] dirty = 0;
reg [10:0] scan;

assign ready = loaded;
assign wprot = ro | hdr_wp;

// the block buffer: the SD side writes bytes in order (gathered into words), DDR3 moves whole words
reg [63:0] bbuf[0:63];
reg [63:0] gather;
reg [63:0] bb_q;
reg  [2:0] sd_lane;
reg  [5:0] bw;                     // word being moved to / from DDR3
reg  [5:0] bb_wa;
reg [63:0] bb_wd;
reg        bb_we;
always @(posedge clk) begin
	if (sd_ack && sd_buff_wr) begin
		gather <= {sd_buff_dout, gather[63:8]};
		if (sd_buff_addr[2:0] == 3'd7) bbuf[sd_buff_addr[8:3]] <= {sd_buff_dout, gather[63:8]};
	end
	else if (bb_we) bbuf[bb_wa] <= bb_wd;
	bb_q <= bbuf[sd_ack && !sd_buff_wr ? sd_buff_addr[8:3] : bw];
	sd_lane <= sd_buff_addr[2:0];
end
assign sd_buff_din = bb_q[{sd_lane, 3'b000} +: 8];

// the word the FDC read last
reg [16:0] c_tag;
reg [63:0] c_word;
reg        c_ok = 0;

// FDC request, held until served
reg        f_rd = 0, f_we = 0;
reg [19:0] f_addr;
reg  [7:0] f_d;

localparam S_IDLE = 4'd0, S_LOAD = 4'd1, S_LOAD_OUT = 4'd2, S_LOAD_W = 4'd3, S_FRD = 4'd4, S_FWE = 4'd5,
           S_WB_IN = 4'd6, S_WB_R = 4'd7;
reg  [3:0] st = S_IDLE;
reg        out_rd;                 // S_LOAD_OUT: the buffer word is being read
reg        wb_sd = 0;              // a written-back block is going out to the SD image

always @(posedge clk) begin
	old_ack <= sd_ack;
	if (sd_ack) sd_wr <= 0;
	if (wb_sd && old_ack && !sd_ack) wb_sd <= 0;
	done <= 0;
	bb_we <= 0;
	if (!ddr_busy) begin ddr_rd <= 0; ddr_we <= 0; end

	if (rd) begin f_rd <= 1'b1; f_addr <= addr; end
	if (we) begin f_we <= 1'b1; f_addr <= addr; f_d <= d; end
	if (loaded && we && !wprot) dirty[addr[18:9]] <= 1'b1;

	if (reset) begin
		loaded <= 0; st <= S_IDLE; wb_sd <= 0;
		sd_rd <= 0; sd_wr <= 0; ddr_rd <= 0; ddr_we <= 0;
		dirty <= 0; c_ok <= 0; f_rd <= 0; f_we <= 0;
		too_big <= 0;
	end
	else if (img_mounted) begin
		loaded <= 0; st <= S_IDLE; wb_sd <= 0;
		sd_rd <= 0; sd_wr <= 0; ddr_rd <= 0; ddr_we <= 0;
		dirty <= 0; c_ok <= 0; f_rd <= 0; f_we <= 0;
		ro <= img_readonly;
		hdr_wp <= 0;
		too_big <= img_size > SIZE;
		nblk <= 11'((img_size + 511) >> 9);
		blk <= 0;
		if (img_size != 0 && img_size <= SIZE) begin
			st <= S_LOAD;
			sd_lba <= 0;
			sd_rd <= 1'b1;
		end
	end
	else case (st)
	// loading: a block from the SD image into the buffer, then its 64 words out to DDR3
	S_LOAD: begin
		if (sd_ack) sd_rd <= 1'b0;
		if (sd_ack && sd_buff_wr && blk == 0 && sd_buff_addr == 9'h01a) hdr_wp <= sd_buff_dout != 8'h00;
		if (old_ack && !sd_ack) begin st <= S_LOAD_OUT; bw <= 0; out_rd <= 1'b1; end
	end
	S_LOAD_OUT:
		if (out_rd) out_rd <= 0;                              // bb_q follows bw a clk later
		else if (!ddr_we || !ddr_busy) begin
			ddr_addr <= BASE + {blk, bw};
			ddr_din <= bb_q;
			ddr_be <= 8'hff;
			ddr_we <= 1'b1;
			st <= S_LOAD_W;
		end
	S_LOAD_W:
		if (!ddr_busy) begin
			if (bw != 6'd63) begin bw <= bw + 1'd1; out_rd <= 1'b1; st <= S_LOAD_OUT; end
			else if (blk + 1'd1 == nblk) begin loaded <= 1'b1; scan <= 0; st <= S_IDLE; end
			else begin
				blk <= blk + 1'd1;
				sd_lba <= 32'(blk + 1'd1);
				sd_rd <= 1'b1;
				st <= S_LOAD;
			end
		end

	S_IDLE:
		if (!loaded) begin
			if (f_rd || f_we) begin f_rd <= 0; f_we <= 0; q <= 8'hff; done <= 1'b1; end
		end
		else if (f_rd) begin
			if (c_ok && c_tag == f_addr[19:3]) begin
				f_rd <= 0;
				q <= c_word[{f_addr[2:0], 3'b000} +: 8];
				done <= 1'b1;
			end
			else begin
				ddr_addr <= BASE + 29'(f_addr[19:3]);
				ddr_rd <= 1'b1;
				st <= S_FRD;
			end
		end
		else if (f_we) begin
			if (!wprot) begin
				ddr_addr <= BASE + 29'(f_addr[19:3]);
				ddr_din <= {8{f_d}};
				ddr_be <= 8'h01 << f_addr[2:0];
				ddr_we <= 1'b1;
				if (c_tag == f_addr[19:3]) c_word[{f_addr[2:0], 3'b000} +: 8] <= f_d;
			end
			f_we <= 0;
			st <= S_FWE;
		end
		// write back: one dirty block at a time, scanning round (the buffer is the SD's until the last went out)
		else if (wb_sd) ;
		else if (scan < nblk && dirty[scan]) begin
			dirty[scan] <= 1'b0;        // a write while it goes out marks it again
			if (we && !wprot && addr[18:9] == scan[9:0]) dirty[scan] <= 1'b1;
			blk <= scan;
			bw <= 0;
			st <= S_WB_IN;
		end
		else scan <= scan + 1'd1 >= nblk ? 11'd0 : scan + 1'd1;

	S_FRD:
		if (ddr_dout_ready) begin
			c_tag <= f_addr[19:3]; c_word <= ddr_dout; c_ok <= 1'b1;
			q <= ddr_dout[{f_addr[2:0], 3'b000} +: 8];
			f_rd <= 0;
			done <= 1'b1;
			st <= S_IDLE;
		end
	S_FWE:
		if (!ddr_we || !ddr_busy) begin done <= 1'b1; st <= S_IDLE; end

	// write back: the block's 64 words from DDR3 into the buffer, then out to the SD image
	S_WB_IN:
		if (!ddr_rd || !ddr_busy) begin
			ddr_addr <= BASE + {blk, bw};
			ddr_rd <= 1'b1;
			st <= S_WB_R;
		end
	S_WB_R:
		if (ddr_dout_ready) begin
			bb_wd <= ddr_dout; bb_wa <= bw; bb_we <= 1'b1;
			if (bw != 6'd63) begin bw <= bw + 1'd1; st <= S_WB_IN; end
			else begin sd_lba <= 32'(blk); sd_wr <= 1'b1; wb_sd <= 1'b1; st <= S_IDLE; end
		end

	default: st <= S_IDLE;
	endcase
end

endmodule
