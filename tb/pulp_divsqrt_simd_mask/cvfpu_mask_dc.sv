// Copyright 2019 ETH Zurich and University of Bologna.
//
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License. You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// SPDX-License-Identifier: SHL-0.51

// Author: Stefan Mach <smach@iis.ee.ethz.ch>

module cvfpu_mask_dc import fpnew_pkg::*; (

  input logic                               clk_i,
  input logic                               rst_ni,
  input logic [31:0]                        hart_id_i,
  // Input signals
  input logic [2:0][63:0] operands_i,
  input fpnew_pkg::roundmode_e              rnd_mode_i,
  input fpnew_pkg::operation_e              op_i,
  input logic                               op_mod_i,
  input fpnew_pkg::fp_format_e              src_fmt_i,
  input fpnew_pkg::fp_format_e              dst_fmt_i,
  input fpnew_pkg::int_format_e             int_fmt_i,
  input logic                               vectorial_op_i,
  input logic [7:0]                             tag_i,
  input logic [3:0]                            simd_mask_i,
  input  logic [0:0]             pace_param_i,
  input  fpnew_pkg::pace_mode_t             pace_mode_i,
  // Input Handshake
  input  logic                              in_valid_i,
  output logic                              in_ready_o,
  input  logic                              flush_i,
  // Output signals
  output logic [63:0]                  result_o,
  output fpnew_pkg::status_t                status_o,
  output logic [7:0]                            tag_o,
  // Output handshake
  output logic                              out_valid_o,
  input  logic                              out_ready_i,
  // Indication of valid data in flight
  output logic                              busy_o
);
  localparam fpu_features_t Features = '{
      Width: 64,
      EnableVectors: 1'b1,
      EnableNanBox: 1'b1,
      FpFmtMask: 9'b111000000, // FP32, FP64 and FP16; indices ascend from zero
      default: '0
  };
  function automatic fpu_implementation_t configured_implementation();
    fpu_implementation_t cfg = '0;
    for (int unsigned g = 0; g < NUM_OPGROUPS; g++) begin
      for (int unsigned f = 0; f < NUM_FP_FORMATS; f++) begin
        cfg.PipeRegs[g][f] = 1;
        cfg.UnitTypes[g][f] = (g == int'(DIVSQRT)) ? MERGED : DISABLED;
      end
    end
    cfg.PipeConfig = AFTER;
    return cfg;
  endfunction
  localparam fpu_implementation_t Implementation = configured_implementation();

  fpnew_top #(.Features(Features),.Implementation(Implementation),.DivSqrtSel(PULP),.TagType(logic [7:0]),.EnableSIMDMask(1'b1)) dut (.*);
endmodule
