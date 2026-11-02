`timescale 1ns/1ns
//
// Simulation top for the PC-6001 core: the machine (rtl/pc6001.sv) with its ports made visible to the C++
// harness (sim_headless.cpp). It stands in for PC6001.sv (the MiSTer top); the harness plays hps_io
// (ps2_key and the ioctl ROM download). The tape status bar is mixed in as in PC6001.sv.
//
module top #(
   parameter int TURBO = 7      // tape turbo factor; make TURBO=N builds obj_dir_headless_tN
)(
   input         clk_sys /*verilator public_flat*/,
   input         reset /*verilator public_flat*/,
   input         ram16k,
   input   [1:0] model,            // OSD Model: 0 PC-6001, 1 PC-6001mkII, 2 PC-6601
   input         tape_turbo,
   input         tape_overlay,
   input         tape_rewind,
   input         composite,        // the picture through rtl/pc6001_composite.sv
   input   [2:0] comp_bw,          // bw_tv (rtl/pc6001_composite.sv)

   output [7:0]  VGA_R /*verilator public_flat*/,
   output [7:0]  VGA_G /*verilator public_flat*/,
   output [7:0]  VGA_B /*verilator public_flat*/,
   output        VGA_HS /*verilator public_flat*/,
   output        VGA_VS /*verilator public_flat*/,
   output        VGA_HB /*verilator public_flat*/,
   output        VGA_VB /*verilator public_flat*/,
   output        ce_pix /*verilator public_flat*/,

   output [15:0] AUDIO_L /*verilator public_flat*/,
   output [15:0] AUDIO_R /*verilator public_flat*/,

   input  [10:0] ps2_key,
   input         kbd_us,
   input   [5:0] joy0,
   input   [5:0] joy1,
   input         touch_en,
   input   [7:0] touch_x,
   input   [7:0] touch_y,
   input         touch_pen,
   input         touch_mouse_on,   // the panel from ps2_mouse through rtl/touch_mouse.sv instead of touch_x/y/pen
   input  [24:0] ps2_mouse,
   output        tape_motor /*verilator public_flat*/,
   output        tape_loaded /*verilator public_flat*/,
   output [16:0] tape_position /*verilator public_flat*/,
   output [16:0] tape_length /*verilator public_flat*/,

   input         ioctl_download,
   input   [7:0] ioctl_index,
   input         ioctl_wr,
   input  [24:0] ioctl_addr,
   input   [7:0] ioctl_dout,
   output        ioctl_wait,

   // the disk image, as hps_io's S0 (sim_headless.cpp serves the blocks)
   input         img_mounted,
   input         img_readonly,
   input  [63:0] img_size,
   output [31:0] sd_lba,
   output        sd_rd,
   output        sd_wr,
   input         sd_ack,
   input   [8:0] sd_buff_addr,
   input   [7:0] sd_buff_dout,
   output  [7:0] sd_buff_din,
   input         sd_buff_wr,
   output        disk_motor /*verilator public_flat*/,
   output        disk_ready /*verilator public_flat*/,

   output [15:0] cpu_addr /*verilator public_flat*/,
   output        cpu_ce /*verilator public_flat*/,
   output        cpu_m1_n /*verilator public_flat*/,
   output        dbg_io_wr /*verilator public_flat*/,
   output        dbg_io_rd /*verilator public_flat*/,
   output [7:0]  dbg_io_port /*verilator public_flat*/,
   output [7:0]  dbg_io_data /*verilator public_flat*/
);

wire [7:0] m_x, m_y;
wire       m_pen;
touch_mouse touch_mouse_i(.clk(clk_sys), .ps2_mouse(ps2_mouse), .x(m_x), .y(m_y), .pen(m_pen));
wire [7:0] tp_x = touch_mouse_on ? m_x : touch_x;
wire [7:0] tp_y = touch_mouse_on ? m_y : touch_y;
wire       tp_pen = touch_mouse_on ? m_pen : touch_pen;



wire [15:0] audio;
assign AUDIO_L = audio;
assign AUDIO_R = audio;

wire [7:0]  R, G, B;
wire        rgb_pix, HSync, VSync, HBlank, VBlank, mono;
wire  [4:0] cidx;
wire        tape_turbo_on;
wire [43:0] tape_status_word;
wire  [1:0] tape_hint;
wire        tape_status_req, tape_status_ack;

pc6001 #(.TURBO(TURBO)) pc6001
(
   .clk_sys(clk_sys),
   .reset(reset),
   .model(model),
   .ioctl_wait(ioctl_wait),
   .ram16k(ram16k),
   .tape_turbo(tape_turbo),
   .tape_rewind(tape_rewind),
   .cart_eject(1'b0),
   .ps2_key(ps2_key),
   .kbd_us(kbd_us),
   .joy0(joy0), .joy1(joy1),
   .touch_en(touch_en), .touch_x(tp_x), .touch_y(tp_y), .touch_pen(tp_pen),

   .ioctl_download(ioctl_download),
   .ioctl_index(ioctl_index),
   .ioctl_wr(ioctl_wr),
   .ioctl_addr(ioctl_addr),
   .ioctl_dout(ioctl_dout),

   .ce_pix(rgb_pix),
   .R(R), .G(G), .B(B),
   .HSync(HSync), .VSync(VSync),
   .HBlank(HBlank), .VBlank(VBlank), .mono(mono), .cidx(cidx),

   .audio(audio),
   .tape_motor(tape_motor),
   .tape_loaded(tape_loaded),
   .tape_too_big(),
   .tape_turbo_on(tape_turbo_on),
   .tape_position(tape_position),
   .tape_length(tape_length),
   .tape_hint(tape_hint),
   .cart_too_big(),

   .img_mounted(img_mounted), .img_readonly(img_readonly), .img_size(img_size),
   .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
   .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din), .sd_buff_wr(sd_buff_wr),
   .ddr_busy(ddr_busy), .ddr_burstcnt(), .ddr_addr(ddr_addr), .ddr_dout(ddr_dout),
   .ddr_dout_ready(ddr_dout_ready), .ddr_rd(ddr_rd), .ddr_din(ddr_din), .ddr_be(ddr_be), .ddr_we(ddr_we),
   .disk_ready(disk_ready), .disk_too_big(), .disk_motor(disk_motor), .disk_unit(),

   .cpu_addr(cpu_addr),
   .cpu_ce(cpu_ce),
   .cpu_m1_n(cpu_m1_n),
   .dbg_io_wr(dbg_io_wr),
   .dbg_io_rd(dbg_io_rd),
   .dbg_io_port(dbg_io_port),
   .dbg_io_data(dbg_io_data)
);

tape_status tape_status
(
   .clk(clk_sys),
   .loaded(tape_loaded), .playing(tape_motor), .fast(tape_turbo_on),
   .position({15'd0, tape_position}), .length({15'd0, tape_length}), .hz(18'd100),
   .hint(tape_hint),
   .status(tape_status_word), .req(tape_status_req), .ack(tape_status_ack)
);

wire       c_pix, c_hs, c_vs, c_hb, c_vb;
wire [7:0] c_r, c_g, c_b;
pc6001_composite pc6001_composite
(
   .clk(clk_sys), .reset(reset), .mono(mono), .bw_tv(comp_bw),
   .cidx(cidx), .hs_in(HSync), .vs_in(VSync), .hb_in(HBlank), .vb_in(VBlank),
   .ce_pix(c_pix), .r(c_r), .g(c_g), .b(c_b), .hs(c_hs), .vs(c_vs), .hb(c_hb), .vb(c_vb)
);
assign ce_pix = composite ? c_pix : rgb_pix;
assign VGA_HS = composite ? c_hs : HSync;
assign VGA_VS = composite ? c_vs : VSync;
assign VGA_HB = composite ? c_hb : HBlank;
assign VGA_VB = composite ? c_vb : VBlank;
wire [23:0] video = composite ? {c_r, c_g, c_b} : {R, G, B};

wire [23:0] cursor_rgb;
touch_cursor touch_cursor_i
(
   .clk(clk_sys), .ce_pix(ce_pix), .hblank(VGA_HB), .vblank(VGA_VB), .enable(touch_en),
   .x(tp_x), .y(tp_y), .pen(tp_pen),
   .rgb_in(video), .rgb_out(cursor_rgb)
);

tape_overlay #(.FACTOR(4'(TURBO))) tape_overlay_i
(
   .clk(clk_sys), .ce_pix(ce_pix), .hblank(VGA_HB), .vblank(VGA_VB), .enable(tape_overlay),
   .status(tape_status_word), .req(tape_status_req), .ack(tape_status_ack),
   .rgb_in(cursor_rgb), .rgb_out({VGA_R, VGA_G, VGA_B})
);


// DDR3 (sys/ddr_svc's side of emu): 512 KB at the disk image's base, one access at a time, busy now and then and
// reads coming back some clocks later, as the real one
wire        ddr_rd, ddr_we;
wire [28:0] ddr_addr;
wire [63:0] ddr_din;
wire  [7:0] ddr_be;
reg  [63:0] ddr_dout;
reg         ddr_dout_ready = 0;
reg  [63:0] ddr_mem[0:262143];   // 2 MB: the disk image at 0, the ROM store at 20000h words
reg   [3:0] ddr_lat = 0;
reg  [17:0] ddr_ra;
reg   [7:0] ddr_lfsr = 8'h5a;
wire        ddr_busy = ddr_lfsr[0] & ddr_lfsr[3] | ddr_lat != 0;
always @(posedge clk_sys) begin
   ddr_lfsr <= {ddr_lfsr[6:0], ddr_lfsr[7] ^ ddr_lfsr[5] ^ ddr_lfsr[4] ^ ddr_lfsr[3]};
   ddr_dout_ready <= 0;
   if (ddr_lat != 0) begin
      ddr_lat <= ddr_lat - 1'd1;
      if (ddr_lat == 1) begin ddr_dout <= ddr_mem[ddr_ra]; ddr_dout_ready <= 1; end
   end
   else if (!ddr_busy) begin
      if (ddr_rd) begin ddr_ra <= ddr_addr[17:0]; ddr_lat <= 4'd10; end
      if (ddr_we) begin : wr
         integer i;
         for (i = 0; i < 8; i = i + 1) if (ddr_be[i]) ddr_mem[ddr_addr[17:0]][i*8 +: 8] <= ddr_din[i*8 +: 8];
      end
   end
end


`ifdef VSP_TRACE
// make EXTRA=-DVSP_TRACE: the uPD7752's frames and samples, for runs/.../ref7752.c (PC6001VX's engine)
always @(posedge clk_sys) begin
   if (pc6001.vsp.wr && pc6001.vsp.addr == 2'd2) $display("vsp wr 2 %02x", pc6001.vsp.din);
   if (pc6001.vsp.setup && pc6001.vsp.sidx == 0 && pc6001.vsp.dstep == 0)
      $display("vsp frame %02x %02x %02x %02x %02x %02x %02x", pc6001.vsp.pbuf[0], pc6001.vsp.pbuf[1], pc6001.vsp.pbuf[2],
               pc6001.vsp.pbuf[3], pc6001.vsp.pbuf[4], pc6001.vsp.pbuf[5], pc6001.vsp.pbuf[6]);
   if (pc6001.vsp.es == 4'd5) $display("vsp s %0d", pc6001.vsp.y);
end
`endif


`ifdef TAPE_TRACE
// make EXTRA=-DTAPE_TRACE: tape bytes the sub CPU drops because the Z80 has not taken the one before
always @(posedge clk_sys)
   if (pc6001.sub.tape_strobe && pc6001.sub.cmt_st == 2'd1 && pc6001.sub.req_cmtr)
      $display("tape drop frame-cycle %0d", $time);
`endif

endmodule
