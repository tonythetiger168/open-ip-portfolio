// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// ETHERCAT_top v1.0: EtherCAT slave controller (ESC) frame processing unit:
// datagrams are executed on the fly as the frame passes from rx to tx
// ----------------------------------------------------------------------------
//  - Byte stream: rx_dv / rx_d carry one octet per clock from the
//    destination MAC address to the FCS (no preamble); tx_dv / tx_d give the
//    same frame 5 clocks later. A frame ends when rx_dv falls; the 4 octets
//    before that are its FCS. The FCS is recomputed over the processed frame
//    (CRC-32); if the received FCS was wrong, the new one is inverted so the
//    next station sees the error too. Frames of fewer than 5 octets pass
//    unchanged.
//  - EtherCAT frames: EtherType 0x88A4 (octets 12..13), EtherCAT header
//    (2 octets, little endian: length[10:0], type[15:12]; type 1 =
//    datagrams). Each datagram: cmd, idx, address (4 octets: ADP, ADO or
//    a 32-bit logical address), length (2 octets: len[10:0], M[15] = more
//    datagrams follow), IRQ (2), len data octets, WKC (2). All fields are
//    little endian. Other frames pass unchanged.
//  - Commands: 0 NOP; 1..3 APRD / APWR / APRW (addressed when ADP = 0,
//    ADP + 1 forwarded); 4..6 FPRD / FPWR / FPRW (ADP = station address);
//    7..9 BRD / BWR / BRW (all; ADP + 1; BRD / BRW read as data OR memory);
//    10..12 LRD / LWR / LRW (logical, through the FMMUs); 13 ARMW (ADP = 0
//    reads, the others write; ADP + 1); 14 FRMW (station address reads,
//    the others write); others act as NOP.
//  - Working counter: + 1 for a read, + 1 for a write, + 3 for a read /
//    write (+ 1 read, + 2 write); a physical datagram counts when addressed,
//    a logical one per kind when at least one of its octets maps.
//  - Physical memory (ADO + i): 0x0010..0x0011 station address,
//    0x0600..0x061F FMMU 0 / 1 (16 octets each: logical start 0..3,
//    length 4..5, physical start 8..9, type 0x0B (bit 0 read, bit 1 write),
//    activate 0x0C bit 0; the other octets are stored only),
//    0x1000..0x13FF 1 KB process RAM; other addresses read 0 and ignore
//    writes. A logical octet maps through the first active FMMU whose
//    range [start, start + length) holds it (octet granular).
//  - Writes take effect as the octets pass (no commit on a good FCS).
//  - Host port: host_rd gives host_rdata the clock after; a host write to
//    the octet the frame writes in the same clock is dropped.
//  - fr_done at the end of every frame with fr_fcs_ok, fr_ecat (EtherCAT
//    datagram frame), fr_dgrams (datagrams processed) and fr_wkc (the sum
//    of this station's working counter increments, saturating at 255).
//  - Not implemented: distributed clocks, SyncManagers, AL state machine,
//    EEPROM / SII, mailbox, bit-granular FMMUs, VLAN tags, port forwarding
//    (one processing direction).
// ============================================================================
`timescale 1ns/1ps
module ETHERCAT_top (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        rx_dv,
  input  logic [7:0]  rx_d,
  output logic        tx_dv,
  output logic [7:0]  tx_d,
  input  logic        host_rd,
  input  logic        host_wr,
  input  logic [15:0] host_addr,
  input  logic [7:0]  host_wdata,
  output logic [7:0]  host_rdata,
  output logic        fr_done,
  output logic        fr_fcs_ok,
  output logic        fr_ecat,
  output logic [7:0]  fr_dgrams,
  output logic [7:0]  fr_wkc
);
  // ---------------- CRC-32 (reflected, 0xEDB88320) ----------------
  function automatic logic [31:0] crc8(input logic [31:0] c, input logic [7:0] d);
    logic [31:0] x;
    x = c ^ {24'd0, d};
    for (int i = 0; i < 8; i++) x = x[0] ? (x >> 1) ^ 32'hEDB88320 : x >> 1;
    crc8 = x;
  endfunction

  // ---------------- memory ----------------
  logic [7:0]   ram [0:1023];
  logic [15:0]  sta;                       // station address
  logic [255:0] fmv;                       // FMMU 0 / 1 octets, octet k at [8k +: 8]
  logic         m_we;
  logic [15:0]  m_wa, m_ra;
  logic [7:0]   m_wd, m_rd;
  wire  m_ram  = m_ra[15:10] == 6'b000100;
  wire  m_sta  = m_ra[15:1] == 15'h0008;
  wire  m_fm   = m_ra[15:5] == 11'h030;
  wire  w_ram  = m_wa[15:10] == 6'b000100;
  wire  w_sta  = m_wa[15:1] == 15'h0008;
  wire  w_fm   = m_wa[15:5] == 11'h030;
  wire  h_ram  = host_addr[15:10] == 6'b000100;
  wire  h_sta  = host_addr[15:1] == 15'h0008;
  wire  h_fm   = host_addr[15:5] == 11'h030;
  wire  h_we   = host_wr && !(m_we && m_wa == host_addr);
  always_comb begin
    m_rd = 8'h00;
    if (m_ram) m_rd = ram[m_ra[9:0]];
    else if (m_sta) m_rd = sta[8 * m_ra[0] +: 8];
    else if (m_fm) m_rd = fmv[8 * m_ra[4:0] +: 8];
  end
  always_ff @(posedge clk) begin
    if (m_we && w_ram) ram[m_wa[9:0]] <= m_wd;
    if (h_we && h_ram) ram[host_addr[9:0]] <= host_wdata;
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sta <= '0; fmv <= '0;
    end else begin
      if (m_we && w_sta) sta[8 * m_wa[0] +: 8] <= m_wd;
      if (m_we && w_fm) fmv[8 * m_wa[4:0] +: 8] <= m_wd;
      if (h_we && h_sta) sta[8 * host_addr[0] +: 8] <= host_wdata;
      if (h_we && h_fm) fmv[8 * host_addr[4:0] +: 8] <= host_wdata;
    end
  end
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) host_rdata <= '0;
    else if (host_rd) host_rdata <= h_ram ? ram[host_addr[9:0]] : h_sta ? sta[8 * host_addr[0] +: 8] :
                                    h_fm ? fmv[8 * host_addr[4:0] +: 8] : 8'h00;

  // ---------------- FMMUs ----------------
  // logical octet la: the first active FMMU holding it gives the physical address
  logic [31:0] la;
  logic [1:0]  f_in, f_rok, f_wok;
  logic [15:0] f_phys [0:1];
  for (genvar f = 0; f < 2; f++) begin : g_fmmu
    wire [31:0] st  = fmv[128 * f +: 32];
    wire [15:0] ln  = fmv[128 * f + 32 +: 16];
    wire [31:0] off = la - st;
    assign f_in[f]   = fmv[128 * f + 96] && la >= st && off < {16'd0, ln};
    assign f_rok[f]  = fmv[128 * f + 88];
    assign f_wok[f]  = fmv[128 * f + 89];
    assign f_phys[f] = fmv[128 * f + 64 +: 16] + off[15:0];
  end
  wire        f_hit = |f_in;
  wire        f_sel = !f_in[0];
  wire        f_r   = f_rok[f_sel];
  wire        f_w   = f_wok[f_sel];
  wire [15:0] f_pa  = f_phys[f_sel];

  // ---------------- parser ----------------
  typedef enum logic [2:0] {P_ETH, P_ECAT, P_HDR, P_DATA, P_WKC, P_PASS} ps_t;
  ps_t         ps;
  logic        in_fr;                      // inside a frame
  logic [3:0]  pos;                        // octet in the Ethernet / EtherCAT / datagram header
  logic        ecat;
  logic [7:0]  cmd;
  logic [15:0] adp, ado;
  logic [10:0] dlen, di;
  logic        more;
  logic        cy;                         // carry for ADP + 1 / WKC
  logic        addr_hit;                   // physical datagram addressed (or read side for xRMW)
  logic        g_r, g_w;                   // logical: an octet was read / written
  logic [1:0]  winc;
  logic [7:0]  ndg, wsum;

  wire        c_ap  = cmd >= 8'd1 && cmd <= 8'd3;
  wire        c_fp  = cmd >= 8'd4 && cmd <= 8'd6;
  wire        c_b   = cmd >= 8'd7 && cmd <= 8'd9;
  wire        c_l   = cmd >= 8'd10 && cmd <= 8'd12;
  wire        c_rmw = cmd == 8'd13 || cmd == 8'd14;
  wire        c_inc = c_ap || c_b || cmd == 8'd13;                 // ADP + 1
  wire        c_rd  = (cmd == 8'd1 || cmd == 8'd4 || cmd == 8'd7 || cmd == 8'd10);
  wire        c_wr  = (cmd == 8'd2 || cmd == 8'd5 || cmd == 8'd8 || cmd == 8'd11);
  wire        c_rw  = (cmd == 8'd3 || cmd == 8'd6 || cmd == 8'd9 || cmd == 8'd12);
  // the address check, on the full ADP once both octets are in
  wire [15:0] adp_in = {rx_d, adp[7:0]};
  wire        hit    = (c_ap || cmd == 8'd13) ? adp_in == 16'd0 :
                       (c_fp || cmd == 8'd14) ? adp_in == sta : c_b;

  // octet processing at the input: memory access (address side, no read data)
  assign la = {ado, adp} + {21'd0, di};
  always_comb begin
    m_we = 1'b0; m_wa = '0; m_wd = rx_d; m_ra = '0;
    if (rx_dv && in_fr && ps == P_DATA) begin
      if (c_l) begin
        m_ra = f_pa; m_wa = f_pa;
        m_we = f_hit && f_w && (cmd == 8'd11 || cmd == 8'd12);
      end else begin
        m_ra = ado + {5'd0, di}; m_wa = ado + {5'd0, di};
        if (c_rmw) m_we = !addr_hit;
        else m_we = addr_hit && (c_wr || c_rw);
      end
    end
  end
  // the output octet (kept apart from the address block: m_rd depends on m_ra)
  logic [7:0] o_d;
  always_comb begin
    o_d = rx_d;
    if (rx_dv && in_fr) begin
      case (ps)
        P_HDR: begin
          if (pos == 4'd2 && c_inc) o_d = rx_d + 8'd1;
          if (pos == 4'd3 && c_inc) o_d = rx_d + {7'd0, cy};
        end
        P_DATA: begin
          if (c_l) begin
            if (f_hit && f_r && (cmd == 8'd10 || cmd == 8'd12)) o_d = m_rd;
          end else if (addr_hit && (c_rmw || c_rd || c_rw)) o_d = c_b ? (rx_d | m_rd) : m_rd;
        end
        P_WKC: o_d = pos == 4'd0 ? rx_d + {6'd0, winc} : rx_d + {7'd0, cy};
        default: ;
      endcase
    end
  end
  // this datagram's working counter increment, with the octet now passing
  logic [1:0] winc_n;
  always_comb begin
    winc_n = winc;
    if (ps == P_DATA && c_l && f_hit) begin
      if (f_r && (cmd == 8'd10 || cmd == 8'd12) && !g_r) winc_n = winc_n + 2'd1;
      if (f_w && cmd == 8'd11 && !g_w) winc_n = winc_n + 2'd1;
      if (f_w && cmd == 8'd12 && !g_w) winc_n = winc_n + 2'd2;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ps <= P_ETH; in_fr <= 1'b0; pos <= '0; ecat <= 1'b0; cmd <= '0; adp <= '0; ado <= '0;
      dlen <= '0; di <= '0; more <= 1'b0; cy <= 1'b0; addr_hit <= 1'b0; g_r <= 1'b0; g_w <= 1'b0;
      winc <= '0; ndg <= '0; wsum <= '0;
    end else if (!rx_dv) begin
      in_fr <= 1'b0; ps <= P_ETH; pos <= '0;
    end else begin
      if (!in_fr) begin                                            // first octet
        in_fr <= 1'b1; ps <= P_ETH; pos <= 4'd1; ecat <= 1'b0; ndg <= '0; wsum <= '0;
      end else case (ps)
        P_ETH: begin                                               // octets 1..13
          pos <= pos + 4'd1;
          if (pos == 4'd12 && rx_d != 8'h88) ps <= P_PASS;
          if (pos == 4'd13) begin
            if (rx_d == 8'hA4) begin ps <= P_ECAT; pos <= '0; end else ps <= P_PASS;
          end
        end
        P_ECAT: begin
          pos <= pos + 4'd1;
          if (pos == 4'd1) begin
            if (rx_d[7:4] == 4'd1) begin ps <= P_HDR; pos <= '0; ecat <= 1'b1; end
            else ps <= P_PASS;
          end
        end
        P_HDR: begin
          pos <= pos + 4'd1;
          case (pos)
            4'd0: cmd <= rx_d;
            4'd2: begin adp[7:0] <= rx_d; cy <= rx_d == 8'hFF; end
            4'd3: begin adp[15:8] <= rx_d; addr_hit <= hit; end
            4'd4: ado[7:0] <= rx_d;
            4'd5: ado[15:8] <= rx_d;
            4'd6: dlen[7:0] <= rx_d;
            4'd7: begin dlen[10:8] <= rx_d[2:0]; more <= rx_d[7]; end
            4'd9: begin
              di <= '0; g_r <= 1'b0; g_w <= 1'b0; pos <= '0;
              // physical commands count here, logical ones per octet
              winc <= (c_rmw || (addr_hit && (c_rd || c_wr))) ? 2'd1 : (addr_hit && c_rw) ? 2'd3 : 2'd0;
              ps <= dlen == 11'd0 ? P_WKC : P_DATA;
            end
            default: ;
          endcase
        end
        P_DATA: begin
          di <= di + 11'd1; winc <= winc_n;
          if (c_l && f_hit && f_r && (cmd == 8'd10 || cmd == 8'd12)) g_r <= 1'b1;
          if (c_l && f_hit && f_w && (cmd == 8'd11 || cmd == 8'd12)) g_w <= 1'b1;
          if (di + 11'd1 == dlen) begin ps <= P_WKC; pos <= '0; end
        end
        P_WKC: begin
          pos <= pos + 4'd1;
          if (pos == 4'd0) cy <= {1'b0, rx_d} + {7'd0, winc} > 9'd255;
          else begin
            ndg <= ndg + 8'd1;
            wsum <= {1'b0, wsum} + {7'd0, winc} > 9'd255 ? 8'd255 : wsum + {6'd0, winc};
            if (more) begin ps <= P_HDR; pos <= '0; end else ps <= P_PASS;
          end
        end
        default: ;                                                 // P_PASS
      endcase
    end
  end

  // ---------------- delay line, FCS ----------------
  logic [4:0]  pv;                         // valid per stage
  logic [7:0]  pd [0:4], rd_ [0:4];        // processed / received octets
  logic [31:0] c_out, c_in;
  logic [2:0]  n_oct;                      // octets of the frame, saturating at 5
  wire  [31:0] c_out_f = crc8(c_out, pd[4]);
  wire  [31:0] c_in_f  = crc8(c_in, rd_[4]);
  wire         f_end   = in_fr && !rx_dv;
  wire  [31:0] fcs_rx  = {rd_[0], rd_[1], rd_[2], rd_[3]};
  wire         fcs_ok  = ~c_in_f == fcs_rx;
  wire  [31:0] fcs_tx  = fcs_ok ? ~c_out_f : c_out_f;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pv <= '0; c_out <= '1; c_in <= '1; n_oct <= '0;
      for (int i = 0; i < 5; i++) begin pd[i] <= '0; rd_[i] <= '0; end
      fr_done <= 1'b0; fr_fcs_ok <= 1'b0; fr_ecat <= 1'b0; fr_dgrams <= '0; fr_wkc <= '0;
    end else begin
      fr_done <= 1'b0;
      pv <= {pv[3:0], rx_dv};
      pd[0] <= o_d; rd_[0] <= rx_d;
      for (int i = 1; i < 5; i++) begin pd[i] <= pd[i - 1]; rd_[i] <= rd_[i - 1]; end
      if (rx_dv && !in_fr) begin c_out <= '1; c_in <= '1; n_oct <= 3'd1; end
      else begin
        if (pv[4]) begin c_out <= c_out_f; c_in <= c_in_f; end
        if (rx_dv && n_oct != 3'd5) n_oct <= n_oct + 3'd1;
      end
      if (f_end) begin
        fr_done <= 1'b1; fr_ecat <= ecat; fr_dgrams <= ndg; fr_wkc <= wsum;
        fr_fcs_ok <= n_oct == 3'd5 && fcs_ok;
        if (n_oct == 3'd5) begin
          pd[4] <= fcs_tx[7:0]; pd[3] <= fcs_tx[15:8]; pd[2] <= fcs_tx[23:16]; pd[1] <= fcs_tx[31:24];
        end
      end
    end
  end
  assign tx_dv = pv[4];
  assign tx_d  = pd[4];
endmodule
