// 第13课练习骨架的完成版。主链路亮度由 fade alpha 调整，本模块负责对比度。
module brightness_contrast_adjust #(
    parameter integer REGISTER_OUTPUT = 1
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        in_de,
    input  wire [23:0] rgb_in,
    input  wire [7:0]  brightness,   // 帧边界锁存后的亮度
    input  wire [7:0]  contrast,     // 帧边界锁存后的对比度
    output wire        out_de,
    output wire [23:0] rgb_out
);
    // 每通道乘亮度；255 为严格透传，避免中性档损失 1 LSB。
    wire [15:0] mul_r = rgb_in[23:16] * brightness;
    wire [15:0] mul_g = rgb_in[15:8]  * brightness;
    wire [15:0] mul_b = rgb_in[7:0]   * brightness;
    wire [7:0] bright_r = brightness == 8'd255 ? rgb_in[23:16] : mul_r[15:8];
    wire [7:0] bright_g = brightness == 8'd255 ? rgb_in[15:8]  : mul_g[15:8];
    wire [7:0] bright_b = brightness == 8'd255 ? rgb_in[7:0]   : mul_b[15:8];

    function [7:0] contrast_channel;
        input [7:0] value;
        input [7:0] gain;
        reg signed [8:0] centered;
        reg signed [17:0] product;
        reg signed [9:0] result;
        begin
            centered = $signed({1'b0, value}) - 9'sd128;
            product = centered * $signed({1'b0, gain});
            result = (product >>> 7) + 10'sd128;
            if (result < 10'sd0)
                contrast_channel = 8'd0;
            else if (result > 10'sd255)
                contrast_channel = 8'd255;
            else
                contrast_channel = result[7:0];
        end
    endfunction
    wire [7:0] final_r = contrast_channel(bright_r, contrast);
    wire [7:0] final_g = contrast_channel(bright_g, contrast);
    wire [7:0] final_b = contrast_channel(bright_b, contrast);
    wire [23:0] adjusted_rgb = {final_r, final_g, final_b};

    generate if (REGISTER_OUTPUT != 0) begin : g_registered
        reg out_de_q;
        reg [23:0] rgb_q;
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                out_de_q <= 1'b0;
                rgb_q <= 24'h000000;
            end else begin
                out_de_q <= in_de;
                rgb_q <= adjusted_rgb;
            end
        end
        assign out_de = out_de_q;
        assign rgb_out = rgb_q;
    end else begin : g_combinational
        assign out_de = in_de;
        assign rgb_out = adjusted_rgb;
    end endgenerate
endmodule
