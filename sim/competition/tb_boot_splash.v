`timescale 1ns/1ps

module tb_boot_splash;
    reg de = 1'b1;
    reg image_ready = 1'b0;
    reg [9:0] pixel_x = 10'd10;
    reg [9:0] pixel_y = 10'd10;
    reg [23:0] rgb_in = 24'h000000;
    wire [23:0] rgb_out;

    boot_splash_overlay dut (
        .de(de), .image_ready(image_ready),
        .pixel_x(pixel_x), .pixel_y(pixel_y),
        .rgb_in(rgb_in), .rgb_out(rgb_out)
    );

    initial begin
        #1;
        if (rgb_out === 24'h000000 || (^rgb_out) === 1'bx)
            $fatal(1, "loading display stayed black before TF images were ready");

        pixel_x = 10'd320;
        pixel_y = 10'd240;
        #1;
        if (rgb_out === 24'h000000 || (^rgb_out) === 1'bx)
            $fatal(1, "loading display has no visible central content");

        // The boot card names the EG4S20 FPGA, not the board's HX4S20 label.
        pixel_x = 10'd248; pixel_y = 10'd211;
        #1;
        if (rgb_out !== 24'hf3fbff)
            $fatal(1, "EG4S20 title is missing its E glyph");
        pixel_x = 10'd272;
        #1;
        if (rgb_out !== 24'h102d44)
            $fatal(1, "EG4S20 title's G glyph has an incorrect top-left pixel");
        pixel_x = 10'd276;
        #1;
        if (rgb_out !== 24'hf3fbff)
            $fatal(1, "EG4S20 title is missing its G glyph");

        image_ready = 1'b1;
        rgb_in = 24'h12ab34;
        #1;
        if (rgb_out !== rgb_in)
            $fatal(1, "ready image was not passed through intact");

        image_ready = 1'b0;
        de = 1'b0;
        rgb_in = 24'hff00ff;
        #1;
        if (rgb_out !== rgb_in)
            $fatal(1, "blanking pixels were changed by the loading layer");

        $display("PASS: visible loading screen, clean image handoff and blanking passthrough");
        $finish;
    end
endmodule
