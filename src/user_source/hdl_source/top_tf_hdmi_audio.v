
module top(
    input                       clk,
    input                       rst_n,
    input                       key1,           // 手动下一张
    input                       key2,           // 自动播放 开/关
    input                       thumbnail_sw,   // SW1: 四图缩略图模式
    input                       adjust_key_n,   // KEY3: 调节一次
    input                       adjust_select_sw,// SW2: 0亮度/1对比度
    input                       adjust_up_sw,    // SW3: 0减小/1增大
    input                       adjust_step_sw,  // SW4: 0步长16/1步长32

    output [5:0]                seg_sel,
    output [7:0]                seg_data,

    // HDMI TMDS
    output                      HDMI_CLK_P,
    output                      HDMI_D2_P,
    output                      HDMI_D1_P,
    output                      HDMI_D0_P,

    // HDMI DDC
    output                      HDMI_DDC_SCL,
    inout                       HDMI_DDC_SDA,

    // TF card SPI
    output                      sd_ncs,
    output                      sd_dclk,
    output                      sd_mosi,
    input                       sd_miso
);

parameter MEM_DATA_BITS = 32;
parameter ADDR_BITS     = 21;
parameter BUSRT_BITS    = 10;
parameter FRAME_PIXELS  = 24'd307200;   // 640*480
parameter BUF0_ADDR     = 24'd0;
parameter BUF1_ADDR     = FRAME_PIXELS;

wire Sdr_init_done;
wire Sdr_init_ref_vld;
wire Sdr_busy;

wire sd_card_clk;
wire ext_mem_clk;
wire ext_mem_clk_sft;
wire video_clk;
wire hdmi_5x_clk;

wire hs;
wire vs;
wire de;

wire [23:0] vout_data;
wire [3:0]  state_code;
wire [6:0]  seg_data_0;
wire        key_next_event;
wire        key_auto_event;
wire        source_load_start;
wire [1:0]  source_image_index;
wire        source_pixel_valid;
wire [23:0] source_pixel_rgb;
wire        source_frame_commit;
wire [7:0]  source_decode_error;
wire        source_preload_done;
wire [7:0]  source_error;
wire        loader_busy;
wire        loader_done;
wire [3:0]  image_complete;
wire [7:0]  source_size_codes;
wire [7:0]  loader_error;
wire        loader_wr_en;
wire [ADDR_BITS-1:0] loader_wr_addr;
wire [31:0] loader_wr_data;
wire [3:0]  loader_wr_mask;
wire        write_cdc_full;
wire        write_cdc_overflow;
wire        write_cdc_idle;
wire [1:0]  active_index;
wire [1:0]  pending_index;
wire        auto_enabled;
wire        video_frame_start;
wire        reader_busy;
wire        reader_underflow;
wire [7:0]  video_error;
wire [9:0]  video_x_unused;
reg         preload_done_d;
wire        boot_select_event = source_preload_done && !preload_done_d &&
                                !image_complete[0] && (image_complete != 0);
wire        player_enable = source_preload_done && write_cdc_idle &&
                            (image_complete != 0);
wire [7:0]  osd_storage_error = source_error != 0 ? source_error :
                                loader_error != 0 ? loader_error :
                                 narration_error != 0 ? narration_error :
                                write_cdc_overflow ? 8'h42 : 8'd0;

wire App_rd_en;
wire [ADDR_BITS-1:0] App_rd_addr;
wire Sdr_rd_en;
wire [MEM_DATA_BITS-1:0] Sdr_rd_dout;
wire App_wr_en;
wire [ADDR_BITS-1:0] App_wr_addr;
wire [MEM_DATA_BITS-1:0] App_wr_din;
wire [3:0] App_wr_dm;


// HDMI 1.4b 音频发射相关
wire        audio_pll_lock;
wire        audio_mclk;
wire        audio_i2s_bclk;
wire        audio_i2s_lrck;
wire        audio_i2s_dout;
wire        audio_valid;
wire [23:0] audio_left_data;
wire [23:0] audio_right_data;
wire [23:0] audio_left_unmuted;
wire [23:0] audio_right_unmuted;
wire tone_valid;
wire [23:0] tone_left_data, tone_right_data;
reg tone_valid_d;
reg [23:0] tone_left_d, tone_right_d;
wire signed [15:0] narration_sample;
wire narration_active;
wire demo_active;
wire demo_complete;
reg demo_complete_meta, demo_complete_sync;
wire auto_advance_ready = !audio_file_valid[pending_index] ||
                          narration_error != 0 || demo_complete_sync;
