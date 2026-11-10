//============================================================================
//  NEC PC-6001 for MiSTer
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301  USA.
//
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;
assign DDRAM_CLK = clk_sys;   // the disk image (rtl/d88_media.sv)

assign VGA_SL = 0;
assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S = 1;
assign AUDIO_MIX = 0;

assign LED_DISK = {1'b0, disk_motor};
assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

wire [1:0] ar = cfg[122:121];

assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;

// The OSD follows the computer-core OSD and tape standards: media on the top page (an MGL can only name rows
// there), then the Machine, Video and Input pages. Settings take effect at the next reset (cfg) and "Changes
// pending" shows until then; Tape speed, Tape overlay, Swap Alt/Win keys, Video and B/W colours
// act at once.
// Status bits: 0 reset, 1 memory, 2 unused (old Fast tape), 3 rewind tape, 4 tape speed, 5 tape overlay,
// 6 swap Alt/Win keys, 7 remove cartridge, 8 keyboard, 9 touch panel, 10 video, 11-13 B/W colours (the black/white
// graphics mode on a TV; in RGB, mode 4 coloured as PC6001VX does), 14-15 model, 16 tape auto-start, 121-122 aspect ratio.
`include "build_id.v"
// Tape turbo factor: the Z80 and the tape run TURBO times as fast while the motor relay is on (rtl/pc6001.sv)
localparam int TURBO = 7;
localparam CONF_STR = {
	"PC6001;;",
	"-;",
	// A cartridge boots at reset, so it is not remembered either: a core start goes to BASIC.
	"F2,ROMBIN60,Cartridge;",
	// PC-6031 disk unit, when boot.rom has DISK.ROM: a .d88 image, written back as the drive changes it
	"S0,D88,Disk;",
	// The whole image is loaded into the core; not remembered (F, not FC), so a core start has no tape.
	"F1,P6 CASP6T,Tape;",
	"F0,ROM,Load ROM;",
	"-;",
	"O[1],Memory,32 KB,16 KB;",
	"-;",
	"P1,Machine;",
	"P2,Video;",
	"P3,Input;",
	"-;",
	"h0-,Changes pending;",
	"R[0],Apply and reset;",

	"P1O[15:14],Model,PC-6001,PC-6001mkII,PC-6601,PC-6001mkIISR;",
	"P1-;",
	"P1O[4],Tape speed,", 8'h30 + 8'(TURBO), "x,Normal;",
	"P1O[16],Tape auto-start,On,Off;",
	"P1-;",
	"P1T[7],Remove cartridge;",
	"P1T[3],Rewind tape;",

	"P2O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"P2O[5],Tape overlay,On,Off;",
	"P2-;",
	"P2O[10],Video,RGB,Composite (TV);",
	"P2O[13:11],B/W colours,Red/Blue,Blue/Red,Pink/Green,Green/Pink,None (grey);",

	"P3O[8],Keyboard,JP (positions),US (symbols);",
	"P3O[6],Swap Alt/Win keys,No,Yes;",
	"P3O[9],Port 2,Joystick,Touch panel (mouse);",

	"I,Tape ready (rewound),Tape too large (64 KB max),Cartridge too large (16 KB max),Disk too large (512 KB max),No disk unit (boot.rom without DISK.ROM);",
	"v,0;",
	"V,v",`BUILD_DATE,
	";J1,Trigger 1,Trigger 2;",
	"jn,A,B;"
};

wire forced_scandoubler;
wire   [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key_raw;
wire  [31:0] joystick_0, joystick_1;
wire  [24:0] ps2_mouse;

wire         ioctl_download;
wire   [7:0] ioctl_index;
wire         ioctl_wait;   // rtl/rom_store.sv
wire         ioctl_wr;
wire  [26:0] ioctl_addr;
wire   [7:0] ioctl_dout;

wire        img_mounted, img_readonly, sd_rd, sd_wr, sd_ack, sd_buff_wr;
wire [63:0] img_size;
wire [31:0] sd_lba;
wire  [8:0] sd_buff_addr;
wire  [7:0] sd_buff_dout, sd_buff_din;
wire        disk_ready, disk_too_big, disk_motor, disk_unit;

hps_io #(.CONF_STR(CONF_STR), .VDNUM(1)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_in(status_in),
	.status_set(status_set),
	.status_menumask({15'd0, osd_pending}),
	.info_req(tape_info_req),
	.info(tape_info),

	.ps2_key(ps2_key_raw),
	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.ps2_mouse(ps2_mouse),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),
	.sd_lba('{sd_lba}),
	.sd_blk_cnt('{6'd0}),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din('{sd_buff_din}),
	.sd_buff_wr(sd_buff_wr)
);


///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys;   // 28.636 MHz
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys)
);

