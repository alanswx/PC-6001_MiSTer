// The picture as a TV shows it: the VDG's dots made into an NTSC composite signal and decoded again by the NES
// core's receiver (rtl/composite_decoder.sv, Jamie Blanks). Colours bleed, and fine dot patterns turn into
// colour, as on the PC-6001's video output.
//
// The encoder runs at clk_sys, 8 samples per colour subcarrier cycle: a 7.16 MHz dot is 4 samples, a line 1820
// (455 dots, 227.5 cycles). Each colour code is sent as the VDG sends it (MC6847 data sheet, figure 10): a luma
// level (black, white low, medium, high) and the two colour difference outputs phiA (R-Y) and phiB (B-Y), each
// low, centred or high. Sync is HSync xor VSync, and the burst (phiB pulled low) follows each HSync. The
// subcarrier starts again at every HSync, so a dot pattern gives the same colours on every line.
//
// What a real PC-6001 does (measured at its video output, refs/docs/pc6001/web/mm_dev_screen4color_.html):
// mode 4's two greens differ only in luma, and stripes one dot apart show green from an even dot, a brownish
// orange from an odd one. P0 (where the subcarrier is against the dots) and the chroma level (C_DEV) are set to
// give that (runs/composite/model.py works it out); the luma levels are the data sheet's. In colour set 2
// (black/white) the VDG sends no burst, so a TV shows grey; many TVs (and RF) colour it anyway, at whatever phase
// they lock to, which is what games such as Orion and EGGY were seen with. bw_tv picks such a set (a burst at
// one of four quarter-cycle phases in that mode; named, as in PC6001VX, by the colours of stripes from an even
// dot / an odd dot) or none.
//
// The later models (rgb_in: the mkII, PC-6601, mkIISR) have no MC6847: their RGB picture is encoded as NTSC (Y,
// and U = 0.492 (B-Y), V = 0.877 (R-Y) on the subcarrier, the burst on -U as for the PC-6001), Y on the same
// voltage scale. Their mode 4 colours then come from the dots, so rtl/pc6001_vdg.sv's colour table is off.
//
// Out: the decoded picture at the dot rate, with the blanking of the RGB picture (320 x 240) cut from the
// receiver's own sync, from where the RGB picture's blanking ends (mode 5 and the SR modes start 8 dots later).

module pc6001_composite
(
	input             clk,            // 28.636 MHz
	input             reset,
	input             mono,           // no burst: rtl/pc6001_vdg.sv
	input       [2:0] bw_tv,          // colour set 2: 0 red/blue, 1 blue/red, 2 pink/green, 3 green/pink, 4 grey
	input       [4:0] cidx,           // the dot's colour code (rtl/pc6001_vdg.sv)
	input             rgb_in,         // a later model: encode r_in, g_in, b_in instead
	input       [7:0] r_in, g_in, b_in,
	input             hs_in, vs_in, hb_in, vb_in,

	output            ce_pix,
	output      [7:0] r, g, b,
	output reg        hs, vs, hb, vb
);

// levels, Q2.21 volts (1.0 V = 2^21; 1 IRE = 14975): blanking 0, sync -40 IRE; luma from the data sheet's
// voltages with blanking (0.77 V) at 0 and white high (0.42 V) at 100 IRE
localparam signed [23:0] V_SYNC = -24'sd599000;
localparam signed [23:0] Y_K  = 24'sd214140,  Y_WL = 24'sd513640,  Y_WM = 24'sd983860,  Y_WH = 24'sd1497380;
// one colour difference output off centre, and the burst: 20 IRE of subcarrier
localparam signed [23:0] C_DEV = 24'sd299490, C_DEV7 = 24'sd211770;   // and times 0.7071

// samples since HSync rose
reg  [10:0] cnt;
reg         old_hs;
always @(posedge clk) begin
	old_hs <= hs_in;
	cnt <= hs_in && !old_hs ? 11'd0 : cnt + 1'd1;
end

