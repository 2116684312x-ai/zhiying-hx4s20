// bilinear_8q8.v —— 双线性插值选做骨架（完赛工程未实现）
// 输入：4个相邻像素 p00/p10/p01/p11（左上/右上/左下/右下）
//       wx = (x的小数部分)<<8, wy = (y的小数部分)<<8  (0~255)
// 思路：先按行加权，再按列加权，每步乘16位再取高8位
// R通道示例已给全（G/B 照抄换信号名，标了 TODO）：
module bilinear_8q8 (
    input  wire [7:0] p00_r, p10_r, p01_r, p11_r,
    input  wire [7:0] p00_g, p10_g, p01_g, p11_g,   // TODO(G通道)：接入对应像素
    input  wire [7:0] p00_b, p10_b, p01_b, p11_b,   // TODO(B通道)：接入对应像素
    input  wire [7:0] wx, wy,
    output wire [7:0] out_r, out_g, out_b
);
    // ---- R通道（已给）----
    // 两个综合陷阱（安路TD实测实锤，见逐课TD综合验证报告第八节，L12日志HDL-5007）：
    // ① 8'd256 会把256截进8位字面量变成0 —— 权重补数必须用 9'd256；
    // ② 行加权结果最大 255*256=65280，若不取高8位直接做列加权，
    //    乘积最大 65280*256≈1670万，16位装不下会被静默截断 —— 每步先取 [15:8]。
    wire [8:0]  inv_wx       = 9'd256 - {1'b0, wx};                    // 256-wx，范围1~256
    wire [8:0]  inv_wy       = 9'd256 - {1'b0, wy};
    wire [15:0] row_top_r    = p00_r * inv_wx + p10_r * wx;            // 顶行: p00*(256-wx)+p10*wx，≤65280
    wire [15:0] row_bottom_r = p01_r * inv_wx + p11_r * wx;            // 底行
    wire [15:0] out_r_full   = row_top_r[15:8] * inv_wy + row_bottom_r[15:8] * wy;
    assign out_r = out_r_full[15:8];                                   // 列加权后取高8位

    // TODO(G通道)：照抄 R 通道，把 _r 换成 _g，接入 p00_g/p10_g/p01_g/p11_g
    //   （注意同样避开两个陷阱：9'd256、行结果先取[15:8]再列加权）
    // TODO(B通道)：照抄 R 通道，把 _r 换成 _b，接入 p00_b/p10_b/p01_b/p11_b
    assign out_g = 8'd0;   // 占位，TODO 删除
    assign out_b = 8'd0;   // 占位，TODO 删除
endmodule