// Loading a ROM or a cartridge, or removing the cartridge, resets the machine (BASIC boots a cartridge at reset)
wire reset = RESET | status[0] | buttons[1] | status[7] |
             (ioctl_download & (ioctl_index[5:0] == 6'd0 | ioctl_index[5:0] == 6'd2));

// The settings the machine runs with, taken from the OSD at every reset (Apply and reset, the board's reset,
// Load ROM, a core reload). The game list (rtl/tape_auto.sv) can switch the model for a tape: at once here, and in
// the OSD through status_set; tape auto-start's reset follows.
reg [127:0] cfg;
reg [127:0] status_in;
reg         status_set;
wire        model_set;
wire  [1:0] model_req;
always @(posedge clk_sys) begin
	status_set <= 1'b0;
	if (reset) cfg <= status;
	else if (model_set) begin
		cfg[15:14] <= model_req;
		status_in <= {status[127:16], model_req, status[13:0]};
		status_set <= 1'b1;
	end
end
wire osd_pending = {status[15:14], status[1], status[122:121]} != {cfg[15:14], cfg[1], cfg[122:121]};

// Swap Alt/Win keys (acts at once): the Win keys become GRAPH and the Alt keys nothing
wire [8:0] key_code = ps2_key_raw[8:0];
reg  [8:0] key_swapped;
always @(*) begin
	key_swapped = key_code;
	if (status[6]) case (key_code)
	9'h011: key_swapped = 9'h11F;   // left Alt <-> left Win
	9'h11F: key_swapped = 9'h011;
	9'h111: key_swapped = 9'h127;   // right Alt <-> right Win
	9'h127: key_swapped = 9'h111;
	default: ;
	endcase
end
wire [10:0] ps2_key = {ps2_key_raw[10:9], key_swapped};

//////////////////////////////////////////////////////////////////

wire [15:0] audio;
assign AUDIO_L = audio;
assign AUDIO_R = audio;

wire rgb_hb, rgb_hs, rgb_vb, rgb_vs, mono;
wire [4:0] cidx;
wire rgb_pix;
wire [7:0] rgb_r, rgb_g, rgb_b;
wire        tape_motor, tape_loaded, tape_too_big, tape_turbo_on, cart_too_big;
wire [16:0] tape_position, tape_length;
wire         hint_show, hint_two, hint_force;
wire [383:0] hint_text;

// Touch panel on joystick port 2 (OSD), worked with the mouse
wire [7:0] touch_x, touch_y;
wire       touch_pen;
touch_mouse touch_mouse
(
	.clk(clk_sys),
	.ps2_mouse(ps2_mouse),
	.x(touch_x),
	.y(touch_y),
	.pen(touch_pen)
);

pc6001 #(.TURBO(TURBO)) pc6001
(
	.clk_sys(clk_sys),
	.reset(reset),
	.model(cfg[15:14]),    // the mkII's ROMs are boot1.rom, the PC-6601's boot2.rom, the mkIISR's boot3.rom
	.ram16k(cfg[1]),
	.tape_turbo(~status[4]),
	.tape_rewind(status[3]),
	.cart_eject(status[7]),
	.tape_autostart(~status[16]),
	.m4col(status[10] && cfg[15:14] != 2'd0 ? 3'd4 : status[13:11]),   // composite: the colours come from the dots

	.ps2_key(ps2_key),
	.kbd_us(status[8]),
	.joy0(joystick_0[5:0]),
	.joy1(joystick_1[5:0]),
	.touch_en(status[9]),
	.touch_x(touch_x),
	.touch_y(touch_y),
	.touch_pen(touch_pen),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr[24:0]),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

	.ce_pix(rgb_pix),
	.R(rgb_r), .G(rgb_g), .B(rgb_b),
	.HSync(rgb_hs), .VSync(rgb_vs),
	.HBlank(rgb_hb), .VBlank(rgb_vb),
	.mono(mono),
	.cidx(cidx),

	.audio(audio),
	.tape_motor(tape_motor),
	.tape_loaded(tape_loaded),
	.tape_too_big(tape_too_big),
	.tape_turbo_on(tape_turbo_on),
	.tape_position(tape_position),
	.tape_length(tape_length),
	.hint_show(hint_show),
	.hint_two(hint_two),
	.hint_text(hint_text),
	.hint_force(hint_force),
	.model_set(model_set),
	.model_req(model_req),
	.cart_too_big(cart_too_big),
	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),
	.sd_lba(sd_lba),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr),
	.ddr_busy(DDRAM_BUSY),
	.ddr_burstcnt(DDRAM_BURSTCNT),
	.ddr_addr(DDRAM_ADDR),
	.ddr_dout(DDRAM_DOUT),
	.ddr_dout_ready(DDRAM_DOUT_READY),
	.ddr_rd(DDRAM_RD),
	.ddr_din(DDRAM_DIN),
	.ddr_be(DDRAM_BE),
	.ddr_we(DDRAM_WE),
	.disk_ready(disk_ready),
	.disk_too_big(disk_too_big),
	.disk_motor(disk_motor),
	.disk_unit(disk_unit),

	.cpu_addr(), .cpu_ce(), .cpu_m1_n(),
	.dbg_io_wr(), .dbg_io_rd(), .dbg_io_port(), .dbg_io_data()
);

