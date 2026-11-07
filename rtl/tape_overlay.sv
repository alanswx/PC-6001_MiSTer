// SPDX-License-Identifier: GPL-2.0-only
// Tape status bar, from the Sharp X1 core's x1_tape_overlay.sv (tape standard rules 19-24).
// tape_status turns the tape position into elapsed/total m:ss and a 64-step progress fill and hands one packed
// word to tape_overlay (video clock) through a toggle handshake. The overlay draws "TAPE > mm:ss/mm:ss x7" and
// a progress bar in the bottom-left corner while the deck plays. While the deck is stopped the same box can show
// what to type next (tape standard rules 25-28): one or two lines of text from rtl/tape_auto.sv, drawn with the
// MC6847's internal font (rtl/pc6001_intfont.svh). It never alters the machine.
`timescale 1ns/1ps
module tape_status (
    input  logic         clk,
    input  logic         loaded,      // a tape is mounted and streaming
    input  logic         playing,     // deck in PLAY
    input  logic         fast,        // turbo active
    input  logic  [31:0] position,    // samples (bytes) played (0 after mount/rewind)
    input  logic  [31:0] length,      // samples (bytes) on the tape
    input  logic  [17:0] hz,          // samples (bytes) per second
    input  logic         hint_show,   // while stopped: the hint (rtl/tape_auto.sv)
    input  logic         hint_two,
    input  logic [383:0] hint_text,
    // to the video clock
    output logic [427:0] status,      // held while req != ack
    output logic         req,
    input  logic         ack          // asynchronous; synchronised here
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
    wire [427:0] pack = {hint_text, hint_two, hint_show && loaded && !playing, loaded, playing, fast, fill,
                         elapsed, total};

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
    input  logic         clk,         // video clock
    input  logic         ce_pix,
    input  logic         hblank, vblank,
    input  logic         enable,
    input  logic [427:0] status,      // from tape_status, stable while req != ack
    input  logic         req,
    output logic         ack,
    input  logic  [23:0] rgb_in,
    output logic  [23:0] rgb_out
);
    localparam int CHARS = 24;
    logic [1:0]   req_sync;
    logic [427:0] shown;
    logic [10:0]  x, width;
    logic [9:0]   y, height;
    logic         line_active, old_hblank, old_vblank;

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

    `include "pc6001_intfont.svh"

    wire         bar = enable && shown[41] && shown[40];
    wire         hint = enable && shown[42];
    wire         two = hint && shown[43];
    wire [383:0] text = shown[427:44];
    wire         visible = bar || hint;
    wire         fast = shown[39];
    wire [6:0]   fill = shown[38:32];
    wire [15:0]  elapsed = shown[31:16], total = shown[15:0];

    // the hint's width: up to its last character that is not a space
    logic [4:0] hint_w;
    always_comb begin
        hint_w = 5'd1;
        for (int i = 0; i < CHARS; i++)
            if (text[383 - 8 * i -: 8] != " " || (two && text[191 - 8 * i -: 8] != " ")) hint_w = 5'(i + 1);
    end

    // Double the overlay on 640-wide and 400-line screens.
    wire        sx = width >= 11'd512, sy = height >= 10'd300;
    wire [4:0]  chars = bar ? 5'd21 : hint_w;
    wire [10:0] box_w = {3'd0, chars, 3'd0} + 11'd4;
    wire [9:0]  box_h = bar ? 10'd18 : two ? 10'd22 : 10'd12;
    wire [10:0] x0 = 11'd4;
    wire [9:0]  y0 = height - (sy ? {box_h[8:0], 1'b0} : box_h) - 10'd4;
    wire [10:0] dx = x - x0;
    wire [9:0]  dy = y - y0;
    wire [10:0] lx = sx ? {1'b0, dx[10:1]} : dx;
    wire [9:0]  ly = sy ? {1'b0, dy[9:1]} : dy;
    wire        in_box = x >= x0 && y >= y0 && lx < box_w && ly < box_h;

    // Text rows at ly 2..9 and (the hint's second line) 12..19, x 2..
    wire [10:0] tx = lx - 11'd2;
    wire        row2 = two && ly >= 10'd12;
    wire [9:0]  ty = ly - (row2 ? 10'd12 : 10'd2);
    wire [4:0]  col = tx[7:3];

    function automatic logic [7:0] dig(input logic [3:0] d, input logic blank_zero);
        return blank_zero && d == 0 ? " " : 8'h30 + {4'd0, d};
    endfunction
    // the status line: "TAPE > m:ss/ m:ss x7" (03h: the play sign)
    logic [7:0] st_ch;
    always_comb begin
        case (col)
            5'd0: st_ch = "T";  5'd1: st_ch = "A";  5'd2: st_ch = "P";  5'd3: st_ch = "E";
            5'd5: st_ch = 8'h03;
            5'd7: st_ch = dig(elapsed[15:12], 1'b1);  5'd8: st_ch = dig(elapsed[11:8], 1'b0);
            5'd9: st_ch = ":";  5'd10: st_ch = dig(elapsed[7:4], 1'b0);  5'd11: st_ch = dig(elapsed[3:0], 1'b0);
            5'd12: st_ch = "/";
            5'd13: st_ch = dig(total[15:12], 1'b1);  5'd14: st_ch = dig(total[11:8], 1'b0);
            5'd15: st_ch = ":";  5'd16: st_ch = dig(total[7:4], 1'b0);  5'd17: st_ch = dig(total[3:0], 1'b0);
            5'd19: st_ch = fast ? "X" : " ";  5'd20: st_ch = fast ? 8'h30 + {4'd0, FACTOR} : " ";
            default: st_ch = " ";
        endcase
    end
    wire [7:0] hint_ch = col >= 5'(CHARS) ? 8'h20 : row2 ? text[191 - 8 * col -: 8] : text[383 - 8 * col -: 8];
    wire [7:0] ch = bar ? st_ch : hint_ch;

    // 01h: Return, 03h: play; 20h-5Fh from the MC6847 font (rows 2-9 of its 12); lower case as upper case
    wire [7:0] chu = ch >= 8'h60 && ch < 8'h80 ? ch - 8'h20 : ch;
    logic [7:0] glyph_row;
    always_comb begin
        case (chu)
            8'h01: glyph_row = 8'(64'h02022262FE602000 >> (8 * (7 - ty[2:0])));
            8'h03: glyph_row = 8'(64'h4060707870604000 >> (8 * (7 - ty[2:0])));
            default: glyph_row = chu >= 8'h20 && chu < 8'h60 ? intfont(chu[5:0], {1'b0, ty[2:0]} + 4'd2) : 8'h00;
        endcase
    end
    wire text_on = ty < 10'd8 && tx < {3'd0, chars, 3'd0} && glyph_row[3'd7 - tx[2:0]];
    // Progress bar at ly 12..15, 128 px for 64 steps.
    wire bar_area = bar && ly >= 10'd12 && ly < 10'd16 && lx >= 11'd2 && lx < 11'd130;
    wire bar_on = bar_area && (lx - 11'd2) < {3'd0, fill, 1'b0};

    always_comb begin
        rgb_out = rgb_in;
        if (visible && in_box)
            rgb_out = text_on && !bar_area ? 24'hFFFFFF : bar_on ? 24'h44CC44 : bar_area ? 24'h333333 : 24'h000000;
    end
endmodule
