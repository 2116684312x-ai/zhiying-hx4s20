
module sd_card_bmp #(
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter [31:0]  SCAN_START_SECTOR = 32'd0,
    parameter [31:0]  SCAN_MAX_SECTOR   = 32'd131071,
    parameter [2:0]   SCAN_TARGET_COUNT = 3'd4,
    parameter integer LONG_PRESS_MS     = 1000,
    parameter integer AUTO_PLAY_MS      = 3000,
    parameter integer SD_READ_TIMEOUT_MS = 500,
    parameter [1:0] MAX_RETRIES = 2'd1
)(
    input                       clk,
    input                       rst,
    input                       key_next,
    input                       key_auto,
    output reg [3:0]            state_code,
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,
    output reg                  display_valid,
    input                       sdram_ready,

    input                       write_finish_toggle,
    output reg [1:0]            write_buf_idx,
    output reg [1:0]            disp_buf_idx,

    output                      write_req,
    input                       write_req_ack,
    output                      write_en,
    output [31:0]               write_data,
    output                      SD_nCS,
    output                      SD_DCLK,
    output                      SD_MOSI,
    input                       SD_MISO
);

wire key_next_press;
wire key_auto_stable;
reg key_auto_stable_d;
reg [31:0] long_press_cnt;
reg long_press_marked;
reg prev_req_pending;

wire             sd_sec_read;
wire [31:0]      sd_sec_read_addr;
wire [7:0]       sd_sec_read_data;
wire             sd_sec_read_data_valid;
wire             sd_sec_read_end;
wire             bmp_data_wr_en;
wire [23:0]      bmp_data;
wire             sd_init_done;
wire             bmp_ready;
wire             bmp_load_done;
wire [7:0]       bmp_error;
wire             load_error;
wire             scan_done;
wire [3:0]       scan_resource_valid;
wire [31:0]      scan_cluster0, scan_cluster1, scan_cluster2, scan_cluster3;
wire [31:0]      scan_size0, scan_size1, scan_size2, scan_size3;
wire [7:0]       scan_error;

reg              scan_start_pulse;
reg              load_start_pulse;
reg [31:0]       load_cluster;
reg [31:0]       load_file_size;
reg              scan_kicked;
reg              first_image_committed;
reg              auto_play_en;
reg [31:0]       auto_cnt;
reg [2:0]        img_found_count;
reg [1:0]        img_idx;              // 当前真正显示中的图片编号
reg [1:0]        load_idx;             // 当前正在写入的图片编号
reg [1:0]        pending_buf_idx;      // 当前正在写入的目标缓冲区
reg              next_req_pending;
reg              load_busy;
reg [1:0]        retry_count;
reg              load_error_seen;
reg [2:0]        failed_first_count;
reg              first_load_exhausted;

// bmp_ready 先表示“源文件读取/送 FIFO 完成”；真正切显示要等 write_finish_toggle 同步后
reg              source_done_seen;
reg              write_done_seen;

// 同步 mem_clk 域的 write_finish_toggle
reg [2:0]        wrfin_tgl_sync;
wire             write_finish_pulse;

wire auto_tick;
wire [1:0] next_from_current;
wire [1:0] prev_from_current;
localparam integer LONG_PRESS_CYCLES = (CLK_FREQ_HZ / 1000) * LONG_PRESS_MS;
localparam integer AUTO_PLAY_CYCLES  = (CLK_FREQ_HZ / 1000) * AUTO_PLAY_MS;

assign write_en   = bmp_data_wr_en;
assign write_data = {bmp_data[23:16], bmp_data[15:8], bmp_data[7:0], 8'b0};
assign auto_tick  = (auto_cnt == (AUTO_PLAY_CYCLES - 1));
assign next_from_current = next_index_limited(img_idx, img_found_count);
assign prev_from_current = prev_index_limited(img_idx, img_found_count);
assign write_finish_pulse = wrfin_tgl_sync[2] ^ wrfin_tgl_sync[1];

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (20)
) u_key_next (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_next),
    .press_pulse(key_next_press),
    .button_stable_out()
);

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (20)
) u_key_auto (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_auto),
    .press_pulse(),
    .button_stable_out(key_auto_stable)
);

