// SPDX-License-Identifier: Apache-2.0
// CI / CI+ CAM model on the card pins of CI_Plus_Host_top, included inside
// the core TB and the APB wrapper TB (define CAM_CLK first). It has:
// - card detect (cam_cd_n, driven by the TB), READY on ci_ireq_n: low while
//   RESET is high and cam_rdy_dly clocks after it, then high; once its COR
//   is written (any write to cam_cor_addr) the card is in I/O mode and
//   ci_ireq_n is the interrupt request (cam_irq).
// - attribute memory cam_attr (the CIS at even addresses), WAIT# held low
//   cam_wait clocks from the start of every strobe, data driven while a
//   read strobe is low.
// - the EN 50221 command interface at I/O addresses 0..3: host-to-module
//   messages land in cam_in (sizes in cam_in_n), module-to-host messages
//   queued with cam_send() raise DA. cam_steal makes FR drop that many
//   times right after HC is set; cam_fr_off holds FR low; RS clears the
//   buffers and FR comes back cam_rs_dly clocks after RS is cleared;
//   cam_st_x supplies STATUS bits 5..0 (WE, RE, reserved).
// - bus timing checks: CE# and REG# low at least cam_setup + 1 clocks before
//   a strobe and cam_strobe + 1 clocks of strobe (counted with the TB's
//   SETUP / STROBE values), one strobe at a time, writes with the data bus
//   driven.
// - the transport stream: the CAM returns ci_mo_* one clock later with
//   every byte but the sync byte inverted ("descrambled").
// Counters cam_errors and cam_cycles.
logic        cam_cd_n = 1'b1;
assign ci_cd_n = cam_cd_n;
logic [7:0]  cam_attr [0:32767];
bit          cam_io = 0, cam_rdy = 0, cam_irq = 0;
logic        cam_wait_n = 1'b1;
int          cam_wait = 0, cam_rdy_dly = 20, cam_rs_dly = 10;
int          cam_setup = 0, cam_strobe = 0;
logic [14:0] cam_cor_addr = 15'h0FFE;
logic [7:0]  cam_cor = 8'h00;
int          cam_rc = 0;
bit          cam_reset_q = 0;
int          cam_rst_len = 0, cam_errors = 0, cam_cycles = 0;
bit          cam_fr = 1, cam_fr_off = 0, cam_stolen = 0, cam_hc = 0, cam_sr = 0;
int          cam_steal = 0, cam_rs_cnt = -1;
logic [5:0]  cam_st_x = 6'h00;                     // reserved / WE / RE bits shown in STATUS
logic [7:0]  cam_out_q [$];                        // the module-to-host message being read
int          cam_out_n = 0;
logic [7:0]  cam_pend [$];                         // further messages, sizes in cam_pend_n
int          cam_pend_n [$];
logic [7:0]  cam_ib [$];                           // the host-to-module message being written
logic [7:0]  cam_in [$];                           // completed host-to-module messages
int          cam_in_n [$];
int          cam_size_w = 0;                       // size the host wrote
assign ci_ireq_n = cam_io ? !cam_irq : cam_rdy;
assign ci_wait_n = cam_wait_n;
initial for (int i = 0; i < 32768; i++) cam_attr[i] = 8'hFF;

function automatic logic [7:0] cam_io_rd(input logic [1:0] a);
  case (a)
    2'd0: return (cam_out_q.size() != 0) ? cam_out_q[0] : 8'h00;
    2'd1: return {cam_out_q.size() != 0, cam_fr && !cam_fr_off && !cam_stolen, cam_st_x};
    2'd2: return cam_sr ? 8'(cam_out_n) : 8'h00;
    default: return cam_sr ? 8'(cam_out_n >> 8) : 8'h00;
  endcase
