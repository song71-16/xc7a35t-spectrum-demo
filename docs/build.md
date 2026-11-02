# 冻结输入和构建边界

顶层 `demo_touch_pc_top`，器件 `xc7a35tfgg484-2`，Vivado2023.2。`setup.tcl` 保持冻结原文（包含准备阶段旧注释）；历史实现结果在 evidence，旧 PREPARED_NOT_RUN 注释不推翻后来实现记录，也不表示这次已重建。

`tools/prepare_project.py` 只复制 fpga 到不存在的新路径，不调用旧生成器。`setup.tcl` 通过 import_ip / generate_target 生成IP产物，设置工程；没有 launch_runs、wait_on_run、write_bitstream 或硬件命令。请不要在源码目录运行，以免产生工程/报告。

必要依赖由 Tcl 实际引用得到，含诊断目录下 `touch_ft_startup.sv`、非Pro以太网XDC、LCD/触控XDC和 `demo_opt_pre.tcl`。不能删除诊断目录或以TB/stub替换真实模块。

## IP 与 ROM

- FFT：`xfft:9.1`，512点、radix_2_burst_io、fixed_point、输入16位、相位18位、unscaled、convergent_rounding、natural_order、nonrealtime、aresetn/xk_index；target_clock_frequency=100。完整参数在 spectrum_fft.xci，setup还会回读关键值。
- VIO：`vio:3.0`，每个实例1个128位输入、0输出、activity禁用；当前设计5个实例，hub50MHz。配置文件只含参数，不含厂商IP网表。VIO XCI的两处旧生成输出路径改为 `.`，其余字节/配置参数保留。
- XPM及MMCME2/BUFG/IDELAY等器件原语来自Vivado和目标器件库，不提供空壳替代。
- ROM：dds_sine.mem、fir_coeff.mem、hann.mem、log2_fraction.mem。全部从冻结输入复制，不调用生成器重新计算；`readmemh` 由模块参数引用这些文件。
- FT generic：configured/profile/map_confirmed=1，swap_xy=1，raw_width=600，raw_height=1024，version_be_exact=1，power_stable_confirmed=1。只对应既有硬件配置，不能作为对未知接线/屏幕的供电证明。

## 未来获准构建时的顺序

1. 复制至新目录，运行静态检查，确保合法工具及 IP 可用；在 Vivado2023.2 中 source setup.tcl。
2. 单独启动综合并等待完成，审日志、资源、FT配置及约束对象。不要仅凭进程退出码判成功。
3. 单独实现到 route_design 并等待，审时序、路由、DRC、methodology、CDC和外部I/O约束。任何新失败需定位，不沿用旧报告为新结果背书。
4. 从同一通过门禁的 routed design 导出匹配 LTX 和 bit，核器件/时间/调试核对应关系。
5. 实板操作需要身份确认和明确范围，出错留证停止。公开整理这一轮没有执行上述步骤、JTAG或Flash。

原匹配 bit/LTX 保留在私有冻结包，bit 2192125字节，头时间2026/11/01 21:23:51。公开源码候选不附二进制或厂商输出；不能声称新用户已经可直接下载运行，也不能宣称已验证从本目录重建。
