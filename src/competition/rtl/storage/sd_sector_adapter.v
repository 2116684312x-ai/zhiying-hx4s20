// Convert the FAT32 sector request/byte interface to the official SD CMD17 port.
// A request is accepted for one clock; busy remains asserted through completion.
module sd_sector_adapter #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer TIMEOUT_MS = 500
)(
    input wire clk,
    input wire rst_n,
    input wire sector_req,
    input wire [31:0] sector_lba,
    output reg sector_busy,
    output reg sector_valid,
    output reg [7:0] sector_byte,
    output reg [8:0] sector_byte_index,
    output reg sector_done,
    output reg [7:0] sector_error,
    output reg sd_sec_read,
    output reg [31:0] sd_sec_read_addr,
    input wire sd_sec_read_data_valid,
    input wire [7:0] sd_sec_read_data,
    input wire sd_sec_read_end
);
    localparam integer TIMEOUT_CYCLES = (CLK_FREQ_HZ / 1000) * TIMEOUT_MS;
    reg [9:0] byte_count;
    reg [31:0] wait_count;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sector_busy <= 1'b0;
            sector_valid <= 1'b0;
            sector_byte <= 8'd0;
            sector_byte_index <= 9'd0;
            sector_done <= 1'b0;
            sector_error <= 8'd0;
            sd_sec_read <= 1'b0;
            sd_sec_read_addr <= 32'd0;
            byte_count <= 10'd0;
            wait_count <= 32'd0;
        end else begin
            sector_valid <= 1'b0;
            sector_done <= 1'b0;
            sd_sec_read <= 1'b0;
            if (!sector_busy) begin
                if (sector_req) begin
                    sector_busy <= 1'b1;
                    sector_error <= 8'd0;
                    sd_sec_read <= 1'b1;
                    sd_sec_read_addr <= sector_lba;
                    byte_count <= 10'd0;
                    wait_count <= 32'd0;
                end
            end else begin
                if (sd_sec_read_data_valid) begin
                    wait_count <= 32'd0;
                    if (byte_count < 10'd512) begin
                        sector_valid <= 1'b1;
                        sector_byte <= sd_sec_read_data;
                        sector_byte_index <= byte_count[8:0];
                    end
                    byte_count <= byte_count + 10'd1;
                end else if (wait_count < TIMEOUT_CYCLES) begin
                    wait_count <= wait_count + 32'd1;
                end
                if (sd_sec_read_end || wait_count >= TIMEOUT_CYCLES) begin
                    sector_busy <= 1'b0;
                    sector_done <= 1'b1;
                    sector_error <= (wait_count >= TIMEOUT_CYCLES) ? 8'h02 :
                                    (byte_count != 10'd512) ? 8'h01 : 8'd0;
                end
            end
        end
    end
endmodule
