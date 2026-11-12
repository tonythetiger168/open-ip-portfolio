// SPDX-License-Identifier: Apache-2.0
// IP part of USB_Type_C_Port_Controller_apb_tb: the port partner drives
// cc1 / cc2 through attach on either pin (orientation), debounce glitches,
// pin swaps, Ra and Rd-on-both (no attach), detach with and without
// bounces, CC faults, in source and sink role. Every core register is read
// through APB against a model and the pins; INT_STAT / FAULT_STAT are
// cleared over APB, IRQ_STATUS.EVENT follows the core irq (masked and on
// the pin); partial writes to core registers are refused; PRESETN while
// attached.
  localparam logic [1:0] CC_OPEN = 2'b00, CC_RD = 2'b01, CC_RA = 2'b10, CC_BAD = 2'b11;
  initial begin cc1 = CC_OPEN; cc2 = CC_OPEN; end

  logic       m_role = 1;           // model: source role
  task automatic regs_exp(input logic [1:0] st, input logic att, input logic ori,
                          input logic [2:0] ints, input logic flt);
    rd_exp(A_CC_STATUS, {24'h0, att, ori, st, cc2, cc1});
    rd_exp(A_ROLE_CTRL, {31'h0, m_role});
    rd_exp(A_FAULT_STAT, {31'h0, flt});
    rd_exp(A_INT_STAT, {29'h0, ints});
    rd_exp(A_ORIENT, {31'h0, ori});
    rd_exp(A_VBUS_STAT, {31'h0, att & m_role});
    if (attached !== att || orientation !== ori || vbus_en !== (att & m_role))
      fail("pins vs registers");
  endtask

  // clear INT_STAT / FAULT_STAT, then IRQ_STATUS
  task automatic clear_all;
    wr(A_INT_STAT, 7);
    wr(A_FAULT_STAT, 1);
    wr(A_IRQ_STATUS, 1 << IRQ_EVENT);
    rd_exp(A_INT_STAT, 0);
    rd_exp(A_IRQ_STATUS, 0);
  endtask

  // attach on one pin after the full debounce
  task automatic attach(input bit pin2);
    if (pin2) cc2 = CC_RD; else cc1 = CC_RD;
    cycles(3);
    rd_exp(A_CC_STATUS, {24'h0, 1'b0, pin2, 2'd1, cc2, cc1});   // attach wait
    rd_exp(A_IRQ_STATUS, 0);
    cycles(110);
    regs_exp(2'd2, 1, pin2, 3'b001, 0);
    rd_exp(A_IRQ_STATUS, 1 << IRQ_EVENT);
    clear_all();
  endtask
  task automatic detach(input bit pin2);
    if (pin2) cc2 = CC_OPEN; else cc1 = CC_OPEN;
    cycles(15);
    regs_exp(2'd0, 0, pin2, 3'b010, 0);
    clear_all();
  endtask

  task automatic ip_func;
    rd_exp(A_FLAGS, 0);
    rd_exp(A_DEBOUNCE, 100);
    rd_exp(A_DEVICE_ID, 32'hC7);
    regs_exp(2'd0, 0, 0, 0, 0);
    // read-only core registers ignore writes
    wr(A_CC_STATUS, 32'hFF); wr(A_DEBOUNCE, 0); wr(A_ORIENT, 1);
    wr(A_VBUS_STAT, 1); wr(A_DEVICE_ID, 0);
    rd_exp(A_DEBOUNCE, 100); rd_exp(A_DEVICE_ID, 32'hC7);
    regs_exp(2'd0, 0, 0, 0, 0);
    // partial writes to core registers: PSLVERR, dropped
    apb(1, A_ROLE_CTRL, 0, 4'h1);
    if (!rerr) fail("no PSLVERR on a partial core write");
    apb(1, A_INT_STAT, 0, 4'hE);
    if (!rerr) fail("no PSLVERR on a partial core write");
    rd_exp(A_ROLE_CTRL, 1);

    // ---- source role: attach on CC1, detach; flipped on CC2 ----
    attach(0);
    detach(0);
    attach(1);
    // detach bounce: back before 10 clocks keeps the attach
    cycles(1); cc2 = CC_OPEN; cycles(9); cc2 = CC_RD; cycles(20);   // 9 clocks open
    regs_exp(2'd2, 1, 1, 0, 0);
    cycles(1); cc2 = CC_OPEN; cycles(10); cc2 = CC_RD; cycles(1);   // 10 clocks: detach
    regs_exp(2'd1, 0, 1, 3'b010, 0);                          // Rd back: attach wait
    clear_all();
    cycles(110);
    regs_exp(2'd2, 1, 1, 3'b001, 0);
    clear_all();
    detach(1);

    // ---- no attach: Ra only, Rd on both pins, glitch, pin swap ----
    cc1 = CC_RA; cycles(150);
    regs_exp(2'd0, 0, 1, 0, 0);
    cc1 = CC_RD; cc2 = CC_RD; cycles(150);
    regs_exp(2'd0, 0, 1, 0, 0);
    cc2 = CC_OPEN; cycles(30); cc1 = CC_OPEN; cycles(3);        // glitch
    regs_exp(2'd0, 0, 0, 0, 0);
    cc1 = CC_RD; cycles(30); cc1 = CC_OPEN; cc2 = CC_RD; cycles(3);   // swap
    rd_exp(A_CC_STATUS, {24'h0, 1'b0, 1'b1, 2'd1, cc2, cc1});
    cc2 = CC_OPEN; cycles(5);
    rd_exp(A_IRQ_STATUS, 0);

    // ---- sink role: attached without VBUS ----
    wr(A_ROLE_CTRL, 0); m_role = 0;
    rd_exp(A_ROLE_CTRL, 0);
    wr(A_IRQ_ENABLE, 1 << IRQ_EVENT);
    cc1 = CC_RD; cycles(115);
    if (irq !== 1'b1) fail("attach event on the irq pin");
    regs_exp(2'd2, 1, 0, 3'b001, 0);
    clear_all();
    if (irq !== 1'b0) fail("irq pin after clear");
    wr(A_ROLE_CTRL, 1); m_role = 1;
    regs_exp(2'd2, 1, 0, 0, 0);                    // VBUS on while attached

    // ---- fault: held while the level lasts, sticky after ----
    cc2 = CC_BAD; cycles(3);
    regs_exp(2'd2, 1, 0, 3'b100, 1);
    wr(A_INT_STAT, 7); wr(A_FAULT_STAT, 1);         // fault still present: set again
    rd_exp(A_FAULT_STAT, 1); rd_exp(A_INT_STAT, 4);
    wr(A_IRQ_STATUS, 1 << IRQ_EVENT);
    rd_exp(A_IRQ_STATUS, 1 << IRQ_EVENT);
    if (irq !== 1'b1) fail("fault on the irq pin");
    cc2 = CC_OPEN; cycles(2);
    rd_exp(A_FAULT_STAT, 1);
    clear_all();
    rd_exp(A_FAULT_STAT, 0);
    wr(A_IRQ_ENABLE, 0);
    // a fault during the attach debounce restarts it
    detach(0);
    cc1 = CC_RD; cycles(50); cc2 = CC_BAD; cycles(2); cc2 = CC_OPEN; cycles(60);
    rd_exp(A_CC_STATUS, {24'h0, 1'b0, 1'b0, 2'd1, cc2, cc1});
    cycles(60);
    regs_exp(2'd2, 1, 0, 3'b101, 1);
    clear_all();

    // ---- PRESETN while attached ----
    PRESETN = 0; cycles(2);
    if (attached !== 0 || vbus_en !== 0 || irq !== 0) fail("PRESETN outputs");
    PRESETN = 1; cycles(2);
    check_reset_values();
    rd_exp(A_CC_STATUS, {24'h0, 1'b0, 1'b0, 2'd1, cc2, cc1});
    cycles(110);
    regs_exp(2'd2, 1, 0, 3'b001, 0);
    // leave EVENT pending (masked) for the final reset
    rd_exp(A_IRQ_STATUS, 1 << IRQ_EVENT);
  endtask
