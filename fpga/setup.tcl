# PREPARED_NOT_RUN. Source only in a separately authorized fresh Vivado 2023.2 session.
if {[version -short] ne "2023.2"} {error "Vivado 2023.2 required"}
set run_dir [file normalize [file dirname [info script]]]
if {[file exists $run_dir/project]} {error "Fresh project directory required; do not overwrite"}
if {![info exists demo_action]} {set demo_action prepare}
if {$demo_action ni {prepare export route}} {error "Supported actions prepare/export/route only"}
create_project demo_touch_pc $run_dir/project -part xc7a35tfgg484-2
set_property target_language Verilog [current_project]
set_property target_simulator XSim [current_project]
set_property XPM_LIBRARIES {XPM_CDC XPM_FIFO XPM_MEMORY} [current_project]
import_ip $run_dir/ip/touch_identity_vio.xci
set vio [get_ips touch_identity_vio]
foreach {key want} {CONFIG.C_NUM_PROBE_IN 1 CONFIG.C_NUM_PROBE_OUT 0 CONFIG.C_PROBE_IN0_WIDTH 128 CONFIG.C_EN_PROBE_IN_ACTIVITY 0} {if {[get_property $key $vio]!=$want} {error "VIO_READBACK $key"}}
set_property generate_synth_checkpoint false [get_files [get_property IP_FILE $vio]]
generate_target all $vio
import_ip $run_dir/ip/spectrum_fft.xci
set fft [get_ips spectrum_fft]
if {[llength $fft] != 1} {error "Pinned spectrum_fft missing"}
if {[get_property CONFIG.transform_length $fft] ne "512"} {error "Pinned FFT readback transform_length"}
if {[get_property CONFIG.implementation_options $fft] ne "radix_2_burst_io"} {error "Pinned FFT readback implementation_options"}
if {[get_property CONFIG.data_format $fft] ne "fixed_point"} {error "Pinned FFT readback data_format"}
if {[get_property CONFIG.input_width $fft] ne "16"} {error "Pinned FFT readback input_width"}
if {[get_property CONFIG.phase_factor_width $fft] ne "18"} {error "Pinned FFT readback phase_factor_width"}
if {[get_property CONFIG.scaling_options $fft] ne "unscaled"} {error "Pinned FFT readback scaling_options"}
if {[get_property CONFIG.rounding_modes $fft] ne "convergent_rounding"} {error "Pinned FFT readback rounding_modes"}
if {[get_property CONFIG.output_ordering $fft] ne "natural_order"} {error "Pinned FFT readback output_ordering"}
if {[get_property CONFIG.aresetn $fft] ne "true"} {error "Pinned FFT readback aresetn"}
if {[get_property CONFIG.xk_index $fft] ne "true"} {error "Pinned FFT readback xk_index"}
if {[get_property CONFIG.throttle_scheme $fft] ne "nonrealtime"} {error "Pinned FFT readback throttle_scheme"}
if {[get_property CONFIG.target_clock_frequency $fft] ne "100"} {error "Pinned FFT readback target_clock_frequency"}
set_property generate_synth_checkpoint false [get_files [get_property IP_FILE $fft]]
generate_target all $fft
add_files -norecurse [file join $run_dir source migration/touch_v1/ethernet/rtl/ethernet_pkg.sv]
add_files -norecurse [file join $run_dir source rtl/dds/dds_dual.v]
add_files -norecurse [file join $run_dir source rtl/fir/fir_symmetric.v]
add_files -norecurse [file join $run_dir source rtl/dsp/dsp_frontend.v]
add_files -norecurse [file join $run_dir source rtl/dsp/window_hann.v]
add_files -norecurse [file join $run_dir source rtl/dsp/fft_postprocess.v]
add_files -norecurse [file join $run_dir source rtl/fft/fft_wrapper.v]
add_files -norecurse [file join $run_dir source rtl/proto/frame_rx.v]
add_files -norecurse [file join $run_dir source rtl/proto/frame_tx.v]
add_files -norecurse [file join $run_dir source migration/touch_v1/rtl/uart_group_queue.sv]
add_files -norecurse [file join $run_dir source migration/touch_v1/rtl/snapshot_ingress.sv]
add_files -norecurse [file join $run_dir source migration/touch_v1/rtl/plot_coordinate_mapper.sv]
add_files -norecurse [file join $run_dir source migration/touch_v1/rtl/plot_line_rasterizer.sv]
add_files -norecurse [file join $run_dir source migration/touch_v1/rtl/plot_span_accumulator.sv]
add_files -norecurse [file join $run_dir source migration/touch_v1/rtl/lcd_timing.sv]
add_files -norecurse [file join $run_dir source migration/touch_v1/rtl/status_numbers.sv]
add_files -norecurse [file join $run_dir source migration/touch_v1/rtl/status_font.sv]
add_files -norecurse [file join $run_dir source migration/touch_v1/demo/rtl/demo_runtime_control.v]
add_files -norecurse [file join $run_dir source migration/touch_v1/demo/rtl/demo_touch_i2c.v]
add_files -norecurse [file join $run_dir source migration/touch_v1/demo/rtl/demo_gt9147_reader.sv]
add_files -norecurse [file join $run_dir source migration/touch_v1/demo/rtl/demo_gt9147_startup.sv]
add_files -norecurse [file join $run_dir source migration/touch_v1/demo/rtl/demo_touch_report_cdc.sv]
add_files -norecurse [file join $run_dir source migration/touch_v1/demo/rtl/demo_touch_actions.sv]
add_files -norecurse [file join $run_dir source migration/touch_v1/demo/rtl/demo_touch_frontend.sv]
add_files -norecurse [file join $run_dir source migration/touch_v1/demo/rtl/demo_ft_reader.sv]
add_files -norecurse [file join $run_dir source migration/touch_v1/demo/rtl/demo_ft_init_compare.sv]
add_files -norecurse [file join $run_dir source migration/touch_v1/demo/rtl/demo_ft_initialized_reader.sv]
add_files -norecurse [file join $run_dir source migration/touch_v1/demo/rtl/demo_ft_frontend.sv]
add_files -norecurse [file join $run_dir source migration/touch_v1/demo/rtl/demo_control_display_cdc.sv]
add_files -norecurse [file join $run_dir source migration/touch_v1/demo/rtl/demo_touch_overlay.sv]
add_files -norecurse [file join $run_dir source migration/touch_v1/demo/rtl/demo_dualtime_capture.v]
add_files -norecurse [file join $run_dir source migration/touch_v1/demo/rtl/demo_dualtime_core.v]
add_files -norecurse [file join $run_dir source migration/touch_v1/demo/rtl/demo_dualtime_snapshot.sv]
add_files -norecurse [file join $run_dir source migration/touch_v1/demo/rtl/demo_dualtime_renderer.sv]
add_files -norecurse [file join $run_dir source migration/touch_v1/demo/rtl/demo_dualtime_columns.sv]
add_files -norecurse [file join $run_dir source migration/touch_v1/demo/rtl/demo_dualtime_pixels.sv]
add_files -norecurse [file join $run_dir source migration/touch_v1/demo/rtl/demo_dualtime_plot.sv]
add_files -norecurse [file join $run_dir source migration/touch_v1/demo/rtl/demo_dualtime_status.sv]
add_files -norecurse [file join $run_dir source migration/touch_v1/demo/rtl/demo_dualtime_runtime_display.sv]
add_files -norecurse [file join $run_dir source migration/touch_v1/demo/rtl/demo_touch_pc_top.sv]
add_files -norecurse [file join $run_dir source migration/touch_v1/ethernet/rtl/eth_async_fifo.sv]
add_files -norecurse [file join $run_dir source migration/touch_v1/ethernet/rtl/eth_clocks.sv]
add_files -norecurse [file join $run_dir source migration/touch_v1/demo/rtl/demo_command_bridge.sv]
add_files -norecurse [file join $run_dir source migration/touch_v1/ethernet/rtl/eth_mac_rx.sv]
add_files -norecurse [file join $run_dir source migration/touch_v1/ethernet/rtl/eth_mac_tx.sv]
add_files -norecurse [file join $run_dir source migration/touch_v1/demo/rtl/demo_eth_endpoint.sv]
add_files -norecurse [file join $run_dir source migration/touch_v1/ethernet/rtl/eth_image.sv]
add_files -norecurse [file join $run_dir source migration/touch_v1/ethernet/rtl/eth_rgmii.sv]
add_files -norecurse [file join $run_dir source migration/touch_v1/ethernet/rtl/eth_phy.sv]
add_files -norecurse [file join $run_dir source migration/touch_v1/demo/diagnostics/ft_read_once_20261031/touch_ft_startup.sv]
add_files -norecurse [file join $run_dir source rtl/proto/protocol_defs.vh]
add_files -norecurse [file join $run_dir source migration/touch_v1/demo/rtl/demo_touch_ui_defs.vh]
add_files -fileset constrs_1 [file join $run_dir source migration/touch_v1/ethernet/configs/ethernet_nonpro.xdc]
add_files -fileset constrs_1 [file join $run_dir source migration/touch_v1/demo/configs/demo_lcd_touch.xdc]
add_files -norecurse [file join $run_dir dds_sine.mem]
add_files -norecurse [file join $run_dir fir_coeff.mem]
add_files -norecurse [file join $run_dir hann.mem]
add_files -norecurse [file join $run_dir log2_fraction.mem]
set_property include_dirs [list $run_dir/source/rtl/proto $run_dir/source/migration/touch_v1/demo/rtl] [get_filesets sources_1]
set_property top demo_touch_pc_top [get_filesets sources_1]
set_property STEPS.OPT_DESIGN.TCL.PRE $run_dir/source/migration/touch_v1/demo/configs/demo_opt_pre.tcl [get_runs impl_1]

# Explicit same-board FT direction profile, no fitted scaling or offset.
set_property generic {TOUCH_PROFILE_CONFIGURED=1 TOUCH_PROFILE_FT=1 TOUCH_FT_MAP_CONFIRMED=1 TOUCH_FT_SWAP_XY=1 TOUCH_FT_RAW_WIDTH=600 TOUCH_FT_RAW_HEIGHT=1024 TOUCH_FT_VERSION_BE_EXACT=1 TOUCH_POWER_STABLE_CONFIRMED=1} [get_filesets sources_1]
update_compile_order -fileset sources_1
report_compile_order -fileset sources_1 -used_in synthesis -file $run_dir/reports/compile-order.rpt
puts INITIALIZED_FULL_DISPLAY_PREPARED_NO_AUTO_FLOW

add_files -fileset constrs_1 $run_dir/hub50.xdc
set_property USED_IN_SYNTHESIS false [get_files $run_dir/hub50.xdc]
set_property USED_IN_IMPLEMENTATION true [get_files $run_dir/hub50.xdc]
set_property PROCESSING_ORDER LATE [get_files $run_dir/hub50.xdc]
