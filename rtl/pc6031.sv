// PC-6031 mini disk unit (one drive), running its own firmware: a Z80 at 4 MHz with DISK.ROM (the PC-80S31's
// 2 KB ROM, MAME disk.rom sha1 bb7103a0...), 16 KB of RAM, a uPD765 and an 8255 that faces the PC-6001's 8255 at
// D0h-D3h. The two 8255s are wired as in CSCP (vm/pc6001/pc6001.cpp with DISK.ROM): each side's port B drives
// the other's port A, and the halves of port C cross.
//
// Drive memory: 0000h-1FFFh the ROM (mirrored), 4000h-7FFFh RAM. I/O: F8h read = TC, write = motor; FAh/FBh
// the uPD765; FCh-FFh the 8255. The FDC interrupt wakes the firmware's HALT; the acknowledge reads a no-op (CSCP
// PC80S31K::get_intr_ack gives NOP), since the firmware stays in interrupt mode 0.
//
// The firmware treats a drive as single sided (cylinder = track) until the host says otherwise, which suits the
// PC-6001's 1D disks.

module pc6031
(
	input             clk,
	input             reset,

	// DISK.ROM, from the ROM download
	input             rom_wr,
	input      [10:0] rom_addr,
	input       [7:0] rom_d,
	input             rom_ok,         // DISK.ROM was loaded: without it the unit is not connected

	// the PC-6001 side: ports D0h-D3h
	input       [1:0] addr,
	input             rd,
	input             wr,
	input       [7:0] din,
	output      [7:0] dout,

	// the disk image (hps_io S0)
	input             img_mounted,
	input             img_readonly,
	input      [63:0] img_size,
	output     [31:0] sd_lba,
	output            sd_rd,
	output            sd_wr,
	input             sd_ack,
	input       [8:0] sd_buff_addr,
	input       [7:0] sd_buff_dout,
	output      [7:0] sd_buff_din,
	input             sd_buff_wr,

	output            disk_ready,
	output            disk_too_big,
	output reg        motor
);

wire drv_reset = reset | ~rom_ok;

// 4 MHz from 28.636364 MHz
reg [14:0] ce_acc = 0;
reg        ce = 0;
always @(posedge clk) begin
	if (ce_acc + 15'd4000 >= 15'd28636) begin ce_acc <= ce_acc + 15'd4000 - 15'd28636; ce <= 1'b1; end
	else begin ce_acc <= ce_acc + 15'd4000; ce <= 1'b0; end
end

wire        mreq_n, iorq_n, rd_n, wr_n, m1_n;
wire [15:0] A;
wire  [7:0] cpu_dout;
reg   [7:0] cpu_din;
wire        fdc_int;

