// Touch panel on joystick port 2, as the NEC "Touch Panel" cartridge (4 KB, "AB" at 4000h) reads it. No emulator
// has it; the protocol is from the cartridge's code (sub 4617h: wait for the pen, sub 4681h: read X and Y):
//
//   PSG port B (out): bit 4 rising latches a coordinate, bit 1 picks it (1: X, 0: Y), bit 0 rising shifts the
//   next bit out (the program reads with bit 0 low, MSB first).
//   PSG port A (in):  bit 0 = 0 while the pen is down, bit 1 = 1 when the panel is ready, bit 2 = data.
//
// X runs 0-255 across the screen and Y 0-255 down it (the program scales Y by 3/4 to its 192 lines). The panel is
// always ready; it answers at once.

module touch_panel
(
	input            clk,
	input            reset,
	input      [7:0] pb,              // PSG port B
	input      [7:0] x,
	input      [7:0] y,
	input            pen,
	output     [7:0] pa               // PSG port A while port B bit 6 = 0 (joystick 2)
);

reg [7:0] sr;
reg [1:0] old;
always @(posedge clk) begin
	old <= {pb[4], pb[0]};
	if (reset) sr <= 0;
	else if (pb[4] & ~old[1]) sr <= pb[1] ? x : y;
	else if (pb[0] & ~old[0]) sr <= {sr[6:0], 1'b0};
end

assign pa = {5'b11111, sr[7], 1'b1, ~pen};

endmodule
