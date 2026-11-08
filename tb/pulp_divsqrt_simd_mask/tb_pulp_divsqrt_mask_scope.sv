// SPDX-License-Identifier: SHL-0.51
// PULP DIVSQRT SIMD-mask regression: legal packed and NaN-boxed scalar inputs.
// CVFPU:       35cb37e0c604b46bf6b62c0c91b05a60ed7c9cd3
// common_cells: 6aeee85d0a34fedc06c14f04fd6363c9f7b4eeea
// div_sqrt_mvp: 86e1f558b3c95e91577c41b2fc452c86b04e85ac
// Status bits are {NV, DZ, OF, UF, NX}. No active 0/0 result is checked.

module tb_pulp_divsqrt_mask_scope;
  timeunit 1ns;
  timeprecision 1ps;

  import fpnew_pkg::*;

  localparam int unsigned NumCases = 240;
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
        $display("[HOLD] id=%0d valid=%b result=%016h flags=%02h tag=%0d",id,out_valid,result,status,tag_out);
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

    run_case(1, "vector_div_e16_flip0_mask0", DIV, FP16, 1, 4'h0,
             64'h3c0046003c004600, 64'h0000400000004000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(2, "vector_div_e16_flip0_mask1", DIV, FP16, 1, 4'h1,
             64'h3c0046003c004600, 64'h0000400000004000,
             5'h00, 64'h0000000000004200, 64'h000000000000ffff, 4'h0, 1'b0);
    run_case(3, "vector_div_e16_flip0_mask2", DIV, FP16, 1, 4'h2,
             64'h3c0046003c004600, 64'h0000400000004000,
             5'h08, 64'h000000007c000000, 64'h00000000ffff0000, 4'h0, 1'b0);
    run_case(4, "vector_div_e16_flip0_mask3", DIV, FP16, 1, 4'h3,
             64'h3c0046003c004600, 64'h0000400000004000,
             5'h08, 64'h000000007c004200, 64'h00000000ffffffff, 4'h0, 1'b0);
    run_case(5, "vector_div_e16_flip0_mask4", DIV, FP16, 1, 4'h4,
             64'h3c0046003c004600, 64'h0000400000004000,
             5'h00, 64'h0000420000000000, 64'h0000ffff00000000, 4'h0, 1'b0);
    run_case(6, "vector_div_e16_flip0_mask5", DIV, FP16, 1, 4'h5,
             64'h3c0046003c004600, 64'h0000400000004000,
             5'h00, 64'h0000420000004200, 64'h0000ffff0000ffff, 4'h0, 1'b0);
    run_case(7, "vector_div_e16_flip0_mask6", DIV, FP16, 1, 4'h6,
             64'h3c0046003c004600, 64'h0000400000004000,
             5'h08, 64'h000042007c000000, 64'h0000ffffffff0000, 4'h0, 1'b0);
    run_case(8, "vector_div_e16_flip0_mask7", DIV, FP16, 1, 4'h7,
             64'h3c0046003c004600, 64'h0000400000004000,
             5'h08, 64'h000042007c004200, 64'h0000ffffffffffff, 4'h0, 1'b0);
    run_case(9, "vector_div_e16_flip0_mask8", DIV, FP16, 1, 4'h8,
             64'h3c0046003c004600, 64'h0000400000004000,
             5'h08, 64'h7c00000000000000, 64'hffff000000000000, 4'h0, 1'b0);
    run_case(10, "vector_div_e16_flip0_mask9", DIV, FP16, 1, 4'h9,
             64'h3c0046003c004600, 64'h0000400000004000,
             5'h08, 64'h7c00000000004200, 64'hffff00000000ffff, 4'h0, 1'b0);
    run_case(11, "vector_div_e16_flip0_maska", DIV, FP16, 1, 4'ha,
             64'h3c0046003c004600, 64'h0000400000004000,
             5'h08, 64'h7c0000007c000000, 64'hffff0000ffff0000, 4'h0, 1'b0);
    run_case(12, "vector_div_e16_flip0_maskb", DIV, FP16, 1, 4'hb,
             64'h3c0046003c004600, 64'h0000400000004000,
             5'h08, 64'h7c0000007c004200, 64'hffff0000ffffffff, 4'h0, 1'b0);
    run_case(13, "vector_div_e16_flip0_maskc", DIV, FP16, 1, 4'hc,
             64'h3c0046003c004600, 64'h0000400000004000,
             5'h08, 64'h7c00420000000000, 64'hffffffff00000000, 4'h0, 1'b0);
    run_case(14, "vector_div_e16_flip0_maskd", DIV, FP16, 1, 4'hd,
             64'h3c0046003c004600, 64'h0000400000004000,
             5'h08, 64'h7c00420000004200, 64'hffffffff0000ffff, 4'h0, 1'b0);
    run_case(15, "vector_div_e16_flip0_maske", DIV, FP16, 1, 4'he,
             64'h3c0046003c004600, 64'h0000400000004000,
             5'h08, 64'h7c0042007c000000, 64'hffffffffffff0000, 4'h0, 1'b0);
    run_case(16, "vector_div_e16_flip0_maskf", DIV, FP16, 1, 4'hf,
             64'h3c0046003c004600, 64'h0000400000004000,
             5'h08, 64'h7c0042007c004200, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(17, "vector_div_e16_flip1_mask0", DIV, FP16, 1, 4'h0,
             64'h46003c0046003c00, 64'h4000000040000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b1);
    run_case(18, "vector_div_e16_flip1_mask1", DIV, FP16, 1, 4'h1,
             64'h46003c0046003c00, 64'h4000000040000000,
             5'h08, 64'h0000000000007c00, 64'h000000000000ffff, 4'h0, 1'b0);
    run_case(19, "vector_div_e16_flip1_mask2", DIV, FP16, 1, 4'h2,
             64'h46003c0046003c00, 64'h4000000040000000,
             5'h00, 64'h0000000042000000, 64'h00000000ffff0000, 4'h0, 1'b0);
    run_case(20, "vector_div_e16_flip1_mask3", DIV, FP16, 1, 4'h3,
             64'h46003c0046003c00, 64'h4000000040000000,
             5'h08, 64'h0000000042007c00, 64'h00000000ffffffff, 4'h0, 1'b0);
    run_case(21, "vector_div_e16_flip1_mask4", DIV, FP16, 1, 4'h4,
             64'h46003c0046003c00, 64'h4000000040000000,
             5'h08, 64'h00007c0000000000, 64'h0000ffff00000000, 4'h0, 1'b0);
    run_case(22, "vector_div_e16_flip1_mask5", DIV, FP16, 1, 4'h5,
             64'h46003c0046003c00, 64'h4000000040000000,
             5'h08, 64'h00007c0000007c00, 64'h0000ffff0000ffff, 4'h0, 1'b0);
    run_case(23, "vector_div_e16_flip1_mask6", DIV, FP16, 1, 4'h6,
             64'h46003c0046003c00, 64'h4000000040000000,
             5'h08, 64'h00007c0042000000, 64'h0000ffffffff0000, 4'h0, 1'b0);
    run_case(24, "vector_div_e16_flip1_mask7", DIV, FP16, 1, 4'h7,
             64'h46003c0046003c00, 64'h4000000040000000,
             5'h08, 64'h00007c0042007c00, 64'h0000ffffffffffff, 4'h0, 1'b0);
    run_case(25, "vector_div_e16_flip1_mask8", DIV, FP16, 1, 4'h8,
             64'h46003c0046003c00, 64'h4000000040000000,
             5'h00, 64'h4200000000000000, 64'hffff000000000000, 4'h0, 1'b0);
    run_case(26, "vector_div_e16_flip1_mask9", DIV, FP16, 1, 4'h9,
             64'h46003c0046003c00, 64'h4000000040000000,
             5'h08, 64'h4200000000007c00, 64'hffff00000000ffff, 4'h0, 1'b0);
    run_case(27, "vector_div_e16_flip1_maska", DIV, FP16, 1, 4'ha,
             64'h46003c0046003c00, 64'h4000000040000000,
             5'h00, 64'h4200000042000000, 64'hffff0000ffff0000, 4'h0, 1'b0);
    run_case(28, "vector_div_e16_flip1_maskb", DIV, FP16, 1, 4'hb,
             64'h46003c0046003c00, 64'h4000000040000000,
             5'h08, 64'h4200000042007c00, 64'hffff0000ffffffff, 4'h0, 1'b0);
    run_case(29, "vector_div_e16_flip1_maskc", DIV, FP16, 1, 4'hc,
             64'h46003c0046003c00, 64'h4000000040000000,
             5'h08, 64'h42007c0000000000, 64'hffffffff00000000, 4'h0, 1'b0);
    run_case(30, "vector_div_e16_flip1_maskd", DIV, FP16, 1, 4'hd,
             64'h46003c0046003c00, 64'h4000000040000000,
             5'h08, 64'h42007c0000007c00, 64'hffffffff0000ffff, 4'h0, 1'b0);
    run_case(31, "vector_div_e16_flip1_maske", DIV, FP16, 1, 4'he,
             64'h46003c0046003c00, 64'h4000000040000000,
             5'h08, 64'h42007c0042000000, 64'hffffffffffff0000, 4'h0, 1'b0);
    run_case(32, "vector_div_e16_flip1_maskf", DIV, FP16, 1, 4'hf,
             64'h46003c0046003c00, 64'h4000000040000000,
             5'h08, 64'h42007c0042007c00, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(33, "vector_sqrt_e16_flip0_mask0", SQRT, FP16, 1, 4'h0,
             64'hbc004400bc004400, 64'h0000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(34, "vector_sqrt_e16_flip0_mask1", SQRT, FP16, 1, 4'h1,
             64'hbc004400bc004400, 64'h0000000000000000,
             5'h00, 64'h0000000000004000, 64'h000000000000ffff, 4'h0, 1'b1);
    run_case(35, "vector_sqrt_e16_flip0_mask2", SQRT, FP16, 1, 4'h2,
             64'hbc004400bc004400, 64'h0000000000000000,
             5'h10, 64'h0000000000000000, 64'h0000000000000000, 4'h2, 1'b0);
    run_case(36, "vector_sqrt_e16_flip0_mask3", SQRT, FP16, 1, 4'h3,
             64'hbc004400bc004400, 64'h0000000000000000,
             5'h10, 64'h0000000000004000, 64'h000000000000ffff, 4'h2, 1'b0);
    run_case(37, "vector_sqrt_e16_flip0_mask4", SQRT, FP16, 1, 4'h4,
             64'hbc004400bc004400, 64'h0000000000000000,
             5'h00, 64'h0000400000000000, 64'h0000ffff00000000, 4'h0, 1'b0);
    run_case(38, "vector_sqrt_e16_flip0_mask5", SQRT, FP16, 1, 4'h5,
             64'hbc004400bc004400, 64'h0000000000000000,
             5'h00, 64'h0000400000004000, 64'h0000ffff0000ffff, 4'h0, 1'b0);
    run_case(39, "vector_sqrt_e16_flip0_mask6", SQRT, FP16, 1, 4'h6,
             64'hbc004400bc004400, 64'h0000000000000000,
             5'h10, 64'h0000400000000000, 64'h0000ffff00000000, 4'h2, 1'b0);
    run_case(40, "vector_sqrt_e16_flip0_mask7", SQRT, FP16, 1, 4'h7,
             64'hbc004400bc004400, 64'h0000000000000000,
             5'h10, 64'h0000400000004000, 64'h0000ffff0000ffff, 4'h2, 1'b0);
    run_case(41, "vector_sqrt_e16_flip0_mask8", SQRT, FP16, 1, 4'h8,
             64'hbc004400bc004400, 64'h0000000000000000,
             5'h10, 64'h0000000000000000, 64'h0000000000000000, 4'h8, 1'b0);
    run_case(42, "vector_sqrt_e16_flip0_mask9", SQRT, FP16, 1, 4'h9,
             64'hbc004400bc004400, 64'h0000000000000000,
             5'h10, 64'h0000000000004000, 64'h000000000000ffff, 4'h8, 1'b0);
    run_case(43, "vector_sqrt_e16_flip0_maska", SQRT, FP16, 1, 4'ha,
             64'hbc004400bc004400, 64'h0000000000000000,
             5'h10, 64'h0000000000000000, 64'h0000000000000000, 4'ha, 1'b0);
    run_case(44, "vector_sqrt_e16_flip0_maskb", SQRT, FP16, 1, 4'hb,
             64'hbc004400bc004400, 64'h0000000000000000,
             5'h10, 64'h0000000000004000, 64'h000000000000ffff, 4'ha, 1'b0);
    run_case(45, "vector_sqrt_e16_flip0_maskc", SQRT, FP16, 1, 4'hc,
             64'hbc004400bc004400, 64'h0000000000000000,
             5'h10, 64'h0000400000000000, 64'h0000ffff00000000, 4'h8, 1'b0);
    run_case(46, "vector_sqrt_e16_flip0_maskd", SQRT, FP16, 1, 4'hd,
             64'hbc004400bc004400, 64'h0000000000000000,
             5'h10, 64'h0000400000004000, 64'h0000ffff0000ffff, 4'h8, 1'b0);
    run_case(47, "vector_sqrt_e16_flip0_maske", SQRT, FP16, 1, 4'he,
             64'hbc004400bc004400, 64'h0000000000000000,
             5'h10, 64'h0000400000000000, 64'h0000ffff00000000, 4'ha, 1'b0);
    run_case(48, "vector_sqrt_e16_flip0_maskf", SQRT, FP16, 1, 4'hf,
             64'hbc004400bc004400, 64'h0000000000000000,
             5'h10, 64'h0000400000004000, 64'h0000ffff0000ffff, 4'ha, 1'b0);
    run_case(49, "vector_sqrt_e16_flip1_mask0", SQRT, FP16, 1, 4'h0,
             64'h4400bc004400bc00, 64'h0000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(50, "vector_sqrt_e16_flip1_mask1", SQRT, FP16, 1, 4'h1,
             64'h4400bc004400bc00, 64'h0000000000000000,
             5'h10, 64'h0000000000000000, 64'h0000000000000000, 4'h1, 1'b0);
    run_case(51, "vector_sqrt_e16_flip1_mask2", SQRT, FP16, 1, 4'h2,
             64'h4400bc004400bc00, 64'h0000000000000000,
             5'h00, 64'h0000000040000000, 64'h00000000ffff0000, 4'h0, 1'b1);
    run_case(52, "vector_sqrt_e16_flip1_mask3", SQRT, FP16, 1, 4'h3,
             64'h4400bc004400bc00, 64'h0000000000000000,
             5'h10, 64'h0000000040000000, 64'h00000000ffff0000, 4'h1, 1'b0);
    run_case(53, "vector_sqrt_e16_flip1_mask4", SQRT, FP16, 1, 4'h4,
             64'h4400bc004400bc00, 64'h0000000000000000,
             5'h10, 64'h0000000000000000, 64'h0000000000000000, 4'h4, 1'b0);
    run_case(54, "vector_sqrt_e16_flip1_mask5", SQRT, FP16, 1, 4'h5,
             64'h4400bc004400bc00, 64'h0000000000000000,
             5'h10, 64'h0000000000000000, 64'h0000000000000000, 4'h5, 1'b0);
    run_case(55, "vector_sqrt_e16_flip1_mask6", SQRT, FP16, 1, 4'h6,
             64'h4400bc004400bc00, 64'h0000000000000000,
             5'h10, 64'h0000000040000000, 64'h00000000ffff0000, 4'h4, 1'b0);
    run_case(56, "vector_sqrt_e16_flip1_mask7", SQRT, FP16, 1, 4'h7,
             64'h4400bc004400bc00, 64'h0000000000000000,
             5'h10, 64'h0000000040000000, 64'h00000000ffff0000, 4'h5, 1'b0);
    run_case(57, "vector_sqrt_e16_flip1_mask8", SQRT, FP16, 1, 4'h8,
             64'h4400bc004400bc00, 64'h0000000000000000,
             5'h00, 64'h4000000000000000, 64'hffff000000000000, 4'h0, 1'b0);
    run_case(58, "vector_sqrt_e16_flip1_mask9", SQRT, FP16, 1, 4'h9,
             64'h4400bc004400bc00, 64'h0000000000000000,
             5'h10, 64'h4000000000000000, 64'hffff000000000000, 4'h1, 1'b0);
    run_case(59, "vector_sqrt_e16_flip1_maska", SQRT, FP16, 1, 4'ha,
             64'h4400bc004400bc00, 64'h0000000000000000,
             5'h00, 64'h4000000040000000, 64'hffff0000ffff0000, 4'h0, 1'b0);
    run_case(60, "vector_sqrt_e16_flip1_maskb", SQRT, FP16, 1, 4'hb,
             64'h4400bc004400bc00, 64'h0000000000000000,
             5'h10, 64'h4000000040000000, 64'hffff0000ffff0000, 4'h1, 1'b0);
    run_case(61, "vector_sqrt_e16_flip1_maskc", SQRT, FP16, 1, 4'hc,
             64'h4400bc004400bc00, 64'h0000000000000000,
             5'h10, 64'h4000000000000000, 64'hffff000000000000, 4'h4, 1'b0);
    run_case(62, "vector_sqrt_e16_flip1_maskd", SQRT, FP16, 1, 4'hd,
             64'h4400bc004400bc00, 64'h0000000000000000,
             5'h10, 64'h4000000000000000, 64'hffff000000000000, 4'h5, 1'b0);
    run_case(63, "vector_sqrt_e16_flip1_maske", SQRT, FP16, 1, 4'he,
             64'h4400bc004400bc00, 64'h0000000000000000,
             5'h10, 64'h4000000040000000, 64'hffff0000ffff0000, 4'h4, 1'b0);
    run_case(64, "vector_sqrt_e16_flip1_maskf", SQRT, FP16, 1, 4'hf,
             64'h4400bc004400bc00, 64'h0000000000000000,
             5'h10, 64'h4000000040000000, 64'hffff0000ffff0000, 4'h5, 1'b0);
    run_case(65, "vector_div_e32_flip0_mask0", DIV, FP32, 1, 4'h0,
             64'h3f80000040c00000, 64'h0000000040000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(66, "vector_div_e32_flip0_mask1", DIV, FP32, 1, 4'h1,
             64'h3f80000040c00000, 64'h0000000040000000,
             5'h00, 64'h0000000040400000, 64'h00000000ffffffff, 4'h0, 1'b0);
    run_case(67, "vector_div_e32_flip0_mask2", DIV, FP32, 1, 4'h2,
             64'h3f80000040c00000, 64'h0000000040000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(68, "vector_div_e32_flip0_mask3", DIV, FP32, 1, 4'h3,
             64'h3f80000040c00000, 64'h0000000040000000,
             5'h00, 64'h0000000040400000, 64'h00000000ffffffff, 4'h0, 1'b1);
    run_case(69, "vector_div_e32_flip0_mask4", DIV, FP32, 1, 4'h4,
             64'h3f80000040c00000, 64'h0000000040000000,
             5'h08, 64'h7f80000000000000, 64'hffffffff00000000, 4'h0, 1'b0);
    run_case(70, "vector_div_e32_flip0_mask5", DIV, FP32, 1, 4'h5,
             64'h3f80000040c00000, 64'h0000000040000000,
             5'h08, 64'h7f80000040400000, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(71, "vector_div_e32_flip0_mask6", DIV, FP32, 1, 4'h6,
             64'h3f80000040c00000, 64'h0000000040000000,
             5'h08, 64'h7f80000000000000, 64'hffffffff00000000, 4'h0, 1'b0);
    run_case(72, "vector_div_e32_flip0_mask7", DIV, FP32, 1, 4'h7,
             64'h3f80000040c00000, 64'h0000000040000000,
             5'h08, 64'h7f80000040400000, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(73, "vector_div_e32_flip0_mask8", DIV, FP32, 1, 4'h8,
             64'h3f80000040c00000, 64'h0000000040000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(74, "vector_div_e32_flip0_mask9", DIV, FP32, 1, 4'h9,
             64'h3f80000040c00000, 64'h0000000040000000,
             5'h00, 64'h0000000040400000, 64'h00000000ffffffff, 4'h0, 1'b0);
    run_case(75, "vector_div_e32_flip0_maska", DIV, FP32, 1, 4'ha,
             64'h3f80000040c00000, 64'h0000000040000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(76, "vector_div_e32_flip0_maskb", DIV, FP32, 1, 4'hb,
             64'h3f80000040c00000, 64'h0000000040000000,
             5'h00, 64'h0000000040400000, 64'h00000000ffffffff, 4'h0, 1'b0);
    run_case(77, "vector_div_e32_flip0_maskc", DIV, FP32, 1, 4'hc,
             64'h3f80000040c00000, 64'h0000000040000000,
             5'h08, 64'h7f80000000000000, 64'hffffffff00000000, 4'h0, 1'b0);
    run_case(78, "vector_div_e32_flip0_maskd", DIV, FP32, 1, 4'hd,
             64'h3f80000040c00000, 64'h0000000040000000,
             5'h08, 64'h7f80000040400000, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(79, "vector_div_e32_flip0_maske", DIV, FP32, 1, 4'he,
             64'h3f80000040c00000, 64'h0000000040000000,
             5'h08, 64'h7f80000000000000, 64'hffffffff00000000, 4'h0, 1'b0);
    run_case(80, "vector_div_e32_flip0_maskf", DIV, FP32, 1, 4'hf,
             64'h3f80000040c00000, 64'h0000000040000000,
             5'h08, 64'h7f80000040400000, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(81, "vector_div_e32_flip1_mask0", DIV, FP32, 1, 4'h0,
             64'h40c000003f800000, 64'h4000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(82, "vector_div_e32_flip1_mask1", DIV, FP32, 1, 4'h1,
             64'h40c000003f800000, 64'h4000000000000000,
             5'h08, 64'h000000007f800000, 64'h00000000ffffffff, 4'h0, 1'b0);
    run_case(83, "vector_div_e32_flip1_mask2", DIV, FP32, 1, 4'h2,
             64'h40c000003f800000, 64'h4000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(84, "vector_div_e32_flip1_mask3", DIV, FP32, 1, 4'h3,
             64'h40c000003f800000, 64'h4000000000000000,
             5'h08, 64'h000000007f800000, 64'h00000000ffffffff, 4'h0, 1'b0);
    run_case(85, "vector_div_e32_flip1_mask4", DIV, FP32, 1, 4'h4,
             64'h40c000003f800000, 64'h4000000000000000,
             5'h00, 64'h4040000000000000, 64'hffffffff00000000, 4'h0, 1'b1);
    run_case(86, "vector_div_e32_flip1_mask5", DIV, FP32, 1, 4'h5,
             64'h40c000003f800000, 64'h4000000000000000,
             5'h08, 64'h404000007f800000, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(87, "vector_div_e32_flip1_mask6", DIV, FP32, 1, 4'h6,
             64'h40c000003f800000, 64'h4000000000000000,
             5'h00, 64'h4040000000000000, 64'hffffffff00000000, 4'h0, 1'b0);
    run_case(88, "vector_div_e32_flip1_mask7", DIV, FP32, 1, 4'h7,
             64'h40c000003f800000, 64'h4000000000000000,
             5'h08, 64'h404000007f800000, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(89, "vector_div_e32_flip1_mask8", DIV, FP32, 1, 4'h8,
             64'h40c000003f800000, 64'h4000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(90, "vector_div_e32_flip1_mask9", DIV, FP32, 1, 4'h9,
             64'h40c000003f800000, 64'h4000000000000000,
             5'h08, 64'h000000007f800000, 64'h00000000ffffffff, 4'h0, 1'b0);
    run_case(91, "vector_div_e32_flip1_maska", DIV, FP32, 1, 4'ha,
             64'h40c000003f800000, 64'h4000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(92, "vector_div_e32_flip1_maskb", DIV, FP32, 1, 4'hb,
             64'h40c000003f800000, 64'h4000000000000000,
             5'h08, 64'h000000007f800000, 64'h00000000ffffffff, 4'h0, 1'b0);
    run_case(93, "vector_div_e32_flip1_maskc", DIV, FP32, 1, 4'hc,
             64'h40c000003f800000, 64'h4000000000000000,
             5'h00, 64'h4040000000000000, 64'hffffffff00000000, 4'h0, 1'b0);
    run_case(94, "vector_div_e32_flip1_maskd", DIV, FP32, 1, 4'hd,
             64'h40c000003f800000, 64'h4000000000000000,
             5'h08, 64'h404000007f800000, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(95, "vector_div_e32_flip1_maske", DIV, FP32, 1, 4'he,
             64'h40c000003f800000, 64'h4000000000000000,
             5'h00, 64'h4040000000000000, 64'hffffffff00000000, 4'h0, 1'b0);
    run_case(96, "vector_div_e32_flip1_maskf", DIV, FP32, 1, 4'hf,
             64'h40c000003f800000, 64'h4000000000000000,
             5'h08, 64'h404000007f800000, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(97, "vector_sqrt_e32_flip0_mask0", SQRT, FP32, 1, 4'h0,
             64'hbf80000040800000, 64'h0000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(98, "vector_sqrt_e32_flip0_mask1", SQRT, FP32, 1, 4'h1,
             64'hbf80000040800000, 64'h0000000000000000,
             5'h00, 64'h0000000040000000, 64'h00000000ffffffff, 4'h0, 1'b0);
    run_case(99, "vector_sqrt_e32_flip0_mask2", SQRT, FP32, 1, 4'h2,
             64'hbf80000040800000, 64'h0000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(100, "vector_sqrt_e32_flip0_mask3", SQRT, FP32, 1, 4'h3,
             64'hbf80000040800000, 64'h0000000000000000,
             5'h00, 64'h0000000040000000, 64'h00000000ffffffff, 4'h0, 1'b0);
    run_case(101, "vector_sqrt_e32_flip0_mask4", SQRT, FP32, 1, 4'h4,
             64'hbf80000040800000, 64'h0000000000000000,
             5'h10, 64'h0000000000000000, 64'h0000000000000000, 4'h2, 1'b0);
    run_case(102, "vector_sqrt_e32_flip0_mask5", SQRT, FP32, 1, 4'h5,
             64'hbf80000040800000, 64'h0000000000000000,
             5'h10, 64'h0000000040000000, 64'h00000000ffffffff, 4'h2, 1'b1);
    run_case(103, "vector_sqrt_e32_flip0_mask6", SQRT, FP32, 1, 4'h6,
             64'hbf80000040800000, 64'h0000000000000000,
             5'h10, 64'h0000000000000000, 64'h0000000000000000, 4'h2, 1'b0);
    run_case(104, "vector_sqrt_e32_flip0_mask7", SQRT, FP32, 1, 4'h7,
             64'hbf80000040800000, 64'h0000000000000000,
             5'h10, 64'h0000000040000000, 64'h00000000ffffffff, 4'h2, 1'b0);
    run_case(105, "vector_sqrt_e32_flip0_mask8", SQRT, FP32, 1, 4'h8,
             64'hbf80000040800000, 64'h0000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(106, "vector_sqrt_e32_flip0_mask9", SQRT, FP32, 1, 4'h9,
             64'hbf80000040800000, 64'h0000000000000000,
             5'h00, 64'h0000000040000000, 64'h00000000ffffffff, 4'h0, 1'b0);
    run_case(107, "vector_sqrt_e32_flip0_maska", SQRT, FP32, 1, 4'ha,
             64'hbf80000040800000, 64'h0000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(108, "vector_sqrt_e32_flip0_maskb", SQRT, FP32, 1, 4'hb,
             64'hbf80000040800000, 64'h0000000000000000,
             5'h00, 64'h0000000040000000, 64'h00000000ffffffff, 4'h0, 1'b0);
    run_case(109, "vector_sqrt_e32_flip0_maskc", SQRT, FP32, 1, 4'hc,
             64'hbf80000040800000, 64'h0000000000000000,
             5'h10, 64'h0000000000000000, 64'h0000000000000000, 4'h2, 1'b0);
    run_case(110, "vector_sqrt_e32_flip0_maskd", SQRT, FP32, 1, 4'hd,
             64'hbf80000040800000, 64'h0000000000000000,
             5'h10, 64'h0000000040000000, 64'h00000000ffffffff, 4'h2, 1'b0);
    run_case(111, "vector_sqrt_e32_flip0_maske", SQRT, FP32, 1, 4'he,
             64'hbf80000040800000, 64'h0000000000000000,
             5'h10, 64'h0000000000000000, 64'h0000000000000000, 4'h2, 1'b0);
    run_case(112, "vector_sqrt_e32_flip0_maskf", SQRT, FP32, 1, 4'hf,
             64'hbf80000040800000, 64'h0000000000000000,
             5'h10, 64'h0000000040000000, 64'h00000000ffffffff, 4'h2, 1'b0);
    run_case(113, "vector_sqrt_e32_flip1_mask0", SQRT, FP32, 1, 4'h0,
             64'h40800000bf800000, 64'h0000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(114, "vector_sqrt_e32_flip1_mask1", SQRT, FP32, 1, 4'h1,
             64'h40800000bf800000, 64'h0000000000000000,
             5'h10, 64'h0000000000000000, 64'h0000000000000000, 4'h1, 1'b0);
    run_case(115, "vector_sqrt_e32_flip1_mask2", SQRT, FP32, 1, 4'h2,
             64'h40800000bf800000, 64'h0000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(116, "vector_sqrt_e32_flip1_mask3", SQRT, FP32, 1, 4'h3,
             64'h40800000bf800000, 64'h0000000000000000,
             5'h10, 64'h0000000000000000, 64'h0000000000000000, 4'h1, 1'b0);
    run_case(117, "vector_sqrt_e32_flip1_mask4", SQRT, FP32, 1, 4'h4,
             64'h40800000bf800000, 64'h0000000000000000,
             5'h00, 64'h4000000000000000, 64'hffffffff00000000, 4'h0, 1'b0);
    run_case(118, "vector_sqrt_e32_flip1_mask5", SQRT, FP32, 1, 4'h5,
             64'h40800000bf800000, 64'h0000000000000000,
             5'h10, 64'h4000000000000000, 64'hffffffff00000000, 4'h1, 1'b0);
    run_case(119, "vector_sqrt_e32_flip1_mask6", SQRT, FP32, 1, 4'h6,
             64'h40800000bf800000, 64'h0000000000000000,
             5'h00, 64'h4000000000000000, 64'hffffffff00000000, 4'h0, 1'b1);
    run_case(120, "vector_sqrt_e32_flip1_mask7", SQRT, FP32, 1, 4'h7,
             64'h40800000bf800000, 64'h0000000000000000,
             5'h10, 64'h4000000000000000, 64'hffffffff00000000, 4'h1, 1'b0);
    run_case(121, "vector_sqrt_e32_flip1_mask8", SQRT, FP32, 1, 4'h8,
             64'h40800000bf800000, 64'h0000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(122, "vector_sqrt_e32_flip1_mask9", SQRT, FP32, 1, 4'h9,
             64'h40800000bf800000, 64'h0000000000000000,
             5'h10, 64'h0000000000000000, 64'h0000000000000000, 4'h1, 1'b0);
    run_case(123, "vector_sqrt_e32_flip1_maska", SQRT, FP32, 1, 4'ha,
             64'h40800000bf800000, 64'h0000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(124, "vector_sqrt_e32_flip1_maskb", SQRT, FP32, 1, 4'hb,
             64'h40800000bf800000, 64'h0000000000000000,
             5'h10, 64'h0000000000000000, 64'h0000000000000000, 4'h1, 1'b0);
    run_case(125, "vector_sqrt_e32_flip1_maskc", SQRT, FP32, 1, 4'hc,
             64'h40800000bf800000, 64'h0000000000000000,
             5'h00, 64'h4000000000000000, 64'hffffffff00000000, 4'h0, 1'b0);
    run_case(126, "vector_sqrt_e32_flip1_maskd", SQRT, FP32, 1, 4'hd,
             64'h40800000bf800000, 64'h0000000000000000,
             5'h10, 64'h4000000000000000, 64'hffffffff00000000, 4'h1, 1'b0);
    run_case(127, "vector_sqrt_e32_flip1_maske", SQRT, FP32, 1, 4'he,
             64'h40800000bf800000, 64'h0000000000000000,
             5'h00, 64'h4000000000000000, 64'hffffffff00000000, 4'h0, 1'b0);
    run_case(128, "vector_sqrt_e32_flip1_maskf", SQRT, FP32, 1, 4'hf,
             64'h40800000bf800000, 64'h0000000000000000,
             5'h10, 64'h4000000000000000, 64'hffffffff00000000, 4'h1, 1'b0);
    run_case(129, "vector_div_e64_flip0_mask0", DIV, FP64, 1, 4'h0,
             64'h4018000000000000, 64'h4000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(130, "vector_div_e64_flip0_mask1", DIV, FP64, 1, 4'h1,
             64'h4018000000000000, 64'h4000000000000000,
             5'h00, 64'h4008000000000000, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(131, "vector_div_e64_flip0_mask2", DIV, FP64, 1, 4'h2,
             64'h4018000000000000, 64'h4000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(132, "vector_div_e64_flip0_mask3", DIV, FP64, 1, 4'h3,
             64'h4018000000000000, 64'h4000000000000000,
             5'h00, 64'h4008000000000000, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(133, "vector_div_e64_flip0_mask4", DIV, FP64, 1, 4'h4,
             64'h4018000000000000, 64'h4000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(134, "vector_div_e64_flip0_mask5", DIV, FP64, 1, 4'h5,
             64'h4018000000000000, 64'h4000000000000000,
             5'h00, 64'h4008000000000000, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(135, "vector_div_e64_flip0_mask6", DIV, FP64, 1, 4'h6,
             64'h4018000000000000, 64'h4000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(136, "vector_div_e64_flip0_mask7", DIV, FP64, 1, 4'h7,
             64'h4018000000000000, 64'h4000000000000000,
             5'h00, 64'h4008000000000000, 64'hffffffffffffffff, 4'h0, 1'b1);
    run_case(137, "vector_div_e64_flip0_mask8", DIV, FP64, 1, 4'h8,
             64'h4018000000000000, 64'h4000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(138, "vector_div_e64_flip0_mask9", DIV, FP64, 1, 4'h9,
             64'h4018000000000000, 64'h4000000000000000,
             5'h00, 64'h4008000000000000, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(139, "vector_div_e64_flip0_maska", DIV, FP64, 1, 4'ha,
             64'h4018000000000000, 64'h4000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(140, "vector_div_e64_flip0_maskb", DIV, FP64, 1, 4'hb,
             64'h4018000000000000, 64'h4000000000000000,
             5'h00, 64'h4008000000000000, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(141, "vector_div_e64_flip0_maskc", DIV, FP64, 1, 4'hc,
             64'h4018000000000000, 64'h4000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(142, "vector_div_e64_flip0_maskd", DIV, FP64, 1, 4'hd,
             64'h4018000000000000, 64'h4000000000000000,
             5'h00, 64'h4008000000000000, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(143, "vector_div_e64_flip0_maske", DIV, FP64, 1, 4'he,
             64'h4018000000000000, 64'h4000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(144, "vector_div_e64_flip0_maskf", DIV, FP64, 1, 4'hf,
             64'h4018000000000000, 64'h4000000000000000,
             5'h00, 64'h4008000000000000, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(145, "vector_div_e64_flip1_mask0", DIV, FP64, 1, 4'h0,
             64'h3ff0000000000000, 64'h0000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(146, "vector_div_e64_flip1_mask1", DIV, FP64, 1, 4'h1,
             64'h3ff0000000000000, 64'h0000000000000000,
             5'h08, 64'h7ff0000000000000, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(147, "vector_div_e64_flip1_mask2", DIV, FP64, 1, 4'h2,
             64'h3ff0000000000000, 64'h0000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(148, "vector_div_e64_flip1_mask3", DIV, FP64, 1, 4'h3,
             64'h3ff0000000000000, 64'h0000000000000000,
             5'h08, 64'h7ff0000000000000, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(149, "vector_div_e64_flip1_mask4", DIV, FP64, 1, 4'h4,
             64'h3ff0000000000000, 64'h0000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(150, "vector_div_e64_flip1_mask5", DIV, FP64, 1, 4'h5,
             64'h3ff0000000000000, 64'h0000000000000000,
             5'h08, 64'h7ff0000000000000, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(151, "vector_div_e64_flip1_mask6", DIV, FP64, 1, 4'h6,
             64'h3ff0000000000000, 64'h0000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(152, "vector_div_e64_flip1_mask7", DIV, FP64, 1, 4'h7,
             64'h3ff0000000000000, 64'h0000000000000000,
             5'h08, 64'h7ff0000000000000, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(153, "vector_div_e64_flip1_mask8", DIV, FP64, 1, 4'h8,
             64'h3ff0000000000000, 64'h0000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b1);
    run_case(154, "vector_div_e64_flip1_mask9", DIV, FP64, 1, 4'h9,
             64'h3ff0000000000000, 64'h0000000000000000,
             5'h08, 64'h7ff0000000000000, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(155, "vector_div_e64_flip1_maska", DIV, FP64, 1, 4'ha,
             64'h3ff0000000000000, 64'h0000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(156, "vector_div_e64_flip1_maskb", DIV, FP64, 1, 4'hb,
             64'h3ff0000000000000, 64'h0000000000000000,
             5'h08, 64'h7ff0000000000000, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(157, "vector_div_e64_flip1_maskc", DIV, FP64, 1, 4'hc,
             64'h3ff0000000000000, 64'h0000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(158, "vector_div_e64_flip1_maskd", DIV, FP64, 1, 4'hd,
             64'h3ff0000000000000, 64'h0000000000000000,
             5'h08, 64'h7ff0000000000000, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(159, "vector_div_e64_flip1_maske", DIV, FP64, 1, 4'he,
             64'h3ff0000000000000, 64'h0000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(160, "vector_div_e64_flip1_maskf", DIV, FP64, 1, 4'hf,
             64'h3ff0000000000000, 64'h0000000000000000,
             5'h08, 64'h7ff0000000000000, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(161, "vector_sqrt_e64_flip0_mask0", SQRT, FP64, 1, 4'h0,
             64'h4010000000000000, 64'h0000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(162, "vector_sqrt_e64_flip0_mask1", SQRT, FP64, 1, 4'h1,
             64'h4010000000000000, 64'h0000000000000000,
             5'h00, 64'h4000000000000000, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(163, "vector_sqrt_e64_flip0_mask2", SQRT, FP64, 1, 4'h2,
             64'h4010000000000000, 64'h0000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(164, "vector_sqrt_e64_flip0_mask3", SQRT, FP64, 1, 4'h3,
             64'h4010000000000000, 64'h0000000000000000,
             5'h00, 64'h4000000000000000, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(165, "vector_sqrt_e64_flip0_mask4", SQRT, FP64, 1, 4'h4,
             64'h4010000000000000, 64'h0000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(166, "vector_sqrt_e64_flip0_mask5", SQRT, FP64, 1, 4'h5,
             64'h4010000000000000, 64'h0000000000000000,
             5'h00, 64'h4000000000000000, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(167, "vector_sqrt_e64_flip0_mask6", SQRT, FP64, 1, 4'h6,
             64'h4010000000000000, 64'h0000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(168, "vector_sqrt_e64_flip0_mask7", SQRT, FP64, 1, 4'h7,
             64'h4010000000000000, 64'h0000000000000000,
             5'h00, 64'h4000000000000000, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(169, "vector_sqrt_e64_flip0_mask8", SQRT, FP64, 1, 4'h8,
             64'h4010000000000000, 64'h0000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(170, "vector_sqrt_e64_flip0_mask9", SQRT, FP64, 1, 4'h9,
             64'h4010000000000000, 64'h0000000000000000,
             5'h00, 64'h4000000000000000, 64'hffffffffffffffff, 4'h0, 1'b1);
    run_case(171, "vector_sqrt_e64_flip0_maska", SQRT, FP64, 1, 4'ha,
             64'h4010000000000000, 64'h0000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(172, "vector_sqrt_e64_flip0_maskb", SQRT, FP64, 1, 4'hb,
             64'h4010000000000000, 64'h0000000000000000,
             5'h00, 64'h4000000000000000, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(173, "vector_sqrt_e64_flip0_maskc", SQRT, FP64, 1, 4'hc,
             64'h4010000000000000, 64'h0000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(174, "vector_sqrt_e64_flip0_maskd", SQRT, FP64, 1, 4'hd,
             64'h4010000000000000, 64'h0000000000000000,
             5'h00, 64'h4000000000000000, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(175, "vector_sqrt_e64_flip0_maske", SQRT, FP64, 1, 4'he,
             64'h4010000000000000, 64'h0000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(176, "vector_sqrt_e64_flip0_maskf", SQRT, FP64, 1, 4'hf,
             64'h4010000000000000, 64'h0000000000000000,
             5'h00, 64'h4000000000000000, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(177, "vector_sqrt_e64_flip1_mask0", SQRT, FP64, 1, 4'h0,
             64'hbff0000000000000, 64'h0000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(178, "vector_sqrt_e64_flip1_mask1", SQRT, FP64, 1, 4'h1,
             64'hbff0000000000000, 64'h0000000000000000,
             5'h10, 64'h0000000000000000, 64'h0000000000000000, 4'h1, 1'b0);
    run_case(179, "vector_sqrt_e64_flip1_mask2", SQRT, FP64, 1, 4'h2,
             64'hbff0000000000000, 64'h0000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(180, "vector_sqrt_e64_flip1_mask3", SQRT, FP64, 1, 4'h3,
             64'hbff0000000000000, 64'h0000000000000000,
             5'h10, 64'h0000000000000000, 64'h0000000000000000, 4'h1, 1'b0);
    run_case(181, "vector_sqrt_e64_flip1_mask4", SQRT, FP64, 1, 4'h4,
             64'hbff0000000000000, 64'h0000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(182, "vector_sqrt_e64_flip1_mask5", SQRT, FP64, 1, 4'h5,
             64'hbff0000000000000, 64'h0000000000000000,
             5'h10, 64'h0000000000000000, 64'h0000000000000000, 4'h1, 1'b0);
    run_case(183, "vector_sqrt_e64_flip1_mask6", SQRT, FP64, 1, 4'h6,
             64'hbff0000000000000, 64'h0000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(184, "vector_sqrt_e64_flip1_mask7", SQRT, FP64, 1, 4'h7,
             64'hbff0000000000000, 64'h0000000000000000,
             5'h10, 64'h0000000000000000, 64'h0000000000000000, 4'h1, 1'b0);
    run_case(185, "vector_sqrt_e64_flip1_mask8", SQRT, FP64, 1, 4'h8,
             64'hbff0000000000000, 64'h0000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(186, "vector_sqrt_e64_flip1_mask9", SQRT, FP64, 1, 4'h9,
             64'hbff0000000000000, 64'h0000000000000000,
             5'h10, 64'h0000000000000000, 64'h0000000000000000, 4'h1, 1'b0);
    run_case(187, "vector_sqrt_e64_flip1_maska", SQRT, FP64, 1, 4'ha,
             64'hbff0000000000000, 64'h0000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b1);
    run_case(188, "vector_sqrt_e64_flip1_maskb", SQRT, FP64, 1, 4'hb,
             64'hbff0000000000000, 64'h0000000000000000,
             5'h10, 64'h0000000000000000, 64'h0000000000000000, 4'h1, 1'b0);
    run_case(189, "vector_sqrt_e64_flip1_maskc", SQRT, FP64, 1, 4'hc,
             64'hbff0000000000000, 64'h0000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(190, "vector_sqrt_e64_flip1_maskd", SQRT, FP64, 1, 4'hd,
             64'hbff0000000000000, 64'h0000000000000000,
             5'h10, 64'h0000000000000000, 64'h0000000000000000, 4'h1, 1'b0);
    run_case(191, "vector_sqrt_e64_flip1_maske", SQRT, FP64, 1, 4'he,
             64'hbff0000000000000, 64'h0000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(192, "vector_sqrt_e64_flip1_maskf", SQRT, FP64, 1, 4'hf,
             64'hbff0000000000000, 64'h0000000000000000,
             5'h10, 64'h0000000000000000, 64'h0000000000000000, 4'h1, 1'b0);
    run_case(193, "scalar_e16_normal_div_mask0", DIV, FP16, 0, 4'h0,
             64'hffffffffffff4600, 64'hffffffffffff4000,
             5'h00, 64'hffffffffffff4200, 64'hffffffffffff0000, 4'h0, 1'b0);
    run_case(194, "scalar_e16_normal_div_mask1", DIV, FP16, 0, 4'h1,
             64'hffffffffffff4600, 64'hffffffffffff4000,
             5'h00, 64'hffffffffffff4200, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(195, "scalar_e16_normal_div_mask2", DIV, FP16, 0, 4'h2,
             64'hffffffffffff4600, 64'hffffffffffff4000,
             5'h00, 64'hffffffffffff4200, 64'hffffffffffff0000, 4'h0, 1'b0);
    run_case(196, "scalar_e16_normal_div_maskf", DIV, FP16, 0, 4'hf,
             64'hffffffffffff4600, 64'hffffffffffff4000,
             5'h00, 64'hffffffffffff4200, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(197, "scalar_e16_dz_mask0", DIV, FP16, 0, 4'h0,
             64'hffffffffffff3c00, 64'hffffffffffff0000,
             5'h00, 64'hffffffffffff7c00, 64'hffffffffffff0000, 4'h0, 1'b0);
    run_case(198, "scalar_e16_dz_mask1", DIV, FP16, 0, 4'h1,
             64'hffffffffffff3c00, 64'hffffffffffff0000,
             5'h08, 64'hffffffffffff7c00, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(199, "scalar_e16_dz_mask2", DIV, FP16, 0, 4'h2,
             64'hffffffffffff3c00, 64'hffffffffffff0000,
             5'h00, 64'hffffffffffff7c00, 64'hffffffffffff0000, 4'h0, 1'b0);
    run_case(200, "scalar_e16_dz_maskf", DIV, FP16, 0, 4'hf,
             64'hffffffffffff3c00, 64'hffffffffffff0000,
             5'h08, 64'hffffffffffff7c00, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(201, "scalar_e16_normal_sqrt_mask0", SQRT, FP16, 0, 4'h0,
             64'hffffffffffff4400, 64'hffffffffffff0000,
             5'h00, 64'hffffffffffff4000, 64'hffffffffffff0000, 4'h0, 1'b0);
    run_case(202, "scalar_e16_normal_sqrt_mask1", SQRT, FP16, 0, 4'h1,
             64'hffffffffffff4400, 64'hffffffffffff0000,
             5'h00, 64'hffffffffffff4000, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(203, "scalar_e16_normal_sqrt_mask2", SQRT, FP16, 0, 4'h2,
             64'hffffffffffff4400, 64'hffffffffffff0000,
             5'h00, 64'hffffffffffff4000, 64'hffffffffffff0000, 4'h0, 1'b0);
    run_case(204, "scalar_e16_normal_sqrt_maskf", SQRT, FP16, 0, 4'hf,
             64'hffffffffffff4400, 64'hffffffffffff0000,
             5'h00, 64'hffffffffffff4000, 64'hffffffffffffffff, 4'h0, 1'b1);
    run_case(205, "scalar_e16_nv_mask0", SQRT, FP16, 0, 4'h0,
             64'hffffffffffffbc00, 64'hffffffffffff0000,
             5'h00, 64'hffffffffffff0000, 64'hffffffffffff0000, 4'h0, 1'b0);
    run_case(206, "scalar_e16_nv_mask1", SQRT, FP16, 0, 4'h1,
             64'hffffffffffffbc00, 64'hffffffffffff0000,
             5'h10, 64'hffffffffffff0000, 64'hffffffffffff0000, 4'h1, 1'b0);
    run_case(207, "scalar_e16_nv_mask2", SQRT, FP16, 0, 4'h2,
             64'hffffffffffffbc00, 64'hffffffffffff0000,
             5'h00, 64'hffffffffffff0000, 64'hffffffffffff0000, 4'h0, 1'b0);
    run_case(208, "scalar_e16_nv_maskf", SQRT, FP16, 0, 4'hf,
             64'hffffffffffffbc00, 64'hffffffffffff0000,
             5'h10, 64'hffffffffffff0000, 64'hffffffffffff0000, 4'h1, 1'b0);
    run_case(209, "scalar_e32_normal_div_mask0", DIV, FP32, 0, 4'h0,
             64'hffffffff40c00000, 64'hffffffff40000000,
             5'h00, 64'hffffffff40400000, 64'hffffffff00000000, 4'h0, 1'b0);
    run_case(210, "scalar_e32_normal_div_mask1", DIV, FP32, 0, 4'h1,
             64'hffffffff40c00000, 64'hffffffff40000000,
             5'h00, 64'hffffffff40400000, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(211, "scalar_e32_normal_div_mask2", DIV, FP32, 0, 4'h2,
             64'hffffffff40c00000, 64'hffffffff40000000,
             5'h00, 64'hffffffff40400000, 64'hffffffff00000000, 4'h0, 1'b0);
    run_case(212, "scalar_e32_normal_div_maskf", DIV, FP32, 0, 4'hf,
             64'hffffffff40c00000, 64'hffffffff40000000,
             5'h00, 64'hffffffff40400000, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(213, "scalar_e32_dz_mask0", DIV, FP32, 0, 4'h0,
             64'hffffffff3f800000, 64'hffffffff00000000,
             5'h00, 64'hffffffff7f800000, 64'hffffffff00000000, 4'h0, 1'b0);
    run_case(214, "scalar_e32_dz_mask1", DIV, FP32, 0, 4'h1,
             64'hffffffff3f800000, 64'hffffffff00000000,
             5'h08, 64'hffffffff7f800000, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(215, "scalar_e32_dz_mask2", DIV, FP32, 0, 4'h2,
             64'hffffffff3f800000, 64'hffffffff00000000,
             5'h00, 64'hffffffff7f800000, 64'hffffffff00000000, 4'h0, 1'b0);
    run_case(216, "scalar_e32_dz_maskf", DIV, FP32, 0, 4'hf,
             64'hffffffff3f800000, 64'hffffffff00000000,
             5'h08, 64'hffffffff7f800000, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(217, "scalar_e32_normal_sqrt_mask0", SQRT, FP32, 0, 4'h0,
             64'hffffffff40800000, 64'hffffffff00000000,
             5'h00, 64'hffffffff40000000, 64'hffffffff00000000, 4'h0, 1'b0);
    run_case(218, "scalar_e32_normal_sqrt_mask1", SQRT, FP32, 0, 4'h1,
             64'hffffffff40800000, 64'hffffffff00000000,
             5'h00, 64'hffffffff40000000, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(219, "scalar_e32_normal_sqrt_mask2", SQRT, FP32, 0, 4'h2,
             64'hffffffff40800000, 64'hffffffff00000000,
             5'h00, 64'hffffffff40000000, 64'hffffffff00000000, 4'h0, 1'b0);
    run_case(220, "scalar_e32_normal_sqrt_maskf", SQRT, FP32, 0, 4'hf,
             64'hffffffff40800000, 64'hffffffff00000000,
             5'h00, 64'hffffffff40000000, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(221, "scalar_e32_nv_mask0", SQRT, FP32, 0, 4'h0,
             64'hffffffffbf800000, 64'hffffffff00000000,
             5'h00, 64'hffffffff00000000, 64'hffffffff00000000, 4'h0, 1'b1);
    run_case(222, "scalar_e32_nv_mask1", SQRT, FP32, 0, 4'h1,
             64'hffffffffbf800000, 64'hffffffff00000000,
             5'h10, 64'hffffffff00000000, 64'hffffffff00000000, 4'h1, 1'b0);
    run_case(223, "scalar_e32_nv_mask2", SQRT, FP32, 0, 4'h2,
             64'hffffffffbf800000, 64'hffffffff00000000,
             5'h00, 64'hffffffff00000000, 64'hffffffff00000000, 4'h0, 1'b0);
    run_case(224, "scalar_e32_nv_maskf", SQRT, FP32, 0, 4'hf,
             64'hffffffffbf800000, 64'hffffffff00000000,
             5'h10, 64'hffffffff00000000, 64'hffffffff00000000, 4'h1, 1'b0);
    run_case(225, "scalar_e64_normal_div_mask0", DIV, FP64, 0, 4'h0,
             64'h4018000000000000, 64'h4000000000000000,
             5'h00, 64'h4008000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(226, "scalar_e64_normal_div_mask1", DIV, FP64, 0, 4'h1,
             64'h4018000000000000, 64'h4000000000000000,
             5'h00, 64'h4008000000000000, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(227, "scalar_e64_normal_div_mask2", DIV, FP64, 0, 4'h2,
             64'h4018000000000000, 64'h4000000000000000,
             5'h00, 64'h4008000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(228, "scalar_e64_normal_div_maskf", DIV, FP64, 0, 4'hf,
             64'h4018000000000000, 64'h4000000000000000,
             5'h00, 64'h4008000000000000, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(229, "scalar_e64_dz_mask0", DIV, FP64, 0, 4'h0,
             64'h3ff0000000000000, 64'h0000000000000000,
             5'h00, 64'h7ff0000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(230, "scalar_e64_dz_mask1", DIV, FP64, 0, 4'h1,
             64'h3ff0000000000000, 64'h0000000000000000,
             5'h08, 64'h7ff0000000000000, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(231, "scalar_e64_dz_mask2", DIV, FP64, 0, 4'h2,
             64'h3ff0000000000000, 64'h0000000000000000,
             5'h00, 64'h7ff0000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(232, "scalar_e64_dz_maskf", DIV, FP64, 0, 4'hf,
             64'h3ff0000000000000, 64'h0000000000000000,
             5'h08, 64'h7ff0000000000000, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(233, "scalar_e64_normal_sqrt_mask0", SQRT, FP64, 0, 4'h0,
             64'h4010000000000000, 64'h0000000000000000,
             5'h00, 64'h4000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(234, "scalar_e64_normal_sqrt_mask1", SQRT, FP64, 0, 4'h1,
             64'h4010000000000000, 64'h0000000000000000,
             5'h00, 64'h4000000000000000, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(235, "scalar_e64_normal_sqrt_mask2", SQRT, FP64, 0, 4'h2,
             64'h4010000000000000, 64'h0000000000000000,
             5'h00, 64'h4000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(236, "scalar_e64_normal_sqrt_maskf", SQRT, FP64, 0, 4'hf,
             64'h4010000000000000, 64'h0000000000000000,
             5'h00, 64'h4000000000000000, 64'hffffffffffffffff, 4'h0, 1'b0);
    run_case(237, "scalar_e64_nv_mask0", SQRT, FP64, 0, 4'h0,
             64'hbff0000000000000, 64'h0000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(238, "scalar_e64_nv_mask1", SQRT, FP64, 0, 4'h1,
             64'hbff0000000000000, 64'h0000000000000000,
             5'h10, 64'h0000000000000000, 64'h0000000000000000, 4'h1, 1'b1);
    run_case(239, "scalar_e64_nv_mask2", SQRT, FP64, 0, 4'h2,
             64'hbff0000000000000, 64'h0000000000000000,
             5'h00, 64'h0000000000000000, 64'h0000000000000000, 4'h0, 1'b0);
    run_case(240, "scalar_e64_nv_maskf", SQRT, FP64, 0, 4'hf,
             64'hbff0000000000000, 64'h0000000000000000,
             5'h10, 64'h0000000000000000, 64'h0000000000000000, 4'h1, 1'b0);
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
    $display("PASS: all 240 transactions matched their expected results and flags");
    $finish;
  end
endmodule