`ifdef VERILATOR
T80s cpu
`else
T80s #(.Mode(0), .T2Write(1), .IOWait(1)) cpu
`endif
(
	.RESET_n(~drv_reset),
	.CLK(clk),
	.CEN(ce),
	.OUT0(1'b0),
	.WAIT_n(1'b1),
	.INT_n(~fdc_int),
	.NMI_n(1'b1),
	.BUSRQ_n(1'b1),
	.M1_n(m1_n),
	.MREQ_n(mreq_n),
	.IORQ_n(iorq_n),
	.RD_n(rd_n),
	.WR_n(wr_n),
	.RFSH_n(),
	.HALT_n(),
	.BUSAK_n(),
	.A(A),
	.DI(cpu_din),
	.DO(cpu_dout)
);

// memory
reg [7:0] rom[0:2047];
reg [7:0] ram[0:16383];
reg [7:0] rom_q, ram_q;
always @(posedge clk) begin
	if (rom_wr) rom[rom_addr] <= rom_d;
	rom_q <= rom[A[10:0]];
end
wire ram_sel = A[15:14] == 2'b01;
always @(posedge clk) begin
	if (ce && ~mreq_n && ~wr_n && ram_sel) ram[A[13:0]] <= cpu_dout;
	ram_q <= ram[A[13:0]];
end

wire sel_f8  = A[7:0] == 8'hf8;
wire sel_fdc = A[7:1] == 7'b1111_101;    // FAh, FBh
wire sel_pio = A[7:2] == 6'b1111_11;     // FCh-FFh

// I/O strobes, one clk at the start of an access
wire io_cyc = ~iorq_n & m1_n;
wire inta   = ~iorq_n & ~m1_n;
reg  io_rd_d, io_wr_d;
always @(posedge clk) begin
	io_rd_d <= io_cyc & ~rd_n;
	io_wr_d <= io_cyc & ~wr_n;
end
wire io_rd = io_cyc & ~rd_n & ~io_rd_d;
wire io_wr = io_cyc & ~wr_n & ~io_wr_d;
// a read with a side effect (the FDC's data register moves on) acts at the end of the access: the T80 takes the
// data later in the cycle than the first clk
reg  rd_fdc, rd_a0;
always @(posedge clk) if (io_rd) begin rd_fdc <= sel_fdc; rd_a0 <= A[0]; end
wire io_rd_end = io_rd_d & ~(io_cyc & ~rd_n);

always @(posedge clk) begin
	if (drv_reset) motor <= 0;
	else if (io_wr && sel_f8) motor <= cpu_dout != 0;
end

// the uPD765 and the disk
wire [17:0] m_addr;
wire  [7:0] m_q, m_d, fdc_dout;
wire        m_we, m_ready, m_wprot;

upd765_lite fdc
(
	.clk(clk),
	.reset(drv_reset),
	.a0(io_rd_end ? rd_a0 : A[0]),
	.rd(io_rd_end & rd_fdc),
	.wr(io_wr & sel_fdc),
	.din(cpu_dout),
	.dout(fdc_dout),
	.tc(io_rd & sel_f8),
	.int_o(fdc_int),
	.m_addr(m_addr),
	.m_q(m_q),
	.m_we(m_we),
	.m_d(m_d),
	.m_ready(m_ready),
	.m_wprot(m_wprot)
);

// not reset with the machine: a reset keeps the disk
d88_media media
(
	.clk(clk),
	.reset(1'b0),
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
	.addr(m_addr),
	.q(m_q),
	.we(m_we),
	.d(m_d),
	.ready(m_ready),
	.wprot(m_wprot),
	.too_big(disk_too_big)
);
assign disk_ready = m_ready;

// the two 8255s
wire [7:0] h_pa, h_pb, h_pc, d_pa, d_pb, d_pc, h_dout, d_dout;

i8255_m0 host_pio
(
	.clk(clk), .reset(drv_reset),
	.addr(addr), .rd(rd), .wr(wr), .din(din), .dout(h_dout),
	.pa_i(d_pb), .pb_i(d_pa), .pc_i({d_pc[3:0], d_pc[7:4]}),
	.pa_o(h_pa), .pb_o(h_pb), .pc_o(h_pc)
);

i8255_m0 drive_pio
(
	.clk(clk), .reset(drv_reset),
	.addr(A[1:0]), .rd(io_rd & sel_pio), .wr(io_wr & sel_pio), .din(cpu_dout), .dout(d_dout),
	.pa_i(h_pb), .pb_i(h_pa), .pc_i({h_pc[3:0], h_pc[7:4]}),
	.pa_o(d_pa), .pb_o(d_pb), .pc_o(d_pc)
);

assign dout = rom_ok ? h_dout : 8'hff;

// The acknowledge's instruction, held until the next opcode fetch. CSCP gives NOP (00h), but the T80 runs 00h in
// an interrupt cycle as its IM 2 sequence (push PC, jump through the vector), so LD A,A (7Fh): it does nothing.
reg ack_nop = 0;
always @(posedge clk) begin
	if (inta) ack_nop <= 1'b1;
	else if (~m1_n & ~mreq_n) ack_nop <= 1'b0;
end

always @(*) begin
	if (inta | ack_nop) cpu_din = 8'h7f;
	else if (~iorq_n) cpu_din = sel_fdc ? fdc_dout : sel_pio ? d_dout : 8'hff;
	else if (A[15:13] == 3'b000) cpu_din = rom_q;
	else if (ram_sel) cpu_din = ram_q;
	else cpu_din = 8'hff;
end

endmodule