endfunction
logic [7:0] cam_d = 8'h00;                         // re-evaluated on both clock edges (the
assign ci_d_i = cam_d;                              // state behind the I/O registers is not a port)
always @(`CAM_CLK or ci_a or ci_oe_n or ci_iord_n)
  cam_d = !ci_oe_n ? cam_attr[ci_a] : !ci_iord_n ? cam_io_rd(ci_a[1:0]) : 8'h00;

task automatic cam_send(input logic [7:0] d []);
  foreach (d[i]) cam_pend.push_back(d[i]);
  cam_pend_n.push_back(d.size());
endtask

logic [3:0] cam_str_q = 4'h0;                      // {iowr, iord, we, oe} last clock
int         cam_ce_n = 0, cam_s_n = 0, cam_wc = 0;
always @(posedge `CAM_CLK) begin
  logic [3:0] st;
  st = {!ci_iowr_n, !ci_iord_n, !ci_we_n, !ci_oe_n};
  // power, reset, READY
  if (!ci_vcc_en) begin
    cam_io = 0; cam_rdy = 0; cam_fr = 1; cam_hc = 0; cam_sr = 0; cam_stolen = 0;
    cam_out_q.delete(); cam_ib.delete(); cam_rs_cnt = -1;
  end else if (ci_reset) begin
    if (!cam_reset_q) cam_rst_len = 0;
    cam_rst_len++; cam_rc = 0;
    cam_rdy = 0; cam_io = 0; cam_out_q.delete(); cam_ib.delete(); cam_fr = 1;
  end else if (!cam_rdy) begin
    cam_rc++;
    if (cam_rc >= cam_rdy_dly) cam_rdy = 1;
  end
  cam_reset_q = ci_reset;
  if (cam_rs_cnt > 0) cam_rs_cnt--;
  else if (cam_rs_cnt == 0) begin cam_fr = 1; cam_rs_cnt = -1; end
  if (cam_out_q.size() == 0 && cam_pend_n.size() != 0 && !cam_sr) begin
    cam_out_n = cam_pend_n.pop_front();
    repeat (cam_out_n) cam_out_q.push_back(cam_pend.pop_front());
  end
  // bus cycle checks
  if (!ci_ce_n && st == 4'h0 && cam_str_q == 4'h0) begin
    cam_ce_n++;
    if (ci_reg_n) begin cam_errors++; $display("ERROR: CAM: REG# high in a cycle @%0t", $time); end
  end
  if (ci_ce_n) cam_ce_n = 0;
  if (st != 4'h0 && $countones(st) != 1) begin cam_errors++; $display("ERROR: CAM: two strobes @%0t", $time); end
  if (st != 4'h0 && cam_str_q == 4'h0) begin       // strobe start
    if (ci_ce_n || cam_ce_n < cam_setup + 1) begin
      cam_errors++; $display("ERROR: CAM: CE# low %0d clocks before the strobe, SETUP %0d @%0t", cam_ce_n, cam_setup, $time);
    end
    if ((st[3] || st[1]) && !ci_d_oe) begin cam_errors++; $display("ERROR: CAM: write without data @%0t", $time); end
    cam_s_n = 0; cam_cycles++;
    if (cam_wait > 0) begin cam_wait_n <= 1'b0; cam_wc = cam_wait; end
  end
  if (st != 4'h0) begin
    cam_s_n++;
    if (cam_wc > 0) begin cam_wc--; if (cam_wc == 0) cam_wait_n <= 1'b1; end
  end
  if (st == 4'h0 && cam_str_q != 4'h0) begin       // strobe end
    cam_wait_n <= 1'b1; cam_wc = 0;
    if (cam_s_n < cam_strobe + 1) begin
      cam_errors++; $display("ERROR: CAM: strobe %0d clocks, STROBE %0d @%0t", cam_s_n, cam_strobe, $time);
    end
    if (cam_str_q[1]) begin                        // attribute write
      if (ci_a == cam_cor_addr) begin cam_cor = ci_d_o; cam_io = 1; end
      else cam_attr[ci_a] = ci_d_o;
    end
    if (cam_str_q[2] && ci_a[1:0] == 2'd0 && cam_out_q.size() != 0) void'(cam_out_q.pop_front());
    if (cam_str_q[3]) begin                        // I/O write
      case (ci_a[1:0])
        2'd0: if (cam_hc) cam_ib.push_back(ci_d_o);
        2'd1: begin
          if (ci_d_o[3]) begin
            cam_fr = 0; cam_ib.delete(); cam_out_q.delete(); cam_hc = 0; cam_rs_cnt = -2;
          end else if (cam_rs_cnt == -2) cam_rs_cnt = cam_rs_dly;
          cam_sr = ci_d_o[2];
          if (ci_d_o[0] && !cam_hc) begin
            cam_hc = 1; cam_ib.delete();
            if (cam_steal > 0) begin cam_steal--; cam_stolen = 1; end
          end else if (!ci_d_o[0] && cam_hc) begin
            cam_hc = 0;
            if (cam_stolen) cam_stolen = 0;
            else if (cam_ib.size() != 0) begin
              if (cam_ib.size() != cam_size_w) begin
                cam_errors++; $display("ERROR: CAM: %0d bytes written, size %0d @%0t", cam_ib.size(), cam_size_w, $time);
              end
              foreach (cam_ib[i]) cam_in.push_back(cam_ib[i]);
              cam_in_n.push_back(cam_ib.size());
            end
          end
        end
        2'd2: cam_size_w = (cam_size_w & 32'hFF00) | ci_d_o;
        default: cam_size_w = (cam_size_w & 32'h00FF) | (int'(ci_d_o) << 8);
      endcase
    end
  end
  cam_str_q <= st;
end

// transport stream through the CAM
always @(posedge `CAM_CLK) begin
  ci_mi_data <= ci_mo_strt ? ci_mo_data : ~ci_mo_data;
  ci_mi_val  <= ci_mo_val;
  ci_mi_strt <= ci_mo_strt;
end