// the subcarrier, one eighth of a cycle a sample
localparam [2:0] P0 = 3'd6;
wire [2:0] p  = cnt[2:0] + P0;
wire [1:0] q  = bw_tv == 3'd0 ? 2'd2 : bw_tv == 3'd1 ? 2'd0 : bw_tv == 3'd2 ? 2'd3 : 2'd1;   // quarter cycles
wire [2:0] pb = mono ? p + {q, 1'b0} : p;
function automatic signed [23:0] sub(input [2:0] a);   // C_DEV sin(a * 45 degrees)
	case (a)
		3'd0: sub = 24'sd0;  3'd1: sub = C_DEV7;  3'd2: sub = C_DEV;  3'd3: sub = C_DEV7;
		3'd4: sub = 24'sd0;  3'd5: sub = -C_DEV7; 3'd6: sub = -C_DEV; default: sub = -C_DEV7;
	endcase
endfunction

// colour code (PC6001VX STDColor order, rtl/pc6001_vdg.sv): luma, phiA, phiB (-1 low, 0 centre, 1 high). The
// PC-6001's dark green and dark orange are green and orange at black's luma.
reg signed [23:0] y;
reg signed  [1:0] ca, cb;
always @(posedge clk) begin
	case (cidx)
		5'd1, 5'd5, 5'd14: {y, ca, cb} <= {Y_WM, -2'sd1, -2'sd1};   // green
		5'd2, 5'd13:       {y, ca, cb} <= {Y_K,  -2'sd1, -2'sd1};   // dark green
		5'd3, 5'd12:       {y, ca, cb} <= {Y_WM,  2'sd1, -2'sd1};   // orange
		5'd4:              {y, ca, cb} <= {Y_K,   2'sd1, -2'sd1};   // dark orange
		5'd6:              {y, ca, cb} <= {Y_WH,  2'sd0, -2'sd1};   // yellow
		5'd7:              {y, ca, cb} <= {Y_WL,  2'sd0,  2'sd1};   // blue
		5'd8:              {y, ca, cb} <= {Y_WL,  2'sd1,  2'sd0};   // red
		5'd9, 5'd16:       {y, ca, cb} <= {Y_WH,  2'sd0,  2'sd0};   // buff
		5'd10:             {y, ca, cb} <= {Y_WM, -2'sd1,  2'sd0};   // cyan
		5'd11:             {y, ca, cb} <= {Y_WM,  2'sd1,  2'sd1};   // magenta
		default:           {y, ca, cb} <= {Y_K,   2'sd0,  2'sd0};   // black
	endcase
end

wire signed [23:0] s_a = sub(p + 3'd2), s_b = sub(p);   // phiA on cos, phiB on sin
wire signed [23:0] chroma = (ca[1] ? -s_a : ca[0] ? s_a : 24'sd0) + (cb[1] ? -s_b : cb[0] ? s_b : 24'sd0);

// the later models: Y from 0 (black at blanking: NTSC-J has no setup) to 255 (white, Y_WH), 5872 a step; U on
// sin, V on cos, at half their size (the receiver doubles its saturation for them): at full size a saturated
// blue swings below the receiver's sync slice, 0.1 V over the tip
reg         [7:0] l8;
reg signed  [8:0] du, dv;
reg signed [23:0] y2, u2, v2;
wire       [16:0] lsum = 17'd77 * r_in + 17'd150 * g_in + 17'd29 * b_in;
always @(posedge clk) begin
	l8 <= lsum[15:8];
	du <= $signed({1'b0, b_in}) - $signed({1'b0, l8});
	dv <= $signed({1'b0, r_in}) - $signed({1'b0, l8});
	y2 <= 24'sd5872 * $signed({1'b0, l8});
	u2 <= 24'sd1444 * du;
	v2 <= 24'sd2575 * dv;
