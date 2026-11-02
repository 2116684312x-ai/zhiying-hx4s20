`timescale 1ns/1ps

// Scan PIC1.BMP..PIC4.BMP once, then preload every present file into its
// fixed SDRAM bank. File parsing stays in the SD-card clock domain; the frame
// loader is the public seam to the memory subsystem.
module sd_card_fourbank_source #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer SD_READ_TIMEOUT_MS = 500
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        sdram_ready,
    input  wire        memory_load_busy,
    input  wire        memory_load_done,
    input  wire [7:0]  memory_error,
    output wire        memory_load_start,
    output reg  [1:0]  memory_image_index,
    output wire        pixel_valid,
    output wire [23:0] pixel_rgb,
    output wire        frame_commit,
    output wire [7:0]  decode_error,
    output reg         preload_done,
    output reg  [7:0]  source_error,
    output reg  [7:0]  source_size_codes,
    output wire [3:0]  audio_file_valid,
    output wire [31:0] audio0_cluster, audio1_cluster,
    output wire [31:0] audio2_cluster, audio3_cluster,
    output wire [31:0] audio0_size, audio1_size,
    output wire [31:0] audio2_size, audio3_size,
    output wire [7:0]  audio_sectors_per_cluster,
    output wire [31:0] audio_fat_start_lba,
    output wire [31:0] audio_data_start_lba,
    output wire [31:0] audio_max_cluster,
    // After image preload, the single SD CMD17 port serves the audio stream.
    input  wire        audio_sector_req,
    input  wire [31:0] audio_sector_lba,
    output wire        audio_sector_busy,
    output wire        audio_sector_valid,
    output wire [7:0]  audio_sector_byte,
    output wire [8:0]  audio_sector_index,
    output wire        audio_sector_done,
    output wire [7:0]  audio_sector_error,
    output wire        SD_nCS,
    output wire        SD_DCLK,
    output wire        SD_MOSI,
    input  wire        SD_MISO
);
    localparam ST_WAIT_SD = 3'd0;
    localparam ST_SCAN    = 3'd1;
    localparam ST_PICK    = 3'd2;
    localparam ST_LOAD    = 3'd3;
    localparam ST_DRAIN   = 3'd4;
    localparam ST_DONE    = 3'd5;

    reg [2:0] state;
    reg scan_start;
    reg load_start;
    reg [2:0] candidate;
    reg [31:0] load_cluster;
    reg [31:0] load_size;
    reg file_done_seen;

    wire sd_init_done;
    wire scan_done;
    wire [7:0] scan_error;
    wire [3:0] resource_valid;
    wire [31:0] cluster0, cluster1, cluster2, cluster3;
    wire [31:0] size0, size1, size2, size3;
    wire reader_ready;
    wire reader_load_done;
    wire reader_load_error;
    wire [7:0] reader_bmp_error;
    wire reader_write_req;
    wire [1:0] reader_source_size_code;
    wire sd_sec_read;
    wire [31:0] sd_sec_read_addr;
    wire [7:0] sd_sec_read_data;
    wire sd_sec_read_data_valid;
    wire sd_sec_read_end;
    wire audio_sd_read;
    wire [31:0] audio_sd_addr;
    wire audio_owner = preload_done;

    sd_sector_adapter #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ), .TIMEOUT_MS(SD_READ_TIMEOUT_MS)
    ) u_audio_sector (
        .clk(clk), .rst_n(~rst),
        .sector_req(audio_owner && audio_sector_req),
        .sector_lba(audio_sector_lba),
        .sector_busy(audio_sector_busy),
        .sector_valid(audio_sector_valid),
        .sector_byte(audio_sector_byte),
        .sector_byte_index(audio_sector_index),
        .sector_done(audio_sector_done),
        .sector_error(audio_sector_error),
        .sd_sec_read(audio_sd_read), .sd_sec_read_addr(audio_sd_addr),
        .sd_sec_read_data_valid(audio_owner && sd_sec_read_data_valid),
        .sd_sec_read_data(sd_sec_read_data),
        .sd_sec_read_end(audio_owner && sd_sec_read_end)
    );

    assign memory_load_start = reader_write_req;
    assign frame_commit = reader_load_done;
    assign decode_error = reader_load_error ?
                          ((reader_bmp_error != 0) ? reader_bmp_error : 8'h44) : 8'd0;

    function [31:0] cluster_lut;
        input [1:0] index;
        begin
            case (index)
                2'd0: cluster_lut = cluster0;
                2'd1: cluster_lut = cluster1;
                2'd2: cluster_lut = cluster2;
                default: cluster_lut = cluster3;
            endcase
        end
    endfunction

    function [31:0] size_lut;
        input [1:0] index;
        begin
            case (index)
                2'd0: size_lut = size0;
                2'd1: size_lut = size1;
                2'd2: size_lut = size2;
                default: size_lut = size3;
            endcase
        end
    endfunction

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= ST_WAIT_SD;
            scan_start <= 1'b0;
            load_start <= 1'b0;
            candidate <= 3'd0;
            load_cluster <= 32'd0;
            load_size <= 32'd0;
            memory_image_index <= 2'd0;
            file_done_seen <= 1'b0;
            preload_done <= 1'b0;
            source_error <= 8'd0;
            source_size_codes <= 8'd0;
        end else begin
            scan_start <= 1'b0;
            load_start <= 1'b0;
            case (state)
                ST_WAIT_SD: if (sd_init_done && sdram_ready) begin
                    scan_start <= 1'b1;
                    preload_done <= 1'b0;
                    source_error <= 8'd0;
                    state <= ST_SCAN;
                end
                ST_SCAN: if (scan_done) begin
                    if (resource_valid == 0) begin
                        source_error <= (scan_error != 0) ? scan_error : 8'h22;
                        preload_done <= 1'b1;
                        state <= ST_DONE;
                    end else begin
                        candidate <= 3'd0;
                        state <= ST_PICK;
                    end
                end
                ST_PICK: begin
                    if (candidate == 3'd4) begin
                        preload_done <= 1'b1;
                        state <= ST_DONE;
                    end else if (!resource_valid[candidate[1:0]]) begin
                        candidate <= candidate + 1'b1;
                    end else if (reader_ready && !memory_load_busy) begin
                        memory_image_index <= candidate[1:0];
                        load_cluster <= cluster_lut(candidate[1:0]);
                        load_size <= size_lut(candidate[1:0]);
                        load_start <= 1'b1;
                        file_done_seen <= 1'b0;
                        state <= ST_LOAD;
                    end
                end
                ST_LOAD: begin
                    if (reader_load_done || reader_load_error)
                        file_done_seen <= 1'b1;
                    if (reader_load_done)
                        source_size_codes[{memory_image_index, 1'b0} +: 2] <= reader_source_size_code;
                    if (memory_load_done) begin
                        if (memory_error != 0 || reader_load_error)
                            source_error <= (memory_error != 0) ? memory_error :
                                            ((reader_bmp_error != 0) ? reader_bmp_error : 8'h44);
                        candidate <= candidate + 1'b1;
                        state <= ST_DRAIN;
                    end
                end
                ST_DRAIN: if (!memory_load_busy && (file_done_seen || reader_ready))
                    state <= ST_PICK;
                ST_DONE: state <= ST_DONE;
                default: state <= ST_WAIT_SD;
            endcase
        end
    end

    fat32_bmp_reader #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .SD_READ_TIMEOUT_MS(SD_READ_TIMEOUT_MS),
        .BMP_WIDTH(640), .BMP_HEIGHT(480),
        .ALLOW_2X_SOURCE(1), .ALLOW_HALF_SOURCE(1), .RESOURCE_LIMIT(4)
    ) u_reader (
        .clk(clk), .rst(rst), .scan_start(scan_start),
        .scan_done(scan_done), .scan_error(scan_error),
        .resource_valid(resource_valid),
        .resource0_cluster(cluster0), .resource1_cluster(cluster1),
        .resource2_cluster(cluster2), .resource3_cluster(cluster3),
        .resource0_size(size0), .resource1_size(size1),
        .resource2_size(size2), .resource3_size(size3),
        .audio_valid(audio_file_valid),
        .audio0_cluster(audio0_cluster), .audio1_cluster(audio1_cluster),
        .audio2_cluster(audio2_cluster), .audio3_cluster(audio3_cluster),
        .audio0_size(audio0_size), .audio1_size(audio1_size),
        .audio2_size(audio2_size), .audio3_size(audio3_size),
        .audio_sectors_per_cluster(audio_sectors_per_cluster),
        .audio_fat_start_lba(audio_fat_start_lba),
        .audio_data_start_lba(audio_data_start_lba),
        .audio_max_cluster(audio_max_cluster),
        .load_start(load_start), .load_cluster(load_cluster),
        .load_file_size(load_size), .ready(reader_ready),
        .load_done(reader_load_done), .load_error(reader_load_error),
        .bmp_error(reader_bmp_error), .source_size_code(reader_source_size_code),
        .write_req(reader_write_req),
        .write_req_ack(memory_load_busy),
        .bmp_data_wr_en(pixel_valid), .bmp_data(pixel_rgb),
        .sd_sec_read(sd_sec_read), .sd_sec_read_addr(sd_sec_read_addr),
        .sd_sec_read_data(sd_sec_read_data),
        .sd_sec_read_data_valid(!audio_owner && sd_sec_read_data_valid),
        .sd_sec_read_end(!audio_owner && sd_sec_read_end)
    );

    sd_card_top u_sd (
        .clk(clk), .rst(rst), .SD_nCS(SD_nCS), .SD_DCLK(SD_DCLK),
        .SD_MOSI(SD_MOSI), .SD_MISO(SD_MISO),
        .sd_init_done(sd_init_done),
        .sd_sec_read(audio_owner ? audio_sd_read : sd_sec_read),
        .sd_sec_read_addr(audio_owner ? audio_sd_addr : sd_sec_read_addr),
        .sd_sec_read_data(sd_sec_read_data),
        .sd_sec_read_data_valid(sd_sec_read_data_valid),
        .sd_sec_read_end(sd_sec_read_end), .sd_sec_write(1'b0),
        .sd_sec_write_addr(32'd0), .sd_sec_write_data(),
        .sd_sec_write_data_req(), .sd_sec_write_end()
    );
endmodule
