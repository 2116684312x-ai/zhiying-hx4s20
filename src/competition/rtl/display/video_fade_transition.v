`timescale 1ns/1ps

// Crossfade controller for the single-read-port player. A manual next event
// runs the full fade-out -> black dwell -> fade-in sequence and only releases
// the switch request to media_player_control at the fully black frame, so the
// SDRAM never has to serve two frames at once. Automatic slideshow switches
// cannot be anticipated (media_player_control issues them internally), so the
// idle state follows index_commit with a fade-in from black instead.
// FADE_FRAMES = 0 bypasses the whole machine: next_event passes straight
// through and alpha stays 255, keeping the legacy regression suites green.
module video_fade_transition #(
    parameter integer FADE_FRAMES = 0
) (
    input  wire       ctrl_clk,
    input  wire       ctrl_rst_n,
    input  wire       next_event_in,
    input  wire       mode_event_in,
    output wire       next_event_out,
    output wire       fade_busy,

    input  wire       pix_clk,
    input  wire       pix_rst_n,
    input  wire       player_active,
    input  wire       frame_start,
    input  wire       index_commit,
    input  wire [1:0] active_index,
    output wire [7:0] alpha_out,
    output wire       fade_active,
    // Wipe reveal: automatic slideshow switches recover with a left-to-right
    // reveal instead of an alpha ramp. wipe_active gates the pixel-domain
    // coordinate compare; ramp_out drives the reveal boundary counter.
    output wire       wipe_active,
    output wire [4:0] ramp_out,
    output wire [1:0] transition_kind
);
    generate
        if (FADE_FRAMES == 0) begin : g_bypass
            assign next_event_out = next_event_in;
            assign fade_busy = 1'b0;
            assign alpha_out = 8'd255;
            assign fade_active = 1'b0;
            assign wipe_active = 1'b0;
            assign ramp_out = 5'd0;
            assign transition_kind = 2'd0;
        end else begin : g_fade
            // 256 % FADE_FRAMES must be zero so the ramp spans exactly 0..255.
            localparam integer STEP = 256 / FADE_FRAMES;
            // ramp holds FADE_FRAMES while unaligned, so it needs one more
            // value than a plain 0..FADE_FRAMES-1 counter.
            localparam integer CNT_W = (FADE_FRAMES <= 2) ? 2 : $clog2(FADE_FRAMES + 1);

            localparam [1:0] S_IDLE = 2'd0;
            localparam [1:0] S_OUT  = 2'd1;
            localparam [1:0] S_HOLD = 2'd2;
            localparam [1:0] S_IN   = 2'd3;

            // ---- shared registers (declared before both always blocks) ----
            reg req_toggle;
            reg mode_toggle;
            reg ack_seen;
            reg commit_sync1, commit_sync2;
            reg busy_sync1, busy_sync2;
            // KEY2 bursts can be much faster than a 16-frame transition.
            // Hold up to 127 presses and start one fade for each press.
            reg [6:0] pending_next_events;
            reg req_ack_sync1, req_ack_sync2;
            wire launch_next = pending_next_events != 0 &&
                               !busy_sync2 && req_toggle == req_ack_sync2;

            // ---- pixel-domain sequencer ----
            reg [1:0] state;
            reg [CNT_W-1:0] ramp;
            reg req_sync1, req_sync2, req_seen;
            reg mode_sync1, mode_sync2, mode_seen;
            reg commit_toggle;
            reg wipe_mode;
            reg [1:0] wipe_kind;

            wire fade_running = (state != S_IDLE);
            assign fade_active = fade_running;
            // ramp is CNT_W bits; zero-extend explicitly because an
            // out-of-range part select would read as X.
            assign ramp_out = {{(5-CNT_W){1'b0}}, ramp};
            assign wipe_active = (state == S_IN) && wipe_mode;
            assign transition_kind = wipe_kind;

            wire [CNT_W+8:0] ramp_alpha = ramp * STEP;
            wire [7:0] ramp_alpha8 = ramp_alpha[7:0];
            // ramp == FADE_FRAMES means the request arrived mid-frame and the
            // current frame must still display untouched full brightness; the
            // fade visibly starts with the next complete frame.
            assign alpha_out = ((state == S_IDLE) ||
                               ((state == S_IN) && wipe_mode)) ? 8'd255 :
                               (state == S_HOLD)  ? 8'd0   :
                               (ramp == FADE_FRAMES) ? 8'd255 : ramp_alpha8;

            always @(posedge pix_clk or negedge pix_rst_n) begin
                if (!pix_rst_n) begin
                    state <= S_IDLE;
                    ramp <= {CNT_W{1'b0}};
                    req_sync1 <= 1'b0;
                    req_sync2 <= 1'b0;
                    req_seen <= 1'b0;
                    mode_sync1 <= 1'b0;
                    mode_sync2 <= 1'b0;
                    mode_seen <= 1'b0;
                    commit_toggle <= 1'b0;
                    wipe_mode <= 1'b0;
                    wipe_kind <= 2'd0;
                end else begin
                    req_sync1 <= req_toggle;
                    req_sync2 <= req_sync1;
                    mode_sync1 <= mode_toggle;
                    mode_sync2 <= mode_sync1;

                    case (state)
                    S_IDLE: begin
                        if (mode_sync2 != mode_seen && frame_start) begin
                            mode_seen <= mode_sync2;
                            state <= S_IN;
                            ramp <= {CNT_W{1'b0}};
                            wipe_mode <= 1'b0;
                        end else if (req_sync2 != req_seen) begin
                            req_seen <= req_sync2;
                            if (player_active) begin
                                state <= S_OUT;
                                ramp <= FADE_FRAMES[CNT_W-1:0];
                            end
                        end else if (index_commit && player_active) begin
                            // Automatic slideshow switch: the old frame is
                            // already committed away; reveal the new one
                            // left-to-right instead of fading from black.
                            state <= S_IN;
                            ramp <= {CNT_W{1'b0}};
                            wipe_mode <= 1'b1;
                            wipe_kind <= active_index;
                        end
                    end
                    S_OUT: begin
                        if (frame_start) begin
                            if (ramp == 0) begin
                                state <= S_HOLD;
                                commit_toggle <= ~commit_toggle;
                            end else begin
                                ramp <= ramp - 1'b1;
                            end
                        end
                        // Track the request handshake even mid-fade so a
                        // second early event cannot desync req_seen.
                        if (req_sync2 != req_seen)
                            req_seen <= req_sync2;
                    end
                    S_HOLD: begin
                        if (index_commit) begin
                            state <= S_IN;
                            ramp <= {CNT_W{1'b0}};
                            wipe_mode <= 1'b0;
                        end
                    end
                    S_IN: begin
                        if (mode_sync2 != mode_seen && frame_start) begin
                            mode_seen <= mode_sync2;
                            ramp <= {CNT_W{1'b0}};
                            wipe_mode <= 1'b0;
                        end
                        if (req_sync2 != req_seen)
                            req_seen <= req_sync2;
                        if (frame_start && mode_sync2 == mode_seen) begin
                            if (ramp >= FADE_FRAMES - 1)
                                state <= S_IDLE;
                            else
                                ramp <= ramp + 1'b1;
                        end
                    end
                    endcase
                end
            end

            // ---- control-domain bookkeeping ----
            assign fade_busy = busy_sync2;
            assign next_event_out = (commit_sync2 != ack_seen);

            always @(posedge ctrl_clk or negedge ctrl_rst_n) begin
                if (!ctrl_rst_n) begin
                    req_toggle <= 1'b0;
                    mode_toggle <= 1'b0;
                    ack_seen <= 1'b0;
                    commit_sync1 <= 1'b0;
                    commit_sync2 <= 1'b0;
                    busy_sync1 <= 1'b0;
                    busy_sync2 <= 1'b0;
                    pending_next_events <= 7'd0;
                    req_ack_sync1 <= 1'b0;
                    req_ack_sync2 <= 1'b0;
                end else begin
                    busy_sync1 <= fade_running;
                    busy_sync2 <= busy_sync1;
                    commit_sync1 <= commit_toggle;
                    commit_sync2 <= commit_sync1;
                    req_ack_sync1 <= req_seen;
                    req_ack_sync2 <= req_ack_sync1;
                    if (mode_event_in)
                        pending_next_events <= 7'd0;
                    else if (next_event_in && !launch_next &&
                             pending_next_events != 7'h7f)
                        pending_next_events <= pending_next_events + 1'b1;
                    else if (!next_event_in && launch_next)
                        pending_next_events <= pending_next_events - 1'b1;
                    if (launch_next)
                        req_toggle <= ~req_toggle;
                    if (mode_event_in)
                        mode_toggle <= ~mode_toggle;
                    if (commit_sync2 != ack_seen)
                        ack_seen <= commit_sync2;
                end
            end
        end
    endgenerate
endmodule