wire [7:0] narration_error;
wire [3:0] audio_file_valid;
wire [31:0] audio0_cluster, audio1_cluster, audio2_cluster, audio3_cluster;
wire [31:0] audio0_size, audio1_size, audio2_size, audio3_size;
wire [7:0] audio_sectors_per_cluster;
wire [31:0] audio_fat_start_lba, audio_data_start_lba, audio_max_cluster;
wire audio_sector_req, audio_sector_busy, audio_sector_valid, audio_sector_done;
wire [31:0] audio_sector_lba;
wire [7:0] audio_sector_byte, audio_sector_error;
wire [8:0] audio_sector_index;
wire        acr_valid;

always @(posedge sd_card_clk or negedge sdcard_rst_n) begin
    if (!sdcard_rst_n) begin
        demo_complete_meta <= 1'b0;
        demo_complete_sync <= 1'b0;
    end else begin
        demo_complete_meta <= demo_complete;
        demo_complete_sync <= demo_complete_meta;
    end
end
wire [19:0] acr_cts;
wire [19:0] acr_n;

wire        axis_s_user;
wire        axis_s_valid;
wire        axis_s_last;
wire [23:0] axis_s_data;
wire        axis_s_ready;

wire        edid_trig;
wire        edid_valid;
wire [7:0]  edid_data;

wire [9:0]  tmds_ch0_data;
wire [9:0]  tmds_ch1_data;
wire [9:0]  tmds_ch2_data;
wire [9:0]  tmds_clk_data;

// 外部复位直接复位 PLL；各业务域在全部 PLL 锁定后分别同步释放。
wire sys_pll_lock, video_pll_lock;
wire clocks_ready_n = rst_n & sys_pll_lock & video_pll_lock & audio_pll_lock;
wire ctrl_rst_n, sdcard_rst_n, mem_rst_n, video_rst_n, audio_rst_n;
wire Sdr_init_done_sd;
reset_sync u_ctrl_reset   (.clk(clk),         .ext_rst_n(clocks_ready_n), .rst_n_sync(ctrl_rst_n));
reset_sync u_sdcard_reset (.clk(sd_card_clk), .ext_rst_n(clocks_ready_n), .rst_n_sync(sdcard_rst_n));
reset_sync u_mem_reset    (.clk(ext_mem_clk), .ext_rst_n(clocks_ready_n), .rst_n_sync(mem_rst_n));
reset_sync u_video_reset  (.clk(video_clk),   .ext_rst_n(clocks_ready_n), .rst_n_sync(video_rst_n));
reset_sync u_audio_reset  (.clk(audio_mclk),  .ext_rst_n(clocks_ready_n), .rst_n_sync(audio_rst_n));
sync_2ff u_sdram_init_sync (
    .clk(sd_card_clk), .rst_n(sdcard_rst_n),
    .async_in(Sdr_init_done), .sync_out(Sdr_init_done_sd)
);

// 保持你原来的 TF / SDRAM / video 时钟
sys_pll_locked sys_pll_m0(
    .refclk     (clk),
    .clk0_out   (sd_card_clk),
    .clk1_out   (ext_mem_clk),
    .clk2_out   (ext_mem_clk_sft),
    .reset      (~rst_n),
    .locked     (sys_pll_lock)
);

video_pll_locked video_pll_m0(
    .refclk     (clk),
    .clk0_out   (video_clk),
    .clk1_out   (hdmi_5x_clk),
    .reset      (~rst_n),
    .locked     (video_pll_lock)
);

// 复用你 I2S->HDMI 工程里的 PLL，只取 12.288MHz 音频主时钟
PLL_HDMI_AUDIO u_audio_pll(
    .refclk     (clk),
    .reset      (~rst_n),
    .extlock    (audio_pll_lock),
    .clk0_out   (),
    .clk1_out   (),
    .clk2_out   (audio_mclk)
);

