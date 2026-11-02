`timescale 1ns/1ps

// AUD1.WAV..AUD4.WAV: canonical 44-byte RIFF PCM, 48 kHz, mono, 16-bit.
// The FAT32 file streamer handles fragmented files; this ring absorbs SD bursts.
module topic_wav_stream #(
    parameter integer ADDR_WIDTH = 12,
    // Complete topic-tone cycles at 48 kHz after each narration: 4/3/4/3 s.
    parameter integer DEMO0_SAMPLES = 192000,
    parameter integer DEMO1_SAMPLES = 144000,
    parameter integer DEMO2_SAMPLES = 192000,
    parameter integer DEMO3_SAMPLES = 144000
) (
    input wire wr_clk, wr_rst_n, preload_done,
    input wire [3:0] file_valid,
    input wire [31:0] cluster0, cluster1, cluster2, cluster3,
    input wire [31:0] size0, size1, size2, size3,
    input wire [7:0] sectors_per_cluster,
    input wire [31:0] fat_start_lba, data_start_lba, max_cluster,
    output wire sector_req,
    output wire [31:0] sector_lba,
    input wire sector_busy, sector_valid, sector_done,
    input wire [7:0] sector_byte, sector_error,
    input wire [8:0] sector_byte_index,
    input wire rd_clk, rd_rst_n,
    input wire [1:0] active_index,
    input wire sample_tick,
    output wire signed [15:0] sample,
    output wire sample_valid,
    output wire narration_active,
    output wire demo_active,
    output reg demo_complete,
    output reg [7:0] stream_error
);
    localparam [1:0] ST_WAIT = 2'd0, ST_START = 2'd1,
                     ST_PLAY = 2'd2, ST_DRAIN = 2'd3;
    reg [1:0] state;
    reg [1:0] selected_index;
    reg file_start, streamer_reset;
    wire file_busy, file_done, file_byte_valid;
    wire [7:0] file_byte, fs_error;
    wire [31:0] file_offset;
    wire [31:0] selected_cluster = selected_index == 0 ? cluster0 :
                                   selected_index == 1 ? cluster1 :
                                   selected_index == 2 ? cluster2 : cluster3;
    wire [31:0] selected_size = selected_index == 0 ? size0 :
                                selected_index == 1 ? size1 :
                                selected_index == 2 ? size2 : size3;
    wire selected_present = file_valid[selected_index] && selected_size >= 46;

    reg [1:0] page_request_data;
    reg page_request_toggle, page_ack_meta, page_ack_sync;
    reg page_req_meta, page_req_sync, page_req_seen, page_ack_toggle;
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            page_request_data <= 0;
            page_request_toggle <= 0;
            page_ack_meta <= 0;
            page_ack_sync <= 0;
        end else begin
            page_ack_meta <= page_ack_toggle;
            page_ack_sync <= page_ack_meta;
            if (page_ack_sync == page_request_toggle &&
                active_index != page_request_data) begin
                page_request_data <= active_index;
                page_request_toggle <= ~page_request_toggle;
            end
        end
    end

    wire [ADDR_WIDTH:0] level_wr, level_rd;
    wire pause_stream = level_wr > ((1<<ADDR_WIDTH)-256);
    wire fifo_empty, fifo_full, fifo_rd_valid;
    wire [15:0] fifo_data;
    reg [7:0] lo_byte;
    reg lo_pending;
    reg header_bad, header_done;
    reg active_wr, eof_wr;
    reg active_rd1, active_rd2;
    reg eof_rd1, eof_rd2, demo_mode;
    reg [1:0] active_topic_sync1, active_topic_sync2;
    reg [1:0] page_rd_last;
    reg started;
    reg [17:0] demo_samples_seen;
    wire [17:0] demo_target = active_index == 0 ? DEMO0_SAMPLES :
                              active_index == 1 ? DEMO1_SAMPLES :
                              active_index == 2 ? DEMO2_SAMPLES : DEMO3_SAMPLES;
    wire ring_write = state == ST_PLAY && file_byte_valid &&
                      file_offset >= 44 && header_done &&
                      !header_bad && lo_pending;
    wire fifo_read = sample_tick && started && !demo_mode && !fifo_empty &&
                     active_topic_sync2 == active_index;
    async_command_fifo #(.DATA_WIDTH(16), .ADDR_WIDTH(ADDR_WIDTH)) u_pcm_fifo (
        .wr_clk(wr_clk), .wr_rst_n(wr_rst_n && !streamer_reset),
        .wr_en(ring_write), .wr_data({file_byte, lo_byte}),
        .wr_full(fifo_full), .wr_level(level_wr),
        .rd_clk(rd_clk),
        .rd_rst_n(rd_rst_n && active_index == page_rd_last),
        .rd_en(fifo_read), .rd_data(fifo_data),
        .rd_valid(fifo_rd_valid), .rd_empty(fifo_empty),
        .rd_level(level_rd)
    );
    assign sample_valid = fifo_rd_valid;
    assign sample = fifo_rd_valid ? $signed(fifo_data) : 16'sd0;
    fat32_file_streamer u_file (
        .clk(wr_clk), .rst_n(wr_rst_n && !streamer_reset),
        .file_start(file_start), .pause(pause_stream),
        .first_cluster(selected_cluster), .file_size(selected_size),
        .sectors_per_cluster(sectors_per_cluster),
        .fat_start_lba(fat_start_lba),
        .data_start_lba(data_start_lba), .max_cluster(max_cluster),
        .file_busy(file_busy), .file_done(file_done),
        .file_valid(file_byte_valid), .file_byte(file_byte),
        .file_byte_offset(file_offset), .fs_error(fs_error),
        .sector_req(sector_req), .sector_lba(sector_lba),
        .sector_busy(sector_busy), .sector_valid(sector_valid),
        .sector_byte(sector_byte), .sector_byte_index(sector_byte_index),
        .sector_done(sector_done), .sector_error(sector_error)
    );

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            state <= ST_WAIT;
            selected_index <= 0;
            page_req_meta <= 0; page_req_sync <= 0;
            page_req_seen <= 0; page_ack_toggle <= 0;
            file_start <= 0; streamer_reset <= 1;
            lo_byte <= 0; lo_pending <= 0;
            header_bad <= 0; header_done <= 0;
            active_wr <= 0; eof_wr <= 0; stream_error <= 0;
        end else begin
            page_req_meta <= page_request_toggle;
            page_req_sync <= page_req_meta;
            file_start <= 0;
            streamer_reset <= 0;
            if (page_req_sync != page_req_seen) begin
                page_req_seen <= page_req_sync;
                page_ack_toggle <= page_req_sync;
                selected_index <= page_request_data;
                streamer_reset <= 1;
                lo_pending <= 0;
                header_done <= 0;
                header_bad <= 0;
                active_wr <= 0;
                eof_wr <= 0;
                stream_error <= 0;
                state <= ST_WAIT;
            end else case (state)
                ST_WAIT: if (preload_done && !sector_busy && selected_present) begin
                    state <= ST_START;
                end
                ST_START: begin
                    file_start <= 1;
                    header_bad <= 0;
                    header_done <= 0;
                    lo_pending <= 0;
                    eof_wr <= 0;
                    state <= ST_PLAY;
                end
                ST_PLAY: begin
                    if (file_byte_valid) begin
                        case (file_offset)
                            0: if (file_byte != "R") header_bad <= 1;
                            1: if (file_byte != "I") header_bad <= 1;
                            2,3: if (file_byte != "F") header_bad <= 1;
                            8: if (file_byte != "W") header_bad <= 1;
                            9: if (file_byte != "A") header_bad <= 1;
                            10: if (file_byte != "V") header_bad <= 1;
                            11: if (file_byte != "E") header_bad <= 1;
                            12: if (file_byte != "f") header_bad <= 1;
                            13: if (file_byte != "m") header_bad <= 1;
                            14: if (file_byte != "t") header_bad <= 1;
                            16: if (file_byte != 16) header_bad <= 1;
                            20: if (file_byte != 1) header_bad <= 1;
                            22: if (file_byte != 1) header_bad <= 1;
                            24: if (file_byte != 8'h80) header_bad <= 1;
                            25: if (file_byte != 8'hbb) header_bad <= 1;
                            26,27: if (file_byte != 0) header_bad <= 1;
                            34: if (file_byte != 16) header_bad <= 1;
                            36: if (file_byte != "d") header_bad <= 1;
                            37: if (file_byte != "a") header_bad <= 1;
                            38: if (file_byte != "t") header_bad <= 1;
                            39: if (file_byte != "a") header_bad <= 1;
                            43: begin
                                header_done <= !header_bad;
                                if (header_bad) stream_error <= 8'h61;
                            end
                            default: begin end
                        endcase
                        if (file_offset >= 44 && header_done && !header_bad) begin
                            if (!lo_pending) begin
                                lo_byte <= file_byte;
                                lo_pending <= 1;
                            end else begin
                                lo_pending <= 0;
                                active_wr <= 1;
                            end
                        end
                    end
                    if (file_done) begin
                        if (fs_error != 0) begin
                            stream_error <= fs_error;
                            active_wr <= 0;
                            state <= ST_DRAIN;
                        end else if (header_bad || !header_done) begin
                            active_wr <= 0;
                            stream_error <= 8'h61;
                            state <= ST_DRAIN;
                        end else begin
                            eof_wr <= 1;
                            state <= ST_DRAIN; // Play the topic's demonstration after FIFO drains.
                        end
                    end
                end
                ST_DRAIN: state <= ST_DRAIN;
                default: state <= ST_WAIT;
            endcase
        end
    end

    assign narration_active = active_rd2 && started && !demo_mode &&
                              active_topic_sync2 == active_index;
    assign demo_active = demo_mode && active_topic_sync2 == active_index;
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            active_rd1 <= 0; active_rd2 <= 0;
            eof_rd1 <= 0; eof_rd2 <= 0; demo_mode <= 0;
            active_topic_sync1 <= 0; active_topic_sync2 <= 0;
            page_rd_last <= 0; started <= 0;
            demo_samples_seen <= 0; demo_complete <= 0;
        end else begin
            active_rd1 <= active_wr;
            active_rd2 <= active_rd1;
            eof_rd1 <= eof_wr;
            eof_rd2 <= eof_rd1;
            active_topic_sync1 <= selected_index;
            active_topic_sync2 <= active_topic_sync1;
            if (active_index != page_rd_last) begin
                page_rd_last <= active_index;
                started <= 0;
                demo_mode <= 0;
                demo_samples_seen <= 0;
                demo_complete <= 0;
            end else begin
                if (!active_rd2)
                    started <= 0;
                else if (!started && level_rd >= 256)
                    started <= 1;
                if (started && eof_rd2 && fifo_empty)
                    demo_mode <= 1;
                if (!demo_mode) begin
                    demo_samples_seen <= 0;
                    demo_complete <= 0;
                end else if (sample_tick && !demo_complete) begin
                    if (demo_samples_seen >= demo_target - 1'b1)
                        demo_complete <= 1;
                    else
                        demo_samples_seen <= demo_samples_seen + 1'b1;
                end
            end
        end
    end
endmodule
