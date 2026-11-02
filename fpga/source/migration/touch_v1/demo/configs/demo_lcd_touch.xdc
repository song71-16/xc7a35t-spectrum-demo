# DRAFT_UNVERIFIED LCD/touch addition; source ethernet_nonpro.xdc first.
# Pin provenance: existing non-Pro spectrum_board_nonpro.xdc, UART excluded.
set_property PACKAGE_PIN AB18 [get_ports {lcd_r[0]}]
set_property PACKAGE_PIN AA18 [get_ports {lcd_r[1]}]
set_property PACKAGE_PIN Y19 [get_ports {lcd_r[2]}]
set_property PACKAGE_PIN Y18 [get_ports {lcd_r[3]}]
set_property PACKAGE_PIN W20 [get_ports {lcd_r[4]}]
set_property PACKAGE_PIN W17 [get_ports {lcd_r[5]}]
set_property PACKAGE_PIN V18 [get_ports {lcd_r[6]}]
set_property PACKAGE_PIN V17 [get_ports {lcd_r[7]}]
set_property PACKAGE_PIN U18 [get_ports {lcd_g[0]}]
set_property PACKAGE_PIN U17 [get_ports {lcd_g[1]}]
set_property PACKAGE_PIN V19 [get_ports {lcd_g[2]}]
set_property PACKAGE_PIN T18 [get_ports {lcd_g[3]}]
set_property PACKAGE_PIN V20 [get_ports {lcd_g[4]}]
set_property PACKAGE_PIN R18 [get_ports {lcd_g[5]}]
set_property PACKAGE_PIN N17 [get_ports {lcd_g[6]}]
set_property PACKAGE_PIN P17 [get_ports {lcd_g[7]}]
set_property PACKAGE_PIN R16 [get_ports {lcd_b[0]}]
set_property PACKAGE_PIN P15 [get_ports {lcd_b[1]}]
set_property PACKAGE_PIN R14 [get_ports {lcd_b[2]}]
set_property PACKAGE_PIN P14 [get_ports {lcd_b[3]}]
set_property PACKAGE_PIN N14 [get_ports {lcd_b[4]}]
set_property PACKAGE_PIN N13 [get_ports {lcd_b[5]}]
set_property PACKAGE_PIN V9 [get_ports {lcd_b[6]}]
set_property PACKAGE_PIN W9 [get_ports {lcd_b[7]}]
set_property PACKAGE_PIN Y9 [get_ports lcd_clk]
set_property PACKAGE_PIN V8 [get_ports lcd_hsync]
set_property PACKAGE_PIN U7 [get_ports lcd_vsync]
set_property PACKAGE_PIN AB7 [get_ports lcd_de]
set_property PACKAGE_PIN V7 [get_ports lcd_bl]
set_property PACKAGE_PIN W7 [get_ports lcd_rst]
set_property PACKAGE_PIN Y8 [get_ports touch_scl]
set_property PACKAGE_PIN AB8 [get_ports touch_sda]
set_property PACKAGE_PIN Y7 [get_ports touch_int]
set_property PACKAGE_PIN AB6 [get_ports touch_rst]
set lcd_outputs [get_ports {lcd_r[*] lcd_g[*] lcd_b[*] lcd_hsync lcd_vsync lcd_de lcd_rst lcd_bl lcd_clk}]
set_property DRIVE 4 $lcd_outputs
set_property SLEW SLOW $lcd_outputs
set_property IOB TRUE [get_ports {lcd_r[*] lcd_g[*] lcd_b[*] lcd_hsync lcd_vsync lcd_de lcd_bl}]
set_property DRIVE 4 [get_ports {touch_scl touch_sda touch_int touch_rst}]
set_property SLEW SLOW [get_ports {touch_scl touch_sda touch_int touch_rst}]
create_generated_clock -name lcd_pclk -source [get_pins clocks/mmcm/CLKOUT1] -divide_by 1 -invert [get_ports lcd_clk]
# EK79001 Rev1.1 p32: setup/hold >=5ns for RGB/DE/HS/VS.
# Receiver minimum only; PCB/cable data-clock skew remains unbudgeted.
# Existing 20261030 default-OFF bit uses OLD 3/-1ns constraints, not this revision.
set_output_delay -clock lcd_pclk -max 5.000 [get_ports {lcd_r[*] lcd_g[*] lcd_b[*] lcd_hsync lcd_vsync lcd_de}]
set_output_delay -clock lcd_pclk -min -5.000 [get_ports {lcd_r[*] lcd_g[*] lcd_b[*] lcd_hsync lcd_vsync lcd_de}]
# Actual profile-OFF synthesis retains the I2C driver clock.
# Static XDC only: ordinary Tcl must require exactly one source/target and
# read back touch_dri=2000ns (50MHz / 100). Missing objects are a build failure.
create_generated_clock -name touch_dri -source [get_pins clocks/mmcm/CLKOUT1] -divide_by 100 [get_pins -hier -filter {NAME == core/gen_ft.touch/bus/dri_clk_reg/Q || NAME == core/gen_gt.touch/bus/dri_clk_reg/Q}]
# Slow touch I/O delays and panel rail attestation remain explicitly unverified.
# No blanket data-clock false paths or fabricated external timing constraints.

# SDA synchronizer input only; second stage and dri-domain data remain timed.
set_false_path -from [get_ports touch_sda] -to [get_cells -hier -filter {NAME == core/gen_ft.touch/bus/sda_meta_reg || NAME == core/gen_gt.touch/bus/sda_meta_reg}]
