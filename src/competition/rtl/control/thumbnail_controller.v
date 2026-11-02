`timescale 1ns/1ps

// Complete the lesson-14 interaction skeleton around the existing player.
// The player owns active_index; this module requests a direct Bank selection
// and waits for its frame-boundary commit before leaving thumbnail view.
module thumbnail_controller (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       key_right,
    input  wire       key_left,
    input  wire       key_confirm,
    input  wire       key_mode,
    input  wire [3:0] image_complete,
    input  wire       frame_start,
    input  wire [1:0] display_index,
    input  wire       request_busy,
    output reg        view_mode,
    output reg  [1:0] focus_index,
    output wire [1:0] active_index,
    output wire       select_valid,
    output wire [1:0] select_index,
    output reg        transition_req
);
    reg [1:0] focus_target;
    reg requested_mode;
    reg mode_pending;
    reg select_pending;
    reg wait_selection;
    reg seen_request_busy;
    reg [1:0] selected_index;
    reg [1:0] display_sync1;
    reg [1:0] display_sync2;

    assign active_index = display_sync2;
    assign select_valid = select_pending && !request_busy;
    assign select_index = selected_index;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            view_mode <= 1'b0;
            focus_index <= 2'd0;
            focus_target <= 2'd0;
            requested_mode <= 1'b0;
            mode_pending <= 1'b0;
            select_pending <= 1'b0;
            wait_selection <= 1'b0;
            seen_request_busy <= 1'b0;
            selected_index <= 2'd0;
            display_sync1 <= 2'd0;
            display_sync2 <= 2'd0;
            transition_req <= 1'b0;
        end else begin
            display_sync1 <= display_index;
            display_sync2 <= display_sync1;
            transition_req <= 1'b0;

            if (wait_selection && request_busy)
                seen_request_busy <= 1'b1;
            if (select_valid) begin
                select_pending <= 1'b0;
                wait_selection <= 1'b1;
                seen_request_busy <= 1'b0;
            end

            if (key_mode && !select_pending && !wait_selection) begin
                requested_mode <= ~view_mode;
                mode_pending <= 1'b1;
                if (!view_mode)
                    focus_target <= display_sync2;
            end

            if (view_mode && !mode_pending && !select_pending && !wait_selection) begin
                if (key_right)
                    focus_target <= focus_target + 2'd1;
                else if (key_left)
                    focus_target <= focus_target - 2'd1;
                if (key_confirm && image_complete[focus_target]) begin
                    selected_index <= focus_target;
                    select_pending <= 1'b1;
                end
            end

            if (frame_start) begin
                focus_index <= focus_target;
                if (mode_pending && !select_pending && !wait_selection) begin
                    view_mode <= requested_mode;
                    mode_pending <= 1'b0;
                    transition_req <= 1'b1;
                end
                if (wait_selection && seen_request_busy && !request_busy &&
                    display_sync2 == selected_index) begin
                    view_mode <= 1'b0;
                    wait_selection <= 1'b0;
                    seen_request_busy <= 1'b0;
                    transition_req <= 1'b1;
                end
            end
        end
    end
endmodule
