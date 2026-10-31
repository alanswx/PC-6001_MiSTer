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
   input         tape_turbo,
   input         tape_overlay,
   input         tape_rewind,

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

assign ioctl_wait = 1'b0;

wire [15:0] audio;
assign AUDIO_L = audio;
assign AUDIO_R = audio;

wire [7:0]  R, G, B;
wire        tape_turbo_on;
wire [43:0] tape_status_word;
wire  [1:0] tape_hint;
wire        tape_status_req, tape_status_ack;

pc6001 #(.TURBO(TURBO)) pc6001
(
   .clk_sys(clk_sys),
   .reset(reset),
   .ram16k(ram16k),
   .tape_turbo(tape_turbo),
   .tape_rewind(tape_rewind),
   .cart_eject(1'b0),
   .ps2_key(ps2_key),
   .kbd_us(kbd_us),
   .joy0(joy0), .joy1(joy1),

   .ioctl_download(ioctl_download),
   .ioctl_index(ioctl_index),
   .ioctl_wr(ioctl_wr),
   .ioctl_addr(ioctl_addr),
   .ioctl_dout(ioctl_dout),

   .ce_pix(ce_pix),
   .R(R), .G(G), .B(B),
   .HSync(VGA_HS), .VSync(VGA_VS),
   .HBlank(VGA_HB), .VBlank(VGA_VB),

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

tape_overlay #(.FACTOR(4'(TURBO))) tape_overlay_i
(
   .clk(clk_sys), .ce_pix(ce_pix), .hblank(VGA_HB), .vblank(VGA_VB), .enable(tape_overlay),
   .status(tape_status_word), .req(tape_status_req), .ack(tape_status_ack),
   .rgb_in({R, G, B}), .rgb_out({VGA_R, VGA_G, VGA_B})
);

endmodule
