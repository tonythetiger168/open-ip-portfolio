// SPDX-License-Identifier: Apache-2.0
// IP part of HDMI_2_1_apb_tb: STATUS follows the hsync / vsync / de pins
// through a frame (active video, hsync, vsync), the TMDS pins run while hpd
// is high, and hpd loss raises HPD_LOST until hpd returns.
  initial hpd = 0;

  // read STATUS and compare with the pins sampled in the access phase
  task automatic status_pins(input logic [2:0] e);
    rd(A_STATUS);
    if (rdv !== {29'h0, e}) fail($sformatf("STATUS %h, expected %h", rdv, e));
    if ({de, vsync, hsync} !== e) fail("pins differ from STATUS");
  endtask

  task automatic ip_func;
    int ones;
    // no activity before hpd
    cycles(20);
    if (tmds_clk !== 0 || tmds_d !== 0) fail("TMDS active before hpd");
    status_pins(3'b011);
    rd_exp(A_IRQ_STATUS, 0);
    wr(A_STATUS, 0);                                    // read-only: ignored
    hpd = 1;
    // active video: de high, both syncs inactive
    @(negedge PCLK); while (!de) @(negedge PCLK);
    status_pins(3'b111);
    // the TMDS clock channel: five ones in every ten bits
    ones = 0;
    repeat (10) begin @(negedge PCLK); ones += tmds_clk; end
    if (ones != 5) fail("TMDS clock pattern");
    // horizontal sync
    @(negedge PCLK); while (hsync) @(negedge PCLK);
    status_pins(3'b010);
    @(negedge PCLK); while (!hsync) @(negedge PCLK);
    status_pins(3'b011);
    // vertical sync (line 490), then hsync inside it
    @(negedge PCLK); while (vsync) @(negedge PCLK);
    @(negedge PCLK); while (!hsync) @(negedge PCLK);
    status_pins(3'b001);
    @(negedge PCLK); while (hsync) @(negedge PCLK);
    status_pins(3'b000);
    rd_exp(A_IRQ_STATUS, 0);
    // hpd lost: HPD_LOST, re-set while hpd is low, pin when enabled
    hpd = 0;
    cycles(2);
    if (tmds_d !== 0) fail("TMDS not stopped");
    rd_exp(A_IRQ_STATUS, 1 << IRQ_HPD_LOST);
    if (irq) fail("masked HPD_LOST drives the pin");
    wr(A_IRQ_ENABLE, IRQ_ALL);
    if (!irq) fail("HPD_LOST drives the pin");
    wr(A_IRQ_STATUS, IRQ_ALL);
    rd_exp(A_IRQ_STATUS, 1 << IRQ_HPD_LOST);            // still low: set again
    status_pins(3'b011);
    hpd = 1;
    cycles(2);
    wr(A_IRQ_STATUS, IRQ_ALL);
    rd_exp(A_IRQ_STATUS, 0);
    if (irq) fail("irq after hpd returned");
    // the timing restarts at pixel (0,0)
    @(negedge PCLK); while (!de) @(negedge PCLK);
    status_pins(3'b111);
    // reset with HPD_LOST pending
    hpd = 0;
    cycles(2);
    if (!irq) fail("HPD_LOST pending");
    rd_exp(A_IRQ_STATUS, 1 << IRQ_HPD_LOST);
    rd_exp(A_FLAGS, 0);                                 // no streams: always 0
  endtask
