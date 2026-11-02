`timescale 1ns/1ps

// Show BMP source dimensions and the ratio to the fixed 640x480 output.
// The three accepted source sizes use a compact two-bit code; no file name or
// fixed page number is used to infer the displayed value.
module source_resolution_osd #(
    parameter integer X = 536,
    parameter integer Y = 42
) (
    input  wire        de,
    input  wire        show,
    input  wire [1:0]  size_code,
    input  wire [9:0]  pixel_x,
    input  wire [11:0] pixel_y,
    input  wire [23:0] rgb_in,
    output wire [23:0] rgb_out
);
    wire in_box = de && show && size_code != 2'd0 &&
                  pixel_x >= X && pixel_x < X + 96 &&
                  pixel_y >= Y && pixel_y < Y + 18;
    wire [6:0] local_x = pixel_x - X;
    wire scale_line = pixel_y >= Y + 10;
    wire text_row = (pixel_y < Y + 8) || scale_line;
    wire [2:0] local_y = scale_line ? pixel_y - Y - 10 : pixel_y - Y;
    wire [3:0] char_pos = local_x[6:3];
    wire [2:0] glyph_x = local_x[2:0];
    wire [2:0] glyph_y = local_y;
    reg [7:0] character;
    reg [4:0] glyph;

    always @* begin
        character = 8'h20;
        if (scale_line) begin
            case (char_pos)
                4'd0: character = "S";
                4'd1: character = "C";
                4'd2: character = "A";
                4'd3: character = "L";
                4'd4: character = "E";
                4'd5: character = " ";
                4'd6: character = size_code == 2'd3 ? "2" : "1";
                4'd7: character = "/";
                4'd8: character = size_code == 2'd2 ? "2" : "1";
            endcase
        end else begin
            case (char_pos)
                4'd0: character = "S";
                4'd1: character = "R";
                4'd2: character = "C";
                4'd3: character = " ";
                4'd4: character = size_code == 2'd2 ? "1" :
                                  size_code == 2'd3 ? "3" : "6";
                4'd5: character = size_code == 2'd2 ? "2" :
                                  size_code == 2'd3 ? "2" : "4";
                4'd6: character = size_code == 2'd2 ? "8" : "0";
                4'd7: character = size_code == 2'd2 ? "0" : "x";
                4'd8: character = size_code == 2'd2 ? "x" :
                                  size_code == 2'd3 ? "2" : "4";
                4'd9: character = size_code == 2'd2 ? "9" :
                                  size_code == 2'd3 ? "4" : "8";
                4'd10: character = size_code == 2'd2 ? "6" : "0";
                4'd11: character = size_code == 2'd2 ? "0" : " ";
            endcase
        end
        glyph = font_row(character, glyph_y);
    end

    function [4:0] font_row;
        input [7:0] ch;
        input [2:0] row;
        begin
            font_row = 5'b00000;
            case (ch)
                "A": case (row)
                    0:font_row=5'b01110;1:font_row=5'b10001;2:font_row=5'b10001;
                    3:font_row=5'b11111;4:font_row=5'b10001;5:font_row=5'b10001;
                    6:font_row=5'b10001;endcase
                "L": case (row)
                    0:font_row=5'b10000;1:font_row=5'b10000;2:font_row=5'b10000;
                    3:font_row=5'b10000;4:font_row=5'b10000;5:font_row=5'b10000;
                    6:font_row=5'b11111;endcase
                "E": case (row)
                    0:font_row=5'b11111;1:font_row=5'b10000;2:font_row=5'b10000;
                    3:font_row=5'b11110;4:font_row=5'b10000;5:font_row=5'b10000;
                    6:font_row=5'b11111;endcase
                "/": case (row)
                    0:font_row=5'b00001;1:font_row=5'b00001;2:font_row=5'b00010;
                    3:font_row=5'b00100;4:font_row=5'b01000;5:font_row=5'b10000;
                    6:font_row=5'b10000;endcase
                "S": case (row)
                    0:font_row=5'b01111;1:font_row=5'b10000;2:font_row=5'b10000;
                    3:font_row=5'b01110;4:font_row=5'b00001;5:font_row=5'b00001;
                    6:font_row=5'b11110;endcase
                "R": case (row)
                    0:font_row=5'b11110;1:font_row=5'b10001;2:font_row=5'b10001;
                    3:font_row=5'b11110;4:font_row=5'b10100;5:font_row=5'b10010;
                    6:font_row=5'b10001;endcase
                "C": case (row)
                    0:font_row=5'b01111;1:font_row=5'b10000;2:font_row=5'b10000;
                    3:font_row=5'b10000;4:font_row=5'b10000;5:font_row=5'b10000;
                    6:font_row=5'b01111;endcase
                "x": case (row)
                    0:font_row=5'b00000;1:font_row=5'b10001;2:font_row=5'b01010;
                    3:font_row=5'b00100;4:font_row=5'b01010;5:font_row=5'b10001;
                    6:font_row=5'b00000;endcase
                "0": case (row)
                    0:font_row=5'b01110;1:font_row=5'b10001;2:font_row=5'b10011;
                    3:font_row=5'b10101;4:font_row=5'b11001;5:font_row=5'b10001;
                    6:font_row=5'b01110;endcase
                "1": case (row)
                    0:font_row=5'b00100;1:font_row=5'b01100;2:font_row=5'b00100;
                    3:font_row=5'b00100;4:font_row=5'b00100;5:font_row=5'b00100;
                    6:font_row=5'b01110;endcase
                "2": case (row)
                    0:font_row=5'b01110;1:font_row=5'b10001;2:font_row=5'b00001;
                    3:font_row=5'b00010;4:font_row=5'b00100;5:font_row=5'b01000;
                    6:font_row=5'b11111;endcase
                "3": case (row)
                    0:font_row=5'b11110;1:font_row=5'b00001;2:font_row=5'b00001;
                    3:font_row=5'b01110;4:font_row=5'b00001;5:font_row=5'b00001;
                    6:font_row=5'b11110;endcase
                "4": case (row)
                    0:font_row=5'b00010;1:font_row=5'b00110;2:font_row=5'b01010;
                    3:font_row=5'b10010;4:font_row=5'b11111;5:font_row=5'b00010;
                    6:font_row=5'b00010;endcase
                "6": case (row)
                    0:font_row=5'b01110;1:font_row=5'b10000;2:font_row=5'b10000;
                    3:font_row=5'b11110;4:font_row=5'b10001;5:font_row=5'b10001;
                    6:font_row=5'b01110;endcase
                "8": case (row)
                    0:font_row=5'b01110;1:font_row=5'b10001;2:font_row=5'b10001;
                    3:font_row=5'b01110;4:font_row=5'b10001;5:font_row=5'b10001;
                    6:font_row=5'b01110;endcase
                "9": case (row)
                    0:font_row=5'b01110;1:font_row=5'b10001;2:font_row=5'b10001;
                    3:font_row=5'b01111;4:font_row=5'b00001;5:font_row=5'b00001;
                    6:font_row=5'b01110;endcase
            endcase
        end
    endfunction

    assign rgb_out = !in_box ? rgb_in :
                     (text_row && glyph_x < 5 && glyph_y < 7 && glyph[4-glyph_x]) ?
                     24'hFFFFFF : 24'h102C3C;
endmodule
