// True dual-port RAM, one clock, registered address and unregistered output (data one clk after the address).
// Quartus gets an altsyncram (M10K); its inference does not take the disk image's 176 KB RAM. Verilator gets the
// same behaviour as an array.

module dpram_tdp #(parameter int WORDS = 1024, parameter int AW = 10)
(
	input               clk,

	input      [AW-1:0] addr_a,
	input               we_a,
	input         [7:0] d_a,
	output        [7:0] q_a,

	input      [AW-1:0] addr_b,
	input               we_b,
	input         [7:0] d_b,
	output        [7:0] q_b
);

`ifdef VERILATOR
reg [7:0] mem[0:WORDS-1];
reg [7:0] ra, rb;
always @(posedge clk) begin
	ra <= mem[addr_a];
	if (we_a) mem[addr_a] <= d_a;
end
always @(posedge clk) begin
	rb <= mem[addr_b];
	if (we_b) mem[addr_b] <= d_b;
end
assign q_a = ra;
assign q_b = rb;
`else
altsyncram #(
	.operation_mode("BIDIR_DUAL_PORT"),
	.width_a(8), .widthad_a(AW), .numwords_a(WORDS),
	.width_b(8), .widthad_b(AW), .numwords_b(WORDS),
	.outdata_reg_a("UNREGISTERED"), .outdata_reg_b("UNREGISTERED"),
	.address_reg_b("CLOCK0"), .indata_reg_b("CLOCK0"), .wrcontrol_wraddress_reg_b("CLOCK0"),
	.read_during_write_mode_mixed_ports("DONT_CARE"),
	.read_during_write_mode_port_a("NEW_DATA_NO_NBE_READ"),
	.read_during_write_mode_port_b("NEW_DATA_NO_NBE_READ"),
	.ram_block_type("M10K"),
	.power_up_uninitialized("FALSE"),
	.intended_device_family("Cyclone V"),
	.lpm_type("altsyncram")
) ram (
	.clock0(clk),
	.address_a(addr_a), .wren_a(we_a), .data_a(d_a), .q_a(q_a),
	.address_b(addr_b), .wren_b(we_b), .data_b(d_b), .q_b(q_b),
	.aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
	.byteena_a(1'b1), .byteena_b(1'b1), .clock1(1'b1), .clocken0(1'b1), .clocken1(1'b1),
	.clocken2(1'b1), .clocken3(1'b1), .eccstatus(), .rden_a(1'b1), .rden_b(1'b1)
);
`endif

endmodule
