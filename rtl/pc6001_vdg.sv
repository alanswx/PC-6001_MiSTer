//============================================================================
//  PC-6001 video: the M5C6847P-1 VDG as the PC-6001 wires it.
//
//  The VDG reads a 512-byte attribute plane and a data plane from main RAM (port B0 picks the 16 KB page):
//  page+000h..1FFh holds one attribute byte per text cell, page+200h.. the characters or the bitmap. In the
//  alphanumeric modes each cell's attribute drives the VDG mode pins (AS, INT/EXT, CSS, INV); in the graphics
//  modes the attribute of the first cell (page+000h) selects the mode for the whole picture, as CSCP and
//  PC6001VX do.
//
//    attribute: b7 A/G  b6 A/S  b5 INT/EXT  b4 GM0  b3 GM1  b2 GM2  b1 CSS  b0 INV
//
//  Timing (PC6001VX vdg.cpp): 455 dots of 7.16 MHz per line, 262 lines, 192 active lines of 256 dots. The
//  Z80 is held off the bus (BUSRQ) from the start of each active line for 256+40 dots while the display is on
//  (port C bit 1 of the 8255, CRTKILL).
//
//  Picture: 320x240 visible, 256x192 active with a 32 dot / 24 line border (as MAME's screen).
//  Colours: PC6001VX's standard palette (src/config.cpp STDColor 0-16).
//============================================================================

module pc6001_vdg
(
	input             clk,
	input             reset,
	input             ce_pix,        // 7.16 MHz dot clock enable (clk / 4)
	input       [1:0] ph,            // clk phase, ce_pix when ph == 3

	input      [15:0] vram_base,     // C000h/E000h/8000h/A000h
	input             disp_on,       // 8255 port C bit 1
	input             artifact,      // mode 4 colour set 2: NTSC artifact colours (not yet)

	output reg [15:0] vaddr,         // combinational         // to the RAM's video port
	input       [7:0] vdata,         // one clk after vaddr

	output reg [11:0] cg_addr,       // combinational       // CGROM (4 KB: 256 chars x 16 lines)
	input       [7:0] cg_data,

	output            busrq,         // hold the Z80 off the bus

	output reg  [7:0] R,
	output reg  [7:0] G,
	output reg  [7:0] B,
	output reg        HSync,
	output reg        VSync,
	output reg        HBlank,
	output reg        VBlank
);

localparam H_TOTAL   = 455;
localparam H_ACTIVE0 = 32;        // first active dot
localparam H_VIS     = 320;       // visible dots (border + active + border)
localparam H_BUSRQ   = 256 + 40;  // dots of each active line the Z80 is held off
localparam HS_START  = 352, HS_END = 386;
localparam V_TOTAL   = 262;
localparam V_ACTIVE0 = 24;        // first active line
localparam V_VIS     = 240;
localparam VS_START  = 250, VS_END = 253;

reg [8:0] h;   // 0..454
reg [8:0] v;   // 0..261

wire       vactive = v >= V_ACTIVE0 && v < V_ACTIVE0 + 192;
wire [7:0] y = v - V_ACTIVE0;

assign busrq = disp_on && vactive && h < H_BUSRQ;

always @(posedge clk) begin
	if (reset) begin
		h <= 0;
		v <= 0;
	end
	else if (ce_pix) begin
		if (h == H_TOTAL - 1) begin
			h <= 0;
			v <= v == V_TOTAL - 1 ? 9'd0 : v + 1'd1;
		end
		else h <= h + 1'd1;
	end
end

//----------------------------------------------------------------------------
// Row counters: text rows of 12 lines, graphics rows of 1, 2 or 3 lines
//----------------------------------------------------------------------------

reg  [7:0] mode_attr;     // attribute of the first cell, latched at the start of each active line
wire       ag  = mode_attr[7];
wire [2:0] gm  = {mode_attr[2], mode_attr[3], mode_attr[4]};   // GM2 GM1 GM0
wire       css_g = mode_attr[1];

// graphics: lines per row and bytes per row
wire [1:0] g_lines = gm <= 3'd2 ? 2'd3 : gm <= 3'd4 ? 2'd2 : 2'd1;
wire       g_wide  = gm == 3'd0 || gm == 3'd1 || gm == 3'd3 || gm == 3'd5;   // 16 bytes per row, 16 dots per byte

