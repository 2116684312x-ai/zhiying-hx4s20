`timescale 1ns/1ps

// Keep the HDMI sample cadence running while the four-card selector is open.
module thumbnail_audio_mute (
    input wire clk,
    input wire rst_n,
    input wire thumbnail_mode_async,
    input wire [23:0] left_in,
    input wire [23:0] right_in,
    output wire [23:0] left_out,
    output wire [23:0] right_out
);
    reg thumbnail_meta;
    reg thumbnail_sync;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            thumbnail_meta <= 1'b0;
            thumbnail_sync <= 1'b0;
        end else begin
            thumbnail_meta <= thumbnail_mode_async;
            thumbnail_sync <= thumbnail_meta;
        end
    end

    assign left_out = thumbnail_sync ? 24'd0 : left_in;
    assign right_out = thumbnail_sync ? 24'd0 : right_in;
endmodule
