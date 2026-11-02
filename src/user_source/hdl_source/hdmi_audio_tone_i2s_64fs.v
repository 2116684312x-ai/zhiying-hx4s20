
module hdmi_audio_tone_i2s_64fs #(
    parameter [31:0] PHASE_INC = 32'd39370534,   // 兼容旧顶层，实际本版内部不用它
    parameter signed [23:0] AMP = 24'sd2000000,
    parameter integer NOTE_HOLD_FRAMES = 24000   // 每个音持续 0.5s @ 48kHz
)(
    input  wire I_mclk,      // 12.288MHz
    input  wire I_rst,
    input  wire I_page_clk,  // committed display index clock domain
    input  wire I_page_rst,
    input  wire [1:0] I_page_index,
    input  wire I_demo_active,
    output reg  O_i2s_BCLK,
    output reg  O_i2s_LRCK,
    output reg  O_i2s_DOUT
);

// do/re/mi/fa/so/la/si/do  （C4 D4 E4 F4 G4 A4 B4 C5）
// 相位增量按 48kHz 采样率计算
function [31:0] note_inc_lut;
    input [2:0] idx;
    begin
        case (idx)
            3'd0: note_inc_lut = 32'd23409862; // do  C4 261.63Hz
            3'd1: note_inc_lut = 32'd26276681; // re  D4 293.66Hz
            3'd2: note_inc_lut = 32'd29494578; // mi  E4 329.63Hz
            3'd3: note_inc_lut = 32'd31248410; // fa  F4 349.23Hz
            3'd4: note_inc_lut = 32'd35075155; // so  G4 392.00Hz
            3'd5: note_inc_lut = 32'd39370534; // la  A4 440.00Hz
            3'd6: note_inc_lut = 32'd44191930; // si  B4 493.88Hz
            default: note_inc_lut = 32'd46819716; // do  C5 523.25Hz
        endcase
    end
endfunction

reg  [5:0]  S_bit_cnt;
reg  [63:0] S_shift_reg;
reg  [31:0] S_phase_acc;
reg signed [23:0] S_sample_word;
reg signed [23:0] S_sample_next;
reg  [2:0]  S_note_idx;
reg [15:0]  S_note_frame_cnt;
reg [1:0] S_topic_active;
reg demo_meta, demo_sync, demo_prev, demo_restart_pending;

// Bundled-data handshake: the two-bit page index remains stable until the
// audio clock acknowledges it. Rapid page changes may coalesce to the latest
// selection; the audio side never uses a partly synchronized index.
reg [1:0] page_req_data;
reg page_req_toggle;
reg page_ack_meta, page_ack_sync;
reg page_req_meta, page_req_sync, page_req_seen;
reg [1:0] page_topic_audio;
reg page_ack_toggle;

always @(posedge I_page_clk or posedge I_page_rst) begin
    if (I_page_rst) begin
        page_req_data <= 2'd0;
        page_req_toggle <= 1'b0;
        page_ack_meta <= 1'b0;
        page_ack_sync <= 1'b0;
    end else begin
        page_ack_meta <= page_ack_toggle;
        page_ack_sync <= page_ack_meta;
        if (page_ack_sync == page_req_toggle &&
            I_page_index != page_req_data) begin
            page_req_data <= I_page_index;
            page_req_toggle <= ~page_req_toggle;
        end
    end
end

always @(posedge I_mclk or posedge I_rst) begin
    if (I_rst) begin
        page_req_meta <= 1'b0;
        page_req_sync <= 1'b0;
        page_req_seen <= 1'b0;
        page_topic_audio <= 2'd0;
        page_ack_toggle <= 1'b0;
    end else begin
        page_req_meta <= page_req_toggle;
        page_req_sync <= page_req_meta;
        if (page_req_sync != page_req_seen) begin
            page_topic_audio <= page_req_data;
            page_req_seen <= page_req_sync;
            page_ack_toggle <= page_req_sync;
        end
    end
end

wire [2:0] W_last_note = S_topic_active == 2'd0 ? 3'd7 :
                         S_topic_active == 2'd1 ? 3'd1 :
                         S_topic_active == 2'd2 ? 3'd3 : 3'd1;