// ===================== TF/FAT32 preload -> four fixed SDRAM banks =====================
key_press_debounce #(.CLK_FREQ_HZ(100_000_000), .DEBOUNCE_MS(20)) u_key_next (
    .clk(sd_card_clk), .rst(~sdcard_rst_n), .button_in(key1),
    .press_pulse(key_next_event), .button_stable_out()
);
key_press_debounce #(.CLK_FREQ_HZ(100_000_000), .DEBOUNCE_MS(20)) u_key_auto (
    .clk(sd_card_clk), .rst(~sdcard_rst_n), .button_in(key2),
    .press_pulse(key_auto_event), .button_stable_out()
);
wire adjust_event;
wire thumbnail_view_mode;
wire [1:0] thumbnail_focus_index;
wire thumbnail_select_valid;
wire [1:0] thumbnail_select_index;
wire thumbnail_transition_req;
wire frame_tick_ctrl;
wire player_request_busy;
wire thumbnail_mode_event;
switch_change_debounce u_thumbnail_switch (
    .clk(sd_card_clk), .rst_n(sdcard_rst_n),
    .switch_in(thumbnail_sw), .change_pulse(thumbnail_mode_event)
);
thumbnail_controller u_thumbnail_controller (
    .clk(sd_card_clk), .rst_n(sdcard_rst_n),
    .key_right(key_next_event), .key_left(key_auto_event),
    .key_confirm(adjust_event), .key_mode(thumbnail_mode_event),
    .image_complete(image_complete), .frame_start(frame_tick_ctrl),
    .display_index(active_index), .request_busy(player_request_busy),
    .view_mode(thumbnail_view_mode), .focus_index(thumbnail_focus_index),
    .active_index(), .select_valid(thumbnail_select_valid),
    .select_index(thumbnail_select_index),
    .transition_req(thumbnail_transition_req)
);
wire [7:0] display_brightness;
wire [7:0] display_contrast;
wire contrast_selected;
key_press_debounce #(.CLK_FREQ_HZ(100_000_000), .DEBOUNCE_MS(20)) u_key_adjust (
    .clk(sd_card_clk), .rst(~sdcard_rst_n), .button_in(adjust_key_n),
    .press_pulse(adjust_event), .button_stable_out()
);
video_adjust_control u_adjust_control (
    .clk(sd_card_clk), .rst_n(sdcard_rst_n), .key_event(adjust_event && !thumbnail_view_mode),
    .select_contrast_sw(adjust_select_sw), .increase_sw(adjust_up_sw),
    .large_step_sw(adjust_step_sw), .brightness(display_brightness),
    .contrast(display_contrast), .contrast_selected(contrast_selected)
);

always @(posedge sd_card_clk or negedge sdcard_rst_n) begin
    if (!sdcard_rst_n)
        preload_done_d <= 1'b0;
    else
        preload_done_d <= source_preload_done;
end

sd_card_fourbank_source #(.CLK_FREQ_HZ(100_000_000)) u_fourbank_source (
    .audio_sector_req(audio_sector_req), .audio_sector_lba(audio_sector_lba),
    .audio_sector_busy(audio_sector_busy), .audio_sector_valid(audio_sector_valid),
    .audio_sector_byte(audio_sector_byte), .audio_sector_index(audio_sector_index),
    .audio_sector_done(audio_sector_done), .audio_sector_error(audio_sector_error),
    .audio_file_valid(audio_file_valid),
    .audio0_cluster(audio0_cluster), .audio1_cluster(audio1_cluster),
    .audio2_cluster(audio2_cluster), .audio3_cluster(audio3_cluster),
    .audio0_size(audio0_size), .audio1_size(audio1_size),
    .audio2_size(audio2_size), .audio3_size(audio3_size),
    .audio_sectors_per_cluster(audio_sectors_per_cluster),
    .audio_fat_start_lba(audio_fat_start_lba),
    .audio_data_start_lba(audio_data_start_lba),
    .audio_max_cluster(audio_max_cluster),
    .clk(sd_card_clk), .rst(~sdcard_rst_n),
    .sdram_ready(Sdr_init_done_sd),
    .memory_load_busy(loader_busy), .memory_load_done(loader_done),
    .memory_error(loader_error), .memory_load_start(source_load_start),
    .memory_image_index(source_image_index),
    .pixel_valid(source_pixel_valid), .pixel_rgb(source_pixel_rgb),
    .frame_commit(source_frame_commit), .decode_error(source_decode_error),
    .preload_done(source_preload_done), .source_error(source_error),
    .source_size_codes(source_size_codes),
    .SD_nCS(sd_ncs), .SD_DCLK(sd_dclk), .SD_MOSI(sd_mosi), .SD_MISO(sd_miso)
);

