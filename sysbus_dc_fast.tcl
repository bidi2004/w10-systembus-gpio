# Full SoC mapping, explicit clock/IO assumptions, separate accelerator area.
source $::env(KWT_SOC_DC_CONFIG)
set out $::env(KWT_SOC_DC_OUT)
if {![info exists external_loading]} { set external_loading 0 }
define_design_lib WORK -path [file join $out WORK]
set_app_var search_path [concat $include_dirs $search_path]
set_app_var target_library [list $std_db]
set_app_var link_library [concat [list * $std_db $rom_db] $sram_dbs]
foreach db [concat [list $std_db $rom_db] $sram_dbs] { read_db $db }
# Report only actual target libraries, avoiding gtech-unit confusion.
redirect -file [file join $out libraries.rpt] {
    foreach_in_collection lib [get_libs *] {
        if {![string match *gtech* [get_object_name $lib]] && ![string match *standard* [get_object_name $lib]]} { report_lib [get_object_name $lib] }
    }
}
if {![analyze -format sverilog -define {SYNTHESIS KWT_SRAM_2025 DISABLE_SV_ASSERTION=1} $source_files]} { error "SoC analysis failed" }
elaborate e203_soc_top
current_design e203_soc_top
if {![link]} { error "Unresolved SoC references" }
uniquify
set macros [get_cells -hierarchical -filter {ref_name =~ RAMSP*}]
if {[sizeof_collection $macros] != 114} { error "Expected 46 accelerator, 64 shared SRAM and 4 TCM macros" }
set_dont_touch $macros true
set roms [get_cells -hierarchical -filter {ref_name == ROM1KX32}]
if {[sizeof_collection $roms] != 1} { error "Expected one official ROM macro" }
set_dont_touch $roms true
redirect -file [file join $out macro_counts.txt] {
    foreach kind {RAMSP128X16 RAMSP1024X16 RAMSP4096X16 RAMSP4KX64 RAMSP8KX32} {
        puts "$kind [sizeof_collection [get_cells -hierarchical -filter ref_name==$kind]]"
    }
    puts "ROM1KX32 [sizeof_collection $roms]"
}
# Start name mapping before compile for a subsequent RTL SAIF annotation.
saif_map -start
foreach {name port period} {hfclk hfextclk 6.666666 lfclk lfextclk 30517.578125 jtagclk io_pads_jtag_TCK_i_ival 100.0} {
    if {[sizeof_collection [get_ports $port]] != 1} { error "Required clock port missing: $port" }
    create_clock -name $name -period $period [get_ports $port]
}
set_clock_groups -asynchronous -group [get_clocks hfclk] -group [get_clocks lfclk] -group [get_clocks jtagclk]
set_clock_uncertainty 0.1 [all_clocks]
set_clock_transition 0.1 [all_clocks]
set inputs [remove_from_collection [all_inputs] [get_ports {hfextclk lfextclk io_pads_jtag_TCK_i_ival}]]
set_input_delay -max 1.0 -clock hfclk $inputs
set_input_delay -min 0.0 -clock hfclk $inputs
set_input_transition 0.1 $inputs
set_output_delay -max 1.0 -clock hfclk [all_outputs]
set_output_delay -min 0.0 -clock hfclk [all_outputs]
set_load 0.01 [all_outputs]
set_fix_hold [get_clocks hfclk]
redirect -file [file join $out check_pre.rpt] { check_design }
if {$external_loading} {
    if {[sizeof_collection [get_pins -hierarchical *]] >= 1000000} { error "Pin approximation threshold must exceed design size" }
    set earlyacc [get_cells -hierarchical u_kwt]
    if {[sizeof_collection $earlyacc] != 1} { error "Expected one accelerator before compile" }
    set earlyname [get_object_name $earlyacc]
    set earlyq [filter_collection [all_registers -output_pins] "full_name =~ ${earlyname}/*"]
    set earlyd [filter_collection [all_registers -data_pins] "full_name =~ ${earlyname}/*"]
    group_path -name accelerator -from $earlyq -to $earlyd -weight 10
    compile -map_effort high
} else {
    compile -map_effort medium
}
if {![link]} { error "Post-mapping SoC link failed" }
if {[sizeof_collection [get_cells -hierarchical -filter {ref_name =~ RAMSP*}]] != 114} { error "SRAM macro count changed" }
redirect -file [file join $out area.rpt] { report_area -hierarchy }
redirect -file [file join $out accelerator_cell.rpt] { report_cell [get_cells -hierarchical u_kwt] }
set acc [get_cells -hierarchical u_kwt]
if {[sizeof_collection $acc] != 1} { error "Expected one accelerator" }
set accname [get_object_name $acc]
set qpins [filter_collection [all_registers -output_pins] "full_name =~ ${accname}/*"]
set dpins [filter_collection [all_registers -data_pins] "full_name =~ ${accname}/*"]
if {[sizeof_collection $qpins] == 0 || [sizeof_collection $dpins] == 0} { error "Missing accelerator sequential pins" }
redirect -file [file join $out accelerator_max.rpt] { report_timing -group accelerator -delay_type max -max_paths 3 -input_pins -nets }
redirect -file [file join $out accelerator_min.rpt] { report_timing -group accelerator -delay_type min -max_paths 3 -input_pins -nets }
redirect -file [file join $out timing_max.rpt] { report_timing -delay_type max -max_paths 20 -input_pins -nets }
redirect -file [file join $out timing_min.rpt] { report_timing -delay_type min -max_paths 20 -input_pins -nets }
redirect -file [file join $out constraints.rpt] { report_constraint -all_violators }
redirect -file [file join $out check_timing.rpt] { check_timing }
redirect -file [file join $out check_post.rpt] { check_design }
redirect -file [file join $out clocks.rpt] { report_clock }
redirect -file [file join $out qor.rpt] { report_qor }
write -format ddc -hierarchy -output [file join $out soc.ddc]
write -format verilog -hierarchy -output [file join $out soc_mapped.v]
write_sdc [file join $out soc.sdc]
write_sdf [file join $out soc.sdf]
if {$saif_file ne ""} {
    # Caller must supply matching full-macro RTL activity and review annotation.
    read_saif -input $saif_file -instance_name tb_top/u_e203_soc_top -auto_map_names
    redirect -file [file join $out activity.rpt] { report_saif -hierarchy }
    redirect -file [file join $out power.rpt] { report_power -hierarchy }
}
puts "KWT_SOC_DC_FINISHED macro_count=114"
exit