wire [31:0] W_note_inc = S_topic_active == 2'd1 ?
    (S_note_idx[0] ? 32'd93639432 : 32'd11704931) : // C6 1046.5 Hz / C3 130.8 Hz
    S_topic_active == 2'd2 ?
    (S_note_idx == 3'd0 ? note_inc_lut(3'd0) :
     S_note_idx == 3'd1 ? note_inc_lut(3'd2) :
     S_note_idx == 3'd2 ? note_inc_lut(3'd4) : note_inc_lut(3'd7)) :
    S_topic_active == 2'd3 ? note_inc_lut(3'd5) :
    note_inc_lut(S_note_idx);

always @(posedge I_mclk or posedge I_rst) begin
    if (I_rst) begin
        O_i2s_BCLK      <= 1'b0;
        O_i2s_LRCK      <= 1'b0;
        O_i2s_DOUT      <= 1'b0;
        S_bit_cnt       <= 6'd0;
        S_shift_reg     <= 64'd0;
        S_phase_acc     <= 32'd0;
        S_sample_word   <= 24'sd0;
        S_sample_next   <= AMP;
        S_note_idx      <= 3'd0;
        S_note_frame_cnt<= 16'd0;
        S_topic_active  <= 2'd0;
        demo_meta <= 1'b0;
        demo_sync <= 1'b0;
        demo_prev <= 1'b0;
        demo_restart_pending <= 1'b0;
    end
    else begin
        demo_meta <= I_demo_active;
        demo_sync <= demo_meta;
        demo_prev <= demo_sync;
        if (demo_sync && !demo_prev)
            demo_restart_pending <= 1'b1;
        // 保持和你现有接收端兼容的 64fs 发送时序
        O_i2s_BCLK <= ~O_i2s_BCLK;

        if (O_i2s_BCLK == 1'b1) begin
            O_i2s_DOUT  <= S_shift_reg[63];
            S_shift_reg <= {S_shift_reg[62:0], 1'b0};

            if (S_bit_cnt == 6'd63) begin
                S_bit_cnt <= 6'd0;

                if (O_i2s_LRCK == 1'b0) begin
                    // 左声道发完，右声道复用同一个样本
                    O_i2s_LRCK  <= 1'b1;
                    S_shift_reg <= {S_sample_word[23:0], 40'd0};
                end
                else begin
                    // 右声道发完，进入下一帧样本
                    O_i2s_LRCK  <= 1'b0;

                    S_sample_word <= S_sample_next;
                    S_shift_reg   <= {S_sample_next[23:0], 40'd0};

                    if (S_topic_active != page_topic_audio) begin
                        S_topic_active <= page_topic_audio;
                        S_note_idx <= 3'd0;
                        S_note_frame_cnt <= 16'd0;
                        S_phase_acc <= 32'd0;
                        demo_restart_pending <= 1'b0;
                    end else if (demo_restart_pending) begin
                        S_note_idx <= 3'd0;
                        S_note_frame_cnt <= 16'd0;
                        S_phase_acc <= 32'd0;
                        S_sample_next <= AMP;
                        demo_restart_pending <= 1'b0;
                    end else begin
                        S_phase_acc <= S_phase_acc + W_note_inc;
                        if (S_topic_active == 2'd3 && S_note_idx[0])
                            S_sample_next <= 24'sd0;
                        else if (S_phase_acc[31])
                            S_sample_next <= AMP;
                        else
                            S_sample_next <= -AMP;

                        if (S_note_frame_cnt == NOTE_HOLD_FRAMES - 1) begin
                            S_note_frame_cnt <= 16'd0;
                            if (S_note_idx == W_last_note)
                                S_note_idx <= 3'd0;
                            else
                                S_note_idx <= S_note_idx + 3'd1;
                        end else begin
                            S_note_frame_cnt <= S_note_frame_cnt + 16'd1;
                        end
                    end
                end
            end
            else begin
                S_bit_cnt <= S_bit_cnt + 6'd1;
            end
        end
    end
end

endmodule
