`timescale 1ns/1ps

module media_video_pipeline #(
    parameter integer IMAGE_WORDS = 307200,
    parameter integer FIFO_DEPTH = 512,
    parameter integer FIFO_MARGIN = 16,
    parameter integer H_ACT = 640,
    parameter integer H_FP = 16,
    parameter integer H_SYNC = 96,
    parameter integer H_BP = 48,
    parameter integer V_ACT = 480,
    parameter integer V_FP = 10,
    parameter integer V_SYNC = 2,
    parameter integer V_BP = 33,
    parameter [31:0] DEFAULT_PERIOD_CYCLES = 32'd250000000,
    parameter [31:0] MIN_PERIOD_CYCLES = 32'd50000000,
    parameter [31:0] MAX_PERIOD_CYCLES = 32'd3000000000,
    // Non-zero enables the fade-out/black/fade-in transition on manual
    // switches and a fade-in on automatic slideshow switches. Zero keeps the
    // legacy direct-switch behaviour for the existing regression suites.
    parameter integer FADE_FRAMES = 0
) (
    input  wire        ctrl_clk,
    input  wire        ctrl_rst_n,
    input  wire        next_event,
    input  wire        auto_advance_ready,
    input  wire        toggle_auto_event,
    input  wire        period_cfg_valid,
    input  wire [31:0] period_cfg_cycles,
    input  wire        auto_cfg_valid,
    input  wire        auto_cfg_enabled,
    input  wire [3:0]  image_complete,
    input  wire [7:0]  source_size_codes,
    input  wire        player_enable,
    input  wire        thumbnail_mode,
    input  wire [1:0]  thumbnail_focus_index,
    input  wire        thumbnail_select_valid,
    input  wire [1:0]  thumbnail_select_index,
    input  wire        thumbnail_transition_req,
    input  wire [7:0]  storage_error,

    input  wire        mem_clk,
    input  wire        mem_rst_n,
    input  wire        controller_init_done,
    input  wire        controller_busy,
    input  wire        refresh_active,
    output wire        app_rd_en,
    output wire [20:0] app_rd_addr,
    input  wire        sdram_rd_valid,
    input  wire [31:0] sdram_rd_data,

    input  wire [7:0]  brightness,
    input  wire [7:0]  contrast,
    input  wire        contrast_selected,
    input  wire        waveform_enable,
    input  wire        pcm_tap_valid,
    input  wire signed [15:0] pcm_tap_left,
    input  wire        pix_clk,
    input  wire        pix_rst_n,
    output wire        video_clk,
    output wire        video_hs,
    output wire        video_vs,
    output wire        video_de,
    output wire [23:0] video_rgb,
    output wire [9:0]  video_x,

    output wire [1:0]  active_index,
    output wire [1:0]  pending_index,
    output wire        auto_enabled,
    output wire        frame_start,
    output reg         frame_tick_ctrl,
    output wire        player_request_busy,
    output wire [7:0]  audio_fade_alpha,
    output wire        audio_fade_active,
    output wire        reader_busy,
    output wire        reader_underflow,
    output wire [7:0]  video_error
);
    wire raw_hs;
    wire raw_vs;
    wire raw_de;
    wire [11:0] raw_x;
    wire [11:0] raw_y;
    localparam integer H_BLANK = H_FP + H_SYNC + H_BP;
    localparam integer V_BLANK = V_FP + V_SYNC + V_BP;
    wire [11:0] active_x = (raw_x >= H_BLANK) ? raw_x - H_BLANK : 12'd0;
    wire [11:0] active_y = (raw_y >= V_BLANK) ? raw_y - V_BLANK : 12'd0;
    wire thumbnail_mode_sync;
    reg thumbnail_mode_frame;
    reg [1:0] focus_pix1;
    reg [1:0] focus_pix2;
    reg [1:0] focus_frame;
    reg [3:0] complete_pix1;
    reg [3:0] complete_pix2;
    reg [3:0] complete_frame;
    reg [7:0] size_codes_pix1;
    reg [7:0] size_codes_pix2;
    reg [7:0] brightness_pix1;
    reg [7:0] brightness_pix2;
    reg [7:0] contrast_pix1;
    reg [7:0] contrast_pix2;
    reg contrast_selected_pix1;
    reg contrast_selected_pix2;
    reg [7:0] brightness_frame;
    reg [7:0] contrast_frame;
    wire thumbnail_de;
    wire thumbnail_border;
    thumbnail_layout u_thumbnail_layout (
        .in_de(raw_de), .pixel_x(active_x), .pixel_y(active_y),
        .focus_index(focus_frame), .image_complete(complete_frame),
        .thumb_de(thumbnail_de), .source_index(), .source_x(),
        .source_y(), .focus_border(thumbnail_border)
    );
    sync_2ff u_thumbnail_mode_sync (
        .clk(pix_clk), .rst_n(pix_rst_n), .async_in(thumbnail_mode),
        .sync_out(thumbnail_mode_sync)
    );
    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            thumbnail_mode_frame <= 1'b0;
            focus_pix1 <= 2'd0;
            focus_pix2 <= 2'd0;
            focus_frame <= 2'd0;
            complete_pix1 <= 4'd0;
            complete_pix2 <= 4'd0;
            complete_frame <= 4'd0;
            size_codes_pix1 <= 8'd0;
            size_codes_pix2 <= 8'd0;
            brightness_pix1 <= 8'd255;
            brightness_pix2 <= 8'd255;
            contrast_pix1 <= 8'd128;
            contrast_pix2 <= 8'd128;
            contrast_selected_pix1 <= 1'b0;
            contrast_selected_pix2 <= 1'b0;
            brightness_frame <= 8'd255;
            contrast_frame <= 8'd128;
        end else begin
            size_codes_pix1 <= source_size_codes;
            size_codes_pix2 <= size_codes_pix1;
            complete_pix1 <= image_complete;
            complete_pix2 <= complete_pix1;
            focus_pix1 <= thumbnail_focus_index;
            focus_pix2 <= focus_pix1;
            brightness_pix1 <= brightness;
            brightness_pix2 <= brightness_pix1;
            contrast_pix1 <= contrast;
            contrast_pix2 <= contrast_pix1;
            contrast_selected_pix1 <= contrast_selected;
            contrast_selected_pix2 <= contrast_selected_pix1;
            if (frame_start) begin
                thumbnail_mode_frame <= thumbnail_mode_sync;
                focus_frame <= focus_pix2;
                complete_frame <= complete_pix2;
                brightness_frame <= brightness_pix2;
                contrast_frame <= contrast_pix2;
            end
        end
    end
    reg raw_vs_q;
    reg [9:0] video_x_q;
    wire index_commit;
    wire [7:0] control_error;
    wire request_busy;
    assign player_request_busy = request_busy;
    wire [31:0] active_period_cycles;
    wire [23:0] reader_rgb;
    wire reader_pixel_valid;
    wire reader_done;
    wire [1:0] reader_index;
    wire [7:0] reader_error;
    wire player_enable_pix;
    wire player_enable_mem;
    wire auto_enabled_pix;
    reg [7:0] storage_error_pix1;
    reg [7:0] storage_error_pix2;
    reg [7:0] reader_error_pix1;
    reg [7:0] reader_error_pix2;
    reg [7:0] control_error_pix1;
    reg [7:0] control_error_pix2;
    wire valid_image_pixel = player_enable_pix && reader_pixel_valid &&
                             reader_error_pix2 == 0 &&
                             (!thumbnail_mode_frame || thumbnail_de);
    wire [23:0] selected_rgb = valid_image_pixel ?
        (thumbnail_mode_frame ?
            (thumbnail_de ? (thumbnail_border ? 24'hffff00 : reader_rgb) : 24'h000000) :
            reader_rgb) : 24'h000000;
    wire [23:0] contrast_rgb;
    wire [23:0] adjusted_rgb;
    brightness_contrast_adjust #(.REGISTER_OUTPUT(0)) u_contrast_adjust (
        .clk(pix_clk), .rst_n(pix_rst_n), .in_de(raw_de),
        .rgb_in(selected_rgb), .brightness(8'd255),
        .contrast(contrast_frame), .out_de(), .rgb_out(contrast_rgb)
    );
    assign adjusted_rgb = valid_image_pixel ? contrast_rgb : 24'h000000;

    sync_2ff u_player_enable_pix (
        .clk(pix_clk), .rst_n(pix_rst_n), .async_in(player_enable),
        .sync_out(player_enable_pix)
    );
    sync_2ff u_player_enable_mem (
        .clk(mem_clk), .rst_n(mem_rst_n), .async_in(player_enable),
        .sync_out(player_enable_mem)
    );
    sync_2ff u_auto_enabled_pix (
        .clk(pix_clk), .rst_n(pix_rst_n), .async_in(auto_enabled),
        .sync_out(auto_enabled_pix)
    );

    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            reader_error_pix1 <= 8'd0;
            reader_error_pix2 <= 8'd0;
            control_error_pix1 <= 8'd0;
            control_error_pix2 <= 8'd0;
            storage_error_pix1 <= 8'd0;
            storage_error_pix2 <= 8'd0;
        end else begin
            reader_error_pix1 <= reader_error;
            reader_error_pix2 <= reader_error_pix1;
            control_error_pix1 <= control_error;
            control_error_pix2 <= control_error_pix1;
            storage_error_pix1 <= storage_error;
            storage_error_pix2 <= storage_error_pix1;
        end
    end

    video_timing_ctrl #(
        .H_ACT(H_ACT), .H_FP(H_FP), .H_SYNC(H_SYNC), .H_BP(H_BP),
        .V_ACT(V_ACT), .V_FP(V_FP), .V_SYNC(V_SYNC), .V_BP(V_BP),
        .ACTIVE_LAST(1)
    ) u_timing (
        .pclk(pix_clk), .rst_n(pix_rst_n), .hsync(raw_hs),
        .vsync(raw_vs), .de(raw_de), .x(raw_x), .y(raw_y)
    );

    // Fade transition: manual switch requests are held until the display has
    // faded to black, then released to the control FSM at the frame boundary.
    // The bypass branch (FADE_FRAMES=0) wires next_event straight through so
    // legacy regression timing is unchanged.
    wire fade_next_event;
    wire [7:0] fade_alpha;
    wire wipe_active;
    wire [4:0] wipe_ramp;
    wire [1:0] transition_kind;
    video_fade_transition #(.FADE_FRAMES(FADE_FRAMES)) u_fade (
        .ctrl_clk(ctrl_clk), .ctrl_rst_n(ctrl_rst_n),
        .next_event_in(next_event), .next_event_out(fade_next_event),
        .mode_event_in(thumbnail_transition_req),
        .fade_busy(),
        .pix_clk(pix_clk), .pix_rst_n(pix_rst_n),
        .player_active(player_enable_pix), .frame_start(frame_start),
        .index_commit(index_commit), .active_index(active_index),
        .alpha_out(fade_alpha), .fade_active(audio_fade_active),
        .wipe_active(wipe_active), .ramp_out(wipe_ramp),
        .transition_kind(transition_kind)
    );
    assign audio_fade_alpha = fade_alpha;

    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n)
            raw_vs_q <= 1'b1;
        else
            raw_vs_q <= raw_vs;
    end
    assign frame_start = raw_vs_q && !raw_vs;
    reg frame_toggle_pix;
    reg frame_sync1_ctrl;
    reg frame_sync2_ctrl;
    reg frame_seen_ctrl;
    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n)
            frame_toggle_pix <= 1'b0;
        else if (frame_start)
            frame_toggle_pix <= ~frame_toggle_pix;
    end
    always @(posedge ctrl_clk or negedge ctrl_rst_n) begin
        if (!ctrl_rst_n) begin
            frame_sync1_ctrl <= 1'b0;
            frame_sync2_ctrl <= 1'b0;
            frame_seen_ctrl <= 1'b0;
            frame_tick_ctrl <= 1'b0;
        end else begin
            frame_sync1_ctrl <= frame_toggle_pix;
            frame_sync2_ctrl <= frame_sync1_ctrl;
            frame_tick_ctrl <= frame_sync2_ctrl != frame_seen_ctrl;
            if (frame_sync2_ctrl != frame_seen_ctrl)
                frame_seen_ctrl <= frame_sync2_ctrl;
        end
    end

    // rgb_video_adapter registers hs/vs/de/rgb by one pixel. Register x in
    // parallel so the HDMI Data Island scheduler sees the coordinate belonging
    // to the same output character, rather than the next raw VTC position.
    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n)
            video_x_q <= 10'd0;
        else
            video_x_q <= active_x[9:0];
    end
    assign video_x = video_x_q;

    media_player_control #(
        .DEFAULT_PERIOD_CYCLES(DEFAULT_PERIOD_CYCLES),
        .MIN_PERIOD_CYCLES(MIN_PERIOD_CYCLES),
        .MAX_PERIOD_CYCLES(MAX_PERIOD_CYCLES)
    ) u_control (
        .sys_clk(ctrl_clk), .sys_rst_n(ctrl_rst_n),
        .select_valid(thumbnail_select_valid),
        .select_index(thumbnail_select_index), .browse_mode(thumbnail_mode),
        .next_event(fade_next_event), .toggle_auto_event(toggle_auto_event),
        .auto_advance_ready(auto_advance_ready),
        .period_cfg_valid(period_cfg_valid),
        .period_cfg_cycles(period_cfg_cycles),
        .auto_cfg_valid(auto_cfg_valid),
        .auto_cfg_enabled(auto_cfg_enabled),
        .image_complete(image_complete), .auto_enabled(auto_enabled),
        .active_period_cycles(active_period_cycles),
        .pending_index(pending_index), .control_error(control_error),
        .request_busy(request_busy), .pix_clk(pix_clk),
        .pix_rst_n(pix_rst_n), .frame_start(frame_start),
        .active_index(active_index), .index_commit(index_commit)
    );

    media_frame_reader #(
        .ADDR_WIDTH(21), .IMAGE_WORDS(IMAGE_WORDS),
        .FIFO_DEPTH(FIFO_DEPTH), .FIFO_MARGIN(FIFO_MARGIN),
        .MAX_INFLIGHT_BURSTS(2), .DIAG_RETURN_PATTERN(0),
        .DIAG_SYNTH_STREAM(0), .DIAG_CONSTANT_STREAM(0),
        .DIAG_THUMB_BANK0(0), .DIAG_THUMB_CONTINUOUS_RIGHT(0)
    ) u_reader (
        .mem_clk(mem_clk), .mem_rst_n(mem_rst_n),
        .controller_init_done(controller_init_done && player_enable_mem),
        .controller_busy(controller_busy), .refresh_active(refresh_active),
        .app_rd_en(app_rd_en), .app_rd_addr(app_rd_addr),
        .sdram_rd_valid(sdram_rd_valid), .sdram_rd_data(sdram_rd_data),
        .pix_clk(pix_clk), .pix_rst_n(pix_rst_n),
        .frame_start(frame_start && player_enable_pix), .active_index(active_index),
        .thumbnail_mode(thumbnail_mode_frame), .image_complete(complete_frame),
        .pixel_consume(raw_de && player_enable_pix), .pixel_rgb(reader_rgb),
        .pixel_valid(reader_pixel_valid), .underflow(reader_underflow),
        .reader_busy(reader_busy), .frame_read_done(reader_done),
        .reader_index(reader_index), .reader_error(reader_error)
    );

    // Fade multiplies the selected frame by the ramp alpha; an automatic
    // slideshow switch instead reveals the new frame left-to-right: pixels
    // right of the moving boundary stay black, the rest show full colour.
    // With FADE_FRAMES=0 the direct assignment keeps every pixel bit-identical
    // to the legacy path so strict regression comparisons still hold.
    wire [23:0] faded_rgb;
    generate
        if (FADE_FRAMES == 0) begin : g_fade_bypass
            assign faded_rgb = adjusted_rgb;
        end else begin : g_fade_mul
            // Session-level brightness folds into the transition alpha with
            // one extra 8x8 multiply, so the steady display and the fade both
            // scale together.
            // (brightness+1)/256 keeps full brightness bit-exact (256/256)
            // while lower steps land within 0.4% of brightness/255.
            wire [8:0] brightness_gain = {1'b0, brightness_frame} + 9'd1;
            wire [7:0] eff_alpha =
                ({8'd0, fade_alpha} * brightness_gain) >> 8;
            wire [8:0] pixel_gain = {1'b0, eff_alpha} + 9'd1;
            wire [16:0] fade_mul_r = {8'd0, adjusted_rgb[23:16]} * pixel_gain;
            wire [16:0] fade_mul_g = {8'd0, adjusted_rgb[15:8]}  * pixel_gain;
            wire [16:0] fade_mul_b = {8'd0, adjusted_rgb[7:0]}   * pixel_gain;
            wire [23:0] alpha_rgb =
                {fade_mul_r[15:8], fade_mul_g[15:8], fade_mul_b[15:8]};
            // Reveal boundary advances one H_ACT/FADE_FRAMES column step per
            // frame; the comparison uses the same raw_x that aligns with
            // selected_rgb at this point in the pipeline.
            localparam integer WIPE_STEP = H_ACT / FADE_FRAMES;
            wire [9:0] wipe_boundary = wipe_ramp * WIPE_STEP;
            wire [6:0] blind_x_boundary = wipe_ramp * 4;
            reg transition_pixel;
            always @* begin
                case (transition_kind)
                    2'd0: transition_pixel = active_x[9:0] < wipe_boundary;
                    2'd1: transition_pixel = active_x[9:0] >= H_ACT - wipe_boundary;
                    2'd2: transition_pixel = {1'b0, active_x[5:0]} < blind_x_boundary;
                    default: transition_pixel = (active_x[6] ^ raw_y[6]) ?
                        ({1'b0, active_x[5:0]} < blind_x_boundary) :
                        ({1'b0, active_x[5:0]} >= 7'd64 - blind_x_boundary);
                endcase
            end
            assign faded_rgb = wipe_active ?
                (transition_pixel ? alpha_rgb : 24'h000000) :
                alpha_rgb;
        end
    endgenerate

    wire [23:0] thumbnail_title_rgb;
    thumbnail_title_overlay u_thumbnail_title_overlay (
        .de(raw_de), .thumbnail_mode(thumbnail_mode_frame),
        .pixel_x(active_x[9:0]), .pixel_y(active_y[9:0]),
        .focus_index(focus_frame), .image_complete(complete_frame),
        .rgb_in(faded_rgb), .rgb_out(thumbnail_title_rgb)
    );

    wire [23:0] boot_rgb;
    boot_splash_overlay u_boot_splash (
        .de(raw_de), .image_ready(player_enable_pix),
        .pixel_x(active_x[9:0]), .pixel_y(active_y[9:0]),
        .rgb_in(thumbnail_title_rgb), .rgb_out(boot_rgb)
    );

    wire [23:0] osd_rgb;
    wire osd_de;
    wire [7:0] osd_error = storage_error_pix2 != 0 ? storage_error_pix2 :
                           video_error;
    osd_overlay_24 #(.OSD_X(8), .OSD_Y(8)) u_status_osd (
        .clk(pix_clk), .rst_n(pix_rst_n), .vsync(raw_vs), .de(raw_de),
        .rgb_in(boot_rgb),
        .pixel_x(active_x[9:0]),
        .active_index(active_index), .auto_enabled(auto_enabled_pix),
        // The OSD latches on this same edge; feed the synchronized next
        // values so its readout matches the newly committed pixel gain.
        .brightness(brightness_pix2), .contrast(contrast_pix2),
        .contrast_selected(contrast_selected_pix2),
        .error_code(osd_error), .rgb_out(osd_rgb),
        .de_out(osd_de), .osd_active()
    );

    wire [1:0] active_source_size =
        size_codes_pix2[{active_index, 1'b0} +: 2];
    wire [23:0] source_osd_rgb;
    source_resolution_osd u_source_resolution_osd (
        .de(osd_de),
        .show(player_enable_pix && !thumbnail_mode_frame &&
              complete_frame[active_index]),
        .size_code(active_source_size),
        .pixel_x(active_x[9:0]), .pixel_y(active_y),
        .rgb_in(osd_rgb), .rgb_out(source_osd_rgb)
    );

    wire [23:0] caption_rgb;
    media_dynamic_caption u_dynamic_caption (
        .clk(pix_clk), .rst_n(pix_rst_n),
        .vsync(raw_vs), .de(osd_de),
        .pixel_x(active_x[9:0]), .pixel_y(active_y),
        .active_index(active_index),
        .rgb_in(source_osd_rgb), .rgb_out(caption_rgb)
    );

    // Browsing is a selection view. Keep its native title and instruction
    // strips clear of the full-screen timer, fixed topic caption and waveform.
    wire [23:0] browse_caption_rgb =
        (thumbnail_mode_frame || !player_enable_pix) ? source_osd_rgb : caption_rgb;
    wire [23:0] waveform_rgb;
    promax_audio_waveform u_audio_waveform (
        .clk(pix_clk), .rst_n(pix_rst_n),
        .vsync(raw_vs), .de(osd_de),
        .rgb_in(browse_caption_rgb), .pixel_x(active_x[9:0]),
        .enable(waveform_enable && player_enable_pix && !thumbnail_mode_frame),
        .pcm_tap_valid(pcm_tap_valid), .pcm_tap_left(pcm_tap_left),
        .rgb_out(waveform_rgb), .waveform_active()
    );

    rgb_video_adapter u_video_adapter (
        .pclk(pix_clk), .rst_n(pix_rst_n), .hs_in(raw_hs),
        .vs_in(raw_vs), .de_in(osd_de),
        .rgb_in(waveform_rgb), .video_clk(video_clk),
        .video_hs(video_hs), .video_vs(video_vs),
        .video_de(video_de), .video_rgb(video_rgb)
    );

    assign video_error = reader_error_pix2 != 0 ? reader_error_pix2 :
                         reader_underflow ? 8'h63 : control_error_pix2;
endmodule
