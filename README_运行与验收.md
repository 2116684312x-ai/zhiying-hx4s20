# HX4S20 声光互动科普工程 - 运行与验收

## 内容
- `src/td_project/HDMI1.4b_Transmitter_v1.0.al`：Anlogic TD 6.2 工程。源文件路径相对该工程目录，85 个引用均已打包。
- `src/competition/rtl` 和 `src/user_source`：当前集成设计引用的 HDL、IP 和约束。
- `media/science_exhibit/PIC1.BMP` ～ `PIC4.BMP`、`narration/AUD1.WAV` ～ `AUD4.WAV`：TF 卡运行输入文件。
- `bitstreams/HX4S20_源码对应_待上板验证.bit`：由当前源码生成的 bit。此 bit 已实板验收。
- `scripts/build_td.ps1` 和 `scripts/td_templates/integrated`：TD 完整构建脚本与设置。
- `sim/competition`：启动画面 ModelSim 定向测试。

## 构建
在装有安路 TD 6.2 的 Windows PC 上，先将 `scripts/build_td.ps1` 中 `$tdExe` 与 `$tdFlow` 改为本机 TD 路径，然后在本目录运行：
`powershell -ExecutionPolicy Bypass -File scripts/build_td.ps1 -Variant integrated -Stage full -RunSuffix _judge`
检查 `src/td_project/HDMI1.4b_Transmitter_v1.0_Runs_judge/phy_1/HDMI1.4b_Transmitter_v1.0.bit` 是否生成，并阅读 TD 报告。

## 实板
将 TF 卡格式化为 FAT32，复制四个 PIC*.BMP 和四个 AUD*.WAV 到卡根目录。插卡后接 HDMI、USB 电源与下载线；TD BitWriter 选择 PROGRAM_SRAM、5 MHz，加载 bit。观察 LOADING 到四页显示、中文解说及演示音、四格选题、KEY2 手动翻页和 KEY4 自动轮播；OSD 错误码应为 00。只有完成此测试后，才能把该 bit 标为实板通过。
