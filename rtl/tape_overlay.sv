// SPDX-License-Identifier: GPL-2.0-only
// Tape status bar, from the Sharp X1 core's x1_tape_overlay.sv (tape standard rules 19-24).
// tape_status turns the tape position into elapsed/total m:ss and a 64-step progress fill and hands one packed
// word to tape_overlay (video clock) through a toggle handshake. The overlay draws "TAPE > mm:ss/mm:ss x3" and
// a progress bar in the bottom-left corner while the deck plays. While the deck is stopped the same box can show
// the next step (tape standard rules 25-28): "TYPE CLOAD <ret>" or "TYPE RUN <ret>" (hint, from the machine).
// It never alters the machine.
`timescale 1ns/1ps
module tape_status (
    input  logic        clk,
    input  logic        loaded,      // a tape is mounted and streaming
    input  logic        playing,     // deck in PLAY
    input  logic        fast,        // turbo active
    input  logic [31:0] position,    // samples (bytes) played (0 after mount/rewind)
    input  logic [31:0] length,      // samples (bytes) on the tape
    input  logic [17:0] hz,          // samples (bytes) per second
    input  logic  [1:0] hint,        // while stopped: 0 none, 1 TYPE CLOAD, 2 TYPE RUN
    // to the video clock
    output logic [43:0] status,      // held while req != ack
    output logic        req,
    input  logic        ack          // asynchronous; synchronised here
);
    logic [15:0] elapsed, total;     // BCD m1 m0 s1 s0
    logic [17:0] frac;
    logic [31:0] last_pos, last_len, rem, cell_count;
    logic [17:0] last_hz;
    logic [6:0]  fill;
    logic        computing;
    logic [1:0]  ack_sync;

    function automatic logic [15:0] bcd_tick(input logic [15:0] t);
        logic [15:0] n;
        n = t;
        if (t == 16'h9959) return t;                 // saturate at 99:59
        if (t[3:0] != 4'd9) n[3:0] = t[3:0] + 4'd1;
        else begin
            n[3:0] = 0;
            if (t[7:4] != 4'd5) n[7:4] = t[7:4] + 4'd1;
            else begin
                n[7:4] = 0;
                if (t[11:8] != 4'd9) n[11:8] = t[11:8] + 4'd1;
                else begin n[11:8] = 0; n[15:12] = t[15:12] + 4'd1; end
            end
        end
        return n;
    endfunction

    wire [31:0] cell_bits = length[31:6] == 0 ? 32'd1 : {6'd0, length[31:6]};
    wire [43:0] pack = {hint, loaded, playing, fast, fill, elapsed, total};

    initial begin
        elapsed = 0; total = 0; frac = 0; last_pos = 0; last_len = 0; last_hz = 0;
        rem = 0; cell_count = 0; fill = 0; computing = 0; req = 0; status = 0; ack_sync = 0;
    end

    always_ff @(posedge clk) begin
        ack_sync <= {ack_sync[0], ack};
        last_pos <= position;
        // Elapsed time and fill follow the cursor; it only steps by one or
        // returns to zero (mount, rewind).
        if (position == 0 || position < last_pos) begin
            elapsed <= 0; frac <= 0; fill <= 0; cell_count <= 0;
        end else if (position != last_pos) begin
            if (frac + 18'd1 >= hz) begin frac <= 0; elapsed <= bcd_tick(elapsed); end
            else frac <= frac + 18'd1;
            if (cell_count + 32'd1 >= cell_bits) begin
                cell_count <= 0;
                if (fill != 7'd64) fill <= fill + 7'd1;
            end else cell_count <= cell_count + 32'd1;
        end
        // Total time: subtract one second of samples per clock after a new tape.
        last_len <= length; last_hz <= hz;
        if (length != last_len || hz != last_hz) begin
            rem <= length; total <= 0; computing <= hz != 0;
        end else if (computing) begin
            if (rem >= {14'd0, hz}) begin rem <= rem - {14'd0, hz}; total <= bcd_tick(total); end
            else computing <= 0;
        end
        // Send a changed status once the previous one was taken.
        if (req == ack_sync[1] && pack != status) begin
            status <= pack;
            req <= !req;
        end
    end
endmodule

module tape_overlay #(parameter logic [3:0] FACTOR = 4'd3) (
    input  logic        clk,         // video clock
    input  logic        ce_pix,
    input  logic        hblank, vblank,
    input  logic        enable,
    input  logic [43:0] status,      // from tape_status, stable while req != ack
    input  logic        req,
    output logic        ack,
    input  logic [23:0] rgb_in,
    output logic [23:0] rgb_out
);
    localparam int CHARS = 21;
    logic [1:0]  req_sync;
    logic [43:0] shown;
    logic [10:0] x, width;
    logic [9:0]  y, height;
    logic        line_active, old_hblank, old_vblank;

    initial begin
        req_sync = 0; ack = 0; shown = 0; x = 0; y = 0; width = 0; height = 0;
        line_active = 0; old_hblank = 0; old_vblank = 0;
    end

    always_ff @(posedge clk) begin
        req_sync <= {req_sync[0], req};
        if (req_sync[1] != ack) begin shown <= status; ack <= req_sync[1]; end
        if (ce_pix) begin
            old_hblank <= hblank; old_vblank <= vblank;
            if (!hblank && !vblank) begin x <= x + 11'd1; line_active <= 1; end
            if (hblank && !old_hblank) begin
                if (line_active) begin width <= x; y <= y + 10'd1; end
                x <= 0; line_active <= 0;
            end
            if (vblank && !old_vblank) begin height <= y; y <= 0; end
        end
    end

    wire        bar = enable && shown[41] && shown[40];
    wire [1:0]  hint = enable && shown[41] && !shown[40] ? shown[43:42] : 2'd0;
    wire        visible = bar || hint != 0;
    wire        fast = shown[39];
    wire [6:0]  fill = shown[38:32];
    wire [15:0] elapsed = shown[31:16], total = shown[15:0];
    // Double the overlay on 640-wide and 400-line screens.
    wire        sx = width >= 11'd512, sy = height >= 10'd300;
    // The box shrinks to the hint: "TYPE CLOAD <ret>" is 12 characters, "TYPE RUN <ret>" 10, one text row.
    wire [4:0]  chars = bar ? 5'(CHARS) : hint == 2'd1 ? 5'd12 : 5'd10;
    wire [10:0] box_w = {3'd0, chars, 3'd0} + 11'd4;
    wire [9:0]  box_h = bar ? 10'd18 : 10'd12;
    wire [10:0] x0 = 11'd4;
    wire [9:0]  y0 = height - (sy ? {box_h[8:0], 1'b0} : box_h) - 10'd4;
    wire [10:0] dx = x - x0;
    wire [9:0]  dy = y - y0;
    wire [10:0] lx = sx ? {1'b0, dx[10:1]} : dx;
    wire [9:0]  ly = sy ? {1'b0, dy[9:1]} : dy;
    wire        in_box = x >= x0 && y >= y0 && lx < box_w && ly < box_h;

    // Text row at ly 2..9, x 2..; codes 0-9 digits, 10 ':', 11 '/', 12 T,
    // 13 A, 14 P, 15 E, 16 x, 17 play, 18 space, 19 Y, 20 C, 21 L, 22 O, 23 D, 24 R, 25 U, 26 N, 27 return.
    logic [4:0] hint_code;
    always_comb begin
        case (col)
            5'd0: hint_code = 5'd12;  5'd1: hint_code = 5'd19;  5'd2: hint_code = 5'd14;  5'd3: hint_code = 5'd15;
            5'd4: hint_code = 5'd18;
            default: hint_code = 5'd18;
        endcase
        if (hint == 2'd1) case (col)
            5'd5: hint_code = 5'd20;  5'd6: hint_code = 5'd21;  5'd7: hint_code = 5'd22;  5'd8: hint_code = 5'd13;
            5'd9: hint_code = 5'd23;  5'd11: hint_code = 5'd27;
            default: ;
        endcase
        else case (col)
            5'd5: hint_code = 5'd24;  5'd6: hint_code = 5'd25;  5'd7: hint_code = 5'd26;  5'd9: hint_code = 5'd27;
            default: ;
        endcase
    end
    wire [10:0] tx = lx - 11'd2;
    wire [9:0]  ty = ly - 10'd2;
    wire [4:0]  col = tx[7:3];
    function automatic logic [4:0] digit(input logic [3:0] d, input logic blank_zero);
        return blank_zero && d == 0 ? 5'd18 : {1'b0, d};
    endfunction
    logic [4:0] code;
    always_comb begin
        case (col)
            5'd0: code = 5'd12;  5'd1: code = 5'd13;  5'd2: code = 5'd14;  5'd3: code = 5'd15;
            5'd4: code = 5'd18;  5'd5: code = 5'd17;  5'd6: code = 5'd18;
            5'd7: code = digit(elapsed[15:12], 1'b1);  5'd8: code = {1'b0, elapsed[11:8]};
            5'd9: code = 5'd10;  5'd10: code = {1'b0, elapsed[7:4]};  5'd11: code = {1'b0, elapsed[3:0]};
            5'd12: code = 5'd11;
            5'd13: code = digit(total[15:12], 1'b1);  5'd14: code = {1'b0, total[11:8]};
            5'd15: code = 5'd10;  5'd16: code = {1'b0, total[7:4]};  5'd17: code = {1'b0, total[3:0]};
            5'd18: code = 5'd18;
            5'd19: code = fast ? 5'd16 : 5'd18;  5'd20: code = fast ? {1'b0, FACTOR} : 5'd18;
            default: code = 5'd18;
        endcase
        if (!bar) code = hint_code;
    end
    function automatic logic [7:0] glyph(input logic [4:0] c, input logic [2:0] r);
        logic [63:0] g;
        case (c)
            5'd0:  g = 64'h3C666E7666663C00;  5'd1:  g = 64'h1838181818187E00;
            5'd2:  g = 64'h3C66060C30607E00;  5'd3:  g = 64'h3C66061C06663C00;
            5'd4:  g = 64'h0C1C3C6C7E0C0C00;  5'd5:  g = 64'h7E607C0606663C00;
            5'd6:  g = 64'h1C30607C66663C00;  5'd7:  g = 64'h7E060C1830303000;
            5'd8:  g = 64'h3C66663C66663C00;  5'd9:  g = 64'h3C66663E060C3800;
            5'd10: g = 64'h0018180018180000;  5'd11: g = 64'h02060C1830604000;
            5'd12: g = 64'h7E18181818181800;  5'd13: g = 64'h183C66667E666600;
            5'd14: g = 64'h7C66667C60606000;  5'd15: g = 64'h7E60607C60607E00;
            5'd16: g = 64'h0000663C183C6600;  5'd17: g = 64'h4060707870604000;
            5'd19: g = 64'h6666663C18181800;  5'd20: g = 64'h3C66606060663C00;
            5'd21: g = 64'h6060606060607E00;  5'd22: g = 64'h3C66666666663C00;
            5'd23: g = 64'h786C6666666C7800;  5'd24: g = 64'h7C66667C786C6600;
            5'd25: g = 64'h6666666666663C00;  5'd26: g = 64'h66767E7E6E666600;
            5'd27: g = 64'h02022262FE602000;
            default: g = 64'h0;
        endcase
        return g[63 - 8 * r -: 8];
    endfunction
    wire [7:0] glyph_row = glyph(code, ty[2:0]);
    wire text_on = ty < 10'd8 && tx < {3'd0, chars, 3'd0} && glyph_row[3'd7 - tx[2:0]];
    // Progress bar at ly 12..15, 128 px for 64 steps.
    wire bar_area = bar && ly >= 10'd12 && ly < 10'd16 && lx >= 11'd2 && lx < 11'd130;
    wire bar_on = bar_area && (lx - 11'd2) < {3'd0, fill, 1'b0};

    always_comb begin
        rgb_out = rgb_in;
        if (visible && in_box)
            rgb_out = text_on ? 24'hFFFFFF : bar_on ? 24'h44CC44 : bar_area ? 24'h333333 : 24'h000000;
    end
endmodule
