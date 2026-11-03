// The mkIISR's bitmap: where dot (x, y) of the 320 x 204 picture is in its 32 KB (PC6001VX vdg.cpp
// SRGVramAddr, VDG64::GetVram). x and y wrap at 320 and 204. Each byte holds two dots (a nibble each); the
// picture's columns 0-255 are at 1A00h-7FFFh, 256 bytes a line pair, and columns 256-319 at 0000h-197Fh, 64
// bytes a line pair, with bits 1-3 of the line rotated. Within each four bytes: bit 1 the line's bit 0, bit 0
// x bit 1.
function automatic [14:0] sr_gv(input [10:0] x, input [8:0] y);
	reg [10:0] hh;
	reg  [8:0] vv, vs;
	reg [14:0] t;
	begin
		hh = x >= 11'd1280 ? x - 11'd1280 : x >= 11'd960 ? x - 11'd960 : x >= 11'd640 ? x - 11'd640 :
		     x >= 11'd320 ? x - 11'd320 : x;
		vv = y >= 9'd408 ? y - 9'd408 : y >= 9'd204 ? y - 9'd204 : y;
		if (hh < 11'd256) begin
			t = {7'd0, hh[7:0]} + {vv[7:1], 8'd0} + 15'h1a00;
			sr_gv = {t[14:2], vv[0], hh[1]};
		end
		else begin
			vs = {vv[8:4], vv[1], vv[3], vv[2], vv[0]};
			t = {9'd0, hh[5:0]} + {2'd0, vs[7:1], 6'd0};
			sr_gv = {t[14:2], vs[0], hh[1]};
		end
	end
endfunction
