`timescale 1ns/1ps

// Elapsed time and the selected science topic's knowledge caption.
module media_dynamic_caption (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vsync,
    input  wire        de,
    input  wire [9:0]  pixel_x,
    input  wire [11:0] pixel_y,
    input  wire [1:0]  active_index,
    input  wire [23:0] rgb_in,
    output wire [23:0] rgb_out
);
    wire [23:0] timed_rgb;
    timestamp_osd #(.OSD_X(500), .OSD_Y(8)) u_elapsed_time (
        .pix_clk(clk), .pix_rst_n(rst_n), .enable(1'b1),
        .vsync(vsync), .de(de), .pixel_x(pixel_x), .pixel_y(pixel_y),
        .rgb_in(rgb_in), .rgb_out(timed_rgb), .ts_active(),
        .sys_rst_n(rst_n)
    );

    science_topic_caption u_topic_caption (
        .clk(clk), .rst_n(rst_n), .vsync(vsync),
        .de(de), .pixel_x(pixel_x), .pixel_y(pixel_y),
        .active_index(active_index), .rgb_in(timed_rgb),
        .rgb_out(rgb_out)
    );
endmodule
