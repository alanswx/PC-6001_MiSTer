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
//
//  PC-6001mkII (mk2): modes 1-4 as above, in the mkII's colours (PC6001VX vdg.cpp COL62 tables, the 16-colour
//  RGB palette config.cpp STDColor 41-56) and with a black border. Port C1 bit 1 = 0 selects the N60m screens
//  (mode 5, PC6001VX device/mc6847.cpp PCZ80_07::Draw1line2), 320x200 from dot 8 and line 20:
//    text (C1 bit 2 = 1): 40x20 cells of 10 lines, attribute plane at the page, characters at page+400h; the
//      attribute is b7 the font's upper 256 characters, b6-4 background, b3-0 foreground (palette indices)
//    graphics: attribute plane at the page, data plane at page+2000h, 40 bytes a line; C1 bit 3 = 0 320x200
//      in 4 colours (a data bit and an attribute bit a dot), = 1 160x200 in 16 (two of each a dot)
//  The page is port B0 bits 2-1: 8000h, C000h, 0000h, 4000h. C0 bits 2-0 are CSS3-1.
//============================================================================

module pc6001_vdg
(
	input             clk,
	input             reset,
	input             ce_pix,        // 7.16 MHz dot clock enable (clk / 4)
	input       [1:0] ph,            // clk phase, ce_pix when ph == 3

	input      [15:0] vram_base,     // C000h/E000h/8000h/A000h
	input             disp_on,       // 8255 port C bit 1

	input             mk2,           // PC-6001mkII
	input       [1:0] page,          // port B0 bits 2-1
	input       [3:1] crt_mode,      // port C1: b1 0 N60m, b2 1 text, b3 1 160x200
	input       [2:0] css,           // port C0: CSS3-1

	output reg [15:0] vaddr,         // combinational         // to the RAM's video port
	input       [7:0] vdata,         // one clk after vaddr

	output reg [13:0] cg_addr,       // combinational       // CGROM: b13 0 the N60 font (256 chars x 16 lines), 1 the
	                                 // mkII's N60m font (512 chars x 16)
	input       [7:0] cg_data,

	output            busrq,         // hold the Z80 off the bus

	output reg  [7:0] R,
	output reg  [7:0] G,
	output reg  [7:0] B,
	output reg        HSync,
	output reg        VSync,
	output reg        HBlank,
	output reg        VBlank,
	output reg        mono,          // resolution graphics, colour set 2 (black/white): the PC-6001 sends no colour
	                                 // burst then (rtl/pc6001_composite.sv)
	output reg  [4:0] cidx           // the dot's colour code, for the composite encoder
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
localparam H5_ACTIVE0 = 8;        // mode 5
localparam V5_ACTIVE0 = 20;
// The Z80 is held off for H_BUSRQ_MK2 (modes 1-4) / H5_BUSRQ (mode 5) dots of each active line. PC6001VX and
// CSCP give 304 and 368 of 456. With 368, mode 5 software that runs at 1x on a real mkII fails here: tapes
// load at Normal with BASIC's pointers a byte off (Chack'n Pop: ?SN Error at RUN), and Jelda crashes once
// running. 336 and 352 both work (PC6001VX boosts tape loading by default, so its 1x path is not exercised);
// 336 keeps a margin below where it fails.
localparam H_BUSRQ_MK2 = 304, H5_BUSRQ = 336;

reg [8:0] h;   // 0..454
reg [8:0] v;   // 0..261

wire       vactive = v >= V_ACTIVE0 && v < V_ACTIVE0 + 192;
wire       vactive5 = v >= V5_ACTIVE0 && v < V5_ACTIVE0 + 200;

// mode 5 for the whole frame, decided at its start
reg        m5 = 0;
always @(posedge clk) if (ce_pix && h == H_TOTAL - 1 && v == V_TOTAL - 1) m5 <= mk2 && !crt_mode[1];
wire       m5_text = crt_mode[2];
wire       m5_g160 = crt_mode[3];

assign busrq = disp_on && (m5 ? vactive5 && h < H5_BUSRQ : vactive && h < (mk2 ? H_BUSRQ_MK2 : H_BUSRQ));

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

// mode 5: text rows of 10 lines, 40 cells; graphics lines of 40 bytes
reg  [3:0] t5_line;
reg [10:0] t5_ofs;
reg [12:0] g5_ofs;
always @(posedge clk) begin
	if (ce_pix && h == H_TOTAL - 1) begin
		if (v == V5_ACTIVE0 - 1) begin
			t5_line <= 0; t5_ofs <= 0; g5_ofs <= 0;
		end
		else if (vactive5) begin
			if (t5_line == 9) begin t5_line <= 0; t5_ofs <= t5_ofs + 11'd40; end
			else t5_line <= t5_line + 1'd1;
			g5_ofs <= g5_ofs + 13'd40;
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

// mode 5: 40 groups from dot 8
wire [8:0]  fx5 = h - (H5_ACTIVE0 - 1);
wire        slot5 = vactive5 && h >= H5_ACTIVE0 - 1 && h < H5_ACTIVE0 + 319 && fx5[2:0] == 3'd0;
wire  [5:0] grp5 = fx5[8:3];
wire [15:0] base5 = {~page[1], page[0], 14'd0};
wire [12:0] ofs5 = (m5_text ? {2'd0, t5_ofs} : g5_ofs) + {7'd0, grp5};
wire        slot = m5 ? slot5 : fetch_slot;

reg  [7:0] f_attr, f_data;
reg  [7:0] s_attr, s_data, s_pat;    // the group being displayed

always @(*) begin
	vaddr = vram_base;
	if (m5) begin
		vaddr = base5;
		if (slot5) vaddr = base5 + (ph == 2'd0 ? 16'd0 : m5_text ? 16'h0400 : 16'h2000) + {3'd0, ofs5};
	end
	else if (fetch_slot) begin
		if (ph == 2'd0) vaddr = vram_base + tcell;
		else vaddr = vram_base + 16'h0200 + (ag ? {3'd0, g_ofs} : {7'd0, tcell});
	end
	cg_addr = m5 ? {1'b1, f_attr[7], vdata, t5_line} : {2'b00, vdata, t_line};
end

always @(posedge clk) begin
	if (mode_slot && !m5 && ph == 2'd1) mode_attr <= vdata;
	if (slot) begin
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
reg        border;

always @(*) begin
	color = C_BLACK;
	pix   = 1'b0;
	pix2  = 2'd0;
	border = 1'b0;
	if (!(vactive && h >= H_ACTIVE0 && h < H_ACTIVE0 + 256)) begin
		border = 1'b1;
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

// the mkII: modes 1-4's colour codes in its palette (PC6001VX COL62_AN, _SG, _CG, _RG; the border is black)
function automatic [3:0] mk2_n60(input [4:0] c);
	case (c)
	C_GREEN:     mk2_n60 = 4'd15;
	C_ORANGE:    mk2_n60 = 4'd10;
	5'd5:  mk2_n60 = 4'd10;  5'd6:  mk2_n60 = 4'd11;  5'd7:  mk2_n60 = 4'd12;  5'd8:  mk2_n60 = 4'd9;
	5'd9:  mk2_n60 = 4'd15;  5'd10: mk2_n60 = 4'd14;  5'd11: mk2_n60 = 4'd13;  5'd12: mk2_n60 = 4'd1;
	C_M4_GREEN:  mk2_n60 = 4'd10;
	C_M4_WHITE:  mk2_n60 = 4'd15;
	default:     mk2_n60 = 4'd8;      // black, dark green, dark orange, mode 4's dark colours
	endcase
endfunction

// mode 5 graphics colours (COL62_CG2): CSS3 = 0 the 16 colours, 1 the mode 1-4 set
function automatic [3:0] cg2(input set, input [3:0] c);
	if (!set) cg2 = {c[3], c[0], c[2], c[1]};
	else case (c[2:0])
		3'd0: cg2 = 4'd10; 3'd1: cg2 = 4'd11; 3'd2: cg2 = 4'd12; 3'd3: cg2 = 4'd9;
		3'd4: cg2 = 4'd15; 3'd5: cg2 = 4'd14; 3'd6: cg2 = 4'd13; default: cg2 = 4'd1;
	endcase
endfunction

wire [8:0] dx5 = h - H5_ACTIVE0;
wire [2:0] b5 = 3'd7 - dx5[2:0];
reg  [3:0] pal;           // the mkII's palette index
always @(*) begin
	pal = 4'd0;
	if (m5) begin
		if (!(vactive5 && h >= H5_ACTIVE0 && h < H5_ACTIVE0 + 320) || !disp_on) pal = 4'd0;
		else if (m5_text) pal = s_pat[b5] ? s_attr[3:0] : {css[1], s_attr[6:4]};
		else if (!m5_g160) pal = cg2(css[2], {css[1], css[0], s_data[b5], s_attr[b5]});
		else case (dx5[2:1])
			2'd0: pal = cg2(css[2], {s_data[7:6], s_attr[7:6]});
			2'd1: pal = cg2(css[2], {s_data[5:4], s_attr[5:4]});
			2'd2: pal = cg2(css[2], {s_data[3:2], s_attr[3:2]});
			default: pal = cg2(css[2], {s_data[1:0], s_attr[1:0]});
		endcase
	end
	else pal = border || !disp_on ? 4'd8 : mk2_n60(color);
end

reg [23:0] rgb2;
always @(*) begin
	case (pal)
	4'd0:  rgb2 = 24'h141414;  4'd1:  rgb2 = 24'hFFAC00;  4'd2:  rgb2 = 24'h00FFAC;  4'd3:  rgb2 = 24'hACFF00;
	4'd4:  rgb2 = 24'hAC00FF;  4'd5:  rgb2 = 24'hFF00AC;  4'd6:  rgb2 = 24'h00ACFF;  4'd7:  rgb2 = 24'hACACAC;
	4'd8:  rgb2 = 24'h141414;  4'd9:  rgb2 = 24'hFF0000;  4'd10: rgb2 = 24'h00FF00;  4'd11: rgb2 = 24'hFFFF00;
	4'd12: rgb2 = 24'h0000FF;  4'd13: rgb2 = 24'hFF00FF;  4'd14: rgb2 = 24'h00FFFF;  default: rgb2 = 24'hFFFFFF;
	endcase
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
		{R, G, B} <= mk2 ? rgb2 : rgb;
		HBlank <= m5 ? h < H5_ACTIVE0 || h >= H5_ACTIVE0 + H_VIS : h >= H_VIS;
		VBlank <= v >= V_VIS;
		HSync  <= h >= HS_START && h < HS_END;
		VSync  <= v >= VS_START && v < VS_END;
		mono   <= !mk2 && ag && gm[0] && css_g;
		cidx   <= color;
	end
end

endmodule