end
function automatic signed [23:0] mod(input signed [23:0] x, input [2:0] a);   // x sin(a * 45 degrees)
	reg signed [31:0] xe, h;
	reg signed [23:0] hs;
	xe = x;
	h = (xe * 32'sd181) >>> 8;
	hs = h[23:0];
	case (a)
		3'd0: mod = 24'sd0;  3'd1: mod = hs;   3'd2: mod = x;   3'd3: mod = hs;
		3'd4: mod = 24'sd0;  3'd5: mod = -hs;  3'd6: mod = -x;  default: mod = -hs;
	endcase
endfunction
wire signed [23:0] chroma2 = mod(u2, p) + mod(v2, p + 3'd2);
wire               sync   = hs_in ^ vs_in;
// the border runs on 16 dots into the blanking at each side (to 12.2 us after the sync edge), as a TV's overscan:
// a step from blanking to the border at the window's edge would show as a coloured column
wire               blank  = vb_in | hb_in && !(cnt >= 11'd348 && cnt < 11'd1756);
wire               in_burst = !vs_in && (rgb_in || !mono || bw_tv < 3'd4) && cnt >= 11'd152 && cnt < 11'd224;   // 5.3-7.8 us after the sync edge

reg signed [23:0] comp;
always @(posedge clk)
	comp <= sync  ? V_SYNC :
	        blank ? (in_burst ? -sub(rgb_in ? p : pb) : 24'sd0) :
	        rgb_in ? y2 + chroma2 : y + chroma;

wire       d_pix, d_hs, d_vs;
composite_decoder #(.SPC(8), .HCNT_W(11), .LUMA_LP(1), .PIX_DIV(4)) composite_decoder
(
	.clk(clk),
	.reset(reset),
	.ce(1'b1),
	.comp(comp),
	.sat(rgb_in ? 8'd255 : 8'd128),
	.hue(8'd0),
	.chroma_trail(4'd2),
	.sharpness(4'd0),
	.black_stretch(2'd0),
	.brightness(16'sd0),
	.contrast(16'd2857),          // 0.714 V to white
	.comb_mode(2'd0),             // the notch: the chroma does not turn over from line to line
	.ce_out(),
	.pix_out(d_pix),
	.hs_out(d_hs),
	.vs_out(d_vs),
	.hb_out(),
	.vb_out(),
	.r_out(r),
	.g_out(g),
	.b_out(b)
);

// the RGB picture's window, counted from the receiver's sync: X0 dots after HSync (and as many more as the RGB
// picture's blanking ends after its usual place, 412 samples after the sync edge), Y0 lines after VSync
localparam [9:0] X0 = 10'd102;
reg        old_hb;
reg [10:0] hb_end = 11'd412;
always @(posedge clk) begin
	old_hb <= hb_in;
	if (old_hb && !hb_in && !vb_in) hb_end <= cnt;
end
// (only when clearly later: mode 5 and the SR modes, 8 dots; a sample or two either way is not a shift)
wire [10:0] hb_d = hb_end - 11'd412;
wire  [9:0] hb_ofs = hb_end >= 11'd428 ? {1'b0, hb_d[10:2]} : 10'd0;
wire [9:0] x0 = X0 + hb_ofs + (rgb_in ? 10'd2 : 10'd0);   // the later models' path: 2 dots later
localparam [8:0] Y0 = 9'd11;
reg [9:0] px;
reg [8:0] ln;
reg       old_dhs, old_dvs, new_frame;
always @(posedge clk) if (d_pix) begin
	old_dhs <= d_hs;
	old_dvs <= d_vs;
	if (d_vs && !old_dvs) new_frame <= 1'b1;
	if (d_hs && !old_dhs) begin
		px <= 10'd0;
		ln <= new_frame ? 9'd0 : ln + 1'd1;
		new_frame <= 1'b0;
	end
	else px <= px + 1'd1;
	hs <= d_hs;
	vs <= d_vs;
	hb <= px < x0 || px >= x0 + 10'd320;
	vb <= ln < Y0 || ln >= Y0 + 9'd240;
end

assign ce_pix = d_pix;

endmodule
