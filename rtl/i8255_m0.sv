// 8255 PPI, mode 0 only (simple I/O), as the PC-6031's two interface PIOs use it.
//
// Mode word (bit 7 = 1): bit 4 port A in, bit 3 port C upper in, bit 1 port B in, bit 0 port C lower in; it clears
// the output latches (CSCP I8255 clear_ports_by_cmdreg). Bit 7 = 0: bit set/reset on port C (bits 3-1 bit, bit 0
// value). A port set as input drives FFh on its outputs.

module i8255_m0
(
	input            clk,
	input            reset,
	input      [1:0] addr,
	input            rd,              // one clk per access (only for symmetry: reads have no side effects)
	input            wr,
	input      [7:0] din,
	output reg [7:0] dout,

	input      [7:0] pa_i,
	input      [7:0] pb_i,
	input      [7:0] pc_i,
	output     [7:0] pa_o,
	output     [7:0] pb_o,
	output     [7:0] pc_o
);

reg [7:0] la, lb, lc;
reg       a_in, b_in, cu_in, cl_in;

always @(posedge clk) begin
	if (reset) begin
		{la, lb, lc} <= 0;
		{a_in, b_in, cu_in, cl_in} <= 4'b1111;
	end
	else if (wr) begin
		case (addr)
		2'd0: la <= din;
		2'd1: lb <= din;
		2'd2: lc <= din;
		2'd3:
			if (din[7]) begin
				a_in <= din[4]; cu_in <= din[3]; b_in <= din[1]; cl_in <= din[0];
				{la, lb, lc} <= 0;
			end
			else lc[din[3:1]] <= din[0];
		endcase
	end
end

always @(*) begin
	case (addr)
	2'd0: dout = a_in ? pa_i : la;
	2'd1: dout = b_in ? pb_i : lb;
	2'd2: dout = {cu_in ? pc_i[7:4] : lc[7:4], cl_in ? pc_i[3:0] : lc[3:0]};
	default: dout = 8'hff;
	endcase
end

assign pa_o = a_in ? 8'hff : la;
assign pb_o = b_in ? 8'hff : lb;
assign pc_o = {cu_in ? 4'hf : lc[7:4], cl_in ? 4'hf : lc[3:0]};

endmodule