function [1:0] next_index_limited;
    input [1:0] cur;
    input [2:0] count;
    begin
        case (count)
            3'd0: next_index_limited = 2'd0;
            3'd1: next_index_limited = 2'd0;
            3'd2: next_index_limited = (cur == 2'd1) ? 2'd0 : (cur + 2'd1);
            3'd3: next_index_limited = (cur == 2'd2) ? 2'd0 : (cur + 2'd1);
            default: next_index_limited = (cur == 2'd3) ? 2'd0 : (cur + 2'd1);
        endcase
    end
endfunction

function [1:0] prev_index_limited;
    input [1:0] cur;
    input [2:0] count;
    begin
        case (count)
            3'd0: prev_index_limited = 2'd0;
            3'd1: prev_index_limited = 2'd0;
            3'd2: prev_index_limited = (cur == 2'd0) ? 2'd1 : (cur - 2'd1);
            3'd3: prev_index_limited = (cur == 2'd0) ? 2'd2 : (cur - 2'd1);
            default: prev_index_limited = (cur == 2'd0) ? 2'd3 : (cur - 2'd1);
        endcase
    end
endfunction

function [1:0] resource_index;
    input [1:0] idx;
    reg [2:0] seen;
    integer i;
    begin
        resource_index = 2'd0;
        seen = 3'd0;
        for (i = 0; i < 4; i = i + 1)
            if (scan_resource_valid[i]) begin
                if (seen == {1'b0, idx})
                    resource_index = i[1:0];
                seen = seen + 3'd1;
            end
    end
endfunction

function [31:0] cluster_lut;
    input [1:0] idx;
    begin
        case (resource_index(idx))
            2'd0: cluster_lut = scan_cluster0;
            2'd1: cluster_lut = scan_cluster1;
            2'd2: cluster_lut = scan_cluster2;
            default: cluster_lut = scan_cluster3;
        endcase
    end
endfunction

function [31:0] size_lut;
    input [1:0] idx;
    begin
        case (resource_index(idx))
            2'd0: size_lut = scan_size0;
            2'd1: size_lut = scan_size1;
            2'd2: size_lut = scan_size2;
            default: size_lut = scan_size3;
        endcase
    end
endfunction

function [2:0] count_resources;
    input [3:0] mask;
    begin
        count_resources = {2'd0,mask[0]} + {2'd0,mask[1]} +
                          {2'd0,mask[2]} + {2'd0,mask[3]};
    end
endfunction

function [1:0] next_buf_lut;
    input [1:0] cur_disp_buf;
    input       valid_now;
    begin
        if (!valid_now)
            next_buf_lut = 2'd0;                 // 首图固定写 buffer0
        else if (cur_disp_buf == 2'd0)
            next_buf_lut = 2'd1;
        else
            next_buf_lut = 2'd0;
    end
endfunction

always @(posedge clk or posedge rst) begin
    if (rst) begin
        wrfin_tgl_sync        <= 3'b000;
        scan_start_pulse      <= 1'b0;
        load_start_pulse      <= 1'b0;
        load_cluster          <= 32'd0;
        load_file_size        <= 32'd0;
        scan_kicked           <= 1'b0;
        first_image_committed <= 1'b0;
        auto_play_en          <= 1'b0;
        auto_cnt              <= 32'd0;
        img_found_count       <= 3'd0;
        img_idx               <= 2'd0;
        load_idx              <= 2'd0;
        pending_buf_idx       <= 2'd0;
        write_buf_idx         <= 2'd0;
        disp_buf_idx          <= 2'd0;
        next_req_pending      <= 1'b0;
        prev_req_pending      <= 1'b0;
        key_auto_stable_d     <= 1'b1;
        long_press_cnt        <= 32'd0;
        long_press_marked     <= 1'b0;
        load_busy             <= 1'b0;
        retry_count           <= 2'd0;
        load_error_seen       <= 1'b0;
        failed_first_count   <= 3'd0;
        first_load_exhausted <= 1'b0;
        source_done_seen      <= 1'b0;
        write_done_seen       <= 1'b0;
        display_valid         <= 1'b0;
        state_code            <= 4'd1;
    end else begin
        wrfin_tgl_sync   <= {wrfin_tgl_sync[1:0], write_finish_toggle};
        key_auto_stable_d <= key_auto_stable;
        scan_start_pulse <= 1'b0;
        load_start_pulse <= 1'b0;
        if (!load_error)
            load_error_seen <= 1'b0;
        state_code <= {2'b0, resource_index(img_idx)} + 4'd1;

        if (!sd_init_done) begin
            scan_kicked           <= 1'b0;
            first_image_committed <= 1'b0;
            auto_play_en          <= 1'b0;
            auto_cnt              <= 32'd0;
            img_found_count       <= 3'd0;
            img_idx               <= 2'd0;
            load_idx              <= 2'd0;
            pending_buf_idx       <= 2'd0;
            write_buf_idx         <= 2'd0;
            disp_buf_idx          <= 2'd0;
            next_req_pending      <= 1'b0;
            prev_req_pending      <= 1'b0;
            long_press_cnt        <= 32'd0;
            long_press_marked     <= 1'b0;
            load_busy             <= 1'b0;
            retry_count           <= 2'd0;
            load_error_seen       <= 1'b0;
            failed_first_count   <= 3'd0;
            first_load_exhausted <= 1'b0;
            source_done_seen      <= 1'b0;
            write_done_seen       <= 1'b0;
            display_valid         <= 1'b0;
            state_code            <= 4'd1;
        end else begin
            if (scan_done)
                img_found_count <= count_resources(scan_resource_valid);

            if (load_error && load_busy && !load_error_seen) begin
                load_error_seen  <= 1'b1;
                source_done_seen <= 1'b0;
                write_done_seen  <= 1'b0;
                if (retry_count < MAX_RETRIES) begin
                    retry_count      <= retry_count + 2'd1;
                    load_start_pulse <= 1'b1;
                end else begin
                    // Keep the displayed buffer; the failed write buffer is never committed.
                    load_busy   <= 1'b0;
                    retry_count <= 2'd0;
                    if (!first_image_committed) begin
                        if (failed_first_count + 3'd1 >= img_found_count)
                            first_load_exhausted <= 1'b1;
                        else begin
                            failed_first_count <= failed_first_count + 3'd1;
                            load_idx <= next_index_limited(load_idx, img_found_count);
                        end
                    end else if (auto_play_en) begin
                        next_req_pending <= 1'b1;
                    end
                end
            end else begin
            // FAT32 file_done/decoder success is a pulse. Wait for SDRAM completion.
            if (load_busy && bmp_load_done)
                source_done_seen <= 1'b1;

            if (load_busy && write_finish_pulse)
                write_done_seen <= 1'b1;

            // 只有真正收到 write_finish_toggle 脉冲，才提交新图并切换显示缓冲区
            if (load_busy && (source_done_seen || bmp_load_done) &&
                (write_done_seen || write_finish_pulse)) begin
                load_busy             <= 1'b0;
                source_done_seen      <= 1'b0;
                write_done_seen       <= 1'b0;
                disp_buf_idx          <= pending_buf_idx;
                img_idx               <= load_idx;
                display_valid         <= 1'b1;
                first_image_committed <= 1'b1;
                retry_count           <= 2'd0;
                load_error_seen       <= 1'b0;
                failed_first_count   <= 3'd0;
            end

            // 上电后自动发起一次“扫描前 4 张 BMP”
            if (!scan_kicked && sd_init_done && sdram_ready) begin
                scan_start_pulse      <= 1'b1;
                scan_kicked           <= 1'b1;
                first_image_committed <= 1'b0;
                auto_play_en          <= 1'b0;
                auto_cnt              <= 32'd0;
                img_found_count       <= 3'd0;
                img_idx               <= 2'd0;
                load_idx              <= 2'd0;
                pending_buf_idx       <= 2'd0;
                write_buf_idx         <= 2'd0;
                disp_buf_idx          <= 2'd0;
                next_req_pending      <= 1'b0;
                prev_req_pending      <= 1'b0;
                long_press_cnt        <= 32'd0;
                long_press_marked     <= 1'b0;
                display_valid         <= 1'b0;
                load_busy             <= 1'b0;
                source_done_seen      <= 1'b0;
                write_done_seen       <= 1'b0;
                retry_count           <= 2'd0;
                load_error_seen       <= 1'b0;
                failed_first_count   <= 3'd0;
                first_load_exhausted <= 1'b0;
            end else begin
                // 忙的时候也只记 1 次“下一张”请求，不会累积成连跳两张
                if (key_next_press && scan_done && (img_found_count > 3'd1))
                    next_req_pending <= 1'b1;

                // KEY2 的短按在消抖后的松开沿确认；长按不会先误切轮播模式。
                if (!key_auto_stable_d && key_auto_stable &&
                    !long_press_marked && scan_done && (img_found_count > 3'd1)) begin
                    auto_play_en <= ~auto_play_en;
                    auto_cnt     <= 32'd0;
                end

                // KEY2 长按一次只挂起一个“上一张”请求，松开后重新计时。
                if (!key_auto_stable && scan_done && (img_found_count > 3'd1)) begin
                    if (!long_press_marked) begin
                        if (long_press_cnt >= LONG_PRESS_CYCLES - 1) begin
                            long_press_marked <= 1'b1;
                            prev_req_pending  <= 1'b1;
                        end else begin
                            long_press_cnt <= long_press_cnt + 32'd1;
                        end
                    end
                end else begin
                    long_press_cnt    <= 32'd0;
                    long_press_marked <= 1'b0;
                end

                // 自动播放周期计数：只有当前没有写图任务时才计时
                if (scan_done && auto_play_en && display_valid && !load_busy && first_image_committed && (img_found_count > 3'd1)) begin
                    if (auto_tick)
                        auto_cnt <= 32'd0;
                    else
                        auto_cnt <= auto_cnt + 32'd1;
                end else begin
                    auto_cnt <= 32'd0;
                end

                // 首图自动加载到 buffer0
                if (scan_done && !first_image_committed && !first_load_exhausted && bmp_ready && !load_busy && (img_found_count != 3'd0)) begin
                    load_cluster     <= cluster_lut(load_idx);
                    load_file_size   <= size_lut(load_idx);
                    pending_buf_idx  <= 2'd0;
                    write_buf_idx    <= 2'd0;
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                    load_error_seen   <= 1'b0;
                    next_req_pending <= 1'b0;
                    prev_req_pending <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
                // 手动下一张优先：写到“非当前显示”的另一块 buffer
                else if (scan_done && bmp_ready && display_valid && !load_busy && next_req_pending && (img_found_count != 3'd0)) begin
                    load_idx         <= next_from_current;
                    load_cluster     <= cluster_lut(next_from_current);
                    load_file_size   <= size_lut(next_from_current);
                    pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                    retry_count      <= 2'd0;
                    load_error_seen  <= 1'b0;
                    next_req_pending <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
                // 手动上一张：下一张请求优先，写非显示缓冲区。
                else if (scan_done && bmp_ready && display_valid && !load_busy && prev_req_pending && (img_found_count > 3'd1)) begin
                    load_idx         <= prev_from_current;
                    load_cluster     <= cluster_lut(prev_from_current);
                    load_file_size   <= size_lut(prev_from_current);
                    pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                    retry_count      <= 2'd0;
                    load_error_seen  <= 1'b0;
                    prev_req_pending <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
                // 自动播放下一张：同样写到“非当前显示”的另一块 buffer
                else if (scan_done && bmp_ready && display_valid && !load_busy && auto_play_en && auto_tick && (img_found_count > 3'd1)) begin
                    load_idx         <= next_from_current;
                    load_cluster     <= cluster_lut(next_from_current);
                    load_file_size   <= size_lut(next_from_current);
                    pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                    retry_count      <= 2'd0;
                    load_error_seen  <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
            end
            end
        end
    end
end

fat32_bmp_reader #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .SD_READ_TIMEOUT_MS (SD_READ_TIMEOUT_MS),
    .RESOURCE_LIMIT (SCAN_TARGET_COUNT)
) fat32_bmp_reader_m0(
    .clk                    (clk),
    .rst                    (rst),
    .ready                  (bmp_ready),
    .scan_start             (scan_start_pulse),
    .scan_done              (scan_done),
    .scan_error             (scan_error),
    .resource_valid         (scan_resource_valid),
    .resource0_cluster      (scan_cluster0),
    .resource1_cluster      (scan_cluster1),
    .resource2_cluster      (scan_cluster2),
    .resource3_cluster      (scan_cluster3),
    .resource0_size         (scan_size0),
    .resource1_size         (scan_size1),
    .resource2_size         (scan_size2),
    .resource3_size         (scan_size3),
    .load_start             (load_start_pulse),
    .load_cluster           (load_cluster),
    .load_file_size         (load_file_size),
    .load_done              (bmp_load_done),
    .bmp_error              (bmp_error),
    .load_error             (load_error),
    .write_req              (write_req),
    .write_req_ack          (write_req_ack),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .bmp_data_wr_en         (bmp_data_wr_en),
    .bmp_data               (bmp_data)
);

sd_card_top sd_card_top_m0(
    .clk                    (clk),
    .rst                    (rst),
    .SD_nCS                 (SD_nCS),
    .SD_DCLK                (SD_DCLK),
    .SD_MOSI                (SD_MOSI),
    .SD_MISO                (SD_MISO),
    .sd_init_done           (sd_init_done),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .sd_sec_write           (1'b0),
    .sd_sec_write_addr      (32'd0),
    .sd_sec_write_data      (),
    .sd_sec_write_data_req  (),
    .sd_sec_write_end       ()
);

endmodule

module key_press_debounce #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20
)(
    input  wire clk,
    input  wire rst,
    input  wire button_in,    // 默认：松开=1，按下=0
    output reg  press_pulse,
    output wire button_stable_out
);

localparam integer DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;

reg button_sync0;
reg button_sync1;
reg button_stable;
reg [31:0] cnt;
assign button_stable_out = button_stable;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        button_sync0  <= 1'b1;
        button_sync1  <= 1'b1;
        button_stable <= 1'b1;
        cnt           <= 32'd0;
        press_pulse   <= 1'b0;
    end else begin
        button_sync0 <= button_in;
        button_sync1 <= button_sync0;
        press_pulse  <= 1'b0;

        if (button_sync1 == button_stable) begin
            cnt <= 32'd0;
        end else begin
            if (cnt >= DEBOUNCE_CYCLES - 1) begin
                if (button_stable && !button_sync1)
                    press_pulse <= 1'b1;
                button_stable <= button_sync1;
                cnt           <= 32'd0;
            end else begin
                cnt <= cnt + 32'd1;
            end
        end
    end
end

endmodule
