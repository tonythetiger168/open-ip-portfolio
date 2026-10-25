// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// MIPI_SoundWire_top v2.0: SoundWire-style two-wire audio bus interface
// (manager or peripheral) with control commands and one data port each way
// ----------------------------------------------------------------------------
//  - CLOCK from the manager, DATA multi-drop, double data rate: every CLOCK
//    edge ends one bit and starts the next (a bit lasts cfg_div + 1 PCLK on
//    the manager, cfg_div >= 11). NRZI: a 1 toggles DATA, a 0 keeps it. A
//    bus keeper holds DATA between drivers. Bits are sampled at the edge
//    that ends them (a peripheral sees CLOCK through two flops). The
//    manager drives its bits from mid-bit to the end of the bit; a
//    peripheral drives from two PCLK after it sees the starting edge to
//    two PCLK after it sees the ending edge.
//  - Frame: 48 rows x cfg_cols columns (2, 4, 8, 16) sent row by row.
//    Column 0 carries the 48-bit control word, MSB in row 0:
//      [47:45] opcode (000 PING, 010 READ, 011 WRITE), [44:41] device,
//      [40:25] register address (PING: two status bits per device 1..8,
//      device 1 in [40:39]), [24:17] data (READ: driven by the device),
//      [16] parity (even, over [47:25], and [24:17] for a WRITE), [15] ACK
//      and [14] NAK (driven by the addressed device), [13:6] static sync
//      8'hB1, [5:2] dynamic sync (PRBS x^4 + x^3 + 1), [1:0] 0.
//  - Manager: one host command per frame (cmd_*), a PING otherwise;
//    rsp_* after the ACK / NAK bits of a host command; ping_status after
//    every PING.
//  - Peripheral (device number cfg_dev): finds the static sync, locks after
//    seeing it in two frames in a row, then checks static and dynamic sync
//    every frame and drops the lock after two bad frames in a row (lost_sync);
//    the expected dynamic sync steps on over a bad frame.
//    READ: reg_re with reg_addr, reg_rdata (combinational) sent in the data
//    bits; WRITE: reg_we once the parity bit checks; ACK, or NAK and
//    par_err on bad parity. PING: dev_status in its slot (devices 1..8).
//  - Data port: column cfg_tx_col (rows 0..31) carries tx_data, MSB first,
//    taken at the column's first bit (tx_underrun and zeros without
//    tx_valid); column cfg_rx_col is delivered as rx_data after row 31.
//    A column of 0 or not below the column count is off. The manager's
//    columns run from the start; a peripheral's while locked.
//  Not implemented: bank switching and other frame shapes, multiple data
//  ports and sample intervals, interrupts / alerts beyond PING status,
//  enumeration, clock stop.
// ============================================================================
module MIPI_SoundWire_top (
  input  logic        clk,
  input  logic        rst_n,
  // configuration
  input  logic        cfg_manager,
  input  logic [4:0]  cfg_div,
  input  logic [1:0]  cfg_cols,          // 2, 4, 8, 16 columns
  input  logic [3:0]  cfg_dev,
  input  logic [3:0]  cfg_tx_col,
  input  logic [3:0]  cfg_rx_col,
  // bus
  output logic        sw_clk_o,
  output logic        sw_clk_oe,
  input  logic        sw_clk_i,
  output logic        sw_dat_o,
  output logic        sw_dat_oe,
  input  logic        sw_dat_i,
  // manager commands
  input  logic        cmd_valid,
  output logic        cmd_ready,
  input  logic [1:0]  cmd_op,            // 0 PING, 2 READ, 3 WRITE (1 reserved)
  input  logic [3:0]  cmd_dev,
  input  logic [15:0] cmd_addr,
  input  logic [7:0]  cmd_wdata,
  output logic        rsp_valid,
  output logic        rsp_ack,
  output logic        rsp_nak,
  output logic [7:0]  rsp_rdata,
  output logic [15:0] ping_status,
  // peripheral registers
  input  logic [1:0]  dev_status,
  output logic        reg_we,
  output logic        reg_re,
  output logic [15:0] reg_addr,
  output logic [7:0]  reg_wdata,
  input  logic [7:0]  reg_rdata,
  // data port
  input  logic        tx_valid,
  output logic        tx_ready,
  input  logic [31:0] tx_data,
  output logic        tx_underrun,
  output logic        rx_valid,
  output logic [31:0] rx_data,
  // status
  output logic        locked,
  output logic        lost_sync,
  output logic        par_err
);
  wire [2:0] lastc_hi = (3'd1 << cfg_cols) - 3'd1;   // last column is {lastc_hi, 1}
  wire       tx_on = cfg_tx_col != 4'd0 && cfg_tx_col <= {lastc_hi, 1'b1};
  wire       rx_on = cfg_rx_col != 4'd0 && cfg_rx_col <= {lastc_hi, 1'b1};
  assign sw_clk_oe = cfg_manager;

  // ---------------- edges ----------------
  logic [4:0]  ph;                       // manager: PCLK since the edge
  logic [1:0]  cs;
  logic        cq, edge_p, drv_p;        // peripheral: edge seen, drive one PCLK later
  wire         m_edge = cfg_manager && ph == cfg_div;
  wire         m_mid = cfg_manager && ph == {1'b0, cfg_div[4:1]};
  wire         edge_now = cfg_manager ? m_edge : edge_p;

  // ---------------- position, sync ----------------
  typedef enum logic [1:0] {Y_HUNT, Y_CHECK, Y_LOCK} yst_t;
  yst_t        ys;
  logic [5:0]  row;                      // bit on the bus
  logic [3:0]  col;
  logic        lvl;                      // level of the bit that ended last
  logic [111:0] hs;                      // decoded bits before the newest
  logic [3:0]  dyn, dyn_m;               // dynamic sync: last seen / manager's
  logic        dyn_ok, s_ok, miss;
  logic [46:16] cw;                      // manager: command fields of this frame's control word
  logic [47:15] rw;                      // control word bits received this frame (sync fields from hs)
  logic        f_host;                   // manager: this frame carries a host command
  // command holding register
  logic        hold;
  logic [1:0]  h_op;
  logic [3:0]  h_dev;
  logic [15:0] h_addr;
  logic [7:0]  h_wd;
  // data port
  logic [30:0] tsh;
  logic [30:0] rsh;
  // next bit to drive
  logic        nx_own, nx_bit, nx_rd;
  logic [2:0]  nx_ri;

  assign cmd_ready = !hold;
  assign locked = ys == Y_LOCK;

  // static sync B1 MSB first at a stride of the column count, newest bit last
  function automatic logic sync_at(input logic [112:0] h, input logic [1:0] c);
    logic [7:0] v;
    for (int i = 0; i < 8; i++)
      case (c)
        2'd0: v[i] = h[2 * i];
        2'd1: v[i] = h[4 * i];
        2'd2: v[i] = h[8 * i];
        default: v[i] = h[16 * i];
      endcase
    sync_at = v == 8'hB1;
  endfunction
  function automatic logic [3:0] dyn_at(input logic [112:0] h, input logic [1:0] c);
    logic [3:0] v;
    for (int i = 0; i < 4; i++)
      case (c)
        2'd0: v[i] = h[2 * i];
        2'd1: v[i] = h[4 * i];
        2'd2: v[i] = h[8 * i];
        default: v[i] = h[16 * i];
      endcase
    dyn_at = v;
  endfunction
  function automatic logic [3:0] prbs(input logic [3:0] d);
    prbs = {d[2:0], d[3] ^ d[2]};
  endfunction

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      ph <= '0; cs <= '0; cq <= 1'b0; edge_p <= 1'b0; drv_p <= 1'b0; sw_clk_o <= 1'b0;
      ys <= Y_HUNT; row <= 6'd47; col <= '0; lvl <= 1'b0; hs <= '0; dyn <= '0; dyn_m <= 4'hF;
      dyn_ok <= 1'b0; s_ok <= 1'b0; miss <= 1'b0; cw <= '0; rw <= '0;
      f_host <= 1'b0; hold <= 1'b0; h_op <= '0; h_dev <= '0; h_addr <= '0; h_wd <= '0;
      tsh <= '0; rsh <= '0; nx_own <= 1'b0; nx_bit <= 1'b0; nx_rd <= 1'b0; nx_ri <= '0;
      sw_dat_o <= 1'b0; sw_dat_oe <= 1'b0; rsp_valid <= 1'b0; rsp_ack <= 1'b0; rsp_nak <= 1'b0;
      rsp_rdata <= '0; ping_status <= '0; reg_we <= 1'b0; reg_re <= 1'b0; reg_addr <= '0; reg_wdata <= '0;
      tx_ready <= 1'b0; tx_underrun <= 1'b0; rx_valid <= 1'b0; rx_data <= '0; lost_sync <= 1'b0; par_err <= 1'b0;
    end else begin
      rsp_valid <= 1'b0; reg_we <= 1'b0; reg_re <= 1'b0; tx_ready <= 1'b0; tx_underrun <= 1'b0;
      rx_valid <= 1'b0; lost_sync <= 1'b0; par_err <= 1'b0;
      // CLOCK
      cs <= {cs[0], sw_clk_i};
      cq <= cs[1];
      edge_p <= !cfg_manager && cs[1] != cq;
      drv_p <= edge_p;
      if (cfg_manager) begin
        ph <= m_edge ? 5'd0 : ph + 5'd1;
        if (m_edge) sw_clk_o <= !sw_clk_o;
        ys <= Y_LOCK;
      end else ph <= '0;
      if (cmd_valid && !hold) begin hold <= 1'b1; h_op <= cmd_op; h_dev <= cmd_dev; h_addr <= cmd_addr; h_wd <= cmd_wdata; end

      // ---- drive: manager at mid-bit, peripheral one PCLK after its edge
      if (cfg_manager ? m_mid : drv_p) begin
        sw_dat_oe <= nx_own;
        if (nx_own) sw_dat_o <= lvl ^ (nx_rd ? reg_rdata[nx_ri] : nx_bit);
      end

      // ---- edge: the bit (row, col) ends
      if (edge_now) begin : b_edge
        logic b, own, bit_v, rdb, first;
        logic [5:0]  r2;
        logic [3:0]  c2;
        logic [5:0]  ci;                 // control bit index of the ended bit
        logic [47:0] w;
        logic [2:0]  ri;
        b = sw_dat_i ^ lvl;
        lvl <= sw_dat_i;
        sw_dat_oe <= 1'b0;
        hs <= {hs[110:0], b};
        ci = 6'd47 - row;
        w = {rw, 15'd0};
        if (col == 4'd0) begin
          w[ci] = b;
          rw <= w[47:15];
        end
        // -- sync (peripheral)
        if (!cfg_manager) begin
          if (ys == Y_HUNT) begin
            if (sync_at({hs, b}, cfg_cols)) begin ys <= Y_CHECK; miss <= 1'b0; s_ok <= 1'b1; dyn_ok <= 1'b0; end
          end else if (col == 4'd0 && ci == 6'd6) s_ok <= sync_at({hs, b}, cfg_cols);
          else if (col == 4'd0 && ci == 6'd2) begin : b_dyn
            logic [3:0] d;
            logic       ok;
            d = dyn_at({hs, b}, cfg_cols);
            ok = s_ok && (ys != Y_LOCK || d == prbs(dyn));
            dyn <= ys != Y_LOCK || ok ? d : prbs(dyn);     // a bad frame keeps the sequence
            if (ys == Y_CHECK) begin
              if (!s_ok) ys <= Y_HUNT;
              else if (dyn_ok) ys <= Y_LOCK;           // second frame in a row
              dyn_ok <= s_ok;
            end else if (ok) miss <= 1'b0;
            else if (!miss) miss <= 1'b1;
            else begin ys <= Y_HUNT; lost_sync <= 1'b1; miss <= 1'b0; dyn_ok <= 1'b0; end
          end
        end
        // -- control word fields
        if (col == 4'd0 && ys != Y_HUNT) begin
          // peripheral: the address is complete
          if (ci == 6'd25 && !cfg_manager && ys == Y_LOCK && w[47:45] == 3'b010 && w[44:41] == cfg_dev) begin
            reg_re <= 1'b1; reg_addr <= w[40:25];
          end
          if (ci == 6'd16 && !cfg_manager && ys == Y_LOCK && w[47:46] == 2'b01 && w[44:41] == cfg_dev) begin
            // even parity over [47:25], and the data of a WRITE
            if ((^w[47:25]) ^ (w[45] ? ^w[24:17] : 1'b0) ^ b) par_err <= 1'b1;
            else if (w[45]) begin reg_we <= 1'b1; reg_addr <= w[40:25]; reg_wdata <= w[24:17]; end
          end
          if (cfg_manager && ci == 6'd25 && w[47:45] == 3'b000)
            ping_status <= w[40:25];
          if (cfg_manager && ci == 6'd14 && f_host) begin
            rsp_valid <= 1'b1; rsp_ack <= w[15]; rsp_nak <= b; rsp_rdata <= w[24:17];
          end
        end
        // -- data port receive
        if (rx_on && col == cfg_rx_col && row < 6'd32 && ys == Y_LOCK) begin
          rsh <= {rsh[29:0], b};
          if (row == 6'd31) begin rx_valid <= 1'b1; rx_data <= {rsh[30:0], b}; end
        end

        // -- next bit
        if (ys == Y_HUNT && !cfg_manager && sync_at({hs, b}, cfg_cols)) begin
          r2 = 6'd41; c2 = 4'd1;                    // the ended bit was control bit 6
        end else if (col == {lastc_hi, 1'b1}) begin
          c2 = 4'd0; r2 = row == 6'd47 ? 6'd0 : row + 6'd1;
        end else begin
          c2 = col + 4'd1; r2 = row;
        end
        row <= r2; col <= c2;
        first = r2 == 6'd0 && c2 == 4'd0;
        if (first) rw <= '0;
        // manager: the control word of a new frame
        if (cfg_manager && first) begin : b_cw
          logic [1:0]  op;
          logic [3:0]  dv;
          logic [15:0] ad;
          logic [7:0]  wd;
          op = hold ? h_op : 2'd0; dv = hold ? h_dev : 4'd0; ad = hold ? h_addr : 16'd0;
          wd = hold && h_op == 2'd3 ? h_wd : 8'd0;
          f_host <= hold;
          if (hold) hold <= 1'b0;                 // a command taken this clock waits
          dyn_m <= prbs(dyn_m);
          w = {1'b0, op, dv, ad, wd, 1'b0, 2'b00, 8'hB1, prbs(dyn_m), 2'b00};
          w[16] = (^w[47:25]) ^ (op == 2'd3 ? ^wd : 1'b0);
          cw <= w[46:16];
        end else w = {1'b0, cw, 2'b00, 8'hB1, dyn_m, 2'b00};
        // owner and value of the next bit
        own = 1'b0; bit_v = 1'b0; rdb = 1'b0; ri = '0;
        if (c2 == 4'd0) begin : b_ctl
          logic [5:0] ni;
          ni = 6'd47 - r2;
          if (cfg_manager) begin
            // the manager leaves READ data, ACK / NAK and PING slots to the devices
            own = !((ni <= 6'd24 && ni >= 6'd17 && w[47:45] == 3'b010) || ni == 6'd15 || ni == 6'd14 ||
                    (ni <= 6'd40 && ni >= 6'd25 && w[47:45] == 3'b000));
            bit_v = w[ni];
          end else if (ys == Y_LOCK) begin : b_dev
            logic [47:16] v;
            logic         me, pok;
            v = rw[47:16];
            me = v[44:41] == cfg_dev;
            pok = !((^v[47:25]) ^ (v[45] ? ^v[24:17] : 1'b0) ^ v[16]);
            if (v[47:45] == 3'b010 && me && ni <= 6'd24 && ni >= 6'd17) begin
              own = 1'b1; rdb = 1'b1; ri = ni[2:0] - 3'd1;
            end else if (v[47:46] == 2'b01 && me && ni == 6'd15) begin own = 1'b1; bit_v = pok; end
            else if (v[47:46] == 2'b01 && me && ni == 6'd14) begin own = 1'b1; bit_v = !pok; end
            else if (v[47:45] == 3'b000 && cfg_dev != 4'd0 && cfg_dev <= 4'd8 &&
                     (ni == 6'd41 - {cfg_dev, 1'b0} || ni == 6'd42 - {cfg_dev, 1'b0})) begin
              own = 1'b1; bit_v = ni[0] ? dev_status[0] : dev_status[1];
            end
          end
        end else if (tx_on && c2 == cfg_tx_col && r2 < 6'd32 && ys == Y_LOCK) begin : b_tx
          logic [31:0] t;
          t = {tsh, 1'b0};
          if (r2 == 6'd0) begin
            t = tx_valid ? tx_data : 32'd0;
            if (tx_valid) tx_ready <= 1'b1; else tx_underrun <= 1'b1;
          end
          own = 1'b1; bit_v = t[31];
          tsh <= t[30:0];
        end
        nx_own <= own; nx_bit <= bit_v; nx_rd <= rdb; nx_ri <= ri;
      end
    end
endmodule
