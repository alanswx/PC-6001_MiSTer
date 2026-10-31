// A .d88 disk image held in block RAM: read in whole from the SD image when Main mounts it (S0), served to the
// FDC a byte at a time, and written back to the image block by block after the FDC changes it.
//
// 176 KB: a 1D disk (40 tracks x 16 x 256 bytes and the D88 headers, 174768 bytes) fits. A larger image is not
// loaded (too_big). Writes go back unless Main mounted the image read-only or its D88 header says protected.

module d88_media #(parameter int SIZE = 180224)    // bytes (352 blocks of 512)
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

	// the FDC: read data follows addr one clk later
	input      [17:0] addr,
	output      [7:0] q,
	input             we,
	input       [7:0] d,

	output            ready,          // an image is loaded
	output            wprot,          // write protected (Main's read-only, or the D88 header)
	output reg        too_big = 0
);

localparam int NBLK = SIZE / 512;

reg        loaded = 0, loading = 0, ro = 0, hdr_wp = 0;
reg  [8:0] nblk;                  // blocks in the image
reg  [8:0] blk;                   // block being loaded / written
reg        old_ack;
reg  [NBLK-1:0] dirty = 0;
reg  [8:0] scan;
reg        wb = 0;                // writing a block back

assign ready = loaded;
assign wprot = ro | hdr_wp;

// port A: the SD side (loading, write back); port B: the FDC
wire [17:0] sd_addr = {blk, sd_buff_addr};
wire        sd_we = loading && sd_ack && sd_buff_wr;
wire        fdc_we = we && loaded && !wprot;

dpram_tdp #(.WORDS(SIZE), .AW(18)) ram
(
	.clk(clk),
	.addr_a(sd_addr), .we_a(sd_we), .d_a(sd_buff_dout), .q_a(sd_buff_din),
	.addr_b(addr), .we_b(fdc_we), .d_b(d), .q_b(q)
);

always @(posedge clk) begin
	old_ack <= sd_ack;
	if (reset) begin
		loaded <= 0; loading <= 0; wb <= 0;
		sd_rd <= 0; sd_wr <= 0;
		dirty <= 0;
		too_big <= 0;
	end
	else if (img_mounted) begin
		loaded <= 0; loading <= 0; wb <= 0;
		sd_rd <= 0; sd_wr <= 0;
		dirty <= 0;
		ro <= img_readonly;
		hdr_wp <= 0;
		too_big <= img_size > SIZE;
		nblk <= 9'((img_size + 511) >> 9);
		blk <= 0;
		if (img_size != 0 && img_size <= SIZE) begin
			loading <= 1'b1;
			sd_lba <= 0;
			sd_rd <= 1'b1;
		end
	end
	else if (loading) begin
		if (sd_ack) sd_rd <= 1'b0;
		if (sd_ack && sd_buff_wr && blk == 0 && sd_buff_addr == 9'h01a) hdr_wp <= sd_buff_dout != 8'h00;
		if (old_ack && !sd_ack) begin
			if (blk + 1'd1 == nblk) begin
				loading <= 0;
				loaded <= 1'b1;
				scan <= 0;
			end
			else begin
				blk <= blk + 1'd1;
				sd_lba <= 32'(blk + 1'd1);
				sd_rd <= 1'b1;
			end
		end
	end
	else if (loaded) begin
		// write back: one dirty block at a time, scanning round
		if (we && !wprot) dirty[addr[17:9]] <= 1'b1;
		if (wb) begin
			if (sd_ack) sd_wr <= 1'b0;
			if (old_ack && !sd_ack) wb <= 0;
		end
		else if (scan < nblk && dirty[scan]) begin
			dirty[scan] <= 1'b0;        // a write while it goes out marks it again
			if (we && !wprot && addr[17:9] == scan) dirty[scan] <= 1'b1;
			blk <= scan;
			sd_lba <= 32'(scan);
			sd_wr <= 1'b1;
			wb <= 1'b1;
		end
		else scan <= scan + 1'd1 >= nblk ? 9'd0 : scan + 1'd1;
	end
end

endmodule
