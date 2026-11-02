`timescale 1ns/1ps

// One event for each stable movement of a mechanical toggle switch.
module switch_change_debounce #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20
) (
    input  wire clk,
    input  wire rst_n,
    input  wire switch_in,
    output reg  change_pulse
);
    localparam integer STABLE_CYCLES = CLK_FREQ_HZ / 1000 * DEBOUNCE_MS;
    localparam integer COUNT_W = (STABLE_CYCLES <= 2) ? 2 : $clog2(STABLE_CYCLES);
    wire switch_sync;
    reg stable_level;
    reg [COUNT_W-1:0] stable_count;

    sync_2ff u_sync (
        .clk(clk), .rst_n(rst_n),
        .async_in(switch_in), .sync_out(switch_sync)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stable_level <= 1'b0;
            stable_count <= {COUNT_W{1'b0}};
            change_pulse <= 1'b0;
        end else begin
            change_pulse <= 1'b0;
            if (switch_sync == stable_level) begin
                stable_count <= {COUNT_W{1'b0}};
            end else if (stable_count == STABLE_CYCLES - 1) begin
                stable_level <= switch_sync;
                stable_count <= {COUNT_W{1'b0}};
                change_pulse <= 1'b1;
            end else begin
                stable_count <= stable_count + 1'b1;
            end
        end
    end
endmodule
