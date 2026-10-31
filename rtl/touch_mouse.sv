// The MiSTer mouse as the touch panel's pen (rtl/touch_panel.sv): touch_mouse moves a point over the panel and
// holds the pen down with the left button; touch_cursor draws that point on the picture as a small cross (a real
// panel needs none: you see where your pen is).
//
// The Touch Panel cartridge draws only between samples less than 5 steps apart (a bigger jump is noise, or the pen
// put down elsewhere), and a real pen moves smoothly. So the point follows the mouse by at most one step every
// 3 ms: the cartridge samples every 6 ms or so while it draws (up to 10 ms), 2-4 steps apart.

module touch_mouse
(
	input             clk,
	input      [24:0] ps2_mouse,      // hps_io: b24 toggles per report, b23-16 dy, b15-8 dx, b5/b4 y/x sign, b0 left
	output      [7:0] x,              // 0-255 left to right
	output      [7:0] y,              // 0-255 top to bottom
	output            pen
);

// the mouse: half a panel step per count
reg [8:0] px = 9'd256, py = 9'd256;
reg       old_tgl = 0, btn = 0;
// the point, following it
reg [7:0] ox = 8'd128, oy = 8'd128;
reg [16:0] tick = 0;
reg        down = 0;               // the pen goes down once the point has caught up with the mouse
reg  [8:0] acc = 0;
wire [7:0] ax = px[8:1] > ox ? px[8:1] - ox : ox - px[8:1];
wire [7:0] ay = py[8:1] > oy ? py[8:1] - oy : oy - py[8:1];

function automatic [8:0] move(input [8:0] p, input signed [9:0] d);
	reg signed [10:0] n;
	n = $signed({2'b00, p}) + d;
	move = n < 0 ? 9'd0 : n > 511 ? 9'd511 : n[8:0];
endfunction

always @(posedge clk) begin
	old_tgl <= ps2_mouse[24];
	if (ps2_mouse[24] != old_tgl) begin
		px  <= move(px, {ps2_mouse[4], ps2_mouse[4], ps2_mouse[15:8]});
		py  <= move(py, -$signed({ps2_mouse[5], ps2_mouse[5], ps2_mouse[23:16]}));   // PS/2 y counts up
		btn <= ps2_mouse[0];
	end
	tick <= tick == 17'd85908 ? 17'd0 : tick + 1'd1;     // 3 ms at 28.636 MHz
	// a step along the line to the mouse: the longer way every time, the shorter in proportion (Bresenham, on
	// what is left)
	if (tick == 0) begin
		if (ax >= ay) begin
			if (ax != 0) ox <= px[8:1] > ox ? ox + 1'd1 : ox - 1'd1;
			if (acc + ay >= ax && ay != 0) begin oy <= py[8:1] > oy ? oy + 1'd1 : oy - 1'd1; acc <= acc + ay - ax; end
			else acc <= ay == 0 ? 9'd0 : acc + ay;
		end
		else begin
			oy <= py[8:1] > oy ? oy + 1'd1 : oy - 1'd1;
			if (acc + ax >= ay && ax != 0) begin ox <= px[8:1] > ox ? ox + 1'd1 : ox - 1'd1; acc <= acc + ax - ay; end
			else acc <= ax == 0 ? 9'd0 : acc + ax;
		end
	end
	if (!btn) down <= 0;
	else if (ox == px[8:1] && oy == py[8:1]) down <= 1'b1;
end

assign x = ox;
assign y = oy;
assign pen = down;

endmodule


module touch_cursor
(
	input             clk,
	input             ce_pix,
	input             hblank,
	input             vblank,
	input             enable,
	input       [7:0] x,              // the panel point: dot 32 + x, line 24 + y * 3/4 of the picture (the
	input       [7:0] y,              // active area's 256 x 192 inside the border, rtl/pc6001_vdg.sv)
	input             pen,
	input      [23:0] rgb_in,
	output     [23:0] rgb_out
);

reg [8:0] h, v;
reg       old_hb = 0;
always @(posedge clk) if (ce_pix) begin
	old_hb <= hblank;
	if (hblank) h <= 0; else h <= h + 1'd1;
	if (vblank) v <= 0; else if (hblank && !old_hb) v <= v + 1'd1;
end

wire [8:0] cx = 9'd32 + x;
wire [9:0] y3 = {2'b00, y} * 10'd3;
wire [8:0] cy = 9'd24 + y3[9:2];
wire [8:0] dx = h > cx ? h - cx : cx - h;
wire [8:0] dy = v > cy ? v - cy : cy - v;
// a cross 7 dots wide, its centre filled in while the pen is down
wire on = enable && !hblank && !vblank &&
          ((h == cx && dy <= 3) || (v == cy && dx <= 3) || (pen && dx <= 1 && dy <= 1));

assign rgb_out = on ? ~rgb_in : rgb_in;

endmodule
