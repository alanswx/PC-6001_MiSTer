// The PC-6601's built-in floppy interface, after PC6001VX (disk.cpp DSK66): a uPD765 (rtl/upd765_lite.sv) the
// main Z80 drives itself, and a 1 KB buffer the FDC's data goes to and from. The CPU copies a sector in or out
// of the buffer with INIR / OTIR: the buffer address is the port's low 2 bits and the B register.
//
//   B1h W  b2 1: the external disk unit instead (not connected here)    B2h R  FFh while the FDC interrupts, else 0Eh
//   B3h W  b0 1: B2h is an output (then no interrupt is shown)
//   D0h-D3h R/W  the buffer                                             D4h R  the motor (0)
//   DAh W  the transfer size: (0Fh - data) x 256 bytes, at least one sector (PC6001VX reads one even for 0)
//   DCh R  the FDC's status                                             DDh R/W  the FDC's data register
//   D6h, D8h, DEh W  motor, write precompensation: ignored
//
// The FDC runs in its non-DMA mode; a transfer engine here moves each byte between it and the buffer from
// address 0, and ends the command (TC) after the transfer size. Meanwhile the CPU sees the FDC busy and not
// ready, and is not interrupted: as PC6001VX, it waits for the result. One drive (drive 0).

module fdc66
(
	input             clk,
	input             reset,

	input      [15:0] addr,           // the I/O address (A15-A8 = B for the buffer)
	input             sel,            // B1h-B3h, D0h-DFh
	input             rd,             // one clk, the start of the read
	input             rd_lvl,         // the read access (its end pops the FDC's data register)
	input             wr,
	input       [7:0] din,
	output reg  [7:0] dout,

	// the disk image (rtl/d88_media.sv, the PC-6031's)
	output     [19:0] m_addr,
	output            m_rd,
	input       [7:0] m_q,
	input             m_done,
	output            m_we,
	output      [7:0] m_d,
	input             m_ready,
	input             m_wprot,
	input             m_one_side      // the image's track table is indexed by cylinder
);

wire [7:0] port = addr[7:0];

reg        b2dir = 0;
reg        ext = 0;                      // B1h b2: D0h-D3h are the external unit's (none: they read FFh)
reg [11:0] sendbytes = 0;
always @(posedge clk) begin
	if (reset) begin b2dir <= 0; sendbytes <= 0; ext <= 0; end
	else if (wr && sel) begin
		if (port == 8'hb1) ext <= din[2];
		if (port == 8'hb3) b2dir <= din[0];
		if (port == 8'hda) sendbytes <= din[3:0] == 4'hf ? 12'h100 : {4'hf - din[3:0], 8'd0};
	end
end

// the buffer: port A the CPU, port B the transfer engine
reg  [7:0] buffer[0:1023];
reg  [7:0] buf_cpu_q, buf_dma_q;
wire [9:0] buf_cpu_a = {port[1:0], addr[15:8]};
wire       buf_cpu_we = wr && sel && port[7:2] == 6'b1101_00 && !ext;
reg  [9:0] bptr;
reg        buf_dma_we;
reg  [7:0] buf_dma_d;
// one write port (the CPU and the engine never write at the same time) and two read ports, so it is block RAM
wire       buf_we = buf_cpu_we | buf_dma_we;
wire [9:0] buf_wa = buf_dma_we ? bptr : buf_cpu_a;
wire [7:0] buf_wd = buf_dma_we ? buf_dma_d : din;
always @(posedge clk) if (buf_we) buffer[buf_wa] <= buf_wd;
always @(posedge clk) buf_cpu_q <= buffer[buf_cpu_a];
always @(posedge clk) buf_dma_q <= buffer[bptr];

// the FDC's data register: the CPU's read takes effect at the end of its access (the T80 samples late)
reg        rd_lvl_d;
reg  [7:0] rd_port;
always @(posedge clk) begin
	rd_lvl_d <= rd_lvl;
	if (rd_lvl) rd_port <= port;
end
wire       cpu_dd_rd = rd_lvl_d && !rd_lvl && rd_port == 8'hdd;
wire       cpu_dd_wr = wr && sel && port == 8'hdd;

wire [7:0] fdc_dout, fdc_msr;
wire       fdc_exec, fdc_drq, fdc_res_int;
reg        dma_rd, dma_wr, tc;
reg        dir_read;                     // the command reads the disk (the FDC sends)

upd765_lite fdc
(
	.clk(clk),
	.reset(reset),
	.a0(1'b1),
	.rd(dma_rd | (cpu_dd_rd & ~fdc_exec)),
	.wr(dma_wr | (cpu_dd_wr & ~fdc_exec)),
	.din(dma_wr ? buf_dma_q : din),
	.dout(fdc_dout),
	.tc(tc),
	.int_o(),
	.exec(fdc_exec),
	.drq_o(fdc_drq),
	.msr_o(fdc_msr),
	.res_int(fdc_res_int),
	.dd(1'b0),
	.m_drv(),
	.m_addr(m_addr),
	.m_rd(m_rd),
	.m_q(m_q),
	.m_done(m_done),
	.m_we(m_we),
	.m_d(m_d),
	.m_ready({1'b0, m_ready}),
	.m_wprot({1'b0, m_wprot}),
	.m_one_side({1'b0, m_one_side})
);

// the transfer engine
reg        exec_d;
reg [11:0] count;
reg        busy;                         // a byte was just moved: wait for the FDC to drop its request
always @(posedge clk) begin
	dma_rd <= 0; dma_wr <= 0; tc <= 0; buf_dma_we <= 0;
	exec_d <= fdc_exec;
	if (reset) begin bptr <= 0; count <= 0; busy <= 0; end
	else if (fdc_exec && !exec_d) begin
		bptr <= 0; count <= 0; busy <= 0;
		dir_read <= fdc_msr[6];
	end
	else if (fdc_exec) begin
		if (busy) busy <= fdc_drq;
		else if (fdc_drq && !dma_rd && !dma_wr) begin
			if (fdc_msr[6]) begin                       // disk to buffer
				dma_rd <= 1'b1;
				buf_dma_d <= fdc_dout;
				buf_dma_we <= 1'b1;
			end
			else dma_wr <= 1'b1;                        // buffer to disk (buf_dma_q holds buffer[bptr])
			busy <= 1'b1;
		end
		if (buf_dma_we || dma_wr) begin
			bptr <= bptr + 1'd1;
			count <= count + 1'd1;
			if (count + 1'd1 == sendbytes) tc <= 1'b1;
		end
	end
end

always @(*) begin
	case (port)
	8'hb2: dout = !b2dir && fdc_res_int ? 8'hff : 8'h0e;
	8'hd0, 8'hd1, 8'hd2, 8'hd3: dout = ext ? 8'hff : buf_cpu_q;
	8'hd4: dout = 8'h00;
	8'hdc: dout = fdc_exec ? {3'b000, 1'b1, fdc_msr[3:0]} : fdc_msr;
	8'hdd: dout = fdc_dout;
	default: dout = 8'hff;
	endcase
end

endmodule