media_frame_loader #(
    .ADDR_WIDTH(ADDR_BITS), .IMAGE_WORDS(FRAME_PIXELS),
    .FIFO_DEPTH(512), .BURST_SIZE(128), .FRAME_WIDTH(640),
    .FRAME_HEIGHT(480), .WRITE_V_FLIP(1)
) u_frame_loader (
    .clk(sd_card_clk), .rst_n(sdcard_rst_n),
    .load_start(source_load_start), .image_index(source_image_index),
    .pixel_valid(source_pixel_valid), .pixel_rgb(source_pixel_rgb),
    .frame_commit(source_frame_commit), .decode_error(source_decode_error),
    .load_busy(loader_busy), .load_done(loader_done),
    .image_complete(image_complete), .memory_error(loader_error),
    .controller_init_done(Sdr_init_done_sd), .controller_busy(1'b0),
    .refresh_active(1'b0), .app_wr_en(loader_wr_en),
    .app_wr_addr(loader_wr_addr), .app_wr_mask(loader_wr_mask),
    .app_wr_data(loader_wr_data)
);

media_sdram_write_cdc #(.ADDR_WIDTH(ADDR_BITS), .BURST_SIZE(128)) u_write_cdc (
    .src_clk(sd_card_clk), .src_rst_n(sdcard_rst_n),
    .src_wr_en(loader_wr_en), .src_wr_addr(loader_wr_addr),
    .src_wr_mask(loader_wr_mask), .src_wr_data(loader_wr_data),
    .src_full(write_cdc_full), .src_overflow(write_cdc_overflow),
    .dst_clk(ext_mem_clk), .dst_rst_n(mem_rst_n),
    .dst_app_wr_en(App_wr_en), .dst_app_wr_addr(App_wr_addr),
    .dst_app_wr_mask(App_wr_dm), .dst_app_wr_data(App_wr_din),
    .dst_idle(write_cdc_idle)
);

media_video_pipeline #(
    .IMAGE_WORDS(FRAME_PIXELS), .FIFO_DEPTH(512), .FIFO_MARGIN(16),
    .DEFAULT_PERIOD_CYCLES(32'd300000000),
    .MIN_PERIOD_CYCLES(32'd1000000), .MAX_PERIOD_CYCLES(32'd3000000000),
    .FADE_FRAMES(16)
) u_video_pipeline (
    .ctrl_clk(sd_card_clk), .ctrl_rst_n(sdcard_rst_n),
    .next_event((key_next_event && !thumbnail_view_mode) | boot_select_event),
    .auto_advance_ready(auto_advance_ready),
    .toggle_auto_event(key_auto_event && !thumbnail_view_mode),
    .period_cfg_valid(1'b0), .period_cfg_cycles(32'd0),
    .auto_cfg_valid(1'b0), .auto_cfg_enabled(1'b0),
    .image_complete(image_complete), .player_enable(player_enable),
    .source_size_codes(source_size_codes),
    .thumbnail_mode(thumbnail_view_mode),
    .thumbnail_focus_index(thumbnail_focus_index),
    .thumbnail_select_valid(thumbnail_select_valid),
    .thumbnail_select_index(thumbnail_select_index),
    .thumbnail_transition_req(thumbnail_transition_req),
    .storage_error(osd_storage_error),
    .mem_clk(ext_mem_clk), .mem_rst_n(mem_rst_n),
    .controller_init_done(Sdr_init_done), .controller_busy(Sdr_busy),
    .refresh_active(Sdr_init_ref_vld), .app_rd_en(App_rd_en),
    .app_rd_addr(App_rd_addr), .sdram_rd_valid(Sdr_rd_en),
    .sdram_rd_data(Sdr_rd_dout), .brightness(display_brightness),
    .contrast(display_contrast), .contrast_selected(contrast_selected),
    .waveform_enable(1'b1), .pcm_tap_valid(audio_valid),
    .pcm_tap_left($signed(audio_left_data[23:8])),
    .pix_clk(video_clk), .pix_rst_n(video_rst_n),
    .video_clk(), .video_hs(hs), .video_vs(vs), .video_de(de),
    .video_rgb(vout_data), .video_x(video_x_unused),
    .active_index(active_index), .pending_index(pending_index),
    .auto_enabled(auto_enabled), .frame_start(video_frame_start),
    .frame_tick_ctrl(frame_tick_ctrl),
    .player_request_busy(player_request_busy),
    .reader_busy(reader_busy), .reader_underflow(reader_underflow),
    .video_error(video_error)
);

assign state_code = {2'b00, active_index} + 4'd1;

seg_decoder seg_decoder_m0(
    .bin_data          (state_code),
    .seg_data          (seg_data_0)
);

seg_scan seg_scan_m0(
    .clk               (clk),
    .rst_n             (ctrl_rst_n),
    .seg_sel           (seg_sel),
    .seg_data          (seg_data),
    .seg_data_0        ({1'b1,7'b1111_111}),
    .seg_data_1        ({1'b1,7'b1111_111}),
    .seg_data_2        ({1'b1,7'b1111_111}),
    .seg_data_3        ({1'b1,7'b1111_111}),
    .seg_data_4        ({1'b1,7'b1111_111}),
    .seg_data_5        ({1'b1,seg_data_0})
);

sdram U3(
    .Clk               (ext_mem_clk),
    .Clk_sft           (ext_mem_clk_sft),
    .Rst               (~mem_rst_n),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),
    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_dm         (App_wr_dm),
    .App_wr_din        (App_wr_din),
    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout)
);

// ===================== 音频：内部 I2S 测试音 =====================
hdmi_audio_tone_i2s_64fs #(
    .PHASE_INC (32'd39370534),
    .AMP       (24'sd2000000)
) u_hdmi_audio_tone_i2s_64fs (
    .I_mclk      (audio_mclk),
    .I_rst       (~audio_rst_n),
    .I_page_clk  (video_clk),
    .I_page_rst  (~video_rst_n),
    .I_page_index(active_index),
    .I_demo_active(demo_active),
    .O_i2s_BCLK  (audio_i2s_bclk),
    .O_i2s_LRCK  (audio_i2s_lrck),
    .O_i2s_DOUT  (audio_i2s_dout)
);

I2S_receiver u_I2S_receiver(
    .I_clk              (video_clk),
    .I_rst              (~video_rst_n),
    .I_i2s_BCLK         (audio_i2s_bclk),
    .I_i2s_LRCK         (audio_i2s_lrck),
    .I_i2s_DOUT         (audio_i2s_dout),
    .O_audio_valid      (tone_valid),
    .O_audio_left_data  (tone_left_data),
    .O_audio_right_data (tone_right_data)
);

topic_wav_stream #(.ADDR_WIDTH(9)) u_topic_wav_stream (
    .wr_clk(sd_card_clk), .wr_rst_n(sdcard_rst_n),
    .preload_done(source_preload_done), .file_valid(audio_file_valid),
    .cluster0(audio0_cluster), .cluster1(audio1_cluster),
    .cluster2(audio2_cluster), .cluster3(audio3_cluster),
    .size0(audio0_size), .size1(audio1_size),
    .size2(audio2_size), .size3(audio3_size),
    .sectors_per_cluster(audio_sectors_per_cluster),
    .fat_start_lba(audio_fat_start_lba),
    .data_start_lba(audio_data_start_lba),
    .max_cluster(audio_max_cluster),
    .sector_req(audio_sector_req), .sector_lba(audio_sector_lba),
    .sector_busy(audio_sector_busy), .sector_valid(audio_sector_valid),
    .sector_done(audio_sector_done), .sector_byte(audio_sector_byte),
    .sector_error(audio_sector_error), .sector_byte_index(audio_sector_index),
    .rd_clk(video_clk), .rd_rst_n(video_rst_n),
    .active_index(active_index), .sample_tick(tone_valid),
    .sample(narration_sample), .sample_valid(),
    .narration_active(narration_active), .demo_active(demo_active),
    .demo_complete(demo_complete),
    .stream_error(narration_error)
);

always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n) begin
        tone_valid_d <= 1'b0;
        tone_left_d <= 24'd0;
        tone_right_d <= 24'd0;
    end else begin
        tone_valid_d <= tone_valid;
        if (tone_valid) begin
            tone_left_d <= tone_left_data;
            tone_right_d <= tone_right_data;
        end
    end
end
assign audio_valid = tone_valid_d;
assign audio_left_unmuted = narration_active ? {narration_sample, 8'd0} : tone_left_d;
assign audio_right_unmuted = narration_active ? {narration_sample, 8'd0} : tone_right_d;

thumbnail_audio_mute u_thumbnail_audio_mute (
    .clk(video_clk), .rst_n(video_rst_n),
    .thumbnail_mode_async(thumbnail_view_mode),
    .left_in(audio_left_unmuted), .right_in(audio_right_unmuted),
    .left_out(audio_left_data), .right_out(audio_right_data)
);

audio_arc_calculate #(
    .ACR_N         (6144)
) u_audio_arc_calculate (
    .I_clk         (video_clk),
    .I_rst         (~video_rst_n),
    .I_audio_valid (audio_valid),
    .O_acr_valid   (acr_valid),
    .O_acr_cts     (acr_cts),
    .O_acr_n       (acr_n)
);

// ===================== RGB/DE 转 AXIS 视频 =====================
video_rgb_to_axis_640x480 u_video_rgb_to_axis_640x480(
    .I_clk         (video_clk),
    .I_rst         (~video_rst_n),
    .I_vs          (vs),
    .I_de          (de),
    .I_rgb         (vout_data),
    .O_video_user  (axis_s_user),
    .O_video_valid (axis_s_valid),
    .O_video_last  (axis_s_last),
    .O_video_data  (axis_s_data)
);

// 上电后自动打一拍，触发一次 EDID 读取
startup_pulse #(
    .CNT_MAX(20'd100000)
) u_startup_pulse (
    .I_clk   (video_clk),
    .I_rst   (~video_rst_n),
    .O_pulse (edid_trig)
);

// ===================== 带音频的 HDMI 1.4b 发射 =====================
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE                 ( "EG"       ),
    .HTOTAL                 ( 800        ),
    .HSA                    ( 96         ),
    .HFP                    ( 16         ),
    .HBP                    ( 48         ),
    .HACTIVE                ( 640        ),
    .VTOTAL                 ( 525        ),
    .VSA                    ( 2          ),
    .VFP                    ( 10         ),
    .VBP                    ( 33         ),
    .VACTIVE                ( 480        ),
    .VIDEO_VIC              ( 1          ),
    .VIDEO_TPG              ( "Disable"  ),
    .VIDEO_FORMAT           ( "RGB"      ),
    .AUDIO_SAMPLE_RATE      ( "48K"      ),
    .IIC_SCL_DIV            ( 250        )
) u_hdmi_1_4b_transmitter_core_wrapper(
    .I_pixel_clk        (video_clk),
    .I_rst              (~video_rst_n),
    .I_edid_read_trig   (edid_trig),
    .O_edid_read_valid  (edid_valid),
    .O_edid_read_data   (edid_data),

    .I_axis_s_user      (axis_s_user),
    .I_axis_s_valid     (axis_s_valid),
    .I_axis_s_last      (axis_s_last),
    .I_axis_s_data      (axis_s_data),
    .O_axis_s_ready     (axis_s_ready),

    .I_audio_valid      (audio_valid),
    .I_audio_left_data  (audio_left_data),
    .I_audio_right_data (audio_right_data),
    .I_acr_valid        (acr_valid),
    .I_acr_cts          (acr_cts),
    .I_acr_n            (acr_n),

    .O_video_locked     (),
    .O_ddc_scl          (HDMI_DDC_SCL),
    .IO_ddc_sda         (HDMI_DDC_SDA),

    .O_ch0_tmds_data    (tmds_ch0_data),
    .O_ch1_tmds_data    (tmds_ch1_data),
    .O_ch2_tmds_data    (tmds_ch2_data),
    .O_clk_tmds_data    (tmds_clk_data)
);

hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi2phy_wrapper(
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (~video_rst_n),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

endmodule
