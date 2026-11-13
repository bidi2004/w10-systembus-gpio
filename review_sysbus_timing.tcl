# Review the saved mapped design without changing its logic or remapping.
set out $::env(KWT_MAP)
source [file join $out config.tcl]
set_app_var target_library [list $std_db]
set_app_var link_library [concat [list * $std_db $rom_db] $sram_dbs]
foreach db [concat [list $std_db $rom_db] $sram_dbs] { read_db $db }
read_ddc [file join $out soc.ddc]
current_design e203_soc_top
if {![link]} { error "Review link failed" }
# The original APB UART infers 8 level-sensitive holding latches per UART.
# Bound these previously unconstrained data paths by one HF cycle, without
# declaring false paths or modifying the provided peripheral RTL.
set uart_d [get_pins -hierarchical -filter {full_name =~ *uart*/fifo_tx_data_reg*/D}]
if {[sizeof_collection $uart_d] != 24} { error "Expected 24 original UART latch data pins" }
set_max_delay 6.566666 -to $uart_d
set acc [get_cells -hierarchical u_kwt]
set accname [get_object_name $acc]
set dpins [filter_collection [all_registers -data_pins] "full_name =~ ${accname}/*"]
# Regroup after compile: precompile group membership may disappear on mapping.
group_path -name accelerator_review -to $dpins
redirect -file [file join $out reviewed_accelerator_max.rpt] { report_timing -group accelerator_review -delay_type max -max_paths 3 }
redirect -file [file join $out reviewed_accelerator_min.rpt] { report_timing -group accelerator_review -delay_type min -max_paths 3 }
redirect -file [file join $out reviewed_check_timing.rpt] { check_timing }
redirect -file [file join $out reviewed_constraints.rpt] { report_constraint -all_violators }
redirect -file [file join $out reviewed_qor.rpt] { report_qor }
write_sdc [file join $out reviewed_soc.sdc]
puts "SYSBUS_TIMING_REVIEW_FINISHED"
exit
