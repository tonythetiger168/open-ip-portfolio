// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// eUSB2 protocol IP -- eUSB2 device/repeater (simplified)
//   * eD+/eD- single-ended 1.2V signalling, simplified to lvcmos logic
//     levels (J = 10, K = 01, SE0 = 00, SE1 = 11 illegal), 1 bit cell/clk
//   * USB2 packet-layer retimer: the received eUSB2 NRZI bit stream is
//     re-registered and driven onto the standard dp/dm output port
//   * Control messages (control packets, PID 8'hC3): register write/read
//     of an 8x8 register file (reg0 = squelch threshold, reg1 = term
//     config, reg2..7 scratch); read responses are transmitted as a
//     USB2-style frame on dp/dm
//   * Squelch detection: SE0 longer than the programmed threshold forces
//     the retimed outputs silent and resets the packet parser
//   * NRZI decode + bit unstuffing on receive; NRZI encode + bit stuffing
//     on transmit; CRC8 (poly 0x07, init 0xFF) protects control packets
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
module eUSB2_top #(
  parameter int DW = 32,        // data width (framework contract)
  parameter int AW = 32         // address width (framework contract)
)(
  input  logic clk,
  input  logic rst_n,
  input  logic edp,             // eD+ single-ended input
  input  logic edm,             // eD- single-ended input
  output logic dp,              // retimed standard USB2 D+ output
  output logic dm,              // retimed standard USB2 D- output
  output logic squelch,         // squelch (signal loss) detected
  output logic irq              // sticky protocol-error indication
);

  localparam logic [1:0] LN_SE0 = 2'b00;
  localparam logic [1:0] LN_K   = 2'b01;
  localparam logic [1:0] LN_J   = 2'b10;
  localparam logic [1:0] LN_SE1 = 2'b11;

  localparam logic [7:0] PID_CTRL = 8'hC3;  // control packet PID
  localparam logic [7:0] PID_RESP = 8'h3C;  // read-response packet PID

  // CRC8, poly x^8+x^2+x+1 (0x07), init all-ones, MSB-first
  function automatic logic [7:0] crc8_b(input logic [7:0] c_in,
                                        input logic [7:0] d);
    logic [7:0] c;
    logic       fb;
    begin
      c = c_in;
      for (int i = 7; i >= 0; i--) begin
        fb = d[i] ^ c[7];
        c  = {c[6:0], 1'b0};
        if (fb) c = c ^ 8'h07;
      end
      crc8_b = c;
    end
  endfunction

  logic [1:0] line;
  assign line = {edp, edm};

  // ------------------------------------------------------------------
  // register file: reg0 squelch threshold, reg1 term config, 2..7 scratch
  // ------------------------------------------------------------------
  logic [7:0] regfile [0:7];

  // ------------------------------------------------------------------
  // squelch detection
  // ------------------------------------------------------------------
  logic [7:0] se0_cnt;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      se0_cnt <= 8'd0;
      squelch <= 1'b0;
    end else begin
      if (line == LN_SE0) begin
        if (se0_cnt != 8'hFF)
          se0_cnt <= se0_cnt + 8'd1;
        if (se0_cnt >= regfile[0])
          squelch <= 1'b1;
      end else if (line == LN_J) begin
        se0_cnt <= 8'd0;
        squelch <= 1'b0;
      end else begin
        se0_cnt <= 8'd0;   // K (or SE1): not idle, but only J exits squelch
      end
    end
  end

  // ------------------------------------------------------------------
  // retime path: re-register eD+/eD- onto dp/dm
  // ------------------------------------------------------------------
  logic edp_q, edm_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      edp_q <= 1'b0;
      edm_q <= 1'b0;
    end else begin
      edp_q <= edp;
      edm_q <= edm;
    end
  end

  // ------------------------------------------------------------------
  // receive packet parser (NRZI decode + unstuffing + control packets)
  // ------------------------------------------------------------------
  typedef enum logic [0:0] {P_IDLE, P_RUN} pstate_t;
  pstate_t    pstate;
  logic [1:0] prev_line;
  logic [2:0] sync_zeros;   // consecutive 0-bits while hunting sync
  logic [2:0] ones_cnt;     // consecutive 1-bits (stuffing)
  logic       stuff_p;      // next bit must be a stuffed 0
  logic [2:0] bit_cnt;
  logic [7:0] byte_shift;
  logic [1:0] byte_pos;     // 0:PID 1:CMD 2:WDATA/CRC 3:CRC
  logic       is_ctrl;
  logic       is_write;
  logic       crc_done;
  logic [7:0] cmd_q;
  logic [7:0] wdata_q;
  logic [7:0] crc_run;
  logic [7:0] crc_q;

  // read-response request handshake towards the transmit block
  logic       resp_req;
  logic [2:0] resp_addr;
  logic       resp_taken;

  logic       bit_valid;
  logic       bit_val;
  logic [7:0] byte_val;
  assign bit_valid = (line == LN_J || line == LN_K) &&
                     (prev_line == LN_J || prev_line == LN_K);
  assign bit_val   = (line == prev_line);   // NRZI: no transition = 1
  assign byte_val  = {bit_val, byte_shift[7:1]};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pstate     <= P_IDLE;
      prev_line  <= LN_SE0;
      sync_zeros <= 3'd0;
      ones_cnt   <= 3'd0;
      stuff_p    <= 1'b0;
      bit_cnt    <= 3'd0;
      byte_shift <= 8'd0;
      byte_pos   <= 2'd0;
      is_ctrl    <= 1'b0;
      is_write   <= 1'b0;
      crc_done   <= 1'b0;
      cmd_q      <= 8'd0;
      wdata_q    <= 8'd0;
      crc_run    <= 8'd0;
      crc_q      <= 8'd0;
      resp_req   <= 1'b0;
      resp_addr  <= 3'd0;
      irq        <= 1'b0;
      for (int k = 0; k < 8; k++)
        regfile[k] <= (k == 0) ? 8'd8 : 8'd0;  // default squelch threshold 8
    end else begin
      if (resp_taken)
        resp_req <= 1'b0;

      if (squelch) begin
        // receiver is squelched: drop any packet in progress
        pstate     <= P_IDLE;
        byte_pos   <= 2'd0;
        bit_cnt    <= 3'd0;
        ones_cnt   <= 3'd0;
        stuff_p    <= 1'b0;
        sync_zeros <= 3'd0;
        prev_line  <= line;
      end else if (line == LN_SE1) begin
        irq        <= 1'b1;   // illegal single-ended state
        pstate     <= P_IDLE;
        byte_pos   <= 2'd0;
        bit_cnt    <= 3'd0;
        ones_cnt   <= 3'd0;
        stuff_p    <= 1'b0;
        sync_zeros <= 3'd0;
        prev_line  <= line;
      end else if (line == LN_SE0) begin
        if (pstate == P_RUN) begin
          // EOP: validate and execute control packet
          if (is_ctrl) begin
            if (!crc_done) begin
              irq <= 1'b1;                 // truncated control packet
            end else if (crc_q != crc_run) begin
              irq <= 1'b1;                 // CRC mismatch: packet ignored
            end else if (is_write) begin
              regfile[cmd_q[6:4]] <= wdata_q;
            end else if (!resp_req) begin
              resp_req  <= 1'b1;           // schedule read response
              resp_addr <= cmd_q[6:4];
            end
          end
        end
        pstate     <= P_IDLE;
        byte_pos   <= 2'd0;
        bit_cnt    <= 3'd0;
        ones_cnt   <= 3'd0;
        stuff_p    <= 1'b0;
        sync_zeros <= 3'd0;
        prev_line  <= line;
      end else begin
        // J or K cell
        if (bit_valid) begin
          if (pstate == P_IDLE) begin
            // sync hunt: seven 0-bits followed by a 1-bit (KJKJKJKK)
            if (!bit_val) begin
              if (sync_zeros < 3'd7)
                sync_zeros <= sync_zeros + 3'd1;
            end else begin
              if (sync_zeros == 3'd7) begin
                pstate   <= P_RUN;
                byte_pos <= 2'd0;
                bit_cnt  <= 3'd0;
                ones_cnt <= 3'd0;
                stuff_p  <= 1'b0;
                crc_done <= 1'b0;
              end
              sync_zeros <= 3'd0;
            end
          end else begin
            if (stuff_p) begin
              if (!bit_val) begin
                stuff_p  <= 1'b0;          // stuffed bit, dropped
                ones_cnt <= 3'd0;
              end else begin
                irq    <= 1'b1;            // bit-stuff error
                pstate <= P_IDLE;
              end
            end else begin
              byte_shift <= byte_val;
              if (bit_val) begin
                if (ones_cnt == 3'd5)
                  stuff_p <= 1'b1;
                ones_cnt <= ones_cnt + 3'd1;
              end else begin
                ones_cnt <= 3'd0;
              end
              if (bit_cnt == 3'd7) begin
                bit_cnt <= 3'd0;
                case (byte_pos)
                  2'd0: begin              // PID
                    is_ctrl  <= (byte_val == PID_CTRL);
                    byte_pos <= 2'd1;
                  end
                  2'd1: begin              // CMD {rnw,addr[2:0],4'b0}
                    if (is_ctrl) begin
                      cmd_q    <= byte_val;
                      is_write <= ~byte_val[7];
                      crc_run  <= crc8_b(8'hFF, byte_val);
                      crc_done <= 1'b0;
                      byte_pos <= 2'd2;
                    end
                  end
                  2'd2: begin
                    if (is_ctrl) begin
                      if (is_write) begin  // WDATA
                        wdata_q  <= byte_val;
                        crc_run  <= crc8_b(crc_run, byte_val);
                        byte_pos <= 2'd3;
                      end else begin       // CRC of read request
                        crc_q    <= byte_val;
                        crc_done <= 1'b1;
                        byte_pos <= 2'd3;
                      end
                    end
                  end
                  default: begin
                    if (is_ctrl && is_write && !crc_done) begin
                      crc_q    <= byte_val;  // CRC of write request
                      crc_done <= 1'b1;
                    end
                  end
                endcase
              end else begin
                bit_cnt <= bit_cnt + 3'd1;
              end
            end
          end
        end
        prev_line <= line;
      end
    end
  end

  // ------------------------------------------------------------------
  // read-response transmitter (NRZI encode + stuffing onto dp/dm)
  // frame: sync + PID_RESP + {1'b1,addr,4'b0} + data + CRC8 + EOP
  // ------------------------------------------------------------------
  typedef enum logic [2:0] {R_IDLE, R_SYNC, R_BYTE, R_EOP0, R_EOP1, R_EOPJ}
    rstate_t;
  rstate_t    rstate;
  logic       resp_active;
  logic       r_dp, r_dm;
  logic [2:0] r_sync_cnt;
  logic [2:0] r_bit_cnt;
  logic [1:0] r_byte_cnt;
  logic [2:0] r_ones;
  logic       r_stuff;
  logic [7:0] r_crc;
  logic [2:0] resp_addr_q;
  logic [7:0] resp_data_q;

  logic [7:0] cur_byte;
  always_comb begin
    case (r_byte_cnt)
      2'd0:    cur_byte = PID_RESP;
      2'd1:    cur_byte = {1'b1, resp_addr_q, 4'b0000};
      2'd2:    cur_byte = resp_data_q;
      default: cur_byte = r_crc;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rstate      <= R_IDLE;
      resp_active <= 1'b0;
      r_dp        <= 1'b1;
      r_dm        <= 1'b0;
      r_sync_cnt  <= 3'd0;
      r_bit_cnt   <= 3'd0;
      r_byte_cnt  <= 2'd0;
      r_ones      <= 3'd0;
      r_stuff     <= 1'b0;
      r_crc       <= 8'd0;
      resp_addr_q <= 3'd0;
      resp_data_q <= 8'd0;
      resp_taken  <= 1'b0;
    end else begin
      resp_taken <= 1'b0;
      case (rstate)
        R_IDLE: begin
          r_dp <= 1'b1;   // J
          r_dm <= 1'b0;
          if (resp_req) begin
            resp_taken  <= 1'b1;
            resp_active <= 1'b1;
            resp_addr_q <= resp_addr;
            resp_data_q <= regfile[resp_addr];
            r_sync_cnt  <= 3'd0;
            rstate      <= R_SYNC;
          end
        end
        R_SYNC: begin
          // seven 0-bits (toggle) then one 1-bit (hold)
          if (r_sync_cnt < 3'd7) begin
            r_dp <= ~r_dp;
            r_dm <= ~r_dm;
          end
          if (r_sync_cnt == 3'd7) begin
            rstate     <= R_BYTE;
            r_byte_cnt <= 2'd0;
            r_bit_cnt  <= 3'd0;
            r_ones     <= 3'd0;
            r_stuff    <= 1'b0;
            r_crc      <= 8'hFF;
          end
          r_sync_cnt <= r_sync_cnt + 3'd1;
        end
        R_BYTE: begin
          if (r_stuff) begin
            r_dp    <= ~r_dp;            // stuffed 0-bit (toggle)
            r_dm    <= ~r_dm;
            r_stuff <= 1'b0;
            r_ones  <= 3'd0;
          end else begin
            if (!cur_byte[r_bit_cnt]) begin
              r_dp   <= ~r_dp;           // 0-bit: toggle
              r_dm   <= ~r_dm;
              r_ones <= 3'd0;
            end else begin
              if (r_ones == 3'd5)
                r_stuff <= 1'b1;
              r_ones <= r_ones + 3'd1;
            end
            if (r_bit_cnt == 3'd7) begin
              r_bit_cnt <= 3'd0;
              if (r_byte_cnt == 2'd1)
                r_crc <= crc8_b(r_crc, cur_byte);   // cmd echo
              if (r_byte_cnt == 2'd2)
                r_crc <= crc8_b(r_crc, cur_byte);   // data
              if (r_byte_cnt == 2'd3)
                rstate <= R_EOP0;
              r_byte_cnt <= r_byte_cnt + 2'd1;
            end else begin
              r_bit_cnt <= r_bit_cnt + 3'd1;
            end
          end
        end
        R_EOP0: begin
          r_dp   <= 1'b0;
          r_dm   <= 1'b0;
          rstate <= R_EOP1;
        end
        R_EOP1: begin
          r_dp   <= 1'b0;
          r_dm   <= 1'b0;
          rstate <= R_EOPJ;
        end
        R_EOPJ: begin
          r_dp        <= 1'b1;
          r_dm        <= 1'b0;
          rstate      <= R_IDLE;
          resp_active <= 1'b0;
        end
        default: rstate <= R_IDLE;
      endcase
    end
  end

  // ------------------------------------------------------------------
  // output mux: response frame > squelch silence > retimed copy
  // ------------------------------------------------------------------
  always_comb begin
    if (resp_active) begin
      dp = r_dp;
      dm = r_dm;
    end else if (squelch) begin
      dp = 1'b0;
      dm = 1'b0;
    end else begin
      dp = edp_q;
      dm = edm_q;
    end
  end

endmodule
