//=============================================================================
// msi_pkg.sv
// Common parameters and typedefs for the dual-core MSI cache coherence system
//=============================================================================
package msi_pkg;

  parameter int ADDR_WIDTH     = 8;
  parameter int DATA_WIDTH     = 32;
  parameter int LINE_IDX_BITS  = 2;                       // 2 bits -> 4 lines/sets
  parameter int NUM_LINES      = 1 << LINE_IDX_BITS;
  parameter int TAG_WIDTH      = ADDR_WIDTH - LINE_IDX_BITS;

  // ---------------------------------------------------------------------
  // MSI cache line states
  // ---------------------------------------------------------------------
  typedef enum logic [1:0] {
    I_STATE = 2'b00,   // Invalid
    S_STATE = 2'b01,   // Shared  (clean, possibly resident in other caches)
    M_STATE = 2'b10    // Modified (dirty, exclusively owned)
  } msi_state_t;

  // ---------------------------------------------------------------------
  // Bus transaction commands (snooping bus)
  // ---------------------------------------------------------------------
  typedef enum logic [2:0] {
    CMD_NONE = 3'b000,
    CMD_RD   = 3'b001,   // BusRd   : read miss  (I -> S)
    CMD_RDX  = 3'b010,   // BusRdX  : write miss (I -> M), invalidates sharers
    CMD_UPGR = 3'b011,   // BusUpgr : write hit on S line (S -> M), invalidates sharers
    CMD_WB   = 3'b100    // BusWB   : silent writeback of a dirty (M) line being evicted
  } bus_cmd_t;

  // ---------------------------------------------------------------------
  // Processor-side operation
  // ---------------------------------------------------------------------
  typedef enum logic {
    PR_RD = 1'b0,
    PR_WR = 1'b1
  } pr_op_t;

endpackage : msi_pkg
