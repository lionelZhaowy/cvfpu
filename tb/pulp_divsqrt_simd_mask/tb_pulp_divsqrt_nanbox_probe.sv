// SPDX-License-Identifier: SHL-0.51
// Separate malformed-scalar-box probe. Both original and mask candidate fail eight cases.
// CVFPU:       35cb37e0c604b46bf6b62c0c91b05a60ed7c9cd3
// common_cells: 6aeee85d0a34fedc06c14f04fd6363c9f7b4eeea
// div_sqrt_mvp: 86e1f558b3c95e91577c41b2fc452c86b04e85ac
// Status bits are {NV, DZ, OF, UF, NX}. No active 0/0 result is checked.

module tb_pulp_divsqrt_nanbox_probe;
  timeunit 1ns;
  timeprecision 1ps;

  import fpnew_pkg::*;

  localparam int unsigned NumCases = 12;
  localparam int unsigned WatchdogCycles = 1024;
  localparam fpu_features_t Features = '{
      Width: 64,
      EnableVectors: 1'b1,
      EnableNanBox: 1'b1,
      FpFmtMask: 9'b111000000, // FP32, FP64 and FP16; indices ascend from zero
      default: '0
  };
  localparam fpu_implementation_t Implementation = '{
      PipeRegs: '{default: '{default: 1}},
      UnitTypes: '{
          '{default: DISABLED}, // ADDMUL
          '{default: MERGED},   // DIVSQRT
          '{default: DISABLED}, // NONCOMP
          '{default: DISABLED}, // CONV
          '{default: DISABLED}, // DOTP
          '{default: DISABLED}  // MXDOTP
      },
      PipeConfig: AFTER
  };

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5ns clk = ~clk;

  logic [2:0][63:0] operands;
  operation_e operation;
  fp_format_e format;
  logic vectorial;
  logic [3:0] simd_mask;
  logic [7:0] tag_in;
  logic in_valid, in_ready, out_valid, out_ready, busy;
  logic [63:0] result;
  status_t status;
  logic [7:0] tag_out;

  fpnew_top #(
      .Features(Features),
      .Implementation(Implementation),
      .DivSqrtSel(PULP),
      .TagType(logic [7:0]),
      .EnableSIMDMask(1'b1)
  ) dut (
      .clk_i(clk),
      .rst_ni(rst_n),
      .hart_id_i(32'd0),
      .operands_i(operands),
      .rnd_mode_i(RNE),
      .op_i(operation),
      .op_mod_i(1'b0),
      .src_fmt_i(format),
      .dst_fmt_i(format),
      .int_fmt_i(INT32),
      .vectorial_op_i(vectorial),
      .tag_i(tag_in),
      .simd_mask_i(simd_mask),
      .pace_param_i('0),
      .pace_mode_i(pace_mode_t'('0)),
      .in_valid_i(in_valid),
      .in_ready_o(in_ready),
      .flush_i(1'b0),
      .result_o(result),
      .status_o(status),
      .tag_o(tag_out),
      .out_valid_o(out_valid),
      .out_ready_i(out_ready),
      .busy_o(busy)
  );

  int unsigned accepted = 0;
  int unsigned completed = 0;
  int unsigned failed_cases = 0;
  int unsigned protocol_errors = 0;
  int unsigned input_seen [0:255];
  int unsigned output_seen [0:255];
  logic [63:0] last_result;
  status_t last_status;
  logic [7:0] last_tag;

  // Sample only real handshakes. The driver reads these values after the edge.
  always @(posedge clk) begin
    if (rst_n) begin
      if (in_valid && in_ready) begin
        accepted++;
        $display("[INPUT] id=%0d op=%s fmt=%s vec=%b mask=%b a=%016h b=%016h",tag_in,operation.name(),format.name(),vectorial,simd_mask,operands[0],operands[1]);
        if ($isunknown(tag_in)) begin
          protocol_errors++;
          $display("ERROR: unknown input tag");
        end else begin
          input_seen[tag_in]++;
          if (tag_in < 1 || tag_in > NumCases || input_seen[tag_in] != 1) begin
            protocol_errors++;
            $display("ERROR: input tag=%0d count=%0d", tag_in, input_seen[tag_in]);
          end
        end
      end
      if (out_valid && out_ready) begin
        completed++;
        $display("[OUTPUT] id=%0d result=%016h flags=%02h",tag_out,result,status);
        last_result = result;
        last_status = status;
        last_tag = tag_out;
        if ($isunknown(tag_out)) begin
          protocol_errors++;
          $display("ERROR: unknown output tag");
        end else begin
          output_seen[tag_out]++;
          if (tag_out < 1 || tag_out > NumCases || output_seen[tag_out] != 1) begin
            protocol_errors++;
            $display("ERROR: output tag=%0d count=%0d", tag_out, output_seen[tag_out]);
          end
        end
      end
    end
  end

  function automatic bit is_qnan(input logic [63:0] value, input fp_format_e fmt);
    case (fmt)
      FP64: return (value[62:52] === 11'h7ff) && (value[51] === 1'b1);
      FP32: return (value[30:23] === 8'hff) && (value[22] === 1'b1);
      FP16: return (value[14:10] === 5'h1f) && (value[9] === 1'b1);
      default: return 1'b0;
    endcase
  endfunction

  task automatic timeout_case(input int unsigned id, input string label);
    $display("[DIVSQRT_MASK_TIMEOUT] tag=%0d %s accepted=%0d completed=%0d", id, label,
             accepted, completed);
    $display("[DIVSQRT_MASK_DONE] accepted=%0d completed=%0d failed_cases=%0d protocol_errors=%0d timeout=1",
             accepted, completed, failed_cases, protocol_errors);
    $fatal(1, "Transaction did not complete; no flush or recovery is attempted");
  endtask

  // result_mask selects exact-result bits; qnan_lanes selects element numbers,
  // not 16-bit mask positions. Disabled elements have no result expectation.
  task automatic run_case(
      input int unsigned id,
      input string label,
      input operation_e op,
      input fp_format_e fmt,
      input bit vec,
      input logic [3:0] mask,
      input logic [63:0] operand_a,
      input logic [63:0] operand_b,
      input logic [4:0] expected_flags,
      input logic [63:0] expected_result,
      input logic [63:0] result_mask,
      input logic [3:0] qnan_lanes = '0,
      input bit stall_output = 1'b0
  );
    int unsigned cycles, accepted_before, completed_before;
    int unsigned element_width;
    bit failed;
    logic [63:0] held_result;
    status_t held_status;
    logic [7:0] held_tag;

    failed = 1'b0;
    accepted_before = accepted;
    completed_before = completed;
    @(negedge clk);
    operands = '0;
    operands[0] = operand_a;
    operands[1] = operand_b;
    operation = op;
    format = fmt;
    vectorial = vec;
    simd_mask = mask;
    tag_in = id[7:0];
    out_ready = !stall_output;
    in_valid = 1'b1;

    cycles = 0;
    while (accepted == accepted_before) begin
      @(posedge clk);
      #1ns;
      cycles++;
      if (cycles == WatchdogCycles) timeout_case(id, label);
    end
    @(negedge clk);
    in_valid = 1'b0;

    if (stall_output) begin
      cycles = 0;
      while (out_valid !== 1'b1) begin
        @(negedge clk);
        cycles++;
        if (cycles == WatchdogCycles) timeout_case(id, label);
      end
      held_result = result;
      held_status = status;
      held_tag = tag_out;
      repeat (3) begin
        @(posedge clk);
        #1ns;
        if (out_valid !== 1'b1 || result !== held_result ||
            status !== held_status || tag_out !== held_tag) begin
          failed = 1'b1;
          $display("ERROR tag=%0d: output changed while out_ready=0", id);
        end
      end
      @(negedge clk);
      out_ready = 1'b1;
    end

    cycles = 0;
    while (completed == completed_before) begin
      @(posedge clk);
      #1ns;
      cycles++;
      if (cycles == WatchdogCycles) timeout_case(id, label);
    end
    if (accepted != accepted_before + 1 || completed != completed_before + 1 ||
        last_tag !== id[7:0]) failed = 1'b1;
    if (last_status !== expected_flags) failed = 1'b1;
    if ($isunknown({last_result,last_status,last_tag})) failed = 1'b1;
    if (((last_result ^ expected_result) & result_mask) !== 64'd0) failed = 1'b1;
    element_width = fp_width(fmt);
    for (int unsigned element = 0; element < 64 / element_width; element++) begin
      if (qnan_lanes[element] && !is_qnan(last_result >> (element * element_width), fmt))
        failed = 1'b1;
    end
    if (failed) failed_cases++;
    $display("[DIVSQRT_MASK_CASE] id=%0d %s fmt=%s vec=%0b mask=%04b tag=%0d got=%016h want=%016h compare=%016h qnan_elements=%04b flags=%02h want_flags=%02h %s",
             id, label, fmt.name(), vec, mask, last_tag, last_result, expected_result,
             result_mask, qnan_lanes, last_status, expected_flags, failed ? "FAIL" : "PASS");
  endtask

  initial begin
    for (int unsigned tag = 0; tag < 256; tag++) begin
      input_seen[tag] = 0;
      output_seen[tag] = 0;
    end
    operands = '0;
    operation = DIV;
    format = FP64;
    vectorial = 1'b0;
    simd_mask = '0;
    tag_in = '0;
    in_valid = 1'b0;
    out_ready = 1'b1;
    last_result = '0;
    last_status = '0;
    last_tag = '0;
    repeat (5) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;

    run_case(1, "scalar_unboxed_e16_div_mask0", DIV, FP16, 0, 4'h0,
             64'h0000000000004600, 64'hffffffffffff4000,
             5'h00, 64'hffffffffffff0000, 64'hffffffffffff0000, 4'h0, 1'b0);
    run_case(2, "scalar_unboxed_e16_div_mask1", DIV, FP16, 0, 4'h1,
             64'h0000000000004600, 64'hffffffffffff4000,
             5'h00, 64'hffffffffffff0000, 64'hffffffffffff0000, 4'h1, 1'b0);
    run_case(3, "scalar_unboxed_e16_div_maskf", DIV, FP16, 0, 4'hf,
             64'h0000000000004600, 64'hffffffffffff4000,
             5'h00, 64'hffffffffffff0000, 64'hffffffffffff0000, 4'h1, 1'b0);
    run_case(4, "scalar_unboxed_e16_sqrt_mask0", SQRT, FP16, 0, 4'h0,
             64'h0000000000004400, 64'hffffffffffff0000,
             5'h00, 64'hffffffffffff0000, 64'hffffffffffff0000, 4'h0, 1'b0);
    run_case(5, "scalar_unboxed_e16_sqrt_mask1", SQRT, FP16, 0, 4'h1,
             64'h0000000000004400, 64'hffffffffffff0000,
             5'h00, 64'hffffffffffff0000, 64'hffffffffffff0000, 4'h1, 1'b0);
    run_case(6, "scalar_unboxed_e16_sqrt_maskf", SQRT, FP16, 0, 4'hf,
             64'h0000000000004400, 64'hffffffffffff0000,
             5'h00, 64'hffffffffffff0000, 64'hffffffffffff0000, 4'h1, 1'b0);
    run_case(7, "scalar_unboxed_e32_div_mask0", DIV, FP32, 0, 4'h0,
             64'h0000000040c00000, 64'hffffffff40000000,
             5'h00, 64'hffffffff00000000, 64'hffffffff00000000, 4'h0, 1'b0);
    run_case(8, "scalar_unboxed_e32_div_mask1", DIV, FP32, 0, 4'h1,
             64'h0000000040c00000, 64'hffffffff40000000,
             5'h00, 64'hffffffff00000000, 64'hffffffff00000000, 4'h1, 1'b0);
    run_case(9, "scalar_unboxed_e32_div_maskf", DIV, FP32, 0, 4'hf,
             64'h0000000040c00000, 64'hffffffff40000000,
             5'h00, 64'hffffffff00000000, 64'hffffffff00000000, 4'h1, 1'b0);
    run_case(10, "scalar_unboxed_e32_sqrt_mask0", SQRT, FP32, 0, 4'h0,
             64'h0000000040800000, 64'hffffffff00000000,
             5'h00, 64'hffffffff00000000, 64'hffffffff00000000, 4'h0, 1'b0);
    run_case(11, "scalar_unboxed_e32_sqrt_mask1", SQRT, FP32, 0, 4'h1,
             64'h0000000040800000, 64'hffffffff00000000,
             5'h00, 64'hffffffff00000000, 64'hffffffff00000000, 4'h1, 1'b0);
    run_case(12, "scalar_unboxed_e32_sqrt_maskf", SQRT, FP32, 0, 4'hf,
             64'h0000000040800000, 64'hffffffff00000000,
             5'h00, 64'hffffffff00000000, 64'hffffffff00000000, 4'h1, 1'b0);

    // Allow the output pipeline to return to idle; catch late duplicate outputs.
    repeat (4) begin
      @(posedge clk);
      #1ns;
    end
    if (accepted != NumCases || completed != NumCases || busy !== 1'b0)
      protocol_errors++;
    for (int unsigned tag = 1; tag <= NumCases; tag++) begin
      if (input_seen[tag] != 1 || output_seen[tag] != 1) begin
        protocol_errors++;
        $display("ERROR: tag=%0d inputs=%0d outputs=%0d", tag,
                 input_seen[tag], output_seen[tag]);
      end
    end
    $display("[DIVSQRT_MASK_DONE] accepted=%0d completed=%0d failed_cases=%0d protocol_errors=%0d busy=%0b timeout=0",
             accepted, completed, failed_cases, protocol_errors, busy);
    if (failed_cases != 0 || protocol_errors != 0)
      $fatal(1, "PULP DIVSQRT SIMD-mask reproducer failed");
    $display("PASS: all 12 transactions matched their expected results and flags");
    $finish;
  end
endmodule
