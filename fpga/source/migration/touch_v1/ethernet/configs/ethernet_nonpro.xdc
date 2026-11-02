# DaVinci non-Pro V2.0/V2.1, YT8531C. All bank 14 signals are 3.3 V.
set_property PACKAGE_PIN R4 [get_ports sys_clk]
set_property PACKAGE_PIN U2 [get_ports sys_rst_n]
set_property PACKAGE_PIN T21 [get_ports eth_rst_n]
set_property PACKAGE_PIN W19 [get_ports eth_rxc]
set_property PACKAGE_PIN Y21 [get_ports eth_rx_ctl]
set_property PACKAGE_PIN Y22 [get_ports {eth_rxd[0]}]
set_property PACKAGE_PIN W21 [get_ports {eth_rxd[1]}]
set_property PACKAGE_PIN W22 [get_ports {eth_rxd[2]}]
set_property PACKAGE_PIN V22 [get_ports {eth_rxd[3]}]
set_property PACKAGE_PIN AA21 [get_ports eth_txc]
set_property PACKAGE_PIN AB22 [get_ports eth_tx_ctl]
set_property PACKAGE_PIN AB21 [get_ports {eth_txd[0]}]
set_property PACKAGE_PIN AA20 [get_ports {eth_txd[1]}]
set_property PACKAGE_PIN AB20 [get_ports {eth_txd[2]}]
set_property PACKAGE_PIN AA19 [get_ports {eth_txd[3]}]
set_property PACKAGE_PIN U22 [get_ports eth_mdc]
set_property PACKAGE_PIN U21 [get_ports eth_mdio]
set_property IOSTANDARD LVCMOS33 [get_ports *]
set_property SLEW FAST [get_ports {eth_txc eth_tx_ctl eth_txd[*]}]
set_property DRIVE 8 [get_ports {eth_txc eth_tx_ctl eth_txd[*]}]
set_property DRIVE 4 [get_ports {eth_mdc eth_mdio eth_rst_n}]
set_property SLEW SLOW [get_ports {eth_mdc eth_mdio eth_rst_n}]
set_property PULLUP TRUE [get_ports eth_mdio]
create_clock -name board_50mhz -period 20 [get_ports sys_clk]
create_clock -name rgmii_receive -period 8 -waveform {0 4} [get_ports eth_rxc]
# Virtual RX data-launch clock is 2 ns before the next PHY sampling edge.
# Transition uncertainty is +/-1 ns (datasheet 1 ns setup/hold), plus 0.2 ns PCB.
# Both DDR edges therefore have [-0.8,+0.8] guaranteed stability about RXC.
create_clock -name rgmii_rx_data -period 8 -waveform {2 6}
set_input_delay -clock rgmii_rx_data -max 1.2 [get_ports {eth_rxd[*] eth_rx_ctl}]
set_input_delay -clock rgmii_rx_data -min -1.2 [get_ports {eth_rxd[*] eth_rx_ctl}]
set_input_delay -clock rgmii_rx_data -clock_fall -add_delay -max 1.2 [get_ports {eth_rxd[*] eth_rx_ctl}]
set_input_delay -clock rgmii_rx_data -clock_fall -add_delay -min -1.2 [get_ports {eth_rxd[*] eth_rx_ctl}]
# This generated clock models the PHY's sampling clock, including its programmed
# 13*150 ps TX delay, not the unshifted pin waveform. Nearest edges now express
# setup/hold naturally; no multicycle or false-path exception hides DDR I/O.
create_generated_clock -name rgmii_transmit -source [get_pins clocks/mmcm/CLKOUT3] -edges {1 2 3} -edge_shift {1.95 1.95 1.95} [get_ports eth_txc]
set_output_delay -clock rgmii_transmit -max 1.2 [get_ports {eth_txd[*] eth_tx_ctl}]
set_output_delay -clock rgmii_transmit -min -1.2 [get_ports {eth_txd[*] eth_tx_ctl}]
set_output_delay -clock rgmii_transmit -clock_fall -add_delay -max 1.2 [get_ports {eth_txd[*] eth_tx_ctl}]
set_output_delay -clock rgmii_transmit -clock_fall -add_delay -min -1.2 [get_ports {eth_txd[*] eth_tx_ctl}]
# XPM applies local FIFO/synchronizer constraints, not blanket clock false paths.
set_false_path -from [get_ports sys_rst_n] -to [get_cells -hier -filter {NAME =~ *pipe_reg*}]
# MDIO is a slow asynchronous management input, sampled through two stages.
set_false_path -from [get_ports eth_mdio] -to [get_cells phy/mdio/mdio_meta_reg]
# MDC/MDIO/reset sequencing is reviewed as a slow management interface separately.
# These outputs intentionally remain visible in external unconstrained-I/O reports.
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN Pullnone [current_design]
