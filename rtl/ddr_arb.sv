// Two DDR3 clients on emu's one port (sys/ddr_svc style, one access at a time each): the disk image
// (rtl/d88_media.sv, client a) and the ROM store (rtl/rom_store.sv, client b). A client holds rd / we until the
// port takes it and, after a read, waits for its data; the port changes hands only between such accesses. The
// other client sees busy meanwhile.

module ddr_arb
(
	input             clk,

	input             a_rd, a_we,
	input      [28:0] a_addr,
	input      [63:0] a_din,
	input       [7:0] a_be,
	output            a_busy,
	output            a_dout_ready,

	input             b_rd, b_we,
	input      [28:0] b_addr,
	input      [63:0] b_din,
	input       [7:0] b_be,
	output            b_busy,
	output            b_dout_ready,

	input             ddr_busy,
	input             ddr_dout_ready,
	output            ddr_rd, ddr_we,
	output     [28:0] ddr_addr,
	output     [63:0] ddr_din,
	output      [7:0] ddr_be
);

reg owner = 0;                // 0 a, 1 b
reg pend = 0;                 // a read is out for the owner

wire o_rd = owner ? b_rd : a_rd;
wire o_we = owner ? b_we : a_we;

always @(posedge clk) begin
	if (o_rd && !ddr_busy) pend <= 1'b1;
	else if (ddr_dout_ready) pend <= 0;
	// hand over when the owner has nothing going and the other wants the port
	if (!o_rd && !o_we && !pend) begin
		if (owner == 0 && (b_rd || b_we)) owner <= 1'b1;
		else if (owner == 1 && (a_rd || a_we)) owner <= 1'b0;
	end
end

assign ddr_rd   = o_rd;
assign ddr_we   = o_we;
assign ddr_addr = owner ? b_addr : a_addr;
assign ddr_din  = owner ? b_din : a_din;
assign ddr_be   = owner ? b_be : a_be;

assign a_busy = owner ? 1'b1 : ddr_busy;
assign b_busy = owner ? ddr_busy : 1'b1;
assign a_dout_ready = !owner && ddr_dout_ready;
assign b_dout_ready = owner && ddr_dout_ready;

endmodule
