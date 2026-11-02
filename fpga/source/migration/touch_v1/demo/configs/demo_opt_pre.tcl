# Prevent opt_design power gating from reintroducing async reset on this ROM CE.
# No DRC waiver, timing exception, or change to protected postprocessor RTL.
set demo_log_rom [get_cells -hier -filter {NAME == core/core/postprocessor/fraction_addr_3_reg}]
if {[llength $demo_log_rom] != 1} {error "Expected unique demo log ROM"}
if {[get_property REF_NAME $demo_log_rom] ne "RAMB18E1"} {error "Unexpected demo log ROM primitive"}
puts "DEMO_LOG_ROM_POWER_OPT_EXCLUDE $demo_log_rom REF [get_property REF_NAME $demo_log_rom]"
set_power_opt -exclude_cells $demo_log_rom
