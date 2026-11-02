// FAT32 directory/file adapter for the existing frame writer.
// The scanner and streamer share one physical sector reader, never concurrently.
module fat32_bmp_reader #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer SD_READ_TIMEOUT_MS = 500,
    parameter integer BMP_WIDTH = 640,
    parameter integer BMP_HEIGHT = 480,
    parameter integer ALLOW_2X_SOURCE = 0,
    parameter integer ALLOW_HALF_SOURCE = 0,
    parameter integer RESOURCE_LIMIT = 4
)(
    input wire clk,
    input wire rst,
    input wire scan_start,
    output reg scan_done,
    output wire [7:0] scan_error,
    output wire [3:0] resource_valid,
    output wire [31:0] resource0_cluster, resource1_cluster,
    output wire [31:0] resource2_cluster, resource3_cluster,
    output wire [31:0] resource0_size, resource1_size,
    output wire [31:0] resource2_size, resource3_size,
    output wire [3:0] audio_valid,
    output wire [31:0] audio0_cluster, audio1_cluster,
    output wire [31:0] audio2_cluster, audio3_cluster,
    output wire [31:0] audio0_size, audio1_size,
    output wire [31:0] audio2_size, audio3_size,
    output wire [7:0] audio_sectors_per_cluster,
    output wire [31:0] audio_fat_start_lba,
    output wire [31:0] audio_data_start_lba,
    output wire [31:0] audio_max_cluster,
    input wire load_start,
    input wire [31:0] load_cluster,
    input wire [31:0] load_file_size,
    output wire ready,
    output reg load_done,
    output reg load_error,
    output wire [7:0] bmp_error,
    output wire [1:0] source_size_code,
    output reg write_req,
    input wire write_req_ack,
    output wire bmp_data_wr_en,
    output wire [23:0] bmp_data,
    output wire sd_sec_read,
    output wire [31:0] sd_sec_read_addr,
    input wire [7:0] sd_sec_read_data,
    input wire sd_sec_read_data_valid,
    input wire sd_sec_read_end
);
    localparam ST_IDLE = 2'd0, ST_WRITE_ACK = 2'd1,
               ST_STREAM = 2'd2, ST_DECODE_END = 2'd3;
    reg [1:0] state;
    reg use_streamer;
    reg file_start;
    wire scanner_done;
    wire scanner_busy;
    wire [7:0] scanner_error;
    wire [3:0] scanner_resource_valid;
    wire [7:0] streamer_error;
    wire scanner_req, streamer_req;
    wire [31:0] scanner_lba, streamer_lba;
    wire sector_busy, sector_valid, sector_done;
    wire [7:0] sector_byte, sector_error;
    wire [8:0] sector_byte_index;
    wire file_busy, file_done, file_valid;
    wire [7:0] file_byte;
    wire [31:0] file_byte_offset;
    wire decoder_done, frame_commit, pixel_valid, top_down;
    wire [23:0] pixel_rgb;
    wire [7:0] decoder_error;
    wire [7:0] effective_error;
    wire [31:0] partition_lba;
    wire [7:0] spc;
    wire [31:0] fat_lba, data_lba, max_cluster;

    assign ready = state == ST_IDLE && scan_done;
    assign scan_error = scanner_error;
    assign resource_valid = scanner_resource_valid & (4'hf >> (4 - RESOURCE_LIMIT));
    assign bmp_error = effective_error;
    assign effective_error = streamer_error != 0 ? streamer_error : decoder_error;
    assign bmp_data_wr_en = pixel_valid;
    assign bmp_data = pixel_rgb;
    assign audio_sectors_per_cluster = spc;
    assign audio_fat_start_lba = fat_lba;
    assign audio_data_start_lba = data_lba;
    assign audio_max_cluster = max_cluster;

    fat32_volume_scanner u_scanner (
        .clk(clk), .rst_n(~rst), .scan_start(scan_start),
        .scan_busy(scanner_busy), .scan_done(scanner_done),
        .fs_error(scanner_error), .partition_lba(partition_lba),
        .sectors_per_cluster(spc), .fat_start_lba(fat_lba),
        .data_start_lba(data_lba), .max_cluster(max_cluster),
        .resource_valid(scanner_resource_valid),
        .resource0_cluster(resource0_cluster), .resource1_cluster(resource1_cluster),
        .resource2_cluster(resource2_cluster), .resource3_cluster(resource3_cluster),
        .resource0_size(resource0_size), .resource1_size(resource1_size),
        .resource2_size(resource2_size), .resource3_size(resource3_size),
        .audio_valid(audio_valid),
        .audio0_cluster(audio0_cluster), .audio1_cluster(audio1_cluster),
        .audio2_cluster(audio2_cluster), .audio3_cluster(audio3_cluster),
        .audio0_size(audio0_size), .audio1_size(audio1_size),
        .audio2_size(audio2_size), .audio3_size(audio3_size),
        .sector_req(scanner_req), .sector_lba(scanner_lba),
        .sector_busy(sector_busy), .sector_valid(sector_valid && !use_streamer),
        .sector_byte(sector_byte), .sector_byte_index(sector_byte_index),
        .sector_done(sector_done && !use_streamer), .sector_error(sector_error)
    );

    fat32_file_streamer u_streamer (
        .clk(clk), .rst_n(~rst), .file_start(file_start), .pause(1'b0),
        .first_cluster(load_cluster), .file_size(load_file_size),
        .sectors_per_cluster(spc), .fat_start_lba(fat_lba),
        .data_start_lba(data_lba), .max_cluster(max_cluster),
        .file_busy(file_busy), .file_done(file_done),
        .file_valid(file_valid), .file_byte(file_byte),
        .file_byte_offset(file_byte_offset), .fs_error(streamer_error),
        .sector_req(streamer_req), .sector_lba(streamer_lba),
        .sector_busy(sector_busy), .sector_valid(sector_valid && use_streamer),
        .sector_byte(sector_byte), .sector_byte_index(sector_byte_index),
        .sector_done(sector_done && use_streamer), .sector_error(sector_error)
    );

    sd_sector_adapter #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ), .TIMEOUT_MS(SD_READ_TIMEOUT_MS)
    ) u_sector_adapter (
        .clk(clk), .rst_n(~rst),
        .sector_req(use_streamer ? streamer_req : scanner_req),
        .sector_lba(use_streamer ? streamer_lba : scanner_lba),
        .sector_busy(sector_busy), .sector_valid(sector_valid),
        .sector_byte(sector_byte), .sector_byte_index(sector_byte_index),
        .sector_done(sector_done), .sector_error(sector_error),
        .sd_sec_read(sd_sec_read), .sd_sec_read_addr(sd_sec_read_addr),
        .sd_sec_read_data_valid(sd_sec_read_data_valid),
        .sd_sec_read_data(sd_sec_read_data), .sd_sec_read_end(sd_sec_read_end)
    );

    bmp24_decoder #(
        .EXPECTED_WIDTH(BMP_WIDTH), .EXPECTED_HEIGHT(BMP_HEIGHT),
        .ALLOW_2X_SOURCE(ALLOW_2X_SOURCE),
        .ALLOW_HALF_SOURCE(ALLOW_HALF_SOURCE)
    ) u_bmp (
        .clk(clk), .rst_n(~rst), .file_start(file_start),
        .file_size(load_file_size), .file_valid(file_valid),
        .file_byte(file_byte), .file_byte_offset(file_byte_offset),
        .file_end(file_done), .upstream_error(streamer_error),
        .header_accepted(), .pixel_valid(pixel_valid), .pixel_rgb(pixel_rgb),
        .pixel_x(), .pixel_y(), .frame_commit(frame_commit),
        .bmp_done(decoder_done), .bmp_error(decoder_error),
        .top_down(top_down), .pixel_offset(), .row_stride(),
        .source_scale_2x(), .source_size_code(source_size_code)
    );

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= ST_IDLE;
            use_streamer <= 1'b0;
            scan_done <= 1'b0;
            file_start <= 1'b0;
            write_req <= 1'b0;
            load_done <= 1'b0;
            load_error <= 1'b0;
        end else begin
            file_start <= 1'b0;
            load_done <= 1'b0;
            load_error <= 1'b0;
            if (scan_start) begin
                scan_done <= 1'b0;
                use_streamer <= 1'b0;
            end
            if (scanner_done) begin
                scan_done <= 1'b1;
                use_streamer <= (resource_valid != 4'd0);
            end
            case (state)
                ST_IDLE: if (load_start && scan_done && resource_valid != 4'd0) begin
                    write_req <= 1'b1;
                    state <= ST_WRITE_ACK;
                end
                ST_WRITE_ACK: if (write_req_ack) begin
                    write_req <= 1'b0;
                    file_start <= 1'b1;
                    state <= ST_STREAM;
                end
                ST_STREAM: if (file_done)
                    state <= ST_DECODE_END;
                ST_DECODE_END: if (decoder_done) begin
                    load_done <= frame_commit && !top_down && effective_error == 8'd0;
                    load_error <= !frame_commit || top_down || effective_error != 8'd0;
                    state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
