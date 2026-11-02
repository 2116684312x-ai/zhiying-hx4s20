`timescale 1ns/1ps

// Pixel-domain loading card. Video timing and HDMI can start while FAT32/BMP
// preload continues; this layer changes only active RGB pixels until the
// existing player_enable gate declares all image banks ready.
module boot_splash_overlay (
    input  wire        de,
    input  wire        image_ready,
    input  wire [9:0]  pixel_x,
    input  wire [9:0]  pixel_y,
    input  wire [23:0] rgb_in,
    output reg  [23:0] rgb_out
);
    reg [7:0] glyph;
    reg [2:0] glyph_x;
    reg [2:0] glyph_y;
    reg       text_area;
    wire [4:0] glyph_bits = font_row(glyph, glyph_y);
    wire       text_dot = text_area && glyph_x < 3'd5 &&
                          glyph_bits[3'd4 - glyph_x];

    function [4:0] font_row;
        input [7:0] ch;
        input [2:0] row;
        begin
            font_row = 5'b00000;
            case (ch)
                "E": case (row)
                    0,3,6: font_row=5'b11111;
                    1,2,4,5: font_row=5'b10000;
                endcase
                "H": case (row)
                    0,1,2,4,5,6: font_row=5'b10001;
                    3: font_row=5'b11111;
                endcase
                "X": case (row)
                    0,6: font_row=5'b10001;
                    1,5: font_row=5'b01010;
                    2,3,4: font_row=5'b00100;
                endcase
                "4": case (row)
                    0: font_row=5'b00110;
                    1: font_row=5'b01010;
                    2: font_row=5'b10010;
                    3: font_row=5'b11111;
                    4,5,6: font_row=5'b00010;
                endcase
                "S": case (row)
                    0,3: font_row=5'b01111;
                    1,2: font_row=5'b10000;
                    4,5: font_row=5'b00001;
                    6: font_row=5'b11110;
                endcase
                "2": case (row)
                    0: font_row=5'b01110;
                    1: font_row=5'b10001;
                    2: font_row=5'b00001;
                    3: font_row=5'b00010;
                    4: font_row=5'b00100;
                    5: font_row=5'b01000;
                    6: font_row=5'b11111;
                endcase
                "0","O": case (row)
                    0,6: font_row=5'b01110;
                    1,2,3,4,5: font_row=5'b10001;
                endcase
                "L": case (row)
                    0,1,2,3,4,5: font_row=5'b10000;
                    6: font_row=5'b11111;
                endcase
                "A": case (row)
                    0: font_row=5'b01110;
                    1,2,4,5,6: font_row=5'b10001;
                    3: font_row=5'b11111;
                endcase
                "D": case (row)
                    0,6: font_row=5'b11110;
                    1,2,3,4,5: font_row=5'b10001;
                endcase
                "I": case (row)
                    0,6: font_row=5'b11111;
                    1,2,3,4,5: font_row=5'b00100;
                endcase
                "N": case (row)
                    0,6: font_row=5'b10001;
                    1: font_row=5'b11001;
                    2: font_row=5'b10101;
                    3: font_row=5'b10011;
                    4,5: font_row=5'b10001;
                endcase
                "G": case (row)
                    0: font_row=5'b01111;
                    1,2: font_row=5'b10000;
                    3: font_row=5'b10111;
                    4,5: font_row=5'b10001;
                    6: font_row=5'b01110;
                endcase
                default: font_row=5'b00000;
            endcase
        end
    endfunction

    always @* begin
        glyph = 8'd0;
        glyph_x = 3'd0;
        glyph_y = 3'd0;
        text_area = 1'b0;

        // Six 5x7 glyphs at 4x scale, with one blank source column.
        if (pixel_y >= 10'd211 && pixel_y < 10'd239) begin
            glyph_y = (pixel_y - 10'd211) >> 2;
            if (pixel_x >= 10'd248 && pixel_x < 10'd272) begin
                glyph="H"; glyph_x=(pixel_x-10'd248)>>2; text_area=1'b1;
            end else if (pixel_x >= 10'd272 && pixel_x < 10'd296) begin
                glyph="X"; glyph_x=(pixel_x-10'd272)>>2; text_area=1'b1;
            end else if (pixel_x >= 10'd296 && pixel_x < 10'd320) begin
                glyph="4"; glyph_x=(pixel_x-10'd296)>>2; text_area=1'b1;
            end else if (pixel_x >= 10'd320 && pixel_x < 10'd344) begin
                glyph="S"; glyph_x=(pixel_x-10'd320)>>2; text_area=1'b1;
            end else if (pixel_x >= 10'd344 && pixel_x < 10'd368) begin
                glyph="2"; glyph_x=(pixel_x-10'd344)>>2; text_area=1'b1;
            end else if (pixel_x >= 10'd368 && pixel_x < 10'd392) begin
                glyph="0"; glyph_x=(pixel_x-10'd368)>>2; text_area=1'b1;
            end
        end else if (pixel_y >= 10'd273 && pixel_y < 10'd287) begin
            // LOADING uses the same font at 2x scale.
            glyph_y = (pixel_y - 10'd273) >> 1;
            if (pixel_x >= 10'd278 && pixel_x < 10'd290) begin
                glyph="L"; glyph_x=(pixel_x-10'd278)>>1; text_area=1'b1;
            end else if (pixel_x >= 10'd290 && pixel_x < 10'd302) begin
                glyph="O"; glyph_x=(pixel_x-10'd290)>>1; text_area=1'b1;
            end else if (pixel_x >= 10'd302 && pixel_x < 10'd314) begin
                glyph="A"; glyph_x=(pixel_x-10'd302)>>1; text_area=1'b1;
            end else if (pixel_x >= 10'd314 && pixel_x < 10'd326) begin
                glyph="D"; glyph_x=(pixel_x-10'd314)>>1; text_area=1'b1;
            end else if (pixel_x >= 10'd326 && pixel_x < 10'd338) begin
                glyph="I"; glyph_x=(pixel_x-10'd326)>>1; text_area=1'b1;
            end else if (pixel_x >= 10'd338 && pixel_x < 10'd350) begin
                glyph="N"; glyph_x=(pixel_x-10'd338)>>1; text_area=1'b1;
            end else if (pixel_x >= 10'd350 && pixel_x < 10'd362) begin
                glyph="G"; glyph_x=(pixel_x-10'd350)>>1; text_area=1'b1;
            end
        end

        if (!de || image_ready)
            rgb_out = rgb_in;
        else if (text_dot)
            rgb_out = (pixel_y < 10'd250) ? 24'hf3fbff : 24'h74dfff;
        else if (pixel_x >= 10'd184 && pixel_x < 10'd456 &&
                 pixel_y >= 10'd168 && pixel_y < 10'd312) begin
            if (pixel_x < 10'd187 || pixel_x >= 10'd453 ||
                pixel_y < 10'd171 || pixel_y >= 10'd309)
                rgb_out = 24'h2697b7;
            else if (pixel_y >= 10'd253 && pixel_y < 10'd255)
                rgb_out = 24'h2697b7;
            else
                rgb_out = 24'h102d44;
        end else
            rgb_out = 24'h071827;
    end
endmodule