// One OSD message per tape download: ready (rewound), or cut off at 64 KB; and one for a cartridge cut off at
// 16 KB
reg       tape_info_req = 0;
reg [7:0] tape_info = 0;
reg       old_tape_dl = 0, old_cart_dl = 0, old_mount = 0;
always @(posedge clk_sys) begin
	old_tape_dl <= ioctl_download && ioctl_index[5:0] == 6'd1;
	old_cart_dl <= ioctl_download && ioctl_index[5:0] == 6'd2;
	tape_info_req <= 0;
	if (old_tape_dl && !(ioctl_download && ioctl_index[5:0] == 6'd1)) begin
		tape_info <= tape_too_big ? 8'd2 : 8'd1;
		tape_info_req <= 1;
	end
	if (old_cart_dl && !(ioctl_download && ioctl_index[5:0] == 6'd2) && cart_too_big) begin
		tape_info <= 8'd3;
		tape_info_req <= 1;
	end
	// a disk mounted: too large, or no unit to put it in
	old_mount <= img_mounted;
	if (old_mount && !img_mounted && img_size != 0) begin
		if (!disk_unit) begin tape_info <= 8'd5; tape_info_req <= 1; end
		else if (img_size > 64'd180224) begin tape_info <= 8'd4; tape_info_req <= 1; end
	end
end

// Tape status bar while the deck plays, next-step hint while it is stopped (tape standard): bytes at 100 per second
wire [427:0] tape_status_word;
wire        tape_status_req, tape_status_ack;

tape_status tape_status
(
	.clk(clk_sys),
	.loaded(tape_loaded | hint_force),
	.playing(tape_motor && !hint_force),
	.fast(tape_turbo_on),
	.position({15'd0, tape_position}),
	.length({15'd0, tape_length}),
	.hz(18'd100),
	.hint_show(hint_show),
	.hint_two(hint_two),
	.hint_text(hint_text),
	.status(tape_status_word),
	.req(tape_status_req),
	.ack(tape_status_ack)
);

// OSD Video: the RGB picture, or the same through an NTSC encoder and a TV's decoder (colour bleed, dot patterns
// turned to colour)
wire       c_pix, c_hs, c_vs, c_hb, c_vb;
wire [7:0] c_r, c_g, c_b;
pc6001_composite pc6001_composite
(
	.clk(clk_sys),
	.reset(reset),
	.mono(mono),
	.bw_tv(status[13:11]),
	.cidx(cidx),
	.rgb_in(cfg[15:14] != 2'd0),
	.r_in(rgb_r), .g_in(rgb_g), .b_in(rgb_b),
	.hs_in(rgb_hs), .vs_in(rgb_vs), .hb_in(rgb_hb), .vb_in(rgb_vb),
	.ce_pix(c_pix),
	.r(c_r), .g(c_g), .b(c_b),
	.hs(c_hs), .vs(c_vs), .hb(c_hb), .vb(c_vb)
);

wire       composite = status[10];
wire       ce_pix = composite ? c_pix : rgb_pix;
wire       HBlank = composite ? c_hb : rgb_hb;
wire       VBlank = composite ? c_vb : rgb_vb;
wire       HSync = composite ? c_hs : rgb_hs;
wire       VSync = composite ? c_vs : rgb_vs;
wire [7:0] R = composite ? c_r : rgb_r;
wire [7:0] G = composite ? c_g : rgb_g;
wire [7:0] B = composite ? c_b : rgb_b;

// the pen's place, while the touch panel is in
wire [23:0] cursor_rgb;
touch_cursor touch_cursor
(
	.clk(clk_sys),
	.ce_pix(ce_pix),
	.hblank(HBlank),
	.vblank(VBlank),
	.enable(status[9]),
	.x(touch_x),
	.y(touch_y),
	.pen(touch_pen),
	.rgb_in({R, G, B}),
	.rgb_out(cursor_rgb)
);

tape_overlay #(.FACTOR(4'(TURBO))) tape_overlay
(
	.clk(clk_sys),
	.ce_pix(ce_pix),
	.hblank(HBlank),
	.vblank(VBlank),
	.enable(~status[5]),
	.status(tape_status_word),
	.req(tape_status_req),
	.ack(tape_status_ack),
	.rgb_in(cursor_rgb),
	.rgb_out({VGA_R, VGA_G, VGA_B})
);

assign CLK_VIDEO = clk_sys;
assign CE_PIXEL = ce_pix;

assign VGA_DE = ~(HBlank | VBlank);
assign VGA_HS = HSync;
assign VGA_VS = VSync;

assign LED_USER = ioctl_download;

endmodule
