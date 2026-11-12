// SPDX-License-Identifier: Apache-2.0
// Per-burst AXI4 latency monitor of the TV SoC IP testbenches, included at
// module scope after the m_* wires (`SOC_SS_AXI_WIRES). Prints one line per
// burst in the regression suite's latency format:
//   LAT <master> <slave> R|W <cycles>
// R: AR handshake (ARVALID first seen) to the RLAST beat; W: AWVALID first
// seen to the B handshake. Set lat_master / lat_slave before traffic starts.
// Counts and the worst case are kept for the TB summary.
  string lat_master = "ip", lat_slave = "dram";
  int    lat_rd_n = 0, lat_wr_n = 0, lat_rd_max = 0, lat_wr_max = 0;
  longint lat_rd_sum = 0, lat_wr_sum = 0;
  int    lat_rd_t = -1, lat_wr_t = -1, lat_now = 0;
  always @(posedge clk) begin
    lat_now++;
    if (!rst_n) begin
      lat_rd_t = -1; lat_wr_t = -1;
    end else begin
      if (m_arvalid && lat_rd_t < 0) lat_rd_t = lat_now;
      if (m_awvalid && lat_wr_t < 0) lat_wr_t = lat_now;
      if (m_rvalid && m_rready && m_rlast && lat_rd_t >= 0) begin
        $display("LAT %s %s R %0d", lat_master, lat_slave, lat_now - lat_rd_t);
        lat_rd_n++; lat_rd_sum += lat_now - lat_rd_t;
        if (lat_now - lat_rd_t > lat_rd_max) lat_rd_max = lat_now - lat_rd_t;
        lat_rd_t = m_arvalid ? lat_now : -1;
      end
      if (m_bvalid && m_bready && lat_wr_t >= 0) begin
        $display("LAT %s %s W %0d", lat_master, lat_slave, lat_now - lat_wr_t);
        lat_wr_n++; lat_wr_sum += lat_now - lat_wr_t;
        if (lat_now - lat_wr_t > lat_wr_max) lat_wr_max = lat_now - lat_wr_t;
        lat_wr_t = m_awvalid ? lat_now : -1;
      end
    end
  end
  task automatic lat_summary;
    $display("LATSUM %s %s R n=%0d avg=%0d max=%0d W n=%0d avg=%0d max=%0d", lat_master, lat_slave,
             lat_rd_n, lat_rd_n ? int'(lat_rd_sum / lat_rd_n) : 0, lat_rd_max,
             lat_wr_n, lat_wr_n ? int'(lat_wr_sum / lat_wr_n) : 0, lat_wr_max);
  endtask
