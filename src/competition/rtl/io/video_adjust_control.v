`timescale 1ns/1ps

// SW2 selects brightness/contrast, SW3 chooses down/up, SW4 chooses 16/32.
// KEY3 is debounced by the board top and supplies one event per press.
module video_adjust_control (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       key_event,
    input  wire       select_contrast_sw,
    input  wire       increase_sw,
    input  wire       large_step_sw,
    output reg  [7:0] brightness,
    output reg  [7:0] contrast,
    output wire       contrast_selected
);
    reg select_1, select_2;
    reg up_1, up_2;
    reg step_1, step_2;
    wire [8:0] step_value = step_2 ? 9'd32 : 9'd16;
    wire [8:0] bright_sum = {1'b0, brightness} + step_value;
    wire [8:0] contrast_sum = {1'b0, contrast} + step_value;
    assign contrast_selected = select_2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            select_1 <= 0; select_2 <= 0;
            up_1 <= 0; up_2 <= 0;
            step_1 <= 0; step_2 <= 0;
            brightness <= 8'd255;
            contrast <= 8'd128;
        end else begin
            select_1 <= select_contrast_sw; select_2 <= select_1;
            up_1 <= increase_sw; up_2 <= up_1;
            step_1 <= large_step_sw; step_2 <= step_1;
            if (key_event) begin
                if (select_2) begin
                    if (up_2)
                        contrast <= contrast_sum > 9'd255 ? 8'd255 : contrast_sum[7:0];
                    else
                        contrast <= {1'b0, contrast} < step_value ?
                                    8'd0 : contrast - step_value[7:0];
                end else begin
                    if (up_2)
                        brightness <= bright_sum > 9'd255 ? 8'd255 : bright_sum[7:0];
                    else
                        brightness <= {1'b0, brightness} < step_value ?
                                      8'd0 : brightness - step_value[7:0];
                end
            end
        end
    end
endmodule
