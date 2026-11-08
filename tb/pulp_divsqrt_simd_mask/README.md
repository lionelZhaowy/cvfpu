# PULP DivSqrt SIMD exception mask

This candidate addresses the exception-mask case reported in [OpenHW CVFPU issue #191](https://github.com/openhwfoundation/cvfpu/issues/191). The tested base is PULP `pulp` commit `35cb37e0c604b46bf6b62c0c91b05a60ed7c9cd3`. The target file is byte-identical to the earlier `682f31e` reproduction. This is a candidate for maintainer discussion. The final repository and target branch need confirmation.

The PULP branch passes one SIMD mask bit directly to each physical DivSqrt unit. A wider format uses fewer units and a different mask stride. An unused unit can therefore contribute NV or DZ; a used unit can receive another element's mask. The candidate first filters units with `LANE_FORMATS[dst_fmt_i]`, then selects the mask with the same element-position rule as the parallel-format path in `fpnew_opgroup_block.sv`. It changes one `.mask_i` connection. Unit startup, synchronization, ready/valid logic, interface ports, and the other backends remain as supplied by the base.

## Configuration and actual results

The real `fpnew_top` has Width=64, FP16/FP32/FP64, vectors, SIMD masks and NaN-boxing enabled. Only DIVSQRT is enabled, with MERGED units, PULP backend, one pipeline register per format, AFTER placement, RNE and an 8-bit tag. No active 0/0 is used; the MVP 0/0 path is outside this test.

| Same test input | Cases | Original failures | Candidate failures | Independent checks per run |
| --- | ---: | ---: | ---: | ---: |
| Original issue reproduction | 12 | 6 | 0 | 57 |
| Legal boxed scalar and vector inputs | 240 | 62 | 0 | 1532 |
| Separate malformed scalar NaN-box probes | 12 | 8 | 8 | 89 |

The 240 cases cover all 16 mask encodings for FP16/32/64 vector DIV and SQRT, two alternating arrangements of normal and exceptional operands, and scalar normal/NV/DZ operations with masks 0, 1, 2 and 15. Every seventeenth transaction holds output ready low for three cycles: 42 held cycles are checked. The reader uses exact rational IEEE decoding and an integer square-root oracle; it does not use the testbench's expected data to compute expected results. A separate AI-assisted review checked the 240 cases with an independent IEEE oracle.

All runs check the number of accepted and completed transactions, tags, all five exception flags, known output data, enabled element values or quiet-NaN classification, scalar output boxing, busy deassertion and completion. Numeric result bits, tags and case metadata are identical between the original and candidate for every transaction in all three groups. Masked-off element data is not an architectural expected value. The 12-case historical source has no INPUT/OUTPUT print records; its handshake monitor and DONE counters remain active. It retains its original source header and SHA.

The 240-case candidate and historical 12-case candidate end with zero errors and ordinary `$finish`. The original counterexamples and the separate NaN-box probes deliberately call `$fatal` after the complete summary. VCS can return status 0 for these failures: inspect DONE and run the reader. All six runs finish before the finite HDL deadline. The original 252-case expansion is retained in the validation evidence: 70 failures before, 8 after. The public 240-case test and separate 12-case probe expose the same distinction.

Ten raw-log mutations were all rejected: missing DONE, missing output, duplicate tag, wrong flags, wrong numeric output, unknown result, changed held payload inconsistent completion count, missing all handshake prints and a consistently corrupted result in both output records. These are offline checker controls, not additional DUT runs.

## Remaining NaN-box defect

`EnableNanBox` is enabled. For malformed narrow scalar operands, [RISC-V D 2.2, NaN Boxing](https://github.com/riscv/riscv-isa-manual/releases/download/20240411/unpriv-isa-asciidoc.pdf) requires a canonical NaN interpretation. The unchanged PULP `fpnew_divsqrt_multi.sv` declares `is_boxed_i` but does not use it. The separate FP16/FP32 DIV and SQRT probes therefore return a normal result instead of a quiet NaN when mask bit 0 is enabled. Eight probes fail in both versions; four mask-zero controls pass. Their quiet-NaN expectations remain unchanged. This candidate does not repair this independent backend defect.

## Reproduce with VCS

Use Git, Bender 0.32.1, VCS W-2024.09-SP1 and Python 3.8 or newer. Keep original and candidate source trees and writable build/run directories separate. Copy this test directory from the candidate commit to a location available to both builds; do not change the original RTL.

In each source checkout, prepare the pinned dependencies. The base's submodule revisions are common_cells `6aeee85d0a34fedc06c14f04fd6363c9f7b4eeea` and fpu_div_sqrt_mvp `86e1f558b3c95e91577c41b2fc452c86b04e85ac` (v1.0.4). Do not change the backend.

```sh
git submodule update --init src/common_cells src/fpu_div_sqrt_mvp
mkdir .repro_deps
git clone https://github.com/pulp-platform/common_verification.git .repro_deps/common_verification
git -C .repro_deps/common_verification checkout --detach 9c07fa860593b2caabd9b5681740c25fac04b878
git clone https://github.com/pulp-platform/tech_cells_generic.git .repro_deps/tech_cells_generic
git -C .repro_deps/tech_cells_generic checkout --detach 7968dd6e6180df2c644636bc6d2908a49f2190cf
cvfpu_source="$PWD"
cat > Bender.local <<YAML
overrides:
  common_cells: {path: "$cvfpu_source/src/common_cells"}
  fpu_div_sqrt_mvp: {path: "$cvfpu_source/src/fpu_div_sqrt_mvp"}
  common_verification: {path: "$cvfpu_source/.repro_deps/common_verification"}
  tech_cells_generic: {path: "$cvfpu_source/.repro_deps/tech_cells_generic"}
YAML
bender --local --git-submodules false script vcs -t rtl \
  --vlogan-args='-full64 -assert svaext +v2k -timescale=1ns/1ps' > compile_vcs.sh
```

Set `TEST_DIR` to the absolute path of this test directory. From a new build directory, use the generated official source list. Select one of `tb_pulp_divsqrt_mask`, `tb_pulp_divsqrt_mask_scope` or `tb_pulp_divsqrt_nanbox_probe` as `test_top`.

```sh
bash "$cvfpu_source/compile_vcs.sh" > analyze.log 2>&1
test_top=tb_pulp_divsqrt_mask_scope
vlogan -full64 -sverilog -timescale=1ns/1ps -assert svaext \
  "$TEST_DIR/$test_top.sv" > tb_compile.log 2>&1
vcs -full64 -sverilog -timescale=1ns/1ps -assert svaext \
  -top "$test_top" -o simv > elaborate.log 2>&1
mkdir run
cd run
printf 'run 1 ms\nrun 0 ns\nquit\n' > control.tcl
timeout 120 ../simv -ucli -i control.tcl > run.log 2>&1
python3 "$TEST_DIR/review_cvfpu_mask.py" run.log "$TEST_DIR/$test_top.sv" --holds
```

Use `--holds` only for `tb_pulp_divsqrt_mask_scope`. A reader exit of 1 is expected for the original failures and for both NaN-box probes. Require one DONE line with all cases accepted and completed, zero protocol errors, busy=0, timeout=0, native completion and the exact error counts above. The candidate scope test must have zero integrity and functional errors. Do not accept the simulator exit code alone. Each test also has a 1024-cycle per-transaction watchdog.

## RTL implementation checks

Both official-source lists pass VCS analysis with `+lint=all`. The same 37 existing diagnostics remain: 31 NS and 6 SV-PIU. Full `fpnew_top` elaboration also emits eight existing SIOB warnings from inactive code in `fpnew_opgroup_fmt_slice.sv`; the candidate adds none. Warnings were retained. The synthesis wrapper uses the same packed features and implementation as the functional tests; an actual VCS equality test checked both constants.

The supplied wrapper exposes all real top-level inputs and outputs. Both versions passed DC W-2024.09-SP1 analysis, elaboration, link, `compile -no_map`, `check_design` and loop checks. Both have 1651 flip-flops and zero latches, final unresolved references and final black boxes. Generic total cell counts are 52862 before and 52939 after. Existing check_design categories are unconnected ports, shorted outputs, constant outputs and nets connected to multiple pins on the same cell, from disabled operation groups and generic arithmetic. These checks are not technology timing or area signoff.

For the same full-module check, set these absolute paths, then run from a fresh directory. `DC_LIBRARY_DIR` is the installed DC `libraries/syn` directory. `synth.tcl` records original diagnostics and classifies generic operator cells separately from unresolved references.

```sh
export CVFPU_ROOT="$cvfpu_source"
export COMMON_CELLS_ROOT="$CVFPU_ROOT/src/common_cells"
export MVP_ROOT="$CVFPU_ROOT/src/fpu_div_sqrt_mvp"
export TEST_DIR
export DC_OUT="$PWD"
export DC_LIBRARY_DIR
export DESIGN_FILELIST="$TEST_DIR/dc.f"
export DESIGN_TOP=cvfpu_mask_dc
timeout 900 dc_shell -f "$TEST_DIR/synth.tcl" > driver.log 2>&1
```

The tests exercise this PULP configuration and the stated NV/DZ operations. They do not validate other backends, every format/configuration, all rounding modes or complete IEEE arithmetic. The RTL and derived wrapper retain the original authors and SHL-0.51 license. The new tests and reader use SHL-0.51. AI tools assisted with the candidate, tests, execution, analysis and this text. Independent AI review is not a claim of human review.
