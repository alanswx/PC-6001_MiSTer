// The mkII's and the PC-6601's ROMs: Main loads boot1.rom and boot2.rom (ioctl index 40h, 80h) once, at the
// core's start, but OSD Model can change at any reset. Both are kept in DDR3 as they come, and at the end of
// every reset (and of their downloads) the current model's 96 KB is copied into the core's ROM (rom62 in
// rtl/pc6001.sv), the machine held in reset meanwhile (busy; about 10 ms).
//
// DDR3 (64-bit words): set n at BASE + n x 4000h words, the byte at ioctl address a in word a / 8, lane a % 8.

module rom_store #(parameter [28:0] BASE = 29'h06020000)   // past the disk image's 512 KB (rtl/d88_media.sv)
(
	input             clk,
	input             reset,          // the machine's reset: a copy follows its end
	input       [1:0] model,          // 1 the mkII (set 0), 2 the PC-6601 (set 1)

	input             ioctl_download,
	input       [7:0] ioctl_index,
	input             ioctl_wr,
	input      [24:0] ioctl_addr,
	input       [7:0] ioctl_dout,
	output            ioctl_wait,

	output            busy,
	output reg [16:0] rom_a,
	output reg  [7:0] rom_d,
	output reg        rom_we = 0,

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

localparam [13:0] WORDS = 14'd12288;     // 96 KB

assign ddr_burstcnt = 8'd1;

wire       dl_set = ioctl_index == 8'h80;
wire       dl_ours = ioctl_index == 8'h40 || ioctl_index == 8'h80;
wire       cur_set = model == 2'd2;

// downloads: each byte goes to DDR3 with its byte enable; the download waits while one is going out
reg        wr_pend = 0;
assign ioctl_wait = wr_pend;

reg        reset_d = 0, dl_d = 0, copy_req = 0;
reg        copying = 0, rd_wait = 0;
reg [13:0] word;
reg  [2:0] lane;
reg [63:0] data;
reg        have = 0;                      // data holds a word still being copied out

assign busy = copying | copy_req;

always @(posedge clk) begin
	reset_d <= reset;
	dl_d <= ioctl_download && dl_ours;
	rom_we <= 0;
	if (!ddr_busy) begin ddr_rd <= 0; ddr_we <= 0; end

	// a copy after each reset, and after a download of the current model's set
	if ((reset_d && !reset) || (dl_d && !(ioctl_download && dl_ours))) copy_req <= model != 2'd0;

	if (ioctl_download && ioctl_wr && dl_ours && ioctl_addr[24:17] == 0) begin
		ddr_addr <= BASE + {14'd0, dl_set, ioctl_addr[16:3]};
		ddr_din <= {8{ioctl_dout}};
		ddr_be <= 8'h01 << ioctl_addr[2:0];
		ddr_we <= 1'b1;
		wr_pend <= 1'b1;
	end
	else if (wr_pend && (!ddr_we || !ddr_busy)) wr_pend <= 0;

	if (copy_req && !copying && !ioctl_download && !wr_pend) begin
		copy_req <= 0; copying <= 1'b1; word <= 0; have <= 0; rd_wait <= 0;
	end
	else if (copying) begin
		if (!have && !rd_wait && !ddr_rd) begin
			ddr_addr <= BASE + {14'd0, cur_set, word};
			ddr_rd <= 1'b1;
			rd_wait <= 1'b1;
		end
		else if (rd_wait && ddr_dout_ready) begin
			data <= ddr_dout; have <= 1'b1; lane <= 0; rd_wait <= 0;
		end
		else if (have) begin
			rom_a <= {word, lane};
			rom_d <= data[{lane, 3'b000} +: 8];
			rom_we <= 1'b1;
			lane <= lane + 1'd1;
			if (lane == 3'd7) begin
				have <= 0;
				if (word + 1'd1 == WORDS) copying <= 0;
				word <= word + 1'd1;
			end
		end
	end
end

endmodule
