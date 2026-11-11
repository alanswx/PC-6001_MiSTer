// Two .d88 disk images held in DDR3: each read in whole from its SD image when Main mounts it (S0, S1), served to
// the FDC a byte at a time, and written back to the image block by block after the FDC changes it.
//
// Up to 512 KB each (a 1D disk is 174768 bytes, a 1DD or 2D disk 348848). A larger image is not loaded (too_big).
// Writes go back unless Main mounted the image read-only or its D88 header says protected. Main does not let an
// image grow, so a write lands only within the file's size.
//
// SD blocks pass through a 512-byte buffer (64 words of 64 bits) on their way to or from DDR3. The FDC side is a
// request and a done pulse: a read's byte is in q at done, from the last word read when it is the same word. A
// mount waits for a transfer of the other drive's image to finish.

module d88_media #(parameter int SIZE = 524288, parameter [28:0] BASE = 29'h06000000)   // bytes; DDR3 word address
(
	input             clk,
	input             reset,

	// hps_io, two virtual disks with 512-byte blocks
	input       [1:0] img_mounted,
	input             img_readonly,
	input      [63:0] img_size,
	output reg [31:0] sd_lba,         // for both drives
	output reg  [1:0] sd_rd = 0,
	output reg  [1:0] sd_wr = 0,
	input       [1:0] sd_ack,
	input       [8:0] sd_buff_addr,
	input       [7:0] sd_buff_dout,
	output      [7:0] sd_buff_din,
	input             sd_buff_wr,

	// the FDC: rd or we for one clk, then wait for done
	input             drv,
	input      [19:0] addr,
	input             rd,
	input             we,
	input       [7:0] d,
	output reg  [7:0] q,
	output reg        done,

	output      [1:0] ready,          // an image is loaded
	output      [1:0] wprot,          // write protected (Main's read-only, or the D88 header)
	output      [1:0] one_side,       // the track table is indexed by cylinder (D88 media 30h 1D, 40h 1DD)
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

reg  [1:0] loaded = 0, ro = 0, hdr_wp = 0;
reg  [7:0] media[0:1];
reg [10:0] nblk[0:1];             // blocks in each image
reg  [1:0] pend = 0;              // mounted, waiting to load
reg [63:0] psize[0:1];
reg  [1:0] pro;
reg        cur;                   // the drive being loaded / written back
reg [10:0] blk;                   // block being loaded / written back
reg  [1:0] old_ack;
reg  [NBLK-1:0] dirty[0:1];
reg        sdrv;                  // write-back scan
reg [10:0] scan;

assign ready = loaded;
assign wprot = ro | hdr_wp;
assign one_side = {media[1] == 8'h30 || media[1] == 8'h40, media[0] == 8'h30 || media[0] == 8'h40};

wire ack = |sd_ack;

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
	if (ack && sd_buff_wr) begin
		gather <= {sd_buff_dout, gather[63:8]};
		if (sd_buff_addr[2:0] == 3'd7) bbuf[sd_buff_addr[8:3]] <= {sd_buff_dout, gather[63:8]};
	end
	else if (bb_we) bbuf[bb_wa] <= bb_wd;
	bb_q <= bbuf[ack && !sd_buff_wr ? sd_buff_addr[8:3] : bw];
	sd_lane <= sd_buff_addr[2:0];
end
assign sd_buff_din = bb_q[{sd_lane, 3'b000} +: 8];

// the word the FDC read last
reg [17:0] c_tag;
reg [63:0] c_word;
reg        c_ok = 0;

// FDC request, held until served
reg        f_rd = 0, f_we = 0;
reg        f_drv;
reg [19:0] f_addr;
reg  [7:0] f_d;

localparam S_IDLE = 4'd0, S_LOAD = 4'd1, S_LOAD_OUT = 4'd2, S_LOAD_W = 4'd3, S_FRD = 4'd4, S_FWE = 4'd5,
           S_WB_IN = 4'd6, S_WB_R = 4'd7;
reg  [3:0] st = S_IDLE;
reg        out_rd;                 // S_LOAD_OUT: the buffer word is being read
reg        wb_sd = 0;              // a written-back block is going out to the SD image
reg        cancel = 0;             // the image being moved was replaced: stop at the end of this word

wire [28:0] blk_word = BASE + {12'd0, cur, blk[9:0], bw};
wire [28:0] f_word   = BASE + {12'd0, f_drv, f_addr[18:3]};

always @(posedge clk) begin
	old_ack <= sd_ack;
	if (|sd_ack) sd_wr <= 0;
	if (wb_sd && |old_ack && !ack) wb_sd <= 0;
	done <= 0;
	bb_we <= 0;
	if (!ddr_busy) begin ddr_rd <= 0; ddr_we <= 0; end

	if (rd) begin f_rd <= 1'b1; f_addr <= addr; f_drv <= drv; end
	if (we) begin f_we <= 1'b1; f_addr <= addr; f_drv <= drv; f_d <= d; end
	if (loaded[drv] && we && !wprot[drv]) dirty[drv][addr[18:9]] <= 1'b1;

	if (reset) begin
		loaded <= 0; pend <= 0; st <= S_IDLE; wb_sd <= 0; cancel <= 0;
		sd_rd <= 0; sd_wr <= 0; ddr_rd <= 0; ddr_we <= 0;
		dirty[0] <= 0; dirty[1] <= 0; c_ok <= 0; f_rd <= 0; f_we <= 0;
		too_big <= 0;
	end
	else begin
		// a mount: the drive's old image is gone. Its load stops; a DDR3 transfer of it finishes first (cancel)
		for (int i = 0; i < 2; i++) if (img_mounted[i]) begin
			loaded[i] <= 0; dirty[i] <= 0; hdr_wp[i] <= 0; media[i] <= 0;
			pend[i] <= img_size != 0 && img_size <= SIZE;
			psize[i] <= img_size; pro[i] <= img_readonly;
			too_big <= img_size > SIZE;
			if (c_tag[17] == i[0]) c_ok <= 0;
			if (cur == i[0] && st == S_LOAD) begin st <= S_IDLE; sd_rd <= 0; end
			else if (cur == i[0] && (st == S_LOAD_OUT || st == S_LOAD_W || st == S_WB_IN || st == S_WB_R)) cancel <= 1'b1;
		end

		case (st)
		// loading: a block from the SD image into the buffer, then its 64 words out to DDR3
		S_LOAD: begin
			if (sd_ack[cur]) sd_rd[cur] <= 1'b0;
			if (sd_ack[cur] && sd_buff_wr && blk == 0 && sd_buff_addr == 9'h01a) hdr_wp[cur] <= sd_buff_dout != 8'h00;
			if (sd_ack[cur] && sd_buff_wr && blk == 0 && sd_buff_addr == 9'h01b) media[cur] <= sd_buff_dout;
			if (old_ack[cur] && !sd_ack[cur]) begin st <= S_LOAD_OUT; bw <= 0; out_rd <= 1'b1; end
		end
		S_LOAD_OUT:
			if (out_rd) out_rd <= 0;                              // bb_q follows bw a clk later
			else if (!ddr_we || !ddr_busy) begin
				ddr_addr <= blk_word;
				ddr_din <= bb_q;
				ddr_be <= 8'hff;
				ddr_we <= 1'b1;
				st <= S_LOAD_W;
			end
		S_LOAD_W:
			if (!ddr_busy) begin
				if (cancel || img_mounted[cur]) begin cancel <= 0; st <= S_IDLE; end
				else if (bw != 6'd63) begin bw <= bw + 1'd1; out_rd <= 1'b1; st <= S_LOAD_OUT; end
				else if (blk + 1'd1 == nblk[cur]) begin loaded[cur] <= 1'b1; scan <= 0; st <= S_IDLE; end
				else begin
					blk <= blk + 1'd1;
					sd_lba <= {21'd0, blk + 1'd1};
					sd_rd[cur] <= 1'b1;
					st <= S_LOAD;
				end
			end

		S_IDLE:
			// a mounted image loads once the SD side is free
			if (|pend && !wb_sd && !ack && !sd_rd && !sd_wr && !img_mounted) begin
				cur <= !pend[0];
				pend[!pend[0]] <= 0;
				ro[!pend[0]] <= pro[!pend[0]];
				nblk[!pend[0]] <= 11'((psize[!pend[0]] + 511) >> 9);
				blk <= 0;
				sd_lba <= 0;
				sd_rd[!pend[0]] <= 1'b1;
				st <= S_LOAD;
			end
			else if ((f_rd || f_we) && !loaded[f_drv]) begin f_rd <= 0; f_we <= 0; q <= 8'hff; done <= 1'b1; end
			else if (f_rd) begin
				if (c_ok && c_tag == {f_drv, f_addr[19:3]}) begin
					f_rd <= 0;
					q <= c_word[{f_addr[2:0], 3'b000} +: 8];
					done <= 1'b1;
				end
				else begin
					ddr_addr <= f_word;
					ddr_rd <= 1'b1;
					st <= S_FRD;
				end
			end
			else if (f_we) begin
				if (!wprot[f_drv]) begin
					ddr_addr <= f_word;
					ddr_din <= {8{f_d}};
					ddr_be <= 8'h01 << f_addr[2:0];
					ddr_we <= 1'b1;
					if (c_tag == {f_drv, f_addr[19:3]}) c_word[{f_addr[2:0], 3'b000} +: 8] <= f_d;
				end
				f_we <= 0;
				st <= S_FWE;
			end
			// write back: one dirty block at a time, scanning round both drives (the buffer is the SD's until the
			// last went out)
			else if (wb_sd) ;
			else if (loaded[sdrv] && scan < nblk[sdrv] && dirty[sdrv][scan[9:0]]) begin
				dirty[sdrv][scan[9:0]] <= 1'b0;        // a write while it goes out marks it again
				if (we && drv == sdrv && !wprot[drv] && addr[18:9] == scan[9:0]) dirty[sdrv][scan[9:0]] <= 1'b1;
				cur <= sdrv;
				blk <= scan;
				bw <= 0;
				st <= S_WB_IN;
			end
			else if (scan + 1'd1 >= nblk[sdrv] || !loaded[sdrv]) begin scan <= 0; sdrv <= !sdrv; end
			else scan <= scan + 1'd1;

		S_FRD:
			if (ddr_dout_ready) begin
				c_tag <= {f_drv, f_addr[19:3]}; c_word <= ddr_dout; c_ok <= 1'b1;
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
				ddr_addr <= blk_word;
				ddr_rd <= 1'b1;
				st <= S_WB_R;
			end
		S_WB_R:
			if (ddr_dout_ready) begin
				bb_wd <= ddr_dout; bb_wa <= bw; bb_we <= 1'b1;
				if (bw != 6'd63) begin bw <= bw + 1'd1; st <= S_WB_IN; end
				else if (cancel || img_mounted[cur]) begin cancel <= 0; st <= S_IDLE; end
				else begin sd_lba <= {21'd0, blk}; sd_wr[cur] <= 1'b1; wb_sd <= 1'b1; st <= S_IDLE; end
			end

		default: st <= S_IDLE;
		endcase
	end
end

endmodule