reg [3:0]  t_line;        // line within a text row (0..11)
reg [3:0]  t_row;         // text row (0..15)
reg [1:0]  g_line;        // line within a graphics row
reg [12:0] g_row_ofs;     // offset of the current graphics row

always @(posedge clk) begin
	if (ce_pix && h == H_TOTAL - 1) begin
		if (v == V_ACTIVE0 - 1) begin
			t_line <= 0; t_row <= 0; g_line <= 0; g_row_ofs <= 0;
		end
		else if (vactive) begin
			if (t_line == 11) begin t_line <= 0; t_row <= t_row + 1'd1; end
			else t_line <= t_line + 1'd1;
			if (g_line == g_lines - 1'd1) begin
				g_line <= 0;
				g_row_ofs <= g_row_ofs + (g_wide ? 13'd16 : 13'd32);
			end
			else g_line <= g_line + 1'd1;
		end
	end
end

//----------------------------------------------------------------------------
// Fetch: for each group of 8 dots, during the dot before it (4 clks). The RAM and the CGROM return data one
// clk after the address, so the addresses are combinational:
//   ph 0: attribute address   ph 1: attribute in, data address   ph 2: data in, CGROM address   ph 3: load
// At dot 0 of each active line the same slot reads the mode byte (the attribute of the first cell).
//----------------------------------------------------------------------------

wire [8:0]  fx = h - (H_ACTIVE0 - 1);   // fetch for group fx[7:3] at fx[2:0] == 0
wire        fetch_slot = vactive && h >= H_ACTIVE0 - 1 && h < H_ACTIVE0 + 255 && fx[2:0] == 3'd0;
wire        mode_slot  = vactive && h == 9'd0;
wire  [4:0] fgrp = fx[7:3];
wire  [8:0] tcell = {t_row, fgrp};
wire [12:0] g_ofs = g_row_ofs + (g_wide ? {9'd0, fgrp[4:1]} : {8'd0, fgrp});

reg  [7:0] f_attr, f_data;
reg  [7:0] s_attr, s_data, s_pat;    // the group being displayed

always @(*) begin
	vaddr = vram_base;
	if (fetch_slot) begin
		if (ph == 2'd0) vaddr = vram_base + tcell;
		else vaddr = vram_base + 16'h0200 + (ag ? {3'd0, g_ofs} : {7'd0, tcell});
	end
	cg_addr = {vdata, t_line};
end

always @(posedge clk) begin
	if (mode_slot && ph == 2'd1) mode_attr <= vdata;
	if (fetch_slot) begin
		case (ph)
		2'd1: f_attr <= vdata;
		2'd2: f_data <= vdata;
		2'd3: begin
			s_attr <= f_attr;
			s_data <= f_data;
			s_pat  <= cg_data;
		end
		default: ;
		endcase
	end
end

// Built-in VDG font (MC6847 internal character generator, 64 characters x 12 lines), from MESS m6847.c via
// CSCP src/vm/mc6847.cpp. Used when a cell's INT/EXT bit is 0.
`include "pc6001_intfont.svh"
reg [7:0] int_pat, int_pat_s;
always @(posedge clk) if (fetch_slot && ph == 2'd2) int_pat <= intfont(vdata[5:0], t_line);
always @(posedge clk) if (fetch_slot && ph == 2'd3) int_pat_s <= int_pat;

//----------------------------------------------------------------------------
// Dots
//----------------------------------------------------------------------------

// Colour codes (PC6001VX STDColor)
localparam C_BLACK = 5'd0, C_GREEN = 5'd1, C_DGREEN = 5'd2, C_ORANGE = 5'd3, C_DORANGE = 5'd4,
           C_SG = 5'd5,   // 5..12: green yellow blue red white cyan magenta orange
           C_M4_DGREEN = 5'd13, C_M4_GREEN = 5'd14, C_M4_BLACK = 5'd15, C_M4_WHITE = 5'd16;

wire [8:0] dx = h - H_ACTIVE0;                  // 0..255 in the active area
wire [2:0] bit_n = dx[2:0];
reg  [4:0] color;

wire t_as   = s_attr[6];
wire t_ext  = s_attr[5];
wire t_css  = s_attr[1];
wire t_inv  = s_attr[0];

reg        pix;
reg  [1:0] pix2;

always @(*) begin
	color = C_BLACK;
	pix   = 1'b0;
	pix2  = 2'd0;
	if (!(vactive && h >= H_ACTIVE0 && h < H_ACTIVE0 + 256)) begin
		// border: black in the text modes, the colour set's first colour in graphics (MC6847)
		color = !ag ? C_BLACK : gm[0] ? (css_g ? C_M4_WHITE : C_M4_GREEN) : (css_g ? C_SG + 5'd4 : C_SG);
	end
	else if (!ag) begin
		if (!t_as) begin
			pix = (t_ext ? s_pat[3'd7 - bit_n] : int_pat_s[3'd7 - bit_n]) ^ t_inv;
			color = t_css ? (pix ? C_ORANGE : C_DORANGE) : (pix ? C_GREEN : C_DGREEN);
		end
		else if (t_ext) begin
			// semigraphics 6: 2x3 blocks, colour from bits 7-6 and CSS
			case (t_line >= 8 ? 2'd2 : t_line >= 4 ? 2'd1 : 2'd0)
			2'd0: pix = bit_n < 4 ? s_data[5] : s_data[4];
			2'd1: pix = bit_n < 4 ? s_data[3] : s_data[2];
			default: pix = bit_n < 4 ? s_data[1] : s_data[0];
			endcase
			color = pix ? C_SG + {t_css, s_data[7:6]} : C_BLACK;
		end
		else begin
			// semigraphics 4: 2x2 blocks, colour from bits 6-4
			pix = t_line < 6 ? (bit_n < 4 ? s_data[3] : s_data[2]) : (bit_n < 4 ? s_data[1] : s_data[0]);
			color = pix ? C_SG + s_data[6:4] : C_BLACK;
		end
	end
	else if (!gm[0]) begin
		// colour graphics, 2 bits per dot
		if (g_wide) case (dx[3:2])   // 64 dots wide: each dot 4 wide
			2'd0: pix2 = s_data[7:6];
			2'd1: pix2 = s_data[5:4];
			2'd2: pix2 = s_data[3:2];
			default: pix2 = s_data[1:0];
		endcase
		else case (dx[2:1])
			2'd0: pix2 = s_data[7:6];
			2'd1: pix2 = s_data[5:4];
			2'd2: pix2 = s_data[3:2];
			default: pix2 = s_data[1:0];
		endcase
		color = C_SG + {css_g, pix2};
	end
	else begin
		// resolution graphics, 1 bit per dot
		pix = g_wide ? s_data[3'd7 - dx[3:1]] : s_data[3'd7 - bit_n];
		color = css_g ? (pix ? C_M4_WHITE : C_M4_BLACK) : (pix ? C_M4_GREEN : C_M4_DGREEN);
	end
	if (!disp_on) color = C_BLACK;
end


reg [23:0] rgb;
always @(*) begin
	case (color)
	5'd0:  rgb = 24'h1E1E1E;
	5'd1:  rgb = 24'h32EE0F;
	5'd2:  rgb = 24'h046A04;
	5'd3:  rgb = 24'hFC6423;
	5'd4:  rgb = 24'hB40604;
	5'd5:  rgb = 24'h32EE0F;
	5'd6:  rgb = 24'hEAE004;
	5'd7:  rgb = 24'h440AF4;
	5'd8:  rgb = 24'hE2060C;
	5'd9:  rgb = 24'hD6D0F6;
	5'd10: rgb = 24'h34BAEC;
	5'd11: rgb = 24'hF40AF4;
	5'd12: rgb = 24'hFC5A04;
	5'd13: rgb = 24'h046A04;
	5'd14: rgb = 24'h53F237;
	5'd15: rgb = 24'h1E1E1E;
	5'd16: rgb = 24'hE0FFD0;
	default: rgb = 24'h000000;
	endcase
end

always @(posedge clk) begin
	if (ce_pix) begin
		{R, G, B} <= rgb;
		HBlank <= h >= H_VIS;
		VBlank <= v >= V_VIS;
		HSync  <= h >= HS_START && h < HS_END;
		VSync  <= v >= VS_START && v < VS_END;
	end
end

endmodule
