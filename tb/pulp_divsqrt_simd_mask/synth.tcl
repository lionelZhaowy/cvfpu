# Real fpnew_top, generic no-map synthesis only.
# The same file list and configuration are used by VCS and DC.
foreach name {CVFPU_ROOT COMMON_CELLS_ROOT MVP_ROOT TEST_DIR DC_OUT DC_LIBRARY_DIR DESIGN_FILELIST DESIGN_TOP} {
    if {![info exists env($name)] || $env($name) eq ""} {error "Missing $name"}
    set $name $env($name)
}
set out $DC_OUT
file mkdir $out/work
set_app_var target_library [list gtech.db]
set_app_var synthetic_library [list standard.sldb]
set_app_var link_library [list * gtech.db standard.sldb]
set_app_var search_path [list $DC_LIBRARY_DIR $COMMON_CELLS_ROOT/include ${CVFPU_ROOT}/src]
define_design_lib WORK -path $out/work
set f [open $DESIGN_FILELIST r]
set sources [list]
foreach line [split [read $f] "\n"] {
    if {$line ne "" && ![string match "+incdir+*" $line]} {
        set path [subst -nocommands -nobackslashes $line]
        if {![file isfile $path]} {error "Missing source $path"}
        lappend sources $path
    }
}
close $f
set definitions [list SYNTHESIS]
set top $DESIGN_TOP
set stats [open $out/structure.tsv w]
puts $stats "stage\tproperty\tvalue"
proc capture_structure {phase out stats} {
    redirect -file $out/${phase}_check_design.rpt {set design_ok [check_design -nosplit]}
    puts $stats "$phase\tcheck_design_status\t$design_ok"
    redirect -file $out/${phase}_loops.rpt {set loops_ok [check_timing -include {loops} -nosplit]}
    puts $stats "$phase\tcheck_timing_status\t$loops_ok"
    set latches [all_registers -cells -level_sensitive -include_operator_register]
    set flops [all_registers -cells -edge_triggered -include_operator_register]
    puts $stats "$phase\tlatches\t[sizeof_collection $latches]"
    puts $stats "$phase\tflipflops\t[sizeof_collection $flops]"
    set file [open $out/${phase}_sequential.tsv w]
    puts $file "kind\tcell\tref"
    foreach_in_collection cell $latches {puts $file "latch\t[get_object_name $cell]\t[get_attribute $cell ref_name]"}
    foreach_in_collection cell $flops {puts $file "flipflop\t[get_object_name $cell]\t[get_attribute $cell ref_name]"}
    close $file
    redirect -file $out/${phase}_references.rpt {report_reference -hierarchy -nosplit}
    redirect -file $out/${phase}_cells.rpt {report_cell -nosplit [get_cells -hierarchical *]}
    set refs [list]
    foreach_in_collection cell [get_cells -hierarchical *] {lappend refs [get_attribute $cell ref_name]}
    set file [open $out/${phase}_resolution.tsv w]
    puts $file "reference\tdesigns\tlibrary_cells\tblack_box\tis_black_box"
    set raw_unresolved_types 0
    set raw_blackbox_types 0
    foreach ref [lsort -unique $refs] {
        set designs [get_designs -quiet $ref]
        set libs [get_lib_cells -quiet */$ref]
        set black [get_attribute -quiet $designs black_box]
        set isblack [get_attribute -quiet $designs is_black_box]
        if {[sizeof_collection $designs] == 0 && [sizeof_collection $libs] == 0} {incr raw_unresolved_types}
        if {$black eq "true" || $black eq "1" || $isblack eq "true" || $isblack eq "1"} {incr raw_blackbox_types}
        puts $file "$ref\t[sizeof_collection $designs]\t[sizeof_collection $libs]\t$black\t$isblack"
    }
    close $file
    # Generic no-map operators are real internal DC cells, but are absent from
    # get_designs/get_lib_cells. Preserve raw reference counts and classify each
    # actual cell from its tool attributes; never waive an unknown reference by
    # name alone or by comparison with the other variant.
    puts $stats "$phase\traw_unresolved_reference_types\t$raw_unresolved_types"
    puts $stats "$phase\traw_black_box_reference_types\t$raw_blackbox_types"
    set file [open $out/${phase}_cell_resolution.tsv w]
    puts $file "cell\tref\thierarchical\tunmapped\tgeneric\tblack_box\tis_black_box\tsequential\tcombinational\tsynlib_operator\tdesignware\tdesign_count\tlibrary_count\tclassification"
    set unresolved 0
    set blackboxes 0
    set generic_cells 0
    foreach_in_collection cell [get_cells -hierarchical *] {
        set ref [get_attribute $cell ref_name]
        set values [list [get_object_name $cell] $ref]
        foreach attr {is_hierarchical is_unmapped is_generic black_box is_black_box is_sequential is_combinational is_synlib_operator is_designware} {
            set a($attr) [get_attribute -quiet $cell $attr]
            lappend values $a($attr)
        }
        set nd [sizeof_collection [get_designs -quiet $ref]]
        set nl [sizeof_collection [get_lib_cells -quiet */$ref]]
        set category unknown
        if {$a(black_box) in {true 1} || $a(is_black_box) in {true 1}} {
            set category black_box
            incr blackboxes
        } elseif {$a(is_black_box) ne "false" && $a(is_black_box) ne "0"} {
            incr unresolved
        } elseif {$a(is_hierarchical) eq "true" && $nd == 1} {
            set category resolved_hierarchy
        } elseif {$a(is_hierarchical) eq "false" && $nl > 0} {
            set category resolved_library
        } elseif {$ref eq "**SEQGEN**" && $a(is_unmapped) eq "true" && $a(is_sequential) eq "true" && $a(is_combinational) eq "false"} {
            set category generic_register
            incr generic_cells
        } elseif {$a(is_unmapped) eq "true" && $a(is_sequential) eq "false" && $a(is_combinational) eq "true" && ([string first "*GEN*" $ref] == 0 || $a(is_synlib_operator) eq "true")} {
            set category generic_combinational
            incr generic_cells
        } else {
            incr unresolved
        }
        lappend values $nd $nl $category
        puts $file [join $values "\t"]
    }
    close $file
    puts $stats "$phase\tunresolved_references\t$unresolved"
    puts $stats "$phase\tblack_box_references\t$blackboxes"
    puts $stats "$phase\tknown_generic_cells\t$generic_cells"
    puts $stats "$phase\tcells\t[sizeof_collection [get_cells -hierarchical *]]"
    flush $stats
}
if {[catch {
    set analyze_ok [analyze -format sverilog -library WORK -define $definitions $sources]
    puts $stats "setup\tanalyze_status\t$analyze_ok"
    if {!$analyze_ok} {error "Analyze failed"}
    set elaborate_ok [elaborate $top -library WORK]
    puts $stats "setup\telaborate_status\t$elaborate_ok"
    if {!$elaborate_ok} {error "Elaborate failed"}
    current_design $top
    set link_ok [link]
    puts $stats "setup\tlink_status\t$link_ok"
    if {!$link_ok} {error "Link failed"}
    redirect -file $out/ports.rpt {report_port -verbose}
    redirect -file $out/pre_design.rpt {report_design}
    capture_structure pre $out $stats
    write -format verilog -hierarchy -output $out/pre_generic.v
    write -format ddc -hierarchy -output $out/pre_generic.ddc
    set compile_ok [compile -no_map]
    puts $stats "compile\tno_map_status\t$compile_ok"
    if {!$compile_ok} {error "Compile -no_map failed"}
    redirect -file $out/post_design.rpt {report_design}
    capture_structure post $out $stats
    write -format verilog -hierarchy -output $out/post_generic.v
    write -format ddc -hierarchy -output $out/post_generic.ddc
    puts "CVFPU_MASK_DC_COMPLETED top=$DESIGN_TOP"
} failure]} {
    puts "CVFPU_MASK_DC_FAILED $failure"
    puts $stats "control\terror\t$failure"
    close $stats
    exit 2
}
close $stats
exit 0
