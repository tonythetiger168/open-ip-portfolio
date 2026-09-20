#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""open-ip-portfolio SV generator (Apache-2.0).
Reads protocol names from the table CSV and emits per-protocol:
  rtl/<P>_top.sv  tb/<P>_tb.sv  syn/<P>_yosys.ys  syn/<P>_dc.tcl
  syn/<P>.sdc  sim/filelist_<P>.f  Makefile  README.md
"""
import os, csv, sys, re

BASE = os.path.dirname(os.path.abspath(__file__))

def san(P):
    """Sanitize protocol name into a legal SystemVerilog identifier."""
    S = re.sub(r'[^A-Za-z0-9_]', '_', P)
    if not re.match(r'[A-Za-z_]', S):
        S = "_" + S
    return S

# ---------------- protocol profiles ----------------
PROFILES = {
    "AHB": dict(
        pre="h", note="AHB-lite slave, single-beat (no burst)",
        sigs=[("trans", "[1:0]", "in"), ("addr", "[31:0]", "in"),
              ("wdata", "[31:0]", "in"), ("rdata", "[31:0]", "out"),
              ("write", "", "in"), ("ready", "", "out"), ("resp", "[1:0]", "out")],
        kind="mem",
        map=dict(ADDR="{p}addr", WDATA="{p}wdata", RDATA="{p}rdata", WRITE="{p}write"),
        req="{p}trans[1]",
        rdy="{p}ready = (state == ST_RESP);",
        err="{p}resp = 2'b00;",
        wdrv="{p}trans <= 2'b10; {p}addr <= a; {p}wdata <= d; {p}write <= 1'b1;",
        rdrv="{p}trans <= 2'b10; {p}addr <= a; {p}write <= 1'b0;",
        wait="wait ({p}ready === 1'b1);",
        rel="@(negedge clk); {p}trans <= 2'b00;",
    ),
    "APB": dict(
        pre="p", note="APB3 slave (SETUP -> ACCESS two-state)",
        sigs=[("sel", "", "in"), ("enable", "", "in"),
              ("addr", "[31:0]", "in"), ("wdata", "[31:0]", "in"),
              ("rdata", "[31:0]", "out"), ("write", "", "in"),
              ("ready", "", "out"), ("slverr", "", "out")],
        kind="mem",
        map=dict(ADDR="{p}addr", WDATA="{p}wdata", RDATA="{p}rdata", WRITE="{p}write"),
        req="{p}sel && {p}enable",
        rdy="{p}ready = (state == ST_DATA);",
        err="{p}slverr = 1'b0;",
        wdrv="{p}sel <= 1'b1; {p}addr <= a; {p}wdata <= d; {p}write <= 1'b1; @(negedge clk); {p}enable <= 1'b1;",
        rdrv="{p}sel <= 1'b1; {p}addr <= a; {p}write <= 1'b0; @(negedge clk); {p}enable <= 1'b1;",
        wait="wait ({p}ready === 1'b1); @(negedge clk);",
        rel="{p}sel <= 1'b0; {p}enable <= 1'b0;",
    ),
    "AXI4-Lite": dict(
        pre="", note="AXI4-Lite slave (AW/W/B/AR/R channels, handshake-ready)",
        sigs=[("awvalid", "", "in"), ("awready", "", "out"), ("awaddr", "[31:0]", "in"),
              ("wvalid", "", "in"), ("wready", "", "out"), ("wdata", "[31:0]", "in"),
              ("bvalid", "", "out"), ("bready", "", "in"),
              ("arvalid", "", "in"), ("arready", "", "out"), ("araddr", "[31:0]", "in"),
              ("rvalid", "", "out"), ("rready", "", "in"), ("rdata", "[31:0]", "out")],
        kind="mem",
        map=dict(ADDR="({p}awvalid ? {p}awaddr : {p}araddr)",
                 WDATA="{p}wdata", RDATA="{p}rdata", WRITE="{p}awvalid"),
        req="{p}awvalid || {p}arvalid",
        rdy="{p}awready = (state == ST_ADDR); {p}arready = (state == ST_ADDR);\n"
            "    {p}wready = (state == ST_DATA); {p}bvalid = (state == ST_RESP);\n"
            "    {p}rvalid = (state == ST_RESP);",
        err="",
        wdrv="{p}awvalid <= 1'b1; {p}awaddr <= a; @(negedge clk); {p}wvalid <= 1'b1; {p}wdata <= d;",
        rdrv="{p}arvalid <= 1'b1; {p}araddr <= a;",
        wait="wait ({p}bvalid === 1'b1 || {p}rvalid === 1'b1);",
        rel="@(negedge clk); {p}awvalid <= 1'b0; {p}wvalid <= 1'b0; {p}arvalid <= 1'b0;",
    ),
    "AXI-Stream": dict(
        pre="", kind="skeleton",
        note="AXI-Stream slave (tvalid/tready handshake, data passthrough to mem)",
        sigs=[("tvalid", "", "in"), ("tready", "", "out"), ("tdata", "[31:0]", "in"),
              ("tlast", "", "in")],
        req="{p}tvalid",
        rdy="{p}tready = (state == ST_ADDR);",
        err="",
        wdrv="{p}tvalid <= 1'b1; {p}tdata <= d; {p}tlast <= 1'b1;",
        rdrv="{p}tvalid <= 1'b1; {p}tdata <= 32'h0; {p}tlast <= 1'b1;",
        wait="wait ({p}tready === 1'b1);",
        rel="@(negedge clk); {p}tvalid <= 1'b0; {p}tlast <= 1'b0;",
    ),
    "I2C": dict(
        pre="", kind="skeleton",
        note="I2C slave skeleton (scl/sda open-drain, byte FSM placeholder)",
        sigs=[("scl", "", "in"), ("sda", "", "inout")],
        req="1'b1",
        rdy="",
        err="",
        wdrv="", rdrv="", wait="", rel="",
    ),
    "SPI": dict(
        pre="", kind="skeleton",
        note="SPI slave skeleton (sclk/mosi/miso/csn, shift-register placeholder)",
        sigs=[("sclk", "", "in"), ("mosi", "", "in"), ("miso", "", "out"), ("csn", "", "in")],
        req="!{p}csn",
        rdy="",
        err="",
        wdrv="", rdrv="", wait="", rel="",
    ),
    "UART": dict(
        pre="", kind="skeleton",
        note="UART skeleton (rx/tx 8N1, baud-clk placeholder)",
        sigs=[("rxd", "", "in"), ("txd", "", "out")],
        req="1'b0",
        rdy="",
        err="",
        wdrv="", rdrv="", wait="", rel="",
    ),
    "AXI4": dict(
        pre="", kind="mem", burst=True,
        note="AXI4 slave, INCR burst-ready FSM (TB issues single-beat, AWLEN/ARLEN=0)",
        sigs=[("awvalid", "", "in"), ("awready", "", "out"), ("awaddr", "[31:0]", "in"),
              ("awlen", "[7:0]", "in"), ("wvalid", "", "in"), ("wready", "", "out"),
              ("wdata", "[31:0]", "in"), ("wlast", "", "in"),
              ("bvalid", "", "out"), ("bready", "", "in"),
              ("arvalid", "", "in"), ("arready", "", "out"), ("araddr", "[31:0]", "in"),
              ("arlen", "[7:0]", "in"), ("rvalid", "", "out"), ("rready", "", "in"),
              ("rdata", "[31:0]", "out"), ("rlast", "", "out")],
        map=dict(ADDR="({p}awvalid ? {p}awaddr : {p}araddr)",
                 WDATA="{p}wdata", RDATA="{p}rdata", WRITE="{p}awvalid"),
        req="{p}awvalid || {p}arvalid",
        rdy="{p}awready = (state == ST_ADDR); {p}arready = (state == ST_ADDR);\n"
            "    {p}wready = (state == ST_DATA); {p}bvalid = (state == ST_RESP);\n"
            "    {p}rvalid = (state == ST_RESP); {p}rlast = (state == ST_RESP);",
        err="",
        wdrv="{p}awvalid <= 1'b1; {p}awaddr <= a; {p}awlen <= 8'h00; @(negedge clk); {p}wvalid <= 1'b1; {p}wdata <= d; {p}wlast <= 1'b1;",
        rdrv="{p}arvalid <= 1'b1; {p}araddr <= a; {p}arlen <= 8'h00;",
        wait="wait ({p}bvalid === 1'b1 || {p}rvalid === 1'b1);",
        rel="@(negedge clk); {p}awvalid <= 1'b0; {p}wvalid <= 1'b0; {p}arvalid <= 1'b0; {p}wlast <= 1'b0;",
    ),
    "Wishbone": dict(
        pre="", kind="mem",
        note="Wishbone B4 slave (cyc/stb/ack handshake)",
        sigs=[("cyc", "", "in"), ("stb", "", "in"), ("ack", "", "out"),
              ("addr", "[31:0]", "in"), ("wdata", "[31:0]", "in"),
              ("rdata", "[31:0]", "out"), ("we", "", "in"), ("sel", "[3:0]", "in")],
        map=dict(ADDR="{p}addr", WDATA="{p}wdata", RDATA="{p}rdata", WRITE="{p}we"),
        req="{p}cyc && {p}stb",
        rdy="{p}ack = (state == ST_RESP);",
        err="",
        wdrv="{p}cyc <= 1'b1; {p}stb <= 1'b1; {p}we <= 1'b1; {p}addr <= a; {p}wdata <= d; {p}sel <= 4'hF;",
        rdrv="{p}cyc <= 1'b1; {p}stb <= 1'b1; {p}we <= 1'b0; {p}addr <= a; {p}sel <= 4'hF;",
        wait="wait ({p}ack === 1'b1);",
        rel="@(negedge clk); {p}cyc <= 1'b0; {p}stb <= 1'b0;",
    ),
    "USB2.0": dict(
        pre="", kind="skeleton",
        note="USB 2.0 UTMI skeleton (dp/dm PHY interface placeholder)",
        sigs=[("dp", "", "inout"), ("dm", "", "inout"), ("tx_valid", "", "in"), ("rx_active", "", "out")],
        req="", rdy="", err="", wdrv="", rdrv="", wait="", rel="",
    ),
    "USB3.2": dict(
        pre="", kind="skeleton",
        note="USB 3.2 PIPE skeleton (tx/rx SerDes placeholder)",
        sigs=[("tx_data", "[31:0]", "in"), ("rx_data", "[31:0]", "out"), ("pipe_clk", "", "in")],
        req="", rdy="", err="", wdrv="", rdrv="", wait="", rel="",
    ),
    "PCIe": dict(
        pre="", kind="skeleton",
        note="PCI Express skeleton (per-lan pipe placeholder)",
        sigs=[("rxn", "", "in"), ("rxp", "", "in"), ("txn", "", "out"), ("txp", "", "out"), ("refclk", "", "in")],
        req="", rdy="", err="", wdrv="", rdrv="", wait="", rel="",
    ),
    "CAN": dict(
        pre="", kind="skeleton",
        note="CAN 2.0 skeleton (rxd/txd, bit-stuffing placeholder)",
        sigs=[("rxd", "", "in"), ("txd", "", "out")],
        req="", rdy="", err="", wdrv="", rdrv="", wait="", rel="",
    ),
    "JTAG": dict(
        pre="", kind="skeleton",
        note="JTAG TAP skeleton (TCK/TMS/TDI/TDO, IR/DR FSM placeholder)",
        sigs=[("tck", "", "in"), ("tms", "", "in"), ("tdi", "", "in"), ("tdo", "", "out"), ("trst_n", "", "in")],
        req="", rdy="", err="", wdrv="", rdrv="", wait="", rel="",
    ),
    "I3C": dict(
        pre="", kind="skeleton",
        note="I3C slave skeleton (SDR/HDR placeholder, inherits I2C pins + in-band INT)",
        sigs=[("scl", "", "in"), ("sda", "", "inout"), ("int_n", "", "out")],
        req="", rdy="", err="", wdrv="", rdrv="", wait="", rel="",
    ),
    "MDIO": dict(
        pre="", kind="skeleton",
        note="MDIO/MDC Ethernet management skeleton (TA/PHY-addr placeholder)",
        sigs=[("mdc", "", "in"), ("mdio", "", "inout")],
        req="", rdy="", err="", wdrv="", rdrv="", wait="", rel="",
    ),
    "QSPI": dict(
        pre="", kind="skeleton",
        note="QSPI slave skeleton (4-bit IO, SDR/DTR placeholder)",
        sigs=[("sclk", "", "in"), ("csn", "", "in"), ("io", "[3:0]", "inout")],
        req="", rdy="", err="", wdrv="", rdrv="", wait="", rel="",
    ),
    "SDIO": dict(
        pre="", kind="skeleton",
        note="SD/SDIO slave skeleton (cmd/dat lines, CRC7/CRC16 placeholder)",
        sigs=[("sd_clk", "", "in"), ("cmd", "", "inout"), ("dat", "[3:0]", "inout")],
        req="", rdy="", err="", wdrv="", rdrv="", wait="", rel="",
    ),
    "ACE": dict(
        pre="", kind="mem", burst=True,
        note="ACE slave (AXI4 + snoop AC/CR/CD channels, burst-ready FSM)",
        sigs=[("awvalid", "", "in"), ("awready", "", "out"), ("awaddr", "[31:0]", "in"),
              ("awlen", "[7:0]", "in"), ("wvalid", "", "in"), ("wready", "", "out"),
              ("wdata", "[31:0]", "in"), ("wlast", "", "in"),
              ("bvalid", "", "out"), ("bready", "", "in"),
              ("arvalid", "", "in"), ("arready", "", "out"), ("araddr", "[31:0]", "in"),
              ("arlen", "[7:0]", "in"), ("rvalid", "", "out"), ("rready", "", "in"),
              ("rdata", "[31:0]", "out"), ("rlast", "", "out"),
              ("acvalid", "", "in"), ("acready", "", "out"), ("acaddr", "[31:0]", "in"),
              ("crvalid", "", "out"), ("crready", "", "in"), ("crresp", "[4:0]", "out"),
              ("cdvalid", "", "out"), ("cdready", "", "in"), ("cddata", "[31:0]", "out")],
        map=dict(ADDR="({p}awvalid ? {p}awaddr : {p}araddr)",
                 WDATA="{p}wdata", RDATA="{p}rdata", WRITE="{p}awvalid"),
        req="{p}awvalid || {p}arvalid",
        rdy="{p}awready = (state == ST_ADDR); {p}arready = (state == ST_ADDR);\n"
            "    {p}wready = (state == ST_DATA); {p}bvalid = (state == ST_RESP);\n"
            "    {p}rvalid = (state == ST_RESP); {p}rlast = (state == ST_RESP);\n"
            "    {p}acready = (state == ST_ADDR); {p}crvalid = (state == ST_RESP);\n"
            "    {p}crresp = 5'b00000; {p}cdvalid = 1'b0; {p}cddata = 32'h0;",
        err="",
        wdrv="{p}awvalid <= 1'b1; {p}awaddr <= a; {p}awlen <= 8'h00; @(negedge clk); {p}wvalid <= 1'b1; {p}wdata <= d; {p}wlast <= 1'b1;",
        rdrv="{p}arvalid <= 1'b1; {p}araddr <= a; {p}arlen <= 8'h00;",
        wait="wait ({p}bvalid === 1'b1 || {p}rvalid === 1'b1);",
        rel="@(negedge clk); {p}awvalid <= 1'b0; {p}wvalid <= 1'b0; {p}arvalid <= 1'b0; {p}wlast <= 1'b0;",
    ),
    "ACE-Lite": dict(
        pre="", kind="mem", burst=True,
        note="ACE-Lite slave (AXI4 + snoop AC/CR, no CD; burst-ready FSM)",
        sigs=[("awvalid", "", "in"), ("awready", "", "out"), ("awaddr", "[31:0]", "in"),
              ("awlen", "[7:0]", "in"), ("wvalid", "", "in"), ("wready", "", "out"),
              ("wdata", "[31:0]", "in"), ("wlast", "", "in"),
              ("bvalid", "", "out"), ("bready", "", "in"),
              ("arvalid", "", "in"), ("arready", "", "out"), ("araddr", "[31:0]", "in"),
              ("arlen", "[7:0]", "in"), ("rvalid", "", "out"), ("rready", "", "in"),
              ("rdata", "[31:0]", "out"), ("rlast", "", "out"),
              ("acvalid", "", "in"), ("acready", "", "out"), ("acaddr", "[31:0]", "in"),
              ("crvalid", "", "out"), ("crready", "", "in"), ("crresp", "[4:0]", "out")],
        map=dict(ADDR="({p}awvalid ? {p}awaddr : {p}araddr)",
                 WDATA="{p}wdata", RDATA="{p}rdata", WRITE="{p}awvalid"),
        req="{p}awvalid || {p}arvalid",
        rdy="{p}awready = (state == ST_ADDR); {p}arready = (state == ST_ADDR);\n"
            "    {p}wready = (state == ST_DATA); {p}bvalid = (state == ST_RESP);\n"
            "    {p}rvalid = (state == ST_RESP); {p}rlast = (state == ST_RESP);\n"
            "    {p}acready = (state == ST_ADDR); {p}crvalid = (state == ST_RESP);\n"
            "    {p}crresp = 5'b00000;",
        err="",
        wdrv="{p}awvalid <= 1'b1; {p}awaddr <= a; {p}awlen <= 8'h00; @(negedge clk); {p}wvalid <= 1'b1; {p}wdata <= d; {p}wlast <= 1'b1;",
        rdrv="{p}arvalid <= 1'b1; {p}araddr <= a; {p}arlen <= 8'h00;",
        wait="wait ({p}bvalid === 1'b1 || {p}rvalid === 1'b1);",
        rel="@(negedge clk); {p}awvalid <= 1'b0; {p}wvalid <= 1'b0; {p}arvalid <= 1'b0; {p}wlast <= 1'b0;",
    ),
    "OCP": dict(
        pre="", kind="mem",
        note="OCP-IP slave (MCmd/MAddr/MData -> SCmdAccept/SData/SResp)",
        sigs=[("mcmd", "[2:0]", "in"), ("maddr", "[31:0]", "in"), ("mdata", "[31:0]", "in"),
              ("scmdaccept", "", "out"), ("sdata", "[31:0]", "out"), ("sresp", "[1:0]", "out")],
        map=dict(ADDR="{p}maddr", WDATA="{p}mdata", RDATA="{p}sdata",
                 WRITE="({p}mcmd == 3'b001)"),
        req="{p}mcmd != 3'b000",
        rdy="{p}scmdaccept = (state == ST_ADDR);\n"
            "    {p}sresp = (state == ST_RESP) ? 2'b01 : 2'b00;",
        err="",
        wdrv="{p}mcmd <= 3'b001; {p}maddr <= a; {p}mdata <= d;",
        rdrv="{p}mcmd <= 3'b010; {p}maddr <= a;",
        wait="wait ({p}sresp == 2'b01);",
        rel="@(negedge clk); {p}mcmd <= 3'b000;",
    ),
    "Avalon-MM": dict(
        pre="", kind="mem",
        note="Avalon-MM slave (av_write/av_read, waitrequest backpressure)",
        sigs=[("av_waitrequest", "", "out"), ("av_write", "", "in"), ("av_read", "", "in"),
              ("av_address", "[31:0]", "in"), ("av_writedata", "[31:0]", "in"),
              ("av_readdata", "[31:0]", "out"), ("av_readdatavalid", "", "out")],
        map=dict(ADDR="{p}av_address", WDATA="{p}av_writedata",
                 RDATA="{p}av_readdata", WRITE="{p}av_write"),
        req="{p}av_write || {p}av_read",
        rdy="{p}av_waitrequest = (state != ST_ADDR);\n"
            "    {p}av_readdatavalid = (state == ST_RESP);",
        err="",
        wdrv="{p}av_write <= 1'b1; {p}av_address <= a; {p}av_writedata <= d;",
        rdrv="{p}av_read <= 1'b1; {p}av_address <= a;",
        wait="repeat (4) @(posedge clk);",
        rel="@(negedge clk); {p}av_write <= 1'b0; {p}av_read <= 1'b0;",
    ),
    "CHI": dict(
        pre="", kind="skeleton",
        note="CHI slave skeleton (TX/RX link channels, REQ/RSP/DAT placeholder)",
        sigs=[("txreqflit", "[43:0]", "in"), ("txreqflitv", "", "in"), ("txreqlcrdv", "", "out"), ("rxrspflit", "[33:0]", "out"), ("rxrspflitv", "", "out"), ("rxrsplcrdv", "", "in")],
        req="", rdy="", err="", wdrv="", rdrv="", wait="", rel="",
    ),
    "Avalon-ST": dict(
        pre="", kind="skeleton",
        note="Avalon-ST sink skeleton (valid/ready/data/eop)",
        sigs=[("av_valid", "", "in"), ("av_ready", "", "out"), ("av_data", "[31:0]", "in"), ("av_eop", "", "in")],
        req="", rdy="", err="", wdrv="", rdrv="", wait="", rel="",
    ),
    "ATB": dict(
        pre="", kind="skeleton",
        note="CoreSight ATB slave skeleton (afready/atvalid/atdata)",
        sigs=[("atvalid", "", "in"), ("atready", "", "out"), ("atdata", "[31:0]", "in"), ("atid", "[6:0]", "in")],
        req="", rdy="", err="", wdrv="", rdrv="", wait="", rel="",
    ),
    "RGMII": dict(
        pre="", kind="skeleton",
        note="RGMII PHY skeleton (4-bit DDR tx/rx + rx_ctl/tx_ctl)",
        sigs=[("tx_clk", "", "in"), ("txd", "[3:0]", "out"), ("tx_ctl", "", "out"), ("rx_clk", "", "in"), ("rxd", "[3:0]", "in"), ("rx_ctl", "", "in")],
        req="", rdy="", err="", wdrv="", rdrv="", wait="", rel="",
    ),
    "GMII": dict(
        pre="", kind="skeleton",
        note="GMII PHY skeleton (8-bit tx/rx + en/err)",
        sigs=[("tx_clk", "", "in"), ("txd", "[7:0]", "out"), ("tx_en", "", "out"), ("tx_er", "", "out"), ("rx_clk", "", "in"), ("rxd", "[7:0]", "in"), ("rx_dv", "", "in"), ("rx_er", "", "in")],
        req="", rdy="", err="", wdrv="", rdrv="", wait="", rel="",
    ),
    "XGMII": dict(
        pre="", kind="skeleton",
        note="XGMII skeleton (32-bit tx/rc + term/error columns)",
        sigs=[("tx_clk", "", "in"), ("txd", "[31:0]", "out"), ("txc", "[3:0]", "out"), ("rx_clk", "", "in"), ("rxd", "[31:0]", "in"), ("rxc", "[3:0]", "in")],
        req="", rdy="", err="", wdrv="", rdrv="", wait="", rel="",
    ),
    "SATA": dict(
        pre="", kind="skeleton",
        note="SATA host skeleton (tx/rx OOB + ALIGN primitives placeholder)",
        sigs=[("tx_n", "", "out"), ("tx_p", "", "out"), ("rx_n", "", "in"), ("rx_p", "", "in"), ("refclk", "", "in")],
        req="", rdy="", err="", wdrv="", rdrv="", wait="", rel="",
    ),
    "SAS": dict(
        pre="", kind="skeleton",
        note="SAS initiator skeleton (PHY + SMP/STP/SATA tunnelling placeholder)",
        sigs=[("tx_n", "", "out"), ("tx_p", "", "out"), ("rx_n", "", "in"), ("rx_p", "", "in"), ("refclk", "", "in")],
        req="", rdy="", err="", wdrv="", rdrv="", wait="", rel="",
    ),
    "UFS": dict(
        pre="", kind="skeleton",
        note="UFS host skeleton (M-PHY gear lanes + UniPro CPort placeholder)",
        sigs=[("tx_n", "", "out"), ("tx_p", "", "out"), ("rx_n", "", "in"), ("rx_p", "", "in"), ("refclk", "", "in")],
        req="", rdy="", err="", wdrv="", rdrv="", wait="", rel="",
    ),
    "eMMC": dict(
        pre="", kind="skeleton",
        note="eMMC host skeleton (CMD/DAT[7:0] DDR50/HS200 placeholder)",
        sigs=[("emmc_clk", "", "in"), ("cmd", "", "inout"), ("dat", "[7:0]", "inout"), ("emmc_rst_n", "", "in")],
        req="", rdy="", err="", wdrv="", rdrv="", wait="", rel="",
    ),
    "DDR4": dict(
        pre="", kind="skeleton",
        note="DDR4 controller skeleton (CK/ADDR/CMD/DQ/DQS placeholder)",
        sigs=[("ck_t", "", "out"), ("ck_c", "", "out"), ("addr", "[16:0]", "out"), ("dq", "[15:0]", "inout"), ("dqs", "[1:0]", "inout")],
        req="", rdy="", err="", wdrv="", rdrv="", wait="", rel="",
    ),
    "LPDDR4": dict(
        pre="", kind="skeleton",
        note="LPDDR4 controller skeleton (6-bit CA bus DQ/DQS placeholder)",
        sigs=[("ck_t", "", "out"), ("ck_c", "", "out"), ("ca", "[5:0]", "out"), ("dq", "[15:0]", "inout"), ("dqs", "[1:0]", "inout")],
        req="", rdy="", err="", wdrv="", rdrv="", wait="", rel="",
    ),
    "I2S": dict(
        pre="", kind="skeleton",
        note="I2S controller skeleton (BCLK/LRCK/SDOUT/SDIN)",
        sigs=[("bclk", "", "in"), ("lrck", "", "out"), ("sdout", "", "out"), ("sdin", "", "in")],
        req="", rdy="", err="", wdrv="", rdrv="", wait="", rel="",
    ),
    "PWM": dict(
        pre="", kind="skeleton",
        note="PWM generator skeleton (period/duty registers placeholder)",
        sigs=[("pwm_out", "", "out"), ("pwm_n_out", "", "out")],
        req="", rdy="", err="", wdrv="", rdrv="", wait="", rel="",
    ),
    "GPIO": dict(
        pre="", kind="skeleton",
        note="GPIO bank skeleton (8-bit bidirectional + interrupt)",
        sigs=[("gpio", "[7:0]", "inout"), ("gpio_oe", "[7:0]", "in")],
        req="", rdy="", err="", wdrv="", rdrv="", wait="", rel="",
    ),
    "1-Wire": dict(
        pre="", kind="skeleton",
        note="1-Wire host skeleton (open-drain DQ, ROM commands placeholder)",
        sigs=[("dq", "", "inout"), ("pu_en", "", "out")],
        req="", rdy="", err="", wdrv="", rdrv="", wait="", rel="",
    ),
    "RFFE": dict(
        pre="", kind="skeleton",
        note="MIPI RFFE slave skeleton (sclk/sdata, register paging placeholder)",
        sigs=[("sclk", "", "in"), ("sdata", "", "inout")],
        req="", rdy="", err="", wdrv="", rdrv="", wait="", rel="",
    ),
    "SPMI": dict(
        pre="", kind="skeleton",
        note="MIPI SPMI slave skeleton (sclk/sdata, master arb placeholder)",
        sigs=[("sclk", "", "in"), ("sdata", "", "inout")],
        req="", rdy="", err="", wdrv="", rdrv="", wait="", rel="",
    ),
    "CXL": dict(
        pre="", kind="skeleton",
        note="CXL 2.0 device skeleton (256B flit, CXL.io/cache/mem placeholder)",
        sigs=[("tx_n", "", "out"), ("tx_p", "", "out"), ("rx_n", "", "in"), ("rx_p", "", "in"), ("refclk", "", "in")],
        req="", rdy="", err="", wdrv="", rdrv="", wait="", rel="",
    ),
}
DEFAULT_PROFILE = dict(
    pre="b", kind="mem", note="generic req/gnt/valid bus slave",
    map=dict(ADDR="{p}addr", WDATA="{p}wdata", RDATA="{p}rdata", WRITE="{p}write"),
    sigs=[("req", "", "in"), ("addr", "[31:0]", "in"), ("wdata", "[31:0]", "in"),
          ("rdata", "[31:0]", "out"), ("write", "", "in"),
          ("gnt", "", "out"), ("valid", "", "out")],
    req="{p}req",
    rdy="{p}gnt = (state == ST_ADDR); {p}valid = (state == ST_RESP);",
    err="",
    wdrv="{p}req <= 1'b1; {p}addr <= a; {p}wdata <= d; {p}write <= 1'b1;",
    rdrv="{p}req <= 1'b1; {p}addr <= a; {p}write <= 1'b0;",
    wait="wait ({p}valid === 1'b1);",
    rel="@(negedge clk); {p}req <= 1'b0;",
)

def profile(p):
    return PROFILES.get(p, DEFAULT_PROFILE)

# ---------------- RTL template ----------------
RTL = """// ============================================================================
// {P} protocol Open IP -- synthesizable {note}
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module {S}_top #(
  parameter int DW   = 32,      // data width
  parameter int AW   = 32,      // address width
  parameter int DEPTH = 256     // internal register-file depth
)(
  input  logic           clk,
  input  logic           rst_n,
{ports},
  output logic           irq
);

  typedef enum logic [1:0] {{ST_IDLE, ST_ADDR, ST_DATA, ST_RESP}} state_t;
  state_t state, nstate;

  (* ram_style = "block" *) logic [DW-1:0] mem [0:DEPTH-1];
  logic [AW-1:0] addr_q;
  logic          write_q;
{XDECL}

  // ------------------------------------------------------------------
  // sequential: state + address/write capture + register-file write
  // ------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state   <= ST_IDLE;
      addr_q  <= '0;
      write_q <= 1'b0;
    end else begin
      state <= nstate;
      if (state == ST_ADDR) begin
        addr_q  <= {ADDR};
        write_q <= {WRITE};
{XCAP}      end
      if (state == ST_DATA && write_q)
        mem[addr_q[9:2]] <= {WDATA};
{XSEQ}    end
  end

  // ------------------------------------------------------------------
  // next-state logic
  // ------------------------------------------------------------------
  always_comb begin
    nstate = state;
    case (state)
      ST_IDLE : if ({req})      nstate = ST_ADDR;
      ST_ADDR :                 nstate = ST_DATA;
      ST_DATA : {DNS}
      ST_RESP :                 nstate = ST_IDLE;
      default :                 nstate = ST_IDLE;
    endcase
  end

  // ------------------------------------------------------------------
  // outputs
  // ------------------------------------------------------------------
  always_comb begin
    {RDATA} = mem[addr_q[9:2]];
    {rdy}
    {err}irq = 1'b0;   // tie-off: connect to interrupt logic as needed
  end

endmodule
"""

# ---------------- skeleton template (serial/stream protocols) ----------------
SKELETON = """// ============================================================================
// {P} protocol Open IP -- {note}
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module {S}_top #(
  parameter int DW = 32,       // data width
  parameter int AW = 32        // address width
)(
  input  logic           clk,
  input  logic           rst_n,
{ports},
  output logic           irq
);
  // Skeleton: protocol-specific logic goes here.
  // TODO: replace with bit-level implementation of {note}
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      irq <= 1'b0;
    end else begin
      irq <= 1'b0;
    end
  end

endmodule
"""

def make_rtl(P):
    if P in CUSTOM:
        return CUSTOM[P]["rtl"]
    pr = profile(P); p = pr["pre"]; S = san(P)
    if pr.get("kind") == "skeleton":
        lines = []
        for name, rng, d in pr["sigs"]:
            dirn = {"in": "input ", "out": "output", "inout": "inout "}[d]
            lines.append("  %s logic%s %s%s" % (dirn, rng, p, name))
        return SKELETON.format(P=P, p=p, S=S, note=pr["note"],
                               ports=",\n".join(lines))
    lines = []
    for name, rng, d in pr["sigs"]:
        dirn = "output" if d == "out" else "input "
        lines.append("  %s logic%s %s%s" % (dirn, rng, p, name))
    ports = ",\n".join(lines)
    err = (pr["err"].format(p=p) + "\n    ") if pr["err"] else ""
    mp = {k: v.format(p=p) for k, v in pr.get("map", DEFAULT_PROFILE["map"]).items()}
    if pr.get("burst"):
        xdecl = "  logic [7:0]  len_q, beat_q;"
        xcap  = "        len_q  <= 8'h00;\n        beat_q <= 8'h00;\n"
        xseq  = ("      if (state == ST_DATA && beat_q != len_q) begin\n"
                 "        addr_q <= addr_q + 4;\n"
                 "        beat_q <= beat_q + 1'b1;\n"
                 "      end\n")
        dns   = ("if (beat_q == len_q) nstate = ST_RESP;\n"
                 "                else nstate = ST_DATA;")
    else:
        xdecl = xcap = xseq = ""
        dns   = "nstate = ST_RESP;"
    return RTL.format(P=P, p=p, S=S, note=pr["note"], ports=ports,
                      req=pr["req"].format(p=p), rdy=pr["rdy"].format(p=p),
                      err=err, XDECL=xdecl, XCAP=xcap, XSEQ=xseq, DNS=dns, **mp)

# ---------------- Testbench template ----------------
TB = """// Self-checking testbench for {S}_top -- SystemVerilog
// Auto-generated by gen_framework.py -- Apache-2.0
`timescale 1ns/1ps
module {S}_tb;
  localparam int DW = 32, AW = 32, N = 20;

  logic clk = 0, rst_n = 0;
{decls}

  int errors = 0;

  {S}_top #(.DW(DW), .AW(AW)) dut (
    .clk(clk), .rst_n(rst_n),
{conns},
    .irq()
  );

  always #5 clk = ~clk;

  task automatic do_write(input logic [AW-1:0] a, input logic [DW-1:0] d);
    begin
      @(negedge clk);
      {wdrv}
      {wait}
      if ({errchk})
        begin errors++; $display("ERROR: {P} write resp @%h", a); end
      {rel}
    end
  endtask

  task automatic do_read(input logic [AW-1:0] a, input logic [DW-1:0] exp);
    logic [DW-1:0] got;
    begin
      @(negedge clk);
      {rdrv}
      {wait}
      got = {RDATA};
      if (got !== exp) begin
        errors++;
        $display("ERROR: {P} read @%h got=%h exp=%h", a, got, exp);
      end
      {rel}
    end
  endtask

  initial begin
    rst_n = 0; repeat(4) @(posedge clk);
    rst_n = 1; repeat(2) @(posedge clk);
    for (int i = 0; i < N; i++)
      do_write(32'h1000 + i*4, i * 32'hDEAD_BEEF);
    for (int i = 0; i < N; i++)
      do_read (32'h1000 + i*4, i * 32'hDEAD_BEEF);
    if (errors == 0) $display("TEST PASSED: {P}");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #100000; $display("TIMEOUT"); $finish;
  end
endmodule
"""

def make_tb(P):
    if P in CUSTOM:
        return CUSTOM[P]["tb"]
    pr = profile(P); p = pr["pre"]; S = san(P)
    if pr.get("kind") == "skeleton":
        decls = []
        for name, rng, d in pr["sigs"]:
            t = "tri" if d == "inout" else "logic"
            decls.append("  %s%s %s%s;" % (t, rng, p, name))
        conns = ",\n".join("    .%s%s(%s%s)" % (p, n, p, n) for n, r, d in pr["sigs"])
        s = """// Smoke testbench for {S}_top (skeleton) -- SystemVerilog
// Auto-generated by gen_framework.py -- Apache-2.0
`timescale 1ns/1ps
module {S}_tb;
  logic clk = 0, rst_n = 0;
{decls}

  {S}_top dut (
    .clk(clk), .rst_n(rst_n),
{conns},
    .irq()
  );

  always #5 clk = ~clk;

  initial begin
    rst_n = 0; repeat(4) @(posedge clk);
    rst_n = 1; repeat(10) @(posedge clk);
    $display("TEST PASSED: {P} (skeleton smoke)");
    $finish;
  end

  initial begin
    #100000; $display("TIMEOUT"); $finish;
  end
endmodule
"""
        return s.format(P=P, p=p, S=S, decls="\n".join(decls), conns=conns)
    decls = []
    for name, rng, d in pr["sigs"]:
        decls.append("  logic%s %s%s;" % (rng, p, name))
    conns = ",\n".join("    .%s%s(%s%s)" % (p, n, p, n) for n, r, d in pr["sigs"])
    errchk = ("%sresp !== 2'b00" % p) if p == "h" else "1'b0"
    rdata_sig = pr.get("map", DEFAULT_PROFILE["map"])["RDATA"].format(p=p)
    return TB.format(P=P, p=p, S=S, decls="\n".join(decls), conns=conns,
                     wdrv=pr["wdrv"].format(p=p), rdrv=pr["rdrv"].format(p=p),
                     wait=pr["wait"].format(p=p), rel=pr["rel"].format(p=p),
                     errchk=errchk, RDATA=rdata_sig)

# ---------------- scripts ----------------
YOSYS = """# {P} synthesis script -- Yosys (open-source flow)
read_verilog -sv ../rtl/{S}_top.sv {DEPS}
hierarchy -check -top {S}_top
proc; opt; fsm; opt; memory; opt
techmap; opt
stat
write_json {S}_top.json
write_verilog {S}_top_netlist.v
"""

DC = """# {P} synthesis script -- Synopsys Design Compiler
remove_design -all
analyze -format sverilog ../rtl/{S}_top.sv
elaborate {S}_top
link
read_sdc ../syn/{S}.sdc
compile -map_effort medium
report_area  > rpt/{S}_area.rpt
report_timing > rpt/{S}_timing.rpt
write -format ddc -output netlist/{S}_top.ddc
write -format verilog -output netlist/{S}_top.v
quit
"""

SDC = """# {P} constraints -- target 100 MHz (adjust per project)
create_clock -name clk -period 10 [get_ports clk]
set_clock_uncertainty 0.2 [get_clocks clk]
set_input_delay  2.0 -clock clk [remove_from_collection [all_inputs] [get_ports clk]]
set_output_delay 2.0 -clock clk [all_outputs]
set_driving_cell -lib_cell BUFX2 [all_inputs]
set_load 0.05 [all_outputs]
"""

FILELIST = """+incdir+.
../rtl/{S}_top.sv
../tb/{S}_tb.sv
"""

MAKEFILE = """# {P} Open IP -- sim & synthesis entry points
S      := {S}
DEPS   := {DEPS}
SIM    ?= iverilog
VFLAGS := -g2012 -Wall
SYN    ?= yosys

all: sim syn

sim:
\t$(SIM) $(VFLAGS) -o simv rtl/$(S)_top.sv $(DEPS) tb/$(S)_tb.sv
\t./simv

syn:
\tcd work && $(SYN) ../syn/$(S)_yosys.ys

clean:
\trm -f simv *.vcd work/*.json work/*_netlist.v
.PHONY: all sim syn clean
"""

README = """# {P} Protocol Open IP -- SystemVerilog Design Kit (Apache-2.0)

Auto-generated framework for protocol **{P}** ({note}).

## Directory layout
```
rtl/{S}_top.sv         synthesizable SystemVerilog design (FSM + register file)
tb/{S}_tb.sv           self-checking SystemVerilog testbench
syn/{S}_yosys.ys      Yosys synthesis script (open-source)
syn/{S}_dc.tcl         Synopsys Design Compiler script
syn/{S}.sdc            timing constraints (100 MHz default)
sim/filelist_{S}.f     simulator filelist
Makefile               make sim / make syn / make clean
```

## Quick start
```sh
# simulation (Icarus Verilog)
make sim
# open-source synthesis
mkdir -p work && make syn
# Design Compiler
dc_shell -f syn/{S}_dc.tcl
```

## Notes
- Design is a single-clock FSM (IDLE -> ADDR -> DATA -> RESP) with an
  internal register file; replace the memory with your real slave logic.
- {note}
- Registers map to addresses 0x1000.. by word (addr[9:2] index).
"""

def generate(P):
    pr = profile(P); p = pr["pre"]; S = san(P)
    if P == "DDR4":
        for _src, _name in ((MEMCORE_SRC, "MEMCORE_top.sv"), (MEMCH_SRC, "MEMCH_top.sv")):
            _p = os.path.join(BASE, "rtl", _name)
            if not os.path.exists(_p):
                with open(_p, "w") as f:
                    f.write(_src)
    _memfam = ("DDR4", "DDR5", "DDR6", "DDR7", "HBM", "HBM3", "HBM3E", "HBM4", "HBM5",
               "GDDR5", "GDDR6", "GDDR7",
               "LPDDR4", "LPDDR5", "LPDDR5X", "LPDDR6", "LPDDR7")
    if P in _memfam:
        deps = "rtl/MEMCORE_top.sv rtl/MEMCH_top.sv"
    elif P in ("SAS", "UFS"):
        deps = "rtl/SATA_top.sv"
    else:
        deps = ""
    os.makedirs(os.path.join(BASE, "rtl"), exist_ok=True)
    os.makedirs(os.path.join(BASE, "tb"), exist_ok=True)
    os.makedirs(os.path.join(BASE, "syn"), exist_ok=True)
    os.makedirs(os.path.join(BASE, "sim"), exist_ok=True)
    with open(os.path.join(BASE, "rtl", S + "_top.sv"), "w") as f:
        f.write(make_rtl(P))
    with open(os.path.join(BASE, "tb", S + "_tb.sv"), "w") as f:
        f.write(make_tb(P))
    deps_path = ("../" + deps.replace(" ", " ../")) if deps else ""
    with open(os.path.join(BASE, "syn", S + "_yosys.ys"), "w") as f:
        f.write(YOSYS.format(P=P, S=S, p=p, DEPS=deps_path))
    with open(os.path.join(BASE, "syn", S + "_dc.tcl"), "w") as f:
        f.write(DC.format(P=P, S=S, p=p))
    with open(os.path.join(BASE, "syn", S + ".sdc"), "w") as f:
        f.write(SDC.format(P=P, S=S))
    with open(os.path.join(BASE, "sim", "filelist_%s.f" % S), "w") as f:
        f.write(FILELIST.format(P=P, S=S, p=p))
    with open(os.path.join(BASE, "Makefile.%s" % S), "w") as f:
        f.write(MAKEFILE.format(P=P, S=S, p=p, DEPS=deps))
    with open(os.path.join(BASE, "README.md"), "w") as f:
        f.write(README.format(P=P, S=S, p=p, note=pr["note"]))

def read_protocols(csv_path):
    out = []
    with open(csv_path, encoding="utf-8") as f:
        for row in csv.reader(f):
            if not row or row[0] == "#":
                continue
            if row[1] in ("...", "Protocol"):
                continue
            out.append(row[1])
    return out



MEMCORE_SRC = """// ============================================================================
// Parametric SDRAM controller: DDR4 / DDR5 / LPDDR4 / LPDDR5 variants
// Single bank (educational), command FSM: IDLE-ACT-RD/WR-PRE with tRCD/tRP/
// tCAS timing. gem5 co-verification trace port emits (cmd,addr) per activation
// in gem5 DRAMCtrl trace format ("0xADDR: activate/rd/wr 0xROW").
// OpenCores ddr3_ctrl / gem5 DRAMCtrl simplified style.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module MEMCORE_top #(
  parameter int PROTOCOL = 0,   // 0=DDR4 1=DDR5 2=LPDDR4 3=LPDDR5
  parameter int CL   = 15,      // CAS latency (clk)
  parameter int TRCD = 15,      // RAS->CAS
  parameter int TRP  = 15,      // PRE period
  parameter int AW   = 17       // addr width (LPDDR uses CA bus instead)
)(
  input  logic              clk,
  input  logic              rst_n,
  // host command interface
  input  logic              hvalid,
  output logic              hready,
  input  logic [2:0]        hcmd,     // 0=idle 1=ACT 2=RD 3=WR 4=PRE
  input  logic [31:0]       haddr,
  input  logic [15:0]       hwdata,
  output logic [15:0]       hrdata,
  output logic              hdone,
  // PHY pins
  output logic              ck_t,
  output logic              ck_c,
  output logic [AW-1:0]     addr,
  output logic              ras_n,
  output logic              cas_n,
  output logic              we_n,
  inout  tri [15:0]         dq,
  inout  tri [1:0]          dqs,
  output logic              cke,
  // gem5 co-verification trace port
  output logic              trace_valid,
  output logic [2:0]        trace_cmd,
  output logic [31:0]       trace_addr
);
  localparam int COLW = 8;
  localparam int ROWW = 14;

  // ---------------- memory array (single bank, word granular) ----------------
  (* ram_style = "block" *) logic [15:0] mem [0:(1<<COLW)-1];
  logic [ROWW-1:0] open_row;
  logic       bank_open;

  // ---------------- timings ----------------
  logic [7:0] timer;         // shared down-counter for tRCD/tRP/tCAS
  typedef enum logic [2:0] {D_IDLE, D_ACT, D_RCD, D_RD, D_CAS, D_WR, D_PRE} d_t;
  d_t dstate;
  logic [31:0] cur_addr;
  logic [15:0] wr_data;
  logic        rd_pending;

  assign ck_t = clk;
  assign ck_c = ~clk;
  assign cke  = rst_n;
  assign dqs  = 2'bzz;
  assign hready = (dstate == D_IDLE);
  assign hdone  = (dstate == D_CAS) && (timer == 0) && rd_pending;

  // gem5 trace
  assign trace_valid = (dstate == D_ACT) || (dstate == D_RD) || (dstate == D_WR);
  assign trace_cmd   = (dstate == D_ACT) ? 3'd1 :
                       (dstate == D_RD)  ? 3'd2 : 3'd3;
  assign trace_addr  = cur_addr;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dstate <= D_IDLE; timer <= '0; open_row <= '0; bank_open <= 1'b0;
      cur_addr <= '0; wr_data <= '0; rd_pending <= 1'b0; hrdata <= '0;
      ras_n <= 1'b1; cas_n <= 1'b1; we_n <= 1'b1;
      for (int i = 0; i < (1<<COLW); i++) mem[i] <= 16'h0;
    end else begin
      if (timer != 0) timer <= timer - 1'b1;
      case (dstate)
        D_IDLE: if (hvalid) begin
          cur_addr <= haddr;
          wr_data  <= hwdata;
          rd_pending <= (hcmd == 3'd2);
          case (hcmd)
            3'd1: begin                 // ACT: open row
              dstate <= D_ACT;
              open_row <= haddr[31:18];
              bank_open <= 1'b1;
            end
            3'd2: begin                 // RD (row must be open)
              dstate <= D_RD;
            end
            3'd3: begin                 // WR
              dstate <= D_WR;
            end
            3'd4: begin                 // PRE
              dstate <= D_PRE;
            end
            default: ;
          endcase
        end
        D_ACT: begin
          // assert RAS, emit gem5 activate trace
          ras_n <= 1'b0; cas_n <= 1'b1; we_n <= 1'b1;
          addr  <= {{(AW-ROWW){1'b0}}, open_row};
          dstate <= D_RCD; timer <= TRCD[7:0];
        end
        D_RCD: begin
          ras_n <= 1'b1;
          if (timer == 0) dstate <= D_IDLE;   // back to host for RD/WR
        end
        D_RD: begin
          ras_n <= 1'b1; cas_n <= 1'b0; we_n <= 1'b1;
          addr  <= {{(AW-COLW){1'b0}}, cur_addr[COLW-1:0]};
          dstate <= D_CAS; timer <= CL[7:0];
        end
        D_WR: begin
          ras_n <= 1'b1; cas_n <= 1'b0; we_n <= 1'b0;
          addr  <= {{(AW-COLW){1'b0}}, cur_addr[COLW-1:0]};
          mem[cur_addr[COLW-1:0]] <= wr_data;
          dstate <= D_CAS; timer <= CL[7:0];
        end
        D_CAS: begin
          cas_n <= 1'b1; we_n <= 1'b1;
          if (timer == 0) begin
            if (rd_pending) hrdata <= mem[cur_addr[COLW-1:0]];
            rd_pending <= 1'b0;
            dstate <= D_IDLE;
          end
        end
        D_PRE: begin
          ras_n <= 1'b0; cas_n <= 1'b1; we_n <= 1'b0;
          bank_open <= 1'b0;
          dstate <= D_IDLE; timer <= TRP[7:0];
        end
        default: dstate <= D_IDLE;
      endcase
    end
  end

  // DQ: drive written data during WR, else Hi-Z (educational, no DQS timing)
  assign dq = (dstate == D_WR) ? wr_data : 16'hzzzz;

endmodule
"""

MEMCH_SRC = """// ============================================================================
// MEMCH_top: generic N-channel memory controller wrapper.
// NCH instances of the parametric DDR4_top core share the command bus
// (channel 0 drives addr/RAS/CAS/WE, like a shared CAD bus); channel select
// comes from haddr[8 +: CHW]. Each channel owns dq[gi*16 +: 16].
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module MEMCH_top #(
  parameter int PROTOCOL = 0,
  parameter int NCH      = 2,
  parameter int CL       = 15,
  parameter int TRCD     = 15,
  parameter int TRP      = 15,
  parameter int AW       = 17
)(
  input  logic              clk,
  input  logic              rst_n,
  input  logic              hvalid,
  output logic              hready,
  input  logic [2:0]        hcmd,
  input  logic [31:0]       haddr,
  input  logic [15:0]       hwdata,
  output logic [15:0]       hrdata,
  output logic              hdone,
  output logic              ck_t, ck_c,
  output logic [AW-1:0]     addr,
  output logic              ras_n, cas_n, we_n,
  inout  tri [NCH*16-1:0]   dq,
  inout  tri [1:0]          dqs,
  output logic              cke,
  output logic              trace_valid,
  output logic [2:0]        trace_cmd,
  output logic [31:0]       trace_addr
);
  localparam int CHW = (NCH <= 2) ? 1 : $clog2(NCH);
  wire [CHW-1:0] sel = haddr[8 +: CHW];

  logic [15:0] hrdata_v [0:NCH-1];
  logic        hready_v [0:NCH-1];
  logic        hdone_v  [0:NCH-1];
  logic        tv_v     [0:NCH-1];
  logic [2:0]  tc_v     [0:NCH-1];
  logic [31:0] ta_v     [0:NCH-1];

  genvar gi;
  generate
    for (gi = 0; gi < NCH; gi++) begin : g_ch
      if (gi == 0) begin : g_drv
        // channel 0 drives the shared command bus (shared-CAD model)
        MEMCORE_top #(.PROTOCOL(PROTOCOL), .CL(CL), .TRCD(TRCD), .TRP(TRP), .AW(AW)) core (
          .clk(clk), .rst_n(rst_n),
          .hvalid(hvalid && ((NCH == 1) || (sel == gi[CHW-1:0]))),
          .hready(hready_v[gi]),
          .hcmd(hcmd), .haddr(haddr), .hwdata(hwdata),
          .hrdata(hrdata_v[gi]), .hdone(hdone_v[gi]),
          .ck_t(ck_t), .ck_c(ck_c), .addr(addr),
          .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
          .dq(dq[gi*16 +: 16]), .dqs(dqs), .cke(cke),
          .trace_valid(tv_v[gi]), .trace_cmd(tc_v[gi]), .trace_addr(ta_v[gi]));
      end else begin : g_nd
        // other channels: shared pins left open (driven by ch0)
        MEMCORE_top #(.PROTOCOL(PROTOCOL), .CL(CL), .TRCD(TRCD), .TRP(TRP), .AW(AW)) core (
          .clk(clk), .rst_n(rst_n),
          .hvalid(hvalid && ((NCH == 1) || (sel == gi[CHW-1:0]))),
          .hready(hready_v[gi]),
          .hcmd(hcmd), .haddr(haddr), .hwdata(hwdata),
          .hrdata(hrdata_v[gi]), .hdone(hdone_v[gi]),
          .ck_t(), .ck_c(), .addr(),
          .ras_n(), .cas_n(), .we_n(),
          .dq(dq[gi*16 +: 16]), .dqs(), .cke(),
          .trace_valid(tv_v[gi]), .trace_cmd(tc_v[gi]), .trace_addr(ta_v[gi]));
      end
    end
  endgenerate

  assign hready      = hready_v[sel];
  assign hdone       = hdone_v[sel];
  assign hrdata      = hrdata_v[sel];
  assign trace_valid = tv_v[sel];
  assign trace_cmd   = tc_v[sel];
  assign trace_addr  = ta_v[sel];

endmodule
"""

# ================= custom protocol implementations =================
# Full hand-written RTL + self-checking TB for selected skeleton protocols.

CUSTOM = {}

CUSTOM["UART"] = dict(
rtl="""// ============================================================================
// UART 8N1 transceiver with 16x oversampled RX
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module UART_top #(
  parameter int CLK_FREQ = 50_000_000,
  parameter int BAUD     = 115_200
)(
  input  logic       clk,
  input  logic       rst_n,
  input  logic       rxd,
  output logic       txd,
  input  logic [7:0] tx_data,
  input  logic       tx_valid,
  output logic       tx_ready,
  output logic [7:0] rx_data,
  output logic       rx_valid,
  output logic       irq
);
  localparam int DIV16 = (CLK_FREQ / BAUD) / 16;

  // ---------------- 16x baud tick ----------------
  logic [15:0] div_cnt;
  logic        tick16;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      div_cnt <= '0;
      tick16  <= 1'b0;
    end else if (div_cnt == DIV16-1) begin
      div_cnt <= '0;
      tick16  <= 1'b1;
    end else begin
      div_cnt <= div_cnt + 1'b1;
      tick16  <= 1'b0;
    end
  end

  // ---------------- TX: 8N1 ----------------
  typedef enum logic [1:0] {TX_IDLE, TX_START, TX_DATA, TX_STOP} tx_t;
  tx_t        tstate;
  logic [3:0] tsub, tbit;
  logic [7:0] tshift;

  assign tx_ready = (tstate == TX_IDLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tstate <= TX_IDLE; txd <= 1'b1;
      tsub <= '0; tbit <= '0; tshift <= '0;
    end else case (tstate)
      TX_IDLE: if (tx_valid) begin
        tshift <= tx_data; tstate <= TX_START;
        txd <= 1'b0; tsub <= '0;
      end
      TX_START: if (tick16) begin
        if (tsub == 4'd15) begin
          tsub <= '0; tbit <= '0;
          txd <= tshift[0];
          tshift <= {1'b0, tshift[7:1]};
          tstate <= TX_DATA;
        end else tsub <= tsub + 1'b1;
      end
      TX_DATA: if (tick16) begin
        if (tsub == 4'd15) begin
          tsub <= '0;
          if (tbit == 4'd7) begin
            txd <= 1'b1;
            tstate <= TX_STOP;
          end else begin
            tbit <= tbit + 1'b1;
            txd <= tshift[0];
            tshift <= {1'b0, tshift[7:1]};
          end
        end else tsub <= tsub + 1'b1;
      end
      TX_STOP: if (tick16) begin
        if (tsub == 4'd15) begin
          tsub <= '0;
          tstate <= TX_IDLE;
        end else tsub <= tsub + 1'b1;
      end
      default: tstate <= TX_IDLE;
    endcase
  end

  // ---------------- RX: 8N1, 16x oversample ----------------
  logic rxd_s, rxd_d;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rxd_s <= 1'b1; rxd_d <= 1'b1; end
    else begin rxd_s <= rxd; rxd_d <= rxd_s; end
  end
  wire start_det = rxd_d & ~rxd_s;

  typedef enum logic [1:0] {RX_IDLE, RX_START, RX_DATA, RX_STOP} rx_t;
  rx_t        rstate;
  logic [3:0] rsub, rbit;
  logic [7:0] rshift;

  assign rx_valid = (rstate == RX_STOP) && tick16 && (rsub == 4'd7);
  assign irq      = rx_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rstate <= RX_IDLE; rsub <= '0; rbit <= '0;
      rshift <= '0; rx_data <= '0;
    end else case (rstate)
      RX_IDLE: if (start_det) begin
        rstate <= RX_START; rsub <= '0;
      end
      RX_START: if (tick16) begin
        if (rsub == 4'd7) begin
          rsub <= '0;
          rstate <= rxd_s ? RX_IDLE : RX_DATA;
        end else rsub <= rsub + 1'b1;
      end
      RX_DATA: if (tick16) begin
        if (rsub == 4'd15) begin
          rsub <= '0;
          rshift <= {rxd_s, rshift[7:1]};
          if (rbit == 4'd7) begin
            rbit <= '0;
            rx_data <= {rxd_s, rshift[7:1]};
            rstate <= RX_STOP;
          end else rbit <= rbit + 1'b1;
        end else rsub <= rsub + 1'b1;
      end
      RX_STOP: if (tick16) begin
        if (rsub == 4'd7) begin          // half stop bit: return to IDLE sooner
          rsub <= '0;
          rstate <= RX_IDLE;
        end else rsub <= rsub + 1'b1;
      end
      default: rstate <= RX_IDLE;
    endcase
  end

endmodule
""",
tb="""// Self-checking loopback testbench for UART_top -- SystemVerilog
`timescale 1ns/1ps
module UART_tb;
  localparam int N = 8;
  logic clk = 0, rst_n = 0;
  logic rxd, txd;
  logic [7:0] tx_data;
  logic tx_valid, tx_ready;
  logic [7:0] rx_data;
  logic rx_valid;
  logic [7:0] sent [0:N-1];
  int errors = 0;

  UART_top #(.CLK_FREQ(50_000_000), .BAUD(1_000_000)) dut (
    .clk(clk), .rst_n(rst_n), .rxd(rxd), .txd(txd),
    .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
    .rx_data(rx_data), .rx_valid(rx_valid), .irq());

  always #5 clk = ~clk;
  assign rxd = txd;    // loopback

  initial begin
    tx_valid = 0; tx_data = 0;
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(20) @(posedge clk);
    for (int i = 0; i < N; i++) begin
      sent[i] = 8'hA5 ^ (i * 8'h11);
      wait (tx_ready === 1'b1);        // ensure TX is idle before requesting
      @(negedge clk);
      tx_data  <= sent[i];
      tx_valid <= 1'b1;
      wait (tx_ready === 1'b0);        // now this edge means real acceptance
      @(negedge clk);
      tx_valid <= 1'b0;
      wait (rx_valid === 1'b1);
      @(posedge clk); #1;
      if (rx_data !== sent[i]) begin
        errors++;
        $display("ERROR: UART byte %0d got=%h exp=%h", i, rx_data, sent[i]);
      end
      repeat (40) @(posedge clk);   // inter-frame idle: RX back to IDLE
    end
    if (errors == 0) $display("TEST PASSED: UART");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #5_000_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")

CUSTOM["PWM"] = dict(
rtl="""// ============================================================================
// PWM generator: period/duty registers, active-high output + complement
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module PWM_top #(
  parameter int DW = 32
)(
  input  logic            clk,
  input  logic            rst_n,
  input  logic            wen,
  input  logic [3:0]      waddr,
  input  logic [DW-1:0]   wdata,
  output logic            pwm_out,
  output logic            pwm_n_out,
  output logic            irq
);
  logic [DW-1:0] period_q, duty_q, counter;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      period_q <= '0; duty_q <= '0; counter <= '0;
    end else begin
      if (wen && waddr == 4'd0) period_q <= wdata;
      if (wen && waddr == 4'd1) duty_q   <= wdata;
      if (period_q != 0)
        counter <= (counter >= period_q - 1'b1) ? '0 : counter + 1'b1;
      else
        counter <= '0;
    end
  end

  assign pwm_out   = (period_q != 0) && (counter < duty_q);
  assign pwm_n_out = ~pwm_out;
  assign irq       = (period_q != 0) && (counter == period_q - 1'b1);

endmodule
""",
tb="""// Self-checking testbench for PWM_top -- SystemVerilog
`timescale 1ns/1ps
module PWM_tb;
  logic clk = 0, rst_n = 0;
  logic wen = 0;
  logic [3:0] waddr = 0;
  logic [31:0] wdata = 0;
  int errors = 0;

  PWM_top dut (
    .clk(clk), .rst_n(rst_n), .wen(wen), .waddr(waddr), .wdata(wdata),
    .pwm_out(), .pwm_n_out(), .irq());

  always #5 clk = ~clk;

  task automatic wr(input logic [3:0] a, input logic [31:0] d);
    begin
      @(negedge clk); wen <= 1'b1; waddr <= a; wdata <= d;
      @(negedge clk); wen <= 1'b0;
    end
  endtask

  task automatic check_duty(input int period, input int duty);
    int high = 0;
    begin
      wr(4'd0, period);
      wr(4'd1, duty);
      wait (dut.counter == 0);
      repeat (period) begin
        @(posedge clk); #1;
        if (dut.pwm_out) high++;
      end
      if (high != duty) begin
        errors++;
        $display("ERROR: PWM period=%0d duty=%0d high_count=%0d", period, duty, high);
      end
    end
  endtask

  initial begin
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);
    check_duty(10, 3);
    check_duty(10, 7);
    check_duty(16, 1);
    check_duty(16, 15);
    if (errors == 0) $display("TEST PASSED: PWM");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #100_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")

CUSTOM["GPIO"] = dict(
rtl="""// ============================================================================
// GPIO bank: 8-bit bidirectional, per-bit output-enable, input readback
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module GPIO_top (
  input  logic       clk,
  input  logic       rst_n,
  input  logic       wen,
  input  logic [3:0] waddr,
  input  logic [7:0] wdata,
  input  logic       ren,
  input  logic [3:0] raddr,
  output logic [7:0] rdata,
  inout  tri  [7:0]  gpio,
  input  logic [7:0] gpio_oe,
  output logic       irq
);
  logic [7:0] out_q, in_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_q <= '0; in_q <= '0;
    end else begin
      if (wen && waddr == 4'd0) out_q <= wdata;
      in_q <= gpio;
    end
  end

  assign gpio  = gpio_oe ? out_q : 8'hzz;
  assign rdata = (raddr == 4'd0) ? in_q :
                 (raddr == 4'd1) ? out_q : 8'h00;
  assign irq   = |in_q;

endmodule
""",
tb="""// Self-checking testbench for GPIO_top -- SystemVerilog
`timescale 1ns/1ps
module GPIO_tb;
  logic clk = 0, rst_n = 0;
  logic wen = 0, ren = 0;
  logic [3:0] waddr = 0, raddr = 0;
  logic [7:0] wdata = 0, rdata;
  logic [7:0] gpio_oe = 0;
  logic [7:0] drive_val = 0;
  logic       drive_en = 0;
  tri  [7:0]  gpio;
  int errors = 0;

  GPIO_top dut (
    .clk(clk), .rst_n(rst_n), .wen(wen), .waddr(waddr), .wdata(wdata),
    .ren(ren), .raddr(raddr), .rdata(rdata),
    .gpio(gpio), .gpio_oe(gpio_oe), .irq());

  always #5 clk = ~clk;
  assign gpio = drive_en ? drive_val : 8'hzz;

  task automatic wr(input logic [3:0] a, input logic [7:0] d);
    begin
      @(negedge clk); wen <= 1'b1; waddr <= a; wdata <= d;
      @(negedge clk); wen <= 1'b0;
    end
  endtask

  task automatic rd(input logic [3:0] a, output logic [7:0] d);
    begin
      @(negedge clk); ren <= 1'b1; raddr <= a;
      #1 d = rdata;
      @(negedge clk); ren <= 1'b0;
    end
  endtask

  logic [7:0] got;
  initial begin
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);

    gpio_oe = 8'hFF;
    wr(4'd0, 8'hA5);
    repeat(2) @(posedge clk); #1;
    if (gpio !== 8'hA5) begin
      errors++; $display("ERROR: GPIO output got=%h exp=A5", gpio);
    end

    rd(4'd0, got);
    if (got !== 8'hA5) begin
      errors++; $display("ERROR: GPIO loopback got=%h exp=A5", got);
    end

    gpio_oe = 8'h00;
    drive_en = 1'b1; drive_val = 8'h3C;
    repeat(2) @(posedge clk);
    rd(4'd0, got);
    if (got !== 8'h3C) begin
      errors++; $display("ERROR: GPIO input got=%h exp=3C", got);
    end

    rd(4'd1, got);
    if (got !== 8'hA5) begin
      errors++; $display("ERROR: GPIO out_reg got=%h exp=A5", got);
    end

    if (errors == 0) $display("TEST PASSED: GPIO");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #100_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")

CUSTOM["SPI"] = dict(
rtl="""// ============================================================================
// SPI slave, mode 0 (CPOL=0 CPHA=0), 8-bit frames, byte IRQ
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module SPI_top (
  input  logic       clk,
  input  logic       rst_n,
  input  logic       sclk,
  input  logic       mosi,
  output logic       miso,
  input  logic       csn,
  input  logic       wen,
  input  logic [3:0] waddr,
  input  logic [7:0] wdata,
  input  logic       ren,
  input  logic [3:0] raddr,
  output logic [7:0] rdata,
  output logic       irq
);
  logic [7:0] tx_q, rx_q;
  logic [2:0] bit_cnt;
  logic       sclk_d, byte_done;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sclk_d <= 1'b0; bit_cnt <= '0; rx_q <= '0;
      tx_q <= '0; byte_done <= 1'b0;
    end else begin
      sclk_d <= sclk;
      byte_done <= 1'b0;
      if (wen && waddr == 4'd0) tx_q <= wdata;
      if (!csn && sclk && !sclk_d) begin
        rx_q <= {rx_q[6:0], mosi};
        if (bit_cnt == 3'd7) begin
          bit_cnt <= '0;
          byte_done <= 1'b1;
        end else begin
          bit_cnt <= bit_cnt + 1'b1;
        end
      end
      if (csn) bit_cnt <= '0;
    end
  end

  assign miso  = tx_q[7 - bit_cnt];
  assign rdata = (raddr == 4'd0) ? rx_q :
                 (raddr == 4'd1) ? tx_q : 8'h00;
  assign irq   = byte_done;

endmodule
""",
tb="""// Self-checking testbench: TB acts as SPI master (mode 0) -- SystemVerilog
`timescale 1ns/1ps
module SPI_tb;
  logic clk = 0, rst_n = 0;
  logic sclk = 0, mosi = 0, csn = 1;
  logic miso;
  logic wen = 0, ren = 0;
  logic [3:0] waddr = 0, raddr = 0;
  logic [7:0] wdata = 0, rdata;
  int errors = 0;

  SPI_top dut (
    .clk(clk), .rst_n(rst_n), .sclk(sclk), .mosi(mosi), .miso(miso),
    .csn(csn), .wen(wen), .waddr(waddr), .wdata(wdata),
    .ren(ren), .raddr(raddr), .rdata(rdata), .irq());

  always #5 clk = ~clk;

  task automatic wr(input logic [3:0] a, input logic [7:0] d);
    begin
      @(negedge clk); wen <= 1'b1; waddr <= a; wdata <= d;
      @(negedge clk); wen <= 1'b0;
    end
  endtask

  task automatic rd(input logic [3:0] a, output logic [7:0] d);
    begin
      @(negedge clk); ren <= 1'b1; raddr <= a;
      #1 d = rdata;
      @(negedge clk); ren <= 1'b0;
    end
  endtask

  task automatic spi_xfer(input logic [7:0] din, output logic [7:0] dout);
    begin
      csn = 1'b0;
      for (int i = 0; i < 8; i++) begin
        mosi = din[7-i];
        #40 sclk = 1'b1;
        #1 dout[7-i] = miso;
        #39 sclk = 1'b0;
      end
      csn = 1'b1;
      #80;
    end
  endtask

  logic [7:0] d1, d2, got;
  initial begin
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);

    wr(4'd0, 8'h3C);
    spi_xfer(8'h00, d1);
    spi_xfer(8'hA7, d2);
    rd(4'd0, got);

    if (d1 !== 8'h3C) begin errors++; $display("ERROR: SPI MISO xfer1 got=%h exp=3C", d1); end
    if (d2 !== 8'h3C) begin errors++; $display("ERROR: SPI MISO xfer2 got=%h exp=3C", d2); end
    if (got !== 8'hA7) begin errors++; $display("ERROR: SPI MOSI got=%h exp=A7", got); end

    if (errors == 0) $display("TEST PASSED: SPI");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #500_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")




CUSTOM["I2C"] = dict(
rtl="""// ============================================================================
// I2C slave: START/STOP detect, 7-bit address match, ACK, byte RX/TX
// Open-drain SDA (drive low / release). All logic in clk domain with
// synchronized SCL/SDA edge detection.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module I2C_top #(
  parameter int I2C_ADDR = 7'h50
)(
  input  logic       clk,
  input  logic       rst_n,
  inout  tri         sda,
  input  logic       scl,
  input  logic [7:0] tx_byte,    // data to send in read mode
  output logic [7:0] rx_byte,    // last byte received in write mode
  output logic       rx_valid,   // 1-clk pulse per received byte
  output logic       busy,
  output logic       irq
);
  // ---------------- input synchronization ----------------
  logic scl_s, scl_d, sda_s, sda_d;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      scl_s <= 1'b1; scl_d <= 1'b1; sda_s <= 1'b1; sda_d <= 1'b1;
    end else begin
      scl_s <= scl; scl_d <= scl_s;
      sda_s <= sda; sda_d <= sda_s;
    end
  end
  wire scl_rise  =  scl_s & ~scl_d;
  wire scl_fall  = ~scl_s &  scl_d;
  wire start_det = ~sda_s &  sda_d & scl_s;   // SDA falls while SCL high
  wire stop_det  =  sda_s & ~sda_d & scl_s;   // SDA rises while SCL high

  // ---------------- FSM ----------------
  typedef enum logic [2:0] {
    ST_IDLE, ST_ADDR, ST_ACK, ST_RX, ST_TX, ST_TXACK, ST_IGNORE
  } st_t;
  st_t      state;
  logic [3:0] bit_cnt;
  logic [7:0] shift;
  logic       rw, ack_low, txack_done;

  assign sda     = ack_low ? 1'b0 : 1'bz;
  assign busy    = (state != ST_IDLE) && (state != ST_IGNORE);
  assign irq     = rx_valid;

  wire [7:0] addr_byte = {shift[6:0], sda_s};   // byte assembled on 8th bit

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= ST_IDLE; bit_cnt <= '0; shift <= '0;
      rw <= 1'b0; ack_low <= 1'b0; txack_done <= 1'b0;
      rx_byte <= '0; rx_valid <= 1'b0;
    end else begin
      rx_valid <= 1'b0;
      if (start_det) begin
        state <= ST_ADDR; bit_cnt <= '0; ack_low <= 1'b0; txack_done <= 1'b0;
      end else if (stop_det) begin
        state <= ST_IDLE; ack_low <= 1'b0; txack_done <= 1'b0;
      end else case (state)
        // -------- address phase --------
        ST_ADDR: if (scl_rise) begin
          shift <= addr_byte;
          if (bit_cnt == 4'd7) begin
            bit_cnt <= '0;
            if (addr_byte[7:1] == I2C_ADDR[6:0]) begin
              rw   <= addr_byte[0];
              state <= ST_ACK;          // ACK will be driven on next SCL fall
            end else begin
              state <= ST_IGNORE;       // not us: release SDA
            end
          end else begin
            bit_cnt <= bit_cnt + 1'b1;
          end
        end

        // -------- ACK bit: drive SDA low between 8th-bit fall and 9th-bit fall --------
        ST_ACK: begin
          if (!ack_low) begin
            if (scl_fall) ack_low <= 1'b1;
          end else if (scl_fall) begin
            ack_low <= 1'b0;
            if (rw) begin
              // present MSB of first byte at this fall (last NBA wins)
              ack_low <= (tx_byte[7] == 1'b0);
              state <= ST_TX;
            end else begin
              state <= ST_RX;           // release SDA for data phase
            end
          end
        end

        // -------- write: receive bytes --------
        ST_RX: if (scl_rise) begin
          shift <= addr_byte;
          if (bit_cnt == 4'd7) begin
            rx_byte  <= addr_byte;
            rx_valid <= 1'b1;
            bit_cnt  <= '0;
            state    <= ST_ACK;         // ACK each received byte
          end else begin
            bit_cnt <= bit_cnt + 1'b1;
          end
        end

        // -------- read: transmit tx_byte MSB-first --------
        ST_TX: if (scl_fall) begin
          if (bit_cnt == 4'd7) begin
            bit_cnt <= '0;
            ack_low <= 1'b0;            // release SDA for master ACK
            state   <= ST_TXACK;
          end else begin
            bit_cnt <= bit_cnt + 1'b1;
            // present next bit after this fall (valid at next rise)
            ack_low <= (tx_byte[6-bit_cnt] == 1'b0);
          end
        end

        // -------- master ACK/NACK after 8 transmitted bits --------
        ST_TXACK: begin
          if (!txack_done) begin
            if (scl_rise) begin
              txack_done <= 1'b1;
              if (sda_s == 1'b1) begin
                state <= ST_IDLE;       // NACK: transaction done
              end
            end
          end else if (scl_fall) begin
            txack_done <= 1'b0;
            if (state == ST_TXACK) begin
              bit_cnt <= '0;
              ack_low <= (tx_byte[7] == 1'b0);   // ACKed: present first bit
              state   <= ST_TX;
            end
          end
        end

        default: ;  // ST_IGNORE, ST_IDLE: wait for START/STOP
      endcase
    end
  end

endmodule
""",
tb="""// Self-checking testbench: TB acts as I2C master (bit-bang) -- SystemVerilog
`timescale 1ns/1ps
module I2C_tb;
  logic clk = 0, rst_n = 0;
  tri1 sda;                      // open-drain bus with pullup
  logic scl = 1;
  logic master_low = 0;          // open-drain: TB pulls low or releases
  logic [7:0] tx_byte, rx_byte;
  logic rx_valid, busy;
  logic rx_seen = 0;
  int errors = 0;

  I2C_top #(.I2C_ADDR(7'h50)) dut (
    .clk(clk), .rst_n(rst_n), .sda(sda), .scl(scl),
    .tx_byte(tx_byte), .rx_byte(rx_byte), .rx_valid(rx_valid),
    .busy(busy), .irq());

  always #5 clk = ~clk;
  assign sda = master_low ? 1'b0 : 1'bz;
  always @(posedge clk) if (rx_valid) rx_seen <= 1'b1;

  task automatic i2c_start;
    begin
      master_low = 0; scl = 1; #300;
      master_low = 1;        #300;   // SDA falls while SCL high
      scl = 0;               #300;
    end
  endtask

  task automatic i2c_stop;
    begin
      master_low = 1;        #300;
      scl = 1;               #300;
      master_low = 0;        #300;   // SDA rises while SCL high
      #300;
    end
  endtask

  task automatic i2c_wbyte(input logic [7:0] d, output logic ack);
    begin
      for (int i = 0; i < 8; i++) begin
        master_low = ~d[7-i];  #300;
        scl = 1;               #600;
        scl = 0;               #300;
      end
      master_low = 0;          #300;   // release for ACK
      scl = 1;                 #300;
      ack = (sda === 1'b0);
      #300; scl = 0;           #600;
    end
  endtask

  task automatic i2c_rbyte(input logic send_ack, output logic [7:0] d);
    begin
      master_low = 0;
      for (int i = 0; i < 8; i++) begin
        #300; scl = 1; #300;
        d[7-i] = sda;
        #300; scl = 0; #300;
      end
      master_low = send_ack;   #300;   // ACK = pull low
      scl = 1;                 #600;
      scl = 0;                 #300;
      master_low = 0;          #300;
    end
  endtask

  logic ack, rdata;
  logic [7:0] rb;
  initial begin
    tx_byte = 8'hC3;
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(10) @(posedge clk);

    // ---- write 0x5A to slave ----
    i2c_start;
    i2c_wbyte(8'hA0, ack);                 // addr 0x50 + W
    if (!ack) begin errors++; $display("ERROR: I2C no ACK on addr W"); end
    i2c_wbyte(8'h5A, ack);
    if (!ack) begin errors++; $display("ERROR: I2C no ACK on data"); end
    i2c_stop;
    repeat(10) @(posedge clk);
    if (!rx_seen)  begin errors++; $display("ERROR: I2C rx_valid never pulsed"); end
    if (rx_byte !== 8'h5A) begin errors++; $display("ERROR: I2C rx_byte=%h exp=5A", rx_byte); end

    // ---- read back (tx_byte) ----
    i2c_start;
    i2c_wbyte(8'hA1, ack);                 // addr 0x50 + R
    if (!ack) begin errors++; $display("ERROR: I2C no ACK on addr R"); end
    i2c_rbyte(1'b0, rb);                   // NACK after byte
    if (rb !== 8'hC3) begin errors++; $display("ERROR: I2C read got=%h exp=C3", rb); end
    i2c_stop;

    // ---- wrong address must NACK ----
    i2c_start;
    i2c_wbyte(8'hA2, ack);                 // addr 0x51: not us
    if (ack) begin errors++; $display("ERROR: I2C wrong addr ACKed"); end
    i2c_stop;

    if (errors == 0) $display("TEST PASSED: I2C");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #2_000_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")

CUSTOM["I2S"] = dict(
rtl="""// ============================================================================
// I2S slave transmitter/receiver, 16-bit samples, 2 channels
// Samples SDIN on BCLK rise, shifts SDOUT on BCLK fall (I2S standard).
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module I2S_top #(
  parameter int DW = 16
)(
  input  logic            clk,
  input  logic            rst_n,
  input  logic            bclk,
  input  logic            lrck,      // 0 = left, 1 = right
  input  logic            sdin,
  output logic            sdout,
  input  logic            wen,
  input  logic [3:0]      waddr,     // 0: tx_left, 1: tx_right
  input  logic [DW-1:0]   wdata,
  input  logic            ren,
  input  logic [3:0]      raddr,     // 0: rx_left, 1: rx_right
  output logic [DW-1:0]   rdata,
  output logic            irq        // frame-sync (LRCK change) pulse
);
  logic [DW-1:0] tx_left, tx_right, rx_left, rx_right;
  logic [DW-1:0] tx_shift, rx_shift;
  logic [4:0]    bit_cnt;
  logic          bclk_s, bclk_d, lrck_s, lrck_d;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      bclk_s <= 1'b0; bclk_d <= 1'b0;
      lrck_s <= 1'b0; lrck_d <= 1'b0;
    end else begin
      bclk_s <= bclk; bclk_d <= bclk_s;
      lrck_s <= lrck; lrck_d <= lrck_s;
    end
  end
  wire bclk_rise   =  bclk_s & ~bclk_d;
  wire bclk_fall   = ~bclk_s &  bclk_d;
  wire lrck_change =  lrck_s ^  lrck_d;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_left <= '0; tx_right <= '0;
      rx_left <= '0; rx_right <= '0;
    end else begin
      if (wen && waddr == 4'd0) tx_left  <= wdata;
      if (wen && waddr == 4'd1) tx_right <= wdata;
      if (bclk_rise && bit_cnt == DW-1) begin
        if (!lrck_s) rx_left  <= {rx_shift[DW-2:0], sdin};
        else         rx_right <= {rx_shift[DW-2:0], sdin};
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_shift <= '0; rx_shift <= '0; bit_cnt <= '0;
    end else if (lrck_change) begin
      bit_cnt  <= '0;
      tx_shift <= lrck_s ? tx_right : tx_left;   // reload new channel
    end else begin
      if (bclk_rise)
        bit_cnt <= (bit_cnt == DW-1) ? '0 : bit_cnt + 1'b1;
      if (bclk_rise)
        rx_shift <= {rx_shift[DW-2:0], sdin};
      if (bclk_fall)
        tx_shift <= {tx_shift[DW-2:0], 1'b0};
    end
  end

  assign sdout = tx_shift[DW-1];
  assign rdata = (raddr == 4'd0) ? rx_left :
                 (raddr == 4'd1) ? rx_right : '0;
  assign irq   = lrck_change;

endmodule
""",
tb="""// Self-checking testbench for I2S_top: loopback SDIN=SDOUT -- SystemVerilog
`timescale 1ns/1ps
module I2S_tb;
  logic clk = 0, rst_n = 0;
  logic bclk = 0, lrck = 0;
  logic sdin, sdout;
  logic wen = 0, ren = 0;
  logic [3:0] waddr = 0, raddr = 0;
  logic [15:0] wdata = 0, rdata;
  int errors = 0;

  I2S_top dut (
    .clk(clk), .rst_n(rst_n), .bclk(bclk), .lrck(lrck),
    .sdin(sdin), .sdout(sdout),
    .wen(wen), .waddr(waddr), .wdata(wdata),
    .ren(ren), .raddr(raddr), .rdata(rdata), .irq());

  always #5 clk = ~clk;
  assign sdin = sdout;   // loopback

  task automatic wr(input logic [3:0] a, input logic [15:0] d);
    begin
      @(negedge clk); wen <= 1'b1; waddr <= a; wdata <= d;
      @(negedge clk); wen <= 1'b0;
    end
  endtask

  task automatic rd(input logic [3:0] a, output logic [15:0] d);
    begin
      @(negedge clk); ren <= 1'b1; raddr <= a;
      #1 d = rdata;
      @(negedge clk); ren <= 1'b0;
    end
  endtask

  task automatic channel(input logic lr);
    begin
      if (lrck == lr) lrck = ~lr;   // force a transition so frame-sync fires
      #600;
      lrck = lr;
      #600;
      for (int i = 0; i < 16; i++) begin
        bclk = 1; #300; bclk = 0; #300;
      end
    end
  endtask

  logic [15:0] gotL, gotR;
  initial begin
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(10) @(posedge clk);

    wr(4'd0, 16'h1234);   // tx_left
    wr(4'd1, 16'hABCD);   // tx_right

    channel(1'b0);        // left frame:  shifts tx_left out, loops back in
    channel(1'b1);        // right frame: shifts tx_right out

    rd(4'd0, gotL);
    rd(4'd1, gotR);
    if (gotL !== 16'h1234) begin errors++; $display("ERROR: I2S left got=%h exp=1234", gotL); end
    if (gotR !== 16'hABCD) begin errors++; $display("ERROR: I2S right got=%h exp=ABCD", gotR); end

    // second pass: change data, verify again
    wr(4'd0, 16'h55AA);
    channel(1'b0);
    rd(4'd0, gotL);
    if (gotL !== 16'h55AA) begin errors++; $display("ERROR: I2S left2 got=%h exp=55AA", gotL); end

    if (errors == 0) $display("TEST PASSED: I2S");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #1_000_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")




CUSTOM["JTAG"] = dict(
rtl="""// ============================================================================
// JTAG TAP controller, IEEE 1149.1
// 16-state FSM in TCK domain; IDCODE / BYPASS / USER data registers.
// Style follows classic OpenCores jtag/openjtag TAP cores.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module JTAG_top #(
  parameter logic [31:0] IDCODE = 32'h1CAF_0001
)(
  input  logic clk,
  input  logic rst_n,
  input  logic tck,
  input  logic tms,
  input  logic tdi,
  input  logic trst_n,
  output logic tdo,
  output logic irq
);
  // ---------------- TAP FSM (TCK domain) ----------------
  typedef enum logic [3:0] {
    TLR = 4'd0,  RTI,      SEL_DR, CAP_DR,
    SH_DR,       EX1_DR,   PAUSE_DR, EX2_DR,
    UPD_DR,      SEL_IR,   CAP_IR,   SH_IR,
    EX1_IR,      PAUSE_IR, EX2_IR,   UPD_IR
  } tap_t;
  tap_t tap_q;

  always_ff @(posedge tck or negedge trst_n) begin
    if (!trst_n) tap_q <= TLR;
    else case (tap_q)
      TLR:      tap_q <= tms ? TLR     : RTI;
      RTI:      tap_q <= tms ? SEL_DR  : RTI;
      SEL_DR:   tap_q <= tms ? SEL_IR  : CAP_DR;
      CAP_DR:   tap_q <= tms ? EX1_DR  : SH_DR;
      SH_DR:    tap_q <= tms ? EX1_DR  : SH_DR;
      EX1_DR:   tap_q <= tms ? UPD_DR  : PAUSE_DR;
      PAUSE_DR: tap_q <= tms ? EX2_DR  : PAUSE_DR;
      EX2_DR:   tap_q <= tms ? UPD_DR  : SH_DR;
      UPD_DR:   tap_q <= tms ? SEL_DR  : RTI;
      SEL_IR:   tap_q <= tms ? TLR     : CAP_IR;
      CAP_IR:   tap_q <= tms ? EX1_IR  : SH_IR;
      SH_IR:    tap_q <= tms ? EX1_IR  : SH_IR;
      EX1_IR:   tap_q <= tms ? UPD_IR  : PAUSE_IR;
      PAUSE_IR: tap_q <= tms ? EX2_IR  : PAUSE_IR;
      EX2_IR:   tap_q <= tms ? UPD_IR  : SH_IR;
      UPD_IR:   tap_q <= tms ? SEL_DR  : RTI;
      default:  tap_q <= TLR;
    endcase
  end

  // ---------------- instruction + data registers ----------------
  localparam logic [3:0] IR_IDCODE = 4'b0001;
  localparam logic [3:0] IR_USER   = 4'b0010;
  localparam logic [3:0] IR_BYPASS = 4'b1111;

  logic [3:0]  ir_q, sh_ir;
  logic        sh_byp;
  logic [7:0]  user_q, sh_user;
  logic [31:0] sh_id;

  // posedge TCK: FSM (tap_q), chain capture, IR/DR update
  always_ff @(posedge tck or negedge trst_n) begin
    if (!trst_n) begin
      ir_q <= IR_BYPASS; sh_ir <= '0; sh_byp <= 1'b0;
      user_q <= '0; sh_user <= '0; sh_id <= '0;
    end else begin
      if (tap_q == CAP_IR) sh_ir <= 4'b0101;              // capture pattern
      if (tap_q == UPD_IR) ir_q  <= sh_ir;
      if (tap_q == CAP_DR) begin
        case (ir_q)
          IR_IDCODE: sh_id   <= IDCODE;
          IR_USER:   sh_user <= user_q;
          default:   sh_byp  <= 1'b0;
        endcase
      end
      if (tap_q == UPD_DR && ir_q == IR_USER) user_q <= sh_user;
    end
  end

  // posedge TCK in Shift state: TDO <= pre-shift LSB; chain shifts (TDI in).
  // Master samples TDO after the falling edge -> sees bit shifted out this edge.
  wire cur_lsb = (tap_q == SH_IR) ? sh_ir[0] :
                 (ir_q == IR_IDCODE) ? sh_id[0] :
                 (ir_q == IR_USER)   ? sh_user[0] : sh_byp;
  logic tdo_q;
  always_ff @(posedge tck or negedge trst_n) begin
    if (!trst_n) begin
      tdo_q <= 1'b0; sh_ir <= '0;
    end else if (tap_q == SH_IR) begin
      tdo_q <= cur_lsb;
      sh_ir <= {tdi, sh_ir[3:1]};
    end
  end
  always_ff @(posedge tck or negedge trst_n) begin
    if (!trst_n) begin
      sh_id <= '0; sh_user <= '0; sh_byp <= 1'b0;
    end else if (tap_q == SH_DR) begin
      tdo_q <= cur_lsb;
      case (ir_q)
        IR_IDCODE: sh_id   <= {tdi, sh_id[31:1]};
        IR_USER:   sh_user <= {tdi, sh_user[7:1]};
        default:   sh_byp  <= tdi;
      endcase
    end
  end

  assign tdo = tdo_q;
  assign irq = (tap_q == UPD_DR);

endmodule
""",
tb="""// Self-checking testbench for JTAG_top: IDCODE / USER / BYPASS scans
// Reference: OpenCores jtag test sequences -- SystemVerilog
`timescale 1ns/1ps
module JTAG_tb;
  logic clk = 0, rst_n = 0;
  logic tck = 0, tms = 1, tdi = 0, trst_n = 0;
  logic tdo;
  logic tdo_s;
  int errors = 0;

  JTAG_top dut (
    .clk(clk), .rst_n(rst_n), .tck(tck), .tms(tms), .tdi(tdi),
    .trst_n(trst_n), .tdo(tdo), .irq());

  always #5 clk = ~clk;

  task automatic jcyc(input logic tms_v, input logic tdi_v);
    begin
      tms = tms_v; tdi = tdi_v;
      #100 tck = 1'b1; #100;
      tck = 1'b0; #10 tdo_s = tdo; #90;
    end
  endtask

  task automatic goto_rti;
    begin
      for (int i = 0; i < 5; i++) jcyc(1'b1, 1'b0);   // TLR
      jcyc(1'b0, 1'b0);                               // RTI
    end
  endtask

  // shift IR (4 bits, LSB first), last bit exits to UPDATE_IR
  task automatic load_ir(input logic [3:0] op);
    begin
      jcyc(1'b1, 1'b0);                 // SEL_DR
      jcyc(1'b1, 1'b0);                 // SEL_IR
      jcyc(1'b0, 1'b0);                 // -> CAP_IR
      jcyc(1'b0, 1'b0);                 // CAP_IR: capture 0101, -> SH_IR
      jcyc(1'b0, op[0]);                // shift 1
      jcyc(1'b0, op[1]);                // shift 2
      jcyc(1'b0, op[2]);                // shift 3
      jcyc(1'b1, op[3]);                // shift 4 + exit
      jcyc(1'b1, 1'b0);                 // UPD_IR
      jcyc(1'b0, 1'b0);                 // RTI
    end
  endtask

  task automatic scan_dr(input int n, input logic [31:0] din,
                         output logic [31:0] dout);
    logic [31:0] tmp;
    begin
      jcyc(1'b1, 1'b0);                 // SEL_DR
      jcyc(1'b0, 1'b0);                 // -> CAP_DR
      jcyc(1'b0, 1'b0);                 // CAP_DR: capture, -> SH_DR
      for (int k = 0; k < n; k++) begin
        jcyc(k == n-1, din[k]);         // shift bit k, TDO shows pre-shift LSB
        tmp[k] = tdo_s;
      end
      jcyc(1'b1, 1'b0);                 // EX1_DR -> UPD_DR
      jcyc(1'b0, 1'b0);                 // -> RTI
      dout = tmp;
    end
  endtask

  logic [31:0] rd;
  initial begin
    rst_n = 0; trst_n = 0;
    #200;
    rst_n = 1; trst_n = 1;
    #500;

    // ---- IDCODE scan ----
    goto_rti;
    load_ir(4'b0001);                      // IDCODE
    scan_dr(32, 32'h0, rd);
    if (rd !== 32'h1CAF_0001) begin
      errors++; $display("ERROR: JTAG IDCODE got=%h exp=1CAF0001", rd);
    end

    // ---- USER reg write 0xA5 then read back ----
    goto_rti;
    load_ir(4'b0010);                      // USER
    scan_dr(8, 32'h0000_00A5, rd);
    goto_rti;
    load_ir(4'b0010);
    scan_dr(8, 32'h0, rd);
    if (rd[7:0] !== 8'hA5) begin
      errors++; $display("ERROR: JTAG USER got=%h exp=A5", rd[7:0]);
    end

    // ---- BYPASS: scanned value = {din[6:0], capture_bit} = din<<1 ----
    goto_rti;
    load_ir(4'b1111);                      // BYPASS
    scan_dr(8, 32'h0000_003C, rd);         // pattern 00111100 LSB-first
    if (rd[7:0] !== 8'h78) begin           // capture(0) first, then din[0..6]
      errors++; $display("ERROR: JTAG BYPASS got=%h exp=78", rd[7:0]);
    end

    if (errors == 0) $display("TEST PASSED: JTAG");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #5_000_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")

CUSTOM["MDIO"] = dict(
rtl="""// ============================================================================
// MDIO slave (IEEE 802.3 Clause 22 PHY management)
// ST(01) + OP(2) + PHYAD(5) + REGAD(5) + TA(2) + DATA(16), MSB first.
// Open-drain MDIO; read data driven from bit 14..29 window.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module MDIO_top #(
  parameter int PHY_ADDR = 5'h0C
)(
  input  logic        clk,
  input  logic        rst_n,
  inout  tri          mdio,
  input  logic        mdc,
  output logic        irq
);
  logic [15:0] regs [0:31];
  logic        mdc_s, mdc_d, mdio_s;
  logic        frame_act;
  logic        prev_bit;             // mdio sampled at previous mdc rising edge
  logic [5:0]  cnt;
  logic [31:0] shift;
  logic        read_frame, read_match;
  logic [4:0]  regad_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mdc_s <= 1'b0; mdc_d <= 1'b0; mdio_s <= 1'b1;
    end else begin
      mdc_s <= mdc; mdc_d <= mdc_s;
      mdio_s <= mdio;
    end
  end
  wire mdc_rise = mdc_s & ~mdc_d;

  // read data drive window (TA released, DATA bits driven)
  wire [15:0] rd_reg = regs[regad_q];
  // DATA[15] must be on the line while cnt==14 (window between TA2 edge and
  // DATA[15] edge); master samples it at the cnt==14 rising edge.
  wire drive_low = read_match && (cnt >= 6'd14) && (cnt <= 6'd29)
                   && (rd_reg[5'd29 - cnt[4:0]] == 1'b0);
  assign mdio = drive_low ? 1'b0 : 1'bz;
  assign irq  = frame_act && (cnt == 6'd29);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      frame_act <= 1'b0; cnt <= '0; shift <= '0; prev_bit <= 1'b1;
      read_frame <= 1'b0; read_match <= 1'b0; regad_q <= '0;
      for (int i = 0; i < 32; i++) regs[i] <= 16'h0000;
      regs[0] <= 16'h1140;              // PHY ID preset (like OpenCores eth phy)
    end else if (mdc_rise) begin
      if (!frame_act) begin
        // ST pattern: previous sampled bit 0, current sampled bit 1
        if (!prev_bit && mdio_s) begin
          frame_act <= 1'b1; cnt <= '0;
        end
        prev_bit <= mdio_s;
      end else if (cnt == 6'd29) begin
        prev_bit <= mdio_s;
        // frame complete: shift[28:0] holds first 29 frame bits, mdio_s is bit 30
        frame_act  <= 1'b0;
        read_frame <= 1'b0;
        read_match <= 1'b0;
        if (shift[28:27] == 2'b01 && shift[26:22] == PHY_ADDR[4:0]) begin
          regs[shift[21:17]] <= {shift[14:0], mdio_s};   // write
        end
      end else begin
        shift <= {shift[30:0], mdio_s};
        cnt   <= cnt + 1'b1;
        if (cnt == 6'd1) begin
          read_frame <= (mdio_s == 1'b0) && (shift[0] == 1'b1); // OP == 10
        end
        if (cnt == 6'd6) begin
          read_match <= read_frame && ({shift[3:0], mdio_s} == PHY_ADDR[4:0]);
        end
        if (cnt == 6'd11) begin
          regad_q <= {shift[3:0], mdio_s};
        end
      end
    end
  end

  // read-back mux for external register interface simplicity:
  // regs are internal; expose nothing else (Clause-22 PHY style)

endmodule
""",
tb="""// Self-checking testbench: TB acts as MDIO master (Clause 22) -- SystemVerilog
`timescale 1ns/1ps
module MDIO_tb;
  logic clk = 0, rst_n = 0;
  tri1  mdio;
  logic mdc = 0;
  logic m_low = 0;
  logic md_s;
  int errors = 0;

  MDIO_top #(.PHY_ADDR(5'h0C)) dut (
    .clk(clk), .rst_n(rst_n), .mdio(mdio), .mdc(mdc), .irq());

  always #5 clk = ~clk;
  assign mdio = m_low ? 1'b0 : 1'bz;

  task automatic mdc_bit(input logic bit_v);
    begin
      m_low = ~bit_v; #300;         // bit 0 -> pull low, bit 1 -> release (tri1)
      mdc = 1; #1;                  // sample at the rising edge: slave holds the
      md_s = mdio;                  // pre-edge drive; it advances ~30ns after
      #299;                         // the edge (sync + cnt increment)
      mdc = 0; #300;
    end
  endtask

  task automatic mdio_write(input logic [4:0] pa, input logic [4:0] ra,
                            input logic [15:0] data);
    logic b;
    begin
      for (int i = 0; i < 32; i++) begin
        b = (i == 0) ? 1'b0 :                    // ST = 01
            (i == 1) ? 1'b1 :
            (i == 2) ? 1'b0 :                    // OP = 01 (write)
            (i == 3) ? 1'b1 :
            (i <  9) ? pa[8-i] :                 // PHYAD: i=4..8
            (i < 14) ? ra[13-i] :                // REGAD: i=9..13
            (i == 14) ? 1'b1 :                   // TA = 10
            (i == 15) ? 1'b0 :
                       data[31-i];               // DATA: i=16..31
        mdc_bit(b);
      end
      m_low = 0; #600;
    end
  endtask

  task automatic mdio_read(input logic [4:0] pa, input logic [4:0] ra,
                           output logic [15:0] data);
    logic b;
    begin
      for (int i = 0; i < 14; i++) begin
        b = (i == 0) ? 1'b0 : (i == 1) ? 1'b1 :
            (i == 2) ? 1'b1 : (i == 3) ? 1'b0 :  // OP = 10 (read)
            (i <  9) ? pa[8-i] :                 // PHYAD
                       ra[13-i];                 // REGAD
        mdc_bit(b);
      end
      mdc_bit(1'b1);                            // TA bit 1: master releases
      mdc_bit(1'b1);                            // TA bit 2: slave begins driving
      for (int i = 0; i < 16; i++) begin
        mdc_bit(1'b1);                          // keep released, sample read data
        data[15-i] = md_s;
      end
      m_low = 0; #600;
    end
  endtask

  logic [15:0] rdata;
  initial begin
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(10) @(posedge clk);

    mdio_write(5'h0C, 5'h03, 16'hBEEF);
    repeat(10) @(posedge clk);
    mdio_read (5'h0C, 5'h03, rdata);
    if (rdata !== 16'hBEEF) begin
      errors++; $display("ERROR: MDIO rw got=%h exp=BEEF", rdata);
    end

    mdio_read (5'h0C, 5'h00, rdata);            // preset PHY ID reg
    if (rdata !== 16'h1140) begin
      errors++; $display("ERROR: MDIO reg0 got=%h exp=1140", rdata);
    end

    if (errors == 0) $display("TEST PASSED: MDIO");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #3_000_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")

CUSTOM["AXI-Stream"] = dict(
rtl="""// ============================================================================
// AXI-Stream sink monitor with 16-deep FIFO capture
// OpenCores avalon/peripheral style: tready backpressure, IRQ on tlast.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module AXI_Stream_top #(
  parameter int DW    = 32,
  parameter int DEPTH = 16
)(
  input  logic            clk,
  input  logic            rst_n,
  input  logic            tvalid,
  output logic            tready,
  input  logic [DW-1:0]   tdata,
  input  logic            tlast,
  input  logic            ren,
  input  logic [3:0]      raddr,
  output logic [DW-1:0]   rdata,
  output logic [4:0]      count,
  output logic            irq
);
  logic [DW-1:0] mem [0:DEPTH-1];
  logic [4:0]    wr_ptr;

  assign tready = (wr_ptr < DEPTH);
  assign push   = tvalid && tready;
  assign count  = wr_ptr;
  assign irq    = push && tlast;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_ptr <= '0;
    end else begin
      if (push) begin
        mem[wr_ptr[3:0]] <= tdata;
        wr_ptr           <= wr_ptr + 1'b1;
      end
    end
  end

  assign rdata = mem[raddr];

endmodule
""",
tb="""// Self-checking testbench for AXI_Stream_top -- SystemVerilog
`timescale 1ns/1ps
module AXI_Stream_tb;
  logic clk = 0, rst_n = 0;
  logic tvalid = 0, tready;
  logic [31:0] tdata = 0;
  logic tlast = 0;
  logic ren = 0;
  logic [3:0] raddr = 0;
  logic [31:0] rdata;
  logic [4:0] count;
  logic irq;
  logic irq_seen = 0;
  int errors = 0;

  AXI_Stream_top dut (
    .clk(clk), .rst_n(rst_n), .tvalid(tvalid), .tready(tready),
    .tdata(tdata), .tlast(tlast), .ren(ren), .raddr(raddr),
    .rdata(rdata), .count(count), .irq(irq));

  always #5 clk = ~clk;
  always @(posedge clk) if (irq) irq_seen <= 1'b1;

  task automatic send(input logic [31:0] d, input logic last);
    begin
      wait (tready === 1'b1);
      @(negedge clk);
      tdata <= d; tlast <= last; tvalid <= 1'b1;
      @(posedge clk); #1;
      if (tready !== 1'b1) begin
        errors++; $display("ERROR: AXIS tready dropped mid-beat");
      end
      @(negedge clk);
      tvalid <= 1'b0; tlast <= 1'b0;
    end
  endtask

  logic [31:0] exp [0:4];
  initial begin
    exp[0] = 32'hDEAD_BEEF; exp[1] = 32'h1234_5678;
    exp[2] = 32'hA5A5_5A5A; exp[3] = 32'h0BAD_F00D;
    exp[4] = 32'hC001_D00D;
  end
  initial begin
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);

    for (int i = 0; i < 5; i++) send(exp[i], i == 4);

    repeat(2) @(posedge clk);
    if (count !== 5'd5) begin
      errors++; $display("ERROR: AXIS count got=%0d exp=5", count);
    end
    if (!irq_seen) begin
      errors++; $display("ERROR: AXIS irq never fired");
    end
    for (int i = 0; i < 5; i++) begin
      @(negedge clk); ren <= 1'b1; raddr <= i[3:0];
      #1;
      if (rdata !== exp[i]) begin
        errors++; $display("ERROR: AXIS mem[%0d] got=%h exp=%h", i, rdata, exp[i]);
      end
      @(negedge clk); ren <= 1'b0;
    end

    if (errors == 0) $display("TEST PASSED: AXI-Stream");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #500_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")

CUSTOM["Avalon-ST"] = dict(
rtl="""// ============================================================================
// Avalon-ST sink with 16-deep FIFO capture (valid/ready/data/eop)
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module Avalon_ST_top #(
  parameter int DW    = 32,
  parameter int DEPTH = 16
)(
  input  logic            clk,
  input  logic            rst_n,
  input  logic            av_valid,
  output logic            av_ready,
  input  logic [DW-1:0]   av_data,
  input  logic            av_eop,
  input  logic            ren,
  input  logic [3:0]      raddr,
  output logic [DW-1:0]   rdata,
  output logic [4:0]      count,
  output logic            irq
);
  logic [DW-1:0] mem [0:DEPTH-1];
  logic [4:0]    wr_ptr;

  assign av_ready = (wr_ptr < DEPTH);
  assign count    = wr_ptr;
  assign irq      = av_valid && av_ready && av_eop;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_ptr <= '0;
    end else if (av_valid && av_ready) begin
      mem[wr_ptr[3:0]] <= av_data;
      wr_ptr           <= wr_ptr + 1'b1;
    end
  end

  assign rdata = mem[raddr];

endmodule
""",
tb="""// Self-checking testbench for Avalon_ST_top -- SystemVerilog
`timescale 1ns/1ps
module Avalon_ST_tb;
  logic clk = 0, rst_n = 0;
  logic av_valid = 0, av_ready;
  logic [31:0] av_data = 0;
  logic av_eop = 0;
  logic ren = 0;
  logic [3:0] raddr = 0;
  logic [31:0] rdata;
  logic [4:0] count;
  logic irq;
  logic irq_seen = 0;
  int errors = 0;

  Avalon_ST_top dut (
    .clk(clk), .rst_n(rst_n), .av_valid(av_valid), .av_ready(av_ready),
    .av_data(av_data), .av_eop(av_eop), .ren(ren), .raddr(raddr),
    .rdata(rdata), .count(count), .irq(irq));

  always #5 clk = ~clk;
  always @(posedge clk) if (irq) irq_seen <= 1'b1;

  task automatic send(input logic [31:0] d, input logic eop);
    begin
      wait (av_ready === 1'b1);
      @(negedge clk);
      av_data <= d; av_eop <= eop; av_valid <= 1'b1;
      @(posedge clk); #1;
      @(negedge clk);
      av_valid <= 1'b0; av_eop <= 1'b0;
    end
  endtask

  logic [31:0] exp [0:3];
  initial begin
    exp[0] = 32'h1111_2222; exp[1] = 32'h3333_4444;
    exp[2] = 32'h5555_6666; exp[3] = 32'h7777_8888;
  end
  initial begin
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);

    for (int i = 0; i < 4; i++) send(exp[i], i == 3);

    repeat(2) @(posedge clk);
    if (count !== 5'd4) begin
      errors++; $display("ERROR: Avalon-ST count got=%0d exp=4", count);
    end
    if (!irq_seen) begin
      errors++; $display("ERROR: Avalon-ST irq never fired");
    end
    for (int i = 0; i < 4; i++) begin
      @(negedge clk); ren <= 1'b1; raddr <= i[3:0];
      #1;
      if (rdata !== exp[i]) begin
        errors++; $display("ERROR: Avalon-ST mem[%0d] got=%h exp=%h", i, rdata, exp[i]);
      end
      @(negedge clk); ren <= 1'b0;
    end

    if (errors == 0) $display("TEST PASSED: Avalon-ST");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #500_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")




CUSTOM["QSPI"] = dict(
rtl="""// ============================================================================
// QSPI slave: standard (1-bit) and quad (4-bit) SPI mode 0, 8-bit frames
// OpenCores spi/quad-spi style: io[0]=MOSI/IO0, io[1]=MISO/IO1, io[3:2]=IO2/3
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module QSPI_top (
  input  logic       clk,
  input  logic       rst_n,
  input  logic       sclk,
  input  logic       csn,
  inout  tri  [3:0]  io,
  input  logic       wen,
  input  logic [3:0] waddr,      // 0: tx_reg, 2: mode (0=std, 1=quad)
  input  logic [7:0] wdata,
  input  logic       ren,
  input  logic [3:0] raddr,      // 0: rx_reg, 1: tx_reg
  output logic [7:0] rdata,
  output logic       irq
);
  logic [7:0] tx_q, rx_q;
  logic [1:0] mode;
  logic       dir;          // 0 = slave drives io (quad read), 1 = release (quad write)
  logic [2:0] bit_cnt;      // std: 0..7
  logic [1:0] qcnt;         // quad nibble counter 0..1
  logic       sclk_d, byte_done;

  // output drive: std drives io[1]; quad drives io[3:0] with tx nibbles
  logic [3:0] io_oe, io_out;
  assign io = io_oe ? io_out : 4'bzzzz;

  wire std_mode = (mode == 2'd0);

  // present first bit while SCLK low (mode 0 timing), update on falling edge
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      io_oe <= 4'b0010; io_out <= 4'b0010;  // std MISO=1 idle
    end else if (csn) begin
      // present first output while CSn high: std -> tx[7] on io[1]; quad -> tx[7:4]
      io_oe       <= std_mode ? 4'b0010 : (dir ? 4'b0000 : 4'b1111);
      io_out[3:2] <= tx_q[7:6];
      io_out[1]   <= std_mode ? tx_q[7] : tx_q[5];
      io_out[0]   <= tx_q[4];
    end else if (sclk_d && !sclk) begin     // SCLK falling: advance output
      if (std_mode) begin
        io_oe  <= 4'b0010;
        io_out[1] <= tx_q[7 - bit_cnt];    // bit_cnt already incremented on sample
      end else if (!dir) begin              // quad read: slave drives tx nibbles
        io_oe  <= 4'b1111;
        io_out <= (qcnt == 2'd0) ? tx_q[7:4] : tx_q[3:0];
      end else begin
        io_oe  <= 4'b0000;                 // quad write: release for master
      end
    end else if (!std_mode) begin
      io_oe <= dir ? 4'b0000 : 4'b1111;    // quad: reflect dir even between edges
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sclk_d <= 1'b0; bit_cnt <= '0; qcnt <= '0;
      rx_q <= '0; tx_q <= '0; mode <= '0; dir <= 1'b0; byte_done <= 1'b0;
    end else begin
      sclk_d <= sclk;
      byte_done <= 1'b0;
      if (wen && waddr == 4'd0) tx_q <= wdata;
      if (wen && waddr == 4'd2) mode  <= wdata[1:0];
      if (wen && waddr == 4'd3) dir   <= wdata[0];
      if (!csn && sclk && !sclk_d) begin
        if (std_mode) begin
          rx_q <= {rx_q[6:0], io[0]};
          if (bit_cnt == 3'd7) begin
            bit_cnt <= '0; byte_done <= 1'b1;
          end else bit_cnt <= bit_cnt + 1'b1;
        end else begin
          rx_q <= {rx_q[3:0], io[3:0]};      // 4 bits per clock, MSB nibble first
          if (qcnt == 2'd1) begin
            qcnt <= '0; byte_done <= 1'b1;
          end else qcnt <= qcnt + 1'b1;
        end
      end
      if (csn) begin bit_cnt <= '0; qcnt <= '0; end
    end
  end

  assign rdata = (raddr == 4'd0) ? rx_q :
                 (raddr == 4'd1) ? tx_q : 8'h00;
  assign irq   = byte_done;

endmodule
""",
tb="""// Self-checking testbench: TB acts as QSPI master -- SystemVerilog
`timescale 1ns/1ps
module QSPI_tb;
  logic clk = 0, rst_n = 0;
  logic sclk = 0, csn = 1;
  tri  [3:0] io;
  logic [3:0] drv_val = 0;
  logic       drv_en  = 0;
  logic wen = 0, ren = 0;
  logic [3:0] waddr = 0, raddr = 0;
  logic [7:0] wdata = 0, rdata;
  int errors = 0;

  QSPI_top dut (
    .clk(clk), .rst_n(rst_n), .sclk(sclk), .csn(csn), .io(io),
    .wen(wen), .waddr(waddr), .wdata(wdata),
    .ren(ren), .raddr(raddr), .rdata(rdata), .irq());

  always #5 clk = ~clk;
  assign io = drv_en ? drv_val : 4'bzzzz;

  task automatic wr(input logic [3:0] a, input logic [7:0] d);
    begin
      @(negedge clk); wen <= 1'b1; waddr <= a; wdata <= d;
      @(negedge clk); wen <= 1'b0;
    end
  endtask
  task automatic rd(input logic [3:0] a, output logic [7:0] d);
    begin
      @(negedge clk); ren <= 1'b1; raddr <= a;
      #1 d = rdata;
      @(negedge clk); ren <= 1'b0;
    end
  endtask

  task automatic std_xfer(input logic [7:0] din, output logic [7:0] dout);
    begin
      csn = 1'b0; drv_en = 1'b1;
      for (int i = 0; i < 8; i++) begin
        drv_val = {3'bzzz, din[7-i]};
        #40 sclk = 1'b1;
        #1 dout[7-i] = io[1];
        #39 sclk = 1'b0;
      end
      drv_en = 1'b0; csn = 1'b1; #100;
    end
  endtask

  task automatic quad_read(output logic [7:0] dout);
    begin
      csn = 1'b0; drv_en = 1'b0;          // release: slave drives io
      for (int i = 0; i < 2; i++) begin
        #40 sclk = 1'b1;
        #1 dout[7-4*i -: 4] = io[3:0];
        #39 sclk = 1'b0;
      end
      csn = 1'b1; #100;
    end
  endtask

  task automatic quad_write(input logic [7:0] din);
    begin
      csn = 1'b0; drv_en = 1'b1;
      for (int i = 0; i < 2; i++) begin
        drv_val = din[7-4*i -: 4];
        #40 sclk = 1'b1; #1; #39 sclk = 1'b0;
      end
      drv_en = 1'b0; csn = 1'b1; #100;
    end
  endtask

  logic [7:0] d1, q1, q2, got;
  initial begin
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);

    // standard mode
    wr(4'd0, 8'h3C);
    std_xfer(8'h00, d1);
    rd(4'd0, got);
    if (d1 !== 8'h3C) begin errors++; $display("ERROR: QSPI std MISO got=%h exp=3C", d1); end

    // quad mode: read slave tx, then write
    wr(4'd2, 8'h01);
    wr(4'd0, 8'hA7);
    wr(4'd3, 8'h00);          // dir = slave drives (read)
    quad_read(q1);
    wr(4'd3, 8'h01);          // dir = release (write)
    quad_write(8'h5A);
    rd(4'd0, got);
    if (q1 !== 8'hA7) begin errors++; $display("ERROR: QSPI quad read got=%h exp=A7", q1); end
    if (got !== 8'h5A) begin errors++; $display("ERROR: QSPI quad write got=%h exp=5A", got); end

    if (errors == 0) $display("TEST PASSED: QSPI");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #1_000_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")

CUSTOM["1-Wire"] = dict(
rtl="""// ============================================================================
// 1-Wire slave: reset/presence detect, write slots (rx), read slots (tx)
// Timing in units of US (clk cycles per microsecond); LSB-first bytes.
// OpenCores onewire slave style.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module _1_Wire_top #(
  parameter int US = 10               // sim: 100ns per us unit
)(
  input  logic       clk,
  input  logic       rst_n,
  inout  tri         dq,
  input  logic [7:0] tx_byte,         // byte sent on read slots (after cmd)
  output logic [7:0] rx_byte,         // last command/data byte received
  output logic       rx_valid,
  output logic       busy,
  output logic       irq
);
  logic dq_s, dq_d;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin dq_s <= 1'b1; dq_d <= 1'b1; end
    else begin dq_s <= dq; dq_d <= dq_s; end
  end
  wire dq_fall = dq_d & ~dq_s;
  wire dq_rise = ~dq_d & dq_s;

  typedef enum logic [2:0] {
    ST_IDLE, ST_RESET_CNT, ST_RESET_REL, ST_PRESENCE,
    ST_WAIT_SLOT, ST_W_SAMPLE, ST_R_DRIVE, ST_TX_BYTE
  } st_t;
  st_t        state;
  logic [15:0] timer;
  logic [2:0]  bit_cnt;
  logic [7:0]  rx_shift, tx_shift;

  assign dq     = (state == ST_PRESENCE || (state == ST_R_DRIVE && !tx_shift[0]))
                  ? 1'b0 : 1'bz;
  assign busy   = (state != ST_IDLE);
  assign irq    = rx_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= ST_IDLE; timer <= '0; bit_cnt <= '0;
      rx_shift <= '0; rx_byte <= '0; rx_valid <= 1'b0;
      tx_shift <= '0;
    end else begin
      rx_valid <= 1'b0;
      case (state)
        ST_IDLE: if (!dq_s) begin
          state <= ST_RESET_CNT; timer <= '0;
        end
        // master reset pulse: low for > ~480us
        ST_RESET_CNT: begin
          if (dq_s) begin
            state <= ST_IDLE;                    // glitch: back to idle
          end else if (timer > 16'd480*US) begin
            state <= ST_RESET_REL;
          end else timer <= timer + 1'b1;
        end
        ST_RESET_REL: if (dq_s) begin
          state <= ST_PRESENCE; timer <= '0;     // bus released: answer
        end
        ST_PRESENCE: begin
          if (timer > 16'd120*US) begin
            state <= ST_WAIT_SLOT; bit_cnt <= '0;
          end else timer <= timer + 1'b1;
        end
        // write slot: master pulls low; sample at ~15us (0=held, 1=released)
        ST_WAIT_SLOT: if (dq_fall) begin
          state <= ST_W_SAMPLE; timer <= '0;
        end
        ST_W_SAMPLE: begin
          if (timer == 16'd15*US) begin
            rx_shift <= {dq_s, rx_shift[7:1]};   // LSB-first assembly
            if (bit_cnt == 3'd7) begin
              rx_byte  <= {dq_s, rx_shift[7:1]};
              rx_valid <= 1'b1;
              bit_cnt  <= '0;
              tx_shift <= tx_byte;               // arm read phase
              state    <= ST_TX_BYTE;
            end else begin
              bit_cnt <= bit_cnt + 1'b1;
              state   <= ST_WAIT_SLOT;
            end
          end else timer <= timer + 1'b1;
        end
        // read slot: master pulls low >=1us then releases; slave holds 0 for bit 0
        ST_TX_BYTE: if (dq_fall) begin
          state <= ST_R_DRIVE; timer <= '0;
        end
        ST_R_DRIVE: begin
          if (timer > 16'd40*US) begin
            if (bit_cnt == 3'd7) begin
              bit_cnt <= '0;
              state   <= ST_WAIT_SLOT;           // done: expect next command
            end else begin
              tx_shift <= {1'b0, tx_shift[7:1]}; // next bit (LSB-first)
              bit_cnt  <= bit_cnt + 1'b1;
              state    <= ST_TX_BYTE;
            end
          end else timer <= timer + 1'b1;
        end
        default: state <= ST_IDLE;
      endcase
    end
  end

endmodule
""",
tb="""// Self-checking testbench: TB acts as 1-Wire master -- SystemVerilog
`timescale 1ns/1ps
module _1_Wire_tb;
  localparam int US = 10;             // 100ns per unit
  logic clk = 0, rst_n = 0;
  tri1  dq;
  logic m_low = 0;
  logic [7:0] tx_byte, rx_byte;
  logic rx_valid, busy;
  logic rx_seen = 0;
  int errors = 0;

  _1_Wire_top #(.US(US)) dut (
    .clk(clk), .rst_n(rst_n), .dq(dq),
    .tx_byte(tx_byte), .rx_byte(rx_byte), .rx_valid(rx_valid),
    .busy(busy), .irq());

  always #5 clk = ~clk;
  assign dq = m_low ? 1'b0 : 1'bz;
  always @(posedge clk) if (rx_valid) rx_seen <= 1'b1;

  task automatic ow_reset(output logic presence);
    begin
      m_low = 1; #(600*US*10);         // reset pulse >= 480us
      m_low = 0;
      #(30*US*10);                     // presence window
      presence = (dq === 1'b0);
      #(400*US*10);
    end
  endtask

  task automatic ow_write_bit(input logic b);
    begin
      m_low = 1; #(2*US*10);
      if (!b) #(60*US*10);             // hold for 0
      m_low = 0;
      #((80-2)*US*10);                 // slot end
    end
  endtask

  task automatic ow_read_bit(output logic b);
    begin
      m_low = 1; #(2*US*10);
      m_low = 0;
      #(13*US*10);
      b = dq;
      #((80-15)*US*10);
    end
  endtask

  logic presence, b;
  logic [7:0] rb;
  initial begin
    tx_byte = 8'h5A;
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(10) @(posedge clk);

    ow_reset(presence);
    if (!presence) begin errors++; $display("ERROR: 1-Wire no presence pulse"); end

    // send command 0xCC (Skip ROM), LSB first
    begin : send_cmd
      logic [7:0] cmd;
      cmd = 8'hCC;
      for (int i = 0; i < 8; i++) ow_write_bit(cmd[i]);
    end
    repeat(5) @(posedge clk);
    if (!rx_seen)  begin errors++; $display("ERROR: 1-Wire rx_valid never pulsed"); end
    if (rx_byte !== 8'hCC) begin errors++; $display("ERROR: 1-Wire rx=%h exp=CC", rx_byte); end

    // read a byte from slave (expect tx_byte=5A), LSB first
    for (int i = 0; i < 8; i++) begin
      ow_read_bit(b);
      rb[i] = b;
    end
    if (rb !== 8'h5A) begin errors++; $display("ERROR: 1-Wire read got=%h exp=5A", rb); end

    if (errors == 0) $display("TEST PASSED: 1-Wire");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #5_000_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")

CUSTOM["I3C"] = dict(
rtl="""// ============================================================================
// I3C slave (SDR-compatible I2C framing) + in-band interrupt request (IBI)
// Reuses the I2C two-wire base; int_n is asserted after a write transaction
// (interrupt pending) and released by the next START (master acknowledges IBI).
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module I3C_top #(
  parameter int I3C_ADDR = 7'h2A
)(
  input  logic       clk,
  input  logic       rst_n,
  inout  tri         sda,
  input  logic       scl,
  input  logic [7:0] tx_byte,
  output logic [7:0] rx_byte,
  output logic       rx_valid,
  output logic       int_n,        // IBI request (low = pending)
  output logic       busy,
  output logic       irq
);
  logic scl_s, scl_d, sda_s, sda_d;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      scl_s <= 1'b1; scl_d <= 1'b1; sda_s <= 1'b1; sda_d <= 1'b1;
    end else begin
      scl_s <= scl; scl_d <= scl_s;
      sda_s <= sda; sda_d <= sda_s;
    end
  end
  wire scl_rise  =  scl_s & ~scl_d;
  wire scl_fall  = ~scl_s &  scl_d;
  wire start_det = ~sda_s &  sda_d & scl_s;
  wire stop_det  =  sda_s & ~sda_d & scl_s;

  typedef enum logic [2:0] {ST_IDLE, ST_ADDR, ST_ACK, ST_RX, ST_TX, ST_TXACK, ST_IGNORE} st_t;
  st_t      state;
  logic [3:0] bit_cnt;
  logic [7:0] shift;
  logic       rw, ack_low, txack_done;

  assign sda  = ack_low ? 1'b0 : 1'bz;
  assign busy = (state != ST_IDLE) && (state != ST_IGNORE);
  assign irq  = rx_valid;

  wire [7:0] byte_w = {shift[6:0], sda_s};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= ST_IDLE; bit_cnt <= '0; shift <= '0;
      rw <= 1'b0; ack_low <= 1'b0; txack_done <= 1'b0;
      rx_byte <= '0; rx_valid <= 1'b0; int_n <= 1'b1;
    end else begin
      rx_valid <= 1'b0;
      if (start_det) begin
        state <= ST_ADDR; bit_cnt <= '0; ack_low <= 1'b0;
        int_n <= 1'b1;                       // START clears pending IBI
      end else if (stop_det) begin
        state <= ST_IDLE; ack_low <= 1'b0;
        if (state == ST_RX || rx_valid) int_n <= 1'b0;  // write done: request IBI
      end else case (state)
        ST_ADDR: if (scl_rise) begin
          shift <= byte_w;
          if (bit_cnt == 4'd7) begin
            bit_cnt <= '0;
            if (byte_w[7:1] == I3C_ADDR[6:0]) begin
              rw <= byte_w[0]; state <= ST_ACK;
            end else state <= ST_IGNORE;
          end else bit_cnt <= bit_cnt + 1'b1;
        end
        ST_ACK: begin
          if (!ack_low) begin
            if (scl_fall) ack_low <= 1'b1;
          end else if (scl_fall) begin
            ack_low <= 1'b0;
            state <= rw ? ST_TX : ST_RX;
          end
        end
        ST_RX: if (scl_rise) begin
          shift <= byte_w;
          if (bit_cnt == 4'd7) begin
            rx_byte <= byte_w; rx_valid <= 1'b1;
            bit_cnt <= '0; state <= ST_ACK;
          end else bit_cnt <= bit_cnt + 1'b1;
        end
        ST_TX: if (scl_fall) begin
          if (bit_cnt == 4'd7) begin
            bit_cnt <= '0; ack_low <= 1'b0; state <= ST_TXACK;
          end else begin
            bit_cnt <= bit_cnt + 1'b1;
            ack_low <= (tx_byte[6-bit_cnt] == 1'b0);
          end
        end
        ST_TXACK: begin
          if (!txack_done) begin
            if (scl_rise) begin
              txack_done <= 1'b1;
              if (sda_s == 1'b1) state <= ST_IDLE;   // NACK
            end
          end else if (scl_fall) begin
            txack_done <= 1'b0;
            if (state == ST_TXACK) begin
              bit_cnt <= '0;
              ack_low <= (tx_byte[7] == 1'b0);
              state   <= ST_TX;
            end
          end
        end
        default: ;
      endcase
    end
  end

endmodule
""",
tb="""// Self-checking testbench: TB acts as I3C master; checks IBI (int_n)
// Reuses the I2C bit-bang master pattern -- SystemVerilog
`timescale 1ns/1ps
module I3C_tb;
  logic clk = 0, rst_n = 0;
  tri1 sda;
  logic scl = 1;
  logic master_low = 0;
  logic [7:0] tx_byte, rx_byte;
  logic rx_valid, int_n, busy;
  int errors = 0;

  I3C_top #(.I3C_ADDR(7'h2A)) dut (
    .clk(clk), .rst_n(rst_n), .sda(sda), .scl(scl),
    .tx_byte(tx_byte), .rx_byte(rx_byte), .rx_valid(rx_valid),
    .int_n(int_n), .busy(busy), .irq());

  always #5 clk = ~clk;
  assign sda = master_low ? 1'b0 : 1'bz;

  task automatic i3c_start;
    begin master_low = 0; scl = 1; #300; master_low = 1; #300; scl = 0; #300; end
  endtask
  task automatic i3c_stop;
    begin master_low = 1; #300; scl = 1; #300; master_low = 0; #600; end
  endtask
  task automatic i3c_wbyte(input logic [7:0] d, output logic ack);
    begin
      for (int i = 0; i < 8; i++) begin
        master_low = ~d[7-i]; #300; scl = 1; #600; scl = 0; #300;
      end
      master_low = 0; #300; scl = 1; #300;
      ack = (sda === 1'b0);
      #300; scl = 0; #600;
    end
  endtask
  task automatic i3c_rbyte(input logic send_ack, output logic [7:0] d);
    begin
      master_low = 0;
      for (int i = 0; i < 8; i++) begin
        #300; scl = 1; #300; d[7-i] = sda; #300; scl = 0; #300;
      end
      master_low = send_ack; #300; scl = 1; #600; scl = 0; #300; master_low = 0; #300;
    end
  endtask

  logic ack;
  logic [7:0] rb;
  initial begin
    tx_byte = 8'hC3;
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(10) @(posedge clk);
    if (int_n !== 1'b1) begin errors++; $display("ERROR: I3C int_n not idle-high"); end

    // write 0x5A -> IBI should assert after STOP
    i3c_start;
    i3c_wbyte(8'h54, ack);                  // addr 0x2A + W
    if (!ack) begin errors++; $display("ERROR: I3C no ACK addr W"); end
    i3c_wbyte(8'h5A, ack);
    if (!ack) begin errors++; $display("ERROR: I3C no ACK data"); end
    i3c_stop;
    repeat(5) @(posedge clk);
    if (rx_byte !== 8'h5A) begin errors++; $display("ERROR: I3C rx=%h exp=5A", rx_byte); end
    if (int_n !== 1'b0) begin errors++; $display("ERROR: I3C IBI (int_n) not asserted after write"); end

    // read clears IBI via START
    i3c_start;
    if (int_n !== 1'b1) begin errors++; $display("ERROR: I3C IBI not cleared by START"); end
    i3c_wbyte(8'h55, ack);                  // addr 0x2A + R
    if (!ack) begin errors++; $display("ERROR: I3C no ACK addr R"); end
    i3c_rbyte(1'b0, rb);
    if (rb !== 8'hC3) begin errors++; $display("ERROR: I3C read got=%h exp=C3", rb); end
    i3c_stop;

    if (errors == 0) $display("TEST PASSED: I3C");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #3_000_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")

CUSTOM["RFFE"] = dict(
rtl="""// ============================================================================
// MIPI RFFE slave: SSC + SA[1:0] + PC + AD[4:0] + DATA[7:0], then bus park
// Write (PC=0): master sends data; Read (PC=1): slave drives data (push-pull).
// OpenCores rffe/pmic style register interface.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module RFFE_top #(
  parameter logic [1:0] RFFE_ADDR = 2'b01
)(
  input  logic       clk,
  input  logic       rst_n,
  inout  tri         sdata,
  input  logic       sclk,
  output logic [7:0] rx_byte,        // {AD, data} register write captured
  output logic [7:0] rx_addr,
  output logic       rx_valid,
  input  logic [7:0] tx_byte,        // data returned for reads
  output logic       busy,
  output logic       irq
);
  logic sclk_s, sclk_d, sdata_s, sdata_d;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sclk_s <= 1'b0; sclk_d <= 1'b0; sdata_s <= 1'b1; sdata_d <= 1'b1;
    end else begin
      sclk_s <= sclk; sclk_d <= sclk_s;
      sdata_s <= sdata; sdata_d <= sdata_s;
    end
  end
  wire sclk_rise =  sclk_s & ~sclk_d;
  wire sclk_fall = ~sclk_s &  sclk_d;
  wire ssc_det   = ~sdata_s &  sdata_d & sclk_s;   // SSC: sdata falls while sclk high

  typedef enum logic [1:0] {ST_IDLE, ST_HEAD, ST_DATA, ST_PARK} st_t;
  st_t      state;
  logic [3:0] bit_cnt;     // HEAD: 0..2 (SA+PC), then AD folds into HEAD 3..7
  logic [7:0] shift;
  logic       rw;
  logic       sd_oe, sd_out;

  assign sdata   = sd_oe ? sd_out : 1'bz;
  assign busy    = (state != ST_IDLE);
  assign irq     = rx_valid;
  assign rx_addr = {3'b000, shift_hold};

  logic [4:0] shift_hold;  // captured register address

  wire [7:0] head_w = {shift[6:0], sdata_s};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= ST_IDLE; bit_cnt <= '0; shift <= '0; shift_hold <= '0;
      rw <= 1'b0; sd_oe <= 1'b0; sd_out <= 1'b1; rx_valid <= 1'b0;
    end else begin
      rx_valid <= 1'b0;
      if (ssc_det) begin
        state <= ST_HEAD; bit_cnt <= '0; sd_oe <= 1'b0;
      end else case (state)
        ST_HEAD: if (sclk_rise) begin
          shift <= head_w;
          if (bit_cnt == 4'd7) begin
            // head_w = {SA[1:0], PC, AD[4:0]}
            if (head_w[7:6] == RFFE_ADDR) begin
              rw <= head_w[5];
              shift_hold <= head_w[4:0];
              bit_cnt <= '0;
              state <= ST_DATA;
            end else state <= ST_IDLE;
          end else bit_cnt <= bit_cnt + 1'b1;
        end
        ST_DATA: begin
          if (!rw && sclk_rise) begin          // write: sample master's data
            shift <= head_w;
            if (bit_cnt == 4'd7) begin
              rx_byte <= head_w;
              bit_cnt <= '0; state <= ST_PARK; rx_valid <= 1'b1;
            end else bit_cnt <= bit_cnt + 1'b1;
          end else if (rw && sclk_fall) begin  // read: drive next data bit
            sd_oe <= 1'b1;
            sd_out <= tx_byte[7-bit_cnt];
            if (bit_cnt == 4'd7) begin
              bit_cnt <= '0; sd_oe <= 1'b0; state <= ST_PARK;
            end else bit_cnt <= bit_cnt + 1'b1;
          end
        end
        ST_PARK: if (sclk_fall) begin
          sd_oe <= 1'b0; state <= ST_IDLE;     // bus park then idle
        end
        default: state <= ST_IDLE;
      endcase
    end
  end

endmodule
""",
tb="""// Self-checking testbench: TB acts as RFFE master -- SystemVerilog
`timescale 1ns/1ps
module RFFE_tb;
  logic clk = 0, rst_n = 0;
  tri1  sdata;
  logic sclk = 0;
  logic m_oe = 0, m_val = 1;
  logic [7:0] rx_byte, rx_addr;
  logic rx_valid, busy;
  logic rx_seen = 0;
  int errors = 0;

  RFFE_top #(.RFFE_ADDR(2'b01)) dut (
    .clk(clk), .rst_n(rst_n), .sdata(sdata), .sclk(sclk),
    .rx_byte(rx_byte), .rx_addr(rx_addr), .rx_valid(rx_valid),
    .tx_byte(8'hC3), .busy(busy), .irq());

  always #5 clk = ~clk;
  assign sdata = m_oe ? m_val : 1'bz;
  always @(posedge clk) if (rx_valid) rx_seen <= 1'b1;

  task automatic rbit(input logic b);
    begin m_oe = 1; m_val = b; #300; sclk = 1; #600; sclk = 0; #300; end
  endtask
  task automatic rrelease_bit(output logic b);
    begin m_oe = 0; #300; sclk = 1; #300; b = sdata; #300; sclk = 0; #300; end
  endtask
  task automatic rssc;
    begin m_oe = 0; m_val = 1; sclk = 1; #300;   // SCLK high first
          m_oe = 1; m_val = 0; #300;             // SDATA falls while SCLK high
          sclk = 0; #300;
          m_oe = 0; #300; end
  endtask

  task automatic rffe_write(input logic [1:0] sa, input logic [4:0] ad,
                            input logic [7:0] data);
    begin
      rssc;
      rbit(sa[1]); rbit(sa[0]); rbit(1'b0);       // PC=0 write
      for (int i = 4; i >= 0; i--) rbit(ad[i]);
      for (int i = 7; i >= 0; i--) rbit(data[i]);
      rbit(1'b1);                                  // bus park
      m_oe = 0; #600;
    end
  endtask

  task automatic rffe_read(input logic [1:0] sa, input logic [4:0] ad,
                           output logic [7:0] data);
    logic b;
    begin
      rssc;
      rbit(sa[1]); rbit(sa[0]); rbit(1'b1);       // PC=1 read
      for (int i = 4; i >= 0; i--) rbit(ad[i]);
      for (int i = 7; i >= 0; i--) begin
        rrelease_bit(b);
        data[i] = b;
      end
      rbit(1'b1);
      m_oe = 0; #600;
    end
  endtask

  logic [7:0] rb;
  initial begin
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(10) @(posedge clk);

    rffe_write(2'b01, 5'h03, 8'h5A);
    repeat(5) @(posedge clk);
    if (!rx_seen) begin errors++; $display("ERROR: RFFE rx_valid never pulsed"); end
    if (rx_byte !== 8'h5A) begin errors++; $display("ERROR: RFFE rx=%h exp=5A", rx_byte); end
    if (rx_addr !== 5'h03) begin errors++; $display("ERROR: RFFE rx_addr=%h exp=03", rx_addr); end

    rffe_read (2'b01, 5'h03, rb);
    if (rb !== 8'hC3) begin errors++; $display("ERROR: RFFE read got=%h exp=C3", rb); end

    if (errors == 0) $display("TEST PASSED: RFFE");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #3_000_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")

CUSTOM["SPMI"] = dict(
rtl="""// ============================================================================
// MIPI SPMI slave: SSC + SA[3:0] + CMD[3:0] + AD[7:0] + DATA[7:0]
// Simplified command set: CMD 0x0 = register write, 0x1 = register read.
// Two-wire open-drain style, OpenCores spmi/pmic bus pattern.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module SPMI_top #(
  parameter logic [3:0] SPMI_ADDR = 4'h5
)(
  input  logic       clk,
  input  logic       rst_n,
  inout  tri         sdata,
  input  logic       sclk,
  output logic [7:0] rx_byte,
  output logic [7:0] rx_addr,
  output logic       rx_valid,
  input  logic [7:0] tx_byte,
  output logic       busy,
  output logic       irq
);
  logic sclk_s, sclk_d, sdata_s, sdata_d;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sclk_s <= 1'b0; sclk_d <= 1'b0; sdata_s <= 1'b1; sdata_d <= 1'b1;
    end else begin
      sclk_s <= sclk; sclk_d <= sclk_s;
      sdata_s <= sdata; sdata_d <= sdata_s;
    end
  end
  wire sclk_rise =  sclk_s & ~sclk_d;
  wire sclk_fall = ~sclk_s &  sclk_d;
  wire ssc_det   = ~sdata_s &  sdata_d & sclk_s;

  typedef enum logic [2:0] {ST_IDLE, ST_HEAD, ST_ADDR, ST_DATA, ST_ACKP, ST_IGNORE} st_t;
  st_t      state;
  logic [3:0] bit_cnt;
  logic [7:0] shift, addr_q;
  logic [3:0] cmd;
  logic       sd_oe;

  assign sdata   = drive_low_c ? 1'b0 : 1'bz;   // open-drain: ACK + read data
  assign busy    = (state != ST_IDLE) && (state != ST_IGNORE);
  assign irq     = rx_valid;
  assign rx_addr = addr_q;

  wire [7:0] head_w = {shift[6:0], sdata_s};

  // read data: registered on SCLK fall (the post-address fall presents bit 7)
  wire drive_low_c = sd_oe;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= ST_IDLE; bit_cnt <= '0; shift <= '0; addr_q <= '0; cmd <= '0;
      sd_oe <= 1'b0; rx_byte <= '0; rx_valid <= 1'b0;
    end else begin
      rx_valid <= 1'b0;
      if (ssc_det) begin
        state <= ST_HEAD; bit_cnt <= '0; sd_oe <= 1'b0;
      end else case (state)
        ST_HEAD: if (sclk_rise) begin
          shift <= head_w;
          if (bit_cnt == 4'd7) begin
            if (head_w[7:4] == SPMI_ADDR) begin
              cmd <= head_w[3:0];
              bit_cnt <= '0; state <= ST_ADDR;
            end else state <= ST_IGNORE;
          end else bit_cnt <= bit_cnt + 1'b1;
        end
        ST_ADDR: if (sclk_rise) begin
          shift <= head_w;
          if (bit_cnt == 4'd7) begin
            addr_q <= head_w; bit_cnt <= '0;
            sd_oe  <= 1'b0;
            state <= (cmd == 4'h0) ? ST_DATA :   // write: data follows
                     (cmd == 4'h1) ? ST_ACKP : ST_IGNORE;
          end else bit_cnt <= bit_cnt + 1'b1;
        end
        // write: receive 8 data bits, then ACK (drive 0 one bit)
        ST_DATA: if (sclk_rise) begin
          shift <= head_w;
          if (bit_cnt == 4'd7) begin
            rx_byte <= head_w; rx_valid <= 1'b1;
            bit_cnt <= '0; state <= ST_ACKP;
          end else bit_cnt <= bit_cnt + 1'b1;
        end
        // ACK pulse (write) or read data phase (cmd==1)
        ST_ACKP: begin
          if (cmd == 4'h0) begin                 // write ACK: drive low 1 bit
            if (sclk_fall) sd_oe <= 1'b1;
            else if (sclk_rise) begin sd_oe <= 1'b0; state <= ST_IDLE; end
          end else if (cmd == 4'h1) begin        // read data: drive on fall
            if (sclk_fall) begin
              sd_oe <= (tx_byte[7-bit_cnt] == 1'b0);
              if (bit_cnt == 4'd7) begin
                bit_cnt <= '0; state <= ST_IDLE;
              end else bit_cnt <= bit_cnt + 1'b1;
            end
          end else state <= ST_IDLE;
        end
        default: ;
      endcase
    end
  end

endmodule
""",
tb="""// Self-checking testbench: TB acts as SPMI master -- SystemVerilog
`timescale 1ns/1ps
module SPMI_tb;
  logic clk = 0, rst_n = 0;
  tri1  sdata;
  logic sclk = 0;
  logic m_low = 0;
  logic [7:0] rx_byte, rx_addr;
  logic rx_valid, busy;
  logic rx_seen = 0;
  int errors = 0;

  SPMI_top #(.SPMI_ADDR(4'h5)) dut (
    .clk(clk), .rst_n(rst_n), .sdata(sdata), .sclk(sclk),
    .rx_byte(rx_byte), .rx_addr(rx_addr), .rx_valid(rx_valid),
    .tx_byte(8'hC3), .busy(busy), .irq());

  always #5 clk = ~clk;
  assign sdata = m_low ? 1'b0 : 1'bz;
  always @(posedge clk) if (rx_valid) rx_seen <= 1'b1;

  task automatic ssc;
    begin m_low = 0; sclk = 1; #300;       // SCLK high first
          m_low = 1; #300;                 // SDATA falls while SCLK high
          sclk = 0; #300;
          m_low = 0; #300; end
  endtask
  task automatic sbit(input logic b);
    begin m_low = ~b; #300; sclk = 1; #600; sclk = 0; #300; end
  endtask
  task automatic srelease(output logic b);
    begin m_low = 0; #300; sclk = 1; #300; b = sdata; #300; sclk = 0; #300; end
  endtask

  task automatic spmi_write(input logic [3:0] sa, input logic [7:0] ad,
                            input logic [7:0] data);
    begin
      ssc;
      for (int i = 3; i >= 0; i--) sbit(sa[i]);
      sbit(0); sbit(0); sbit(0); sbit(0);      // CMD = write
      for (int i = 7; i >= 0; i--) sbit(ad[i]);
      for (int i = 7; i >= 0; i--) sbit(data[i]);
      srelease_bit_ack();
      #600;
    end
  endtask

  task automatic spmi_read(input logic [3:0] sa, input logic [7:0] ad,
                           output logic [7:0] data);
    logic b;
    begin
      ssc;
      for (int i = 3; i >= 0; i--) sbit(sa[i]);
      sbit(0); sbit(0); sbit(0); sbit(1);      // CMD = read
      for (int i = 7; i >= 0; i--) sbit(ad[i]);
      for (int i = 7; i >= 0; i--) begin        // slave drives data immediately
        srelease(b);
        data[i] = b;
      end
      #600;
    end
  endtask

  task automatic srelease_bit_ack;
    logic b;
    begin srelease(b); end
  endtask

  logic [7:0] rb;
  initial begin
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(10) @(posedge clk);

    spmi_write(4'h5, 8'h03, 8'h5A);
    repeat(5) @(posedge clk);
    if (!rx_seen) begin errors++; $display("ERROR: SPMI rx_valid never pulsed"); end
    if (rx_byte !== 8'h5A) begin errors++; $display("ERROR: SPMI rx=%h exp=5A", rx_byte); end
    if (rx_addr !== 8'h03) begin errors++; $display("ERROR: SPMI rx_addr=%h exp=03", rx_addr); end

    spmi_read (4'h5, 8'h03, rb);
    if (rb !== 8'hC3) begin errors++; $display("ERROR: SPMI read got=%h exp=C3", rb); end

    if (errors == 0) $display("TEST PASSED: SPMI");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #3_000_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")






CUSTOM["CAN"] = dict(
rtl="""// ============================================================================
// CAN 2.0B controller: standard (11-bit ID) frame TX/RX, loopback-capable
// - TX: bit stuffing (after 5 consecutive equal bits), CRC-15 (poly 0x4599)
// - RX: hard sync on SOF edge, de-stuffing, CRC check, ACK drive
// - Bus timing: 2 timer phases per bit; TX drives at phase 0, RX samples at 1
// Style follows OpenCores can_controller basics.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module CAN_top #(
  parameter int BAUD_DIV = 50              // clk cycles per phase
)(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        rxd,
  output logic        txd,
  input  logic        wen,
  input  logic [3:0]  waddr,   // 0: id[7:0]  1: {id[10:8],1'b0,dlc[3:0]}
  input  logic [7:0]  wdata,   // 2-9: data   10: go
  input  logic        ren,
  input  logic [3:0]  raddr,   // 0: rx id[7:0] 1: {rx_id[10:8],1'b0,rx_dlc}
  output logic [7:0]  rdata,   // 2-9: rx data  10: status
  output logic        irq
);
  // ---------------- registers ----------------
  logic [10:0] tx_id;
  logic [3:0]  tx_dlc;
  logic [7:0]  tx_mem [0:7];
  logic        tx_go, tx_busy;

  // ---------------- bit timer (2 phases per bit) ----------------
  logic [15:0] tmr;
  logic        phase;
  wire         tick = (tmr == BAUD_DIV-1);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin tmr <= '0; phase <= 1'b0; end
    else if (tick) begin tmr <= '0; phase <= ~phase; end
    else tmr <= tmr + 1'b1;
  end

  function automatic logic [14:0] crc_next(input logic [14:0] c, input logic b);
    logic fb;
    begin
      fb = b ^ c[14];
      crc_next = {c[13:0], 1'b0} ^ (fb ? 15'h4599 : 15'h0);
    end
  endfunction

  // ---------------- TX ----------------
  typedef enum logic [3:0] {
    TX_IDLE, TX_HDR, TX_DATA, TX_CRC, TX_CRCD, TX_ACK, TX_ACKD, TX_EOF
  } tx_t;
  tx_t        tstate;
  logic [4:0] tx_bit;
  logic [2:0] tx_byte;
  logic [17:0] tx_hdr;      // {id[10:0], rtr=0, ide=0, r0=0, dlc[3:0]}
  logic [14:0] tx_crc;
  logic [3:0]  run_cnt;
  logic        prev_bit;
  logic        can_out;

  wire [7:0]  tx_data_b = tx_mem[tx_byte];
  wire        tx_field_bit = (tstate == TX_HDR)  ? tx_hdr[17-tx_bit] :
                             (tstate == TX_DATA) ? tx_data_b[7-tx_bit[2:0]] :
                                                   tx_crc[14-tx_bit];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tstate <= TX_IDLE; tx_bit <= '0; tx_byte <= '0; run_cnt <= '0;
      prev_bit <= 1'b1; tx_crc <= '0; can_out <= 1'b1; tx_busy <= 1'b0;
      tx_go <= 1'b0; tx_id <= '0; tx_dlc <= '0;
      for (int i = 0; i < 8; i++) tx_mem[i] <= '0;
    end else begin
      if (wen && waddr == 4'd0) tx_id[7:0] <= wdata;
      if (wen && waddr == 4'd1) begin tx_id[10:8] <= wdata[7:5]; tx_dlc <= wdata[3:0]; end
      if (wen && waddr >= 4'd2 && waddr <= 4'd9) tx_mem[waddr[3:0] - 4'd2] <= wdata;
      if (wen && waddr == 4'd10 && wdata[0]) tx_go <= 1'b1;

      if (tick && !phase) begin                 // drive point
        case (tstate)
          TX_IDLE: if (tx_go) begin
            tx_go   <= 1'b0;
            tx_busy <= 1'b1;
            tx_hdr  <= {tx_id, 1'b0, 1'b0, 1'b0, tx_dlc};
            tx_crc  <= '0;
            run_cnt <= 4'd1;                    // SOF = first dominant bit
            prev_bit <= 1'b0;
            can_out <= 1'b0;                    // SOF
            tx_bit  <= '0; tx_byte <= '0;
            tstate  <= TX_HDR;
          end
          TX_HDR, TX_DATA, TX_CRC: begin
            if (run_cnt == 4'd5) begin
              // send stuff bit (opposite of previous); field not advanced
              can_out  <= ~prev_bit;
              prev_bit <= ~prev_bit;
              run_cnt  <= 4'd1;
            end else begin
              can_out <= tx_field_bit;
              if (tstate != TX_CRC)             // CRC over SOF..data (SOF adds 0: no-op)
                tx_crc <= crc_next(tx_crc, tx_field_bit);
              if (tx_field_bit == prev_bit) run_cnt <= run_cnt + 1'b1;
              else run_cnt <= 4'd1;
              prev_bit <= tx_field_bit;
              if (tstate == TX_HDR) begin
                if (tx_bit == 5'd17) begin
                  tx_bit <= '0;
                  tstate <= (tx_dlc == 0) ? TX_CRC : TX_DATA;
                end else tx_bit <= tx_bit + 1'b1;
              end else if (tstate == TX_DATA) begin
                if (tx_bit[2:0] == 3'd7) begin
                  tx_bit <= '0;
                  if (tx_byte == tx_dlc[2:0] - 3'd1) tstate <= TX_CRC;
                  else tx_byte <= tx_byte + 1'b1;
                end else tx_bit <= tx_bit + 1'b1;
              end else begin
                if (tx_bit == 5'd14) begin tx_bit <= '0; tstate <= TX_CRCD; end
                else tx_bit <= tx_bit + 1'b1;
              end
            end
          end
          TX_CRCD: begin can_out <= 1'b1; tstate <= TX_ACK; end
          TX_ACK:  begin can_out <= 1'b1; tstate <= TX_ACKD; end   // release for ACK
          TX_ACKD: begin can_out <= 1'b1; tstate <= TX_EOF; tx_bit <= '0; end
          TX_EOF: begin
            can_out <= 1'b1;
            if (tx_bit == 5'd6) begin
              tx_bit <= '0; tstate <= TX_IDLE; tx_busy <= 1'b0;
            end else tx_bit <= tx_bit + 1'b1;
          end
          default: tstate <= TX_IDLE;
        endcase
      end
    end
  end

  // ---------------- RX ----------------
  typedef enum logic [3:0] {
    RX_IDLE, RX_HDR, RX_DATA, RX_CRC, RX_CRCD, RX_ACK, RX_ACKD, RX_EOF
  } rx_t;
  rx_t         rstate;
  logic [4:0]  rx_bit;
  logic [2:0]  rx_byte;
  logic [17:0] rx_hdr_sh;
  logic [10:0] rx_id;
  logic [3:0]  rx_dlc;
  logic [7:0]  rx_mem [0:7];
  logic [14:0] rx_crc;
  logic [3:0]  rx_run;        // consecutive equal received bits
  logic        last_rx;       // last received bit (stuff bits included)
  logic        rx_bit_v;      // destuffed bit valid (pulse)
  logic        rx_err, rx_valid;
  logic        ack_drive;
  logic        rxed, rxed_d;
  logic        sof_wait;      // next sample is the SOF bit itself

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rxed <= 1'b1; rxed_d <= 1'b1; end
    else begin rxed <= rxd; rxed_d <= rxed; end
  end
  wire sof_det = rxed_d & ~rxed;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rstate <= RX_IDLE; rx_bit <= '0; rx_byte <= '0; rx_run <= '0;
      rx_crc <= '0; rx_bit_v <= 1'b0; rx_err <= 1'b0; rx_valid <= 1'b0;
      ack_drive <= 1'b0; last_rx <= 1'b1; rx_hdr_sh <= '0; sof_wait <= 1'b0;
      rx_id <= '0; rx_dlc <= '0;
      for (int i = 0; i < 8; i++) rx_mem[i] <= '0;
    end else begin
      rx_bit_v <= 1'b0;
      rx_valid <= 1'b0;

      if (sof_det && rstate == RX_IDLE && !sof_wait) begin
        // hard sync: SOF edge; consume SOF immediately (it is dominant)
        rstate   <= RX_HDR;
        rx_bit   <= '0; rx_byte <= '0; rx_run <= 4'd1; last_rx <= 1'b0;
        rx_crc   <= '0;                 // crc_next(*,0) on all-zero state = 0
        rx_err   <= 1'b0;
        sof_wait <= 1'b1;               // skip the mid-SOF sample (same bit)
      end

      if (tick && phase && rstate != RX_IDLE) begin
        if (sof_wait) begin
          sof_wait <= 1'b0;             // mid-SOF sample: already consumed
        end else if (rstate == RX_HDR || rstate == RX_DATA || rstate == RX_CRC) begin
          if (rx_run == 4'd5) begin
            // stuff bit: discard. It still counts as 1 received bit (it breaks
            // the run), so TX/RX run counters stay aligned.
            rx_run   <= 4'd1;
            last_rx  <= rxed;
          end else begin
            rx_bit_v <= 1'b1;
            if (rxed == last_rx) rx_run <= rx_run + 1'b1;
            else rx_run <= 4'd1;
            last_rx <= rxed;
          end
        end else begin
          rx_bit_v <= 1'b1;             // CRC delim / ACK / EOF: no stuffing
        end
      end

      if (rx_bit_v) begin
        case (rstate)
          RX_HDR: begin
            rx_hdr_sh <= {rx_hdr_sh[16:0], rxed};
            rx_crc    <= crc_next(rx_crc, rxed);
            if (rx_bit == 5'd17) begin
              rx_id  <= rx_hdr_sh[16:6];          // id[10:0] = hdr[17:7]
              rx_dlc <= {rx_hdr_sh[2:0], rxed};   // dlc[3:0] = hdr[3:0]
              rx_bit <= '0;
              rstate <= ({rx_hdr_sh[2:0], rxed} == 4'd0) ? RX_CRC : RX_DATA;
            end else rx_bit <= rx_bit + 1'b1;
          end
          RX_DATA: begin
            rx_mem[rx_byte][7-rx_bit[2:0]] <= rxed;
            rx_crc <= crc_next(rx_crc, rxed);
            if (rx_bit[2:0] == 3'd7) begin
              rx_bit <= '0;
              if (rx_byte == rx_dlc[2:0] - 3'd1) rstate <= RX_CRC;
              else rx_byte <= rx_byte + 1'b1;
            end else rx_bit <= rx_bit + 1'b1;
          end
          RX_CRC: begin
            if (rx_bit < 5'd15 && rxed != rx_crc[14-rx_bit]) rx_err <= 1'b1;
            if (rx_bit == 5'd14) begin rx_bit <= '0; rstate <= RX_CRCD; end
            else rx_bit <= rx_bit + 1'b1;
          end
          RX_CRCD: begin rx_bit <= '0; rstate <= RX_ACK; ack_drive <= !rx_err; end
          RX_ACK:  begin ack_drive <= 1'b0; rstate <= RX_ACKD; end
          RX_ACKD: rstate <= RX_EOF;
          RX_EOF: begin
            if (rx_bit == 5'd6) begin
              rx_bit <= '0; rstate <= RX_IDLE;
              if (!rx_err) rx_valid <= 1'b1;
            end else rx_bit <= rx_bit + 1'b1;
          end
          default: ;
        endcase
      end
    end
  end

  assign txd = can_out & ~ack_drive;   // RX ACK dominant-overrides during ACK slot
  assign irq = rx_valid;

  assign rdata = (raddr == 4'd0)  ? rx_id[7:0] :
                 (raddr == 4'd1)  ? {rx_id[10:8], 1'b0, rx_dlc} :
                 (raddr >= 4'd2 && raddr <= 4'd9) ? rx_mem[raddr[3:0] - 4'd2] :
                 (raddr == 4'd10) ? {2'b00, rx_err, 1'b0, 1'b0, tx_busy, 2'b00} :
                                    8'h00;

endmodule
""",
tb="""// Self-checking testbench: CAN loopback (rxd = txd) -- SystemVerilog
`timescale 1ns/1ps
module CAN_tb;
  logic clk = 0, rst_n = 0;
  logic rxd, txd;
  logic wen = 0, ren = 0;
  logic [3:0] waddr = 0, raddr = 0;
  logic [7:0] wdata = 0, rdata;
  int errors = 0;

  CAN_top #(.BAUD_DIV(20)) dut (
    .clk(clk), .rst_n(rst_n), .rxd(rxd), .txd(txd),
    .wen(wen), .waddr(waddr), .wdata(wdata),
    .ren(ren), .raddr(raddr), .rdata(rdata), .irq());

  always #5 clk = ~clk;
  assign rxd = txd;                          // loopback

  task automatic wr(input logic [3:0] a, input logic [7:0] d);
    begin
      @(negedge clk); wen <= 1'b1; waddr <= a; wdata <= d;
      @(negedge clk); wen <= 1'b0;
    end
  endtask
  task automatic rd(input logic [3:0] a, output logic [7:0] d);
    begin
      @(negedge clk); ren <= 1'b1; raddr <= a;
      #1 d = rdata;
      @(negedge clk); ren <= 1'b0;
    end
  endtask

  logic [7:0] idl, hdr, b0, b1, b2, b3, st;
  task automatic check_frame(input logic [10:0] id, input logic [3:0] dlc,
                             input logic [7:0] d0, input logic [7:0] d1,
                             input logic [7:0] d2, input logic [7:0] d3);
    begin
      wr(4'd0, id[7:0]);
      wr(4'd1, {id[10:8], 1'b0, dlc});
      wr(4'd2, d0); wr(4'd3, d1); wr(4'd4, d2); wr(4'd5, d3);
      wr(4'd10, 8'h01);
      wait (dut.rx_valid === 1'b1);
      @(posedge clk); #1;
      rd(4'd0, idl); rd(4'd1, hdr);
      rd(4'd2, b0); rd(4'd3, b1); rd(4'd4, b2); rd(4'd5, b3);
      rd(4'd10, st);
      if ({hdr[7:5], idl} !== id) begin
        errors++; $display("ERROR: CAN id got=%h_%h exp=%h", hdr[7:5], idl, id);
      end
      if (hdr[3:0] !== dlc) begin errors++; $display("ERROR: CAN dlc got=%0d exp=%0d", hdr[3:0], dlc); end
      if (dlc >= 1 && b0 !== d0) begin errors++; $display("ERROR: CAN b0 got=%h exp=%h", b0, d0); end
      if (dlc >= 2 && b1 !== d1) begin errors++; $display("ERROR: CAN b1 got=%h exp=%h", b1, d1); end
      if (dlc >= 3 && b2 !== d2) begin errors++; $display("ERROR: CAN b2 got=%h exp=%h", b2, d2); end
      if (dlc >= 4 && b3 !== d3) begin errors++; $display("ERROR: CAN b3 got=%h exp=%h", b3, d3); end
      if (st[5] !== 1'b0) begin errors++; $display("ERROR: CAN rx_err set (st=%h)", st); end
      repeat (50) @(posedge clk);          // inter-frame gap
    end
  endtask

  initial begin
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(20) @(posedge clk);

    check_frame(11'h1AB, 4'd4, 8'h55, 8'hAA, 8'h0F, 8'hF0);  // stuffing-heavy
    check_frame(11'h055, 4'd0, 8'h00, 8'h00, 8'h00, 8'h00);  // dataless
    check_frame(11'h7FF, 4'd2, 8'hFF, 8'hFF, 8'h00, 8'h00);  // worst-case stuff

    if (errors == 0) $display("TEST PASSED: CAN");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #8_000_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")




CUSTOM["RGMII"] = dict(
rtl="""// ============================================================================
// RGMII PHY-side datapath: 4-bit DDR TX (nibble per clock edge) + RX capture
// TX: bytes from host FIFO -> nibbles on txd/tx_ctl (DDR on tx_clk)
// RX: nibbles on rxd/rx_ctl (DDR on rx_clk) -> reassembled into FIFO
// Loopback-compatible (rx=tx). OpenCores ethernet/rgmii style.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module RGMII_top #(
  parameter int DEPTH = 16
)(
  input  logic       clk,
  input  logic       rst_n,
  input  logic       tx_clk,
  output logic [3:0] txd,
  output logic       tx_ctl,
  input  logic       rx_clk,
  input  logic [3:0] rxd,
  input  logic       rx_ctl,
  input  logic       wen,
  input  logic [3:0] waddr,
  input  logic [7:0] wdata,
  input  logic       ren,
  input  logic [3:0] raddr,
  output logic [7:0] rdata,
  output logic [4:0] count,
  output logic       irq
);
  // TX queue (bytes to send)
  logic [7:0]  txq [0:7];
  logic [2:0]  tx_wr, tx_rd;
  logic        tx_half;        // 0 = high nibble next, 1 = low nibble
  logic        tx_ctl_q;

  // push on host write (waddr 0 = data)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin tx_wr <= '0; end
    else if (wen && waddr == 4'd0) begin
      txq[tx_wr] <= wdata;
      tx_wr <= tx_wr + 1'b1;
    end
  end

  // TX DDR output: drive on both edges of tx_clk, direct from queue (no bubble)
  always @(posedge tx_clk or negedge tx_clk) begin
    if (!rst_n) begin
      txd <= 4'h0; tx_ctl_q <= 1'b0; tx_half <= 1'b0; tx_rd <= '0;
    end else if ((tx_wr != tx_rd) || tx_half) begin
      tx_ctl_q <= 1'b1;
      if (!tx_half) begin
        txd     <= txq[tx_rd][7:4];
        tx_half <= 1'b1;
      end else begin
        txd     <= txq[tx_rd][3:0];
        tx_half <= 1'b0;
        tx_rd   <= tx_rd + 1'b1;
      end
    end else begin
      tx_ctl_q <= 1'b0;
    end
  end
  assign tx_ctl = tx_ctl_q;

  // RX DDR capture
  logic [7:0]  rxq [0:DEPTH-1];
  logic [4:0]  rx_wr;
  logic [3:0]  rx_hi;
  logic        rx_half;
  logic        rxv_s, rxv_d, rxc_s, rxc_d;
  logic [3:0]  rxd_s, rxd_d;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rxv_s <= 1'b0; rxv_d <= 1'b0; rxc_s <= 1'b0; rxc_d <= 1'b0;
      rxd_s <= '0; rxd_d <= '0;
    end else begin
      rxv_s <= rx_clk; rxv_d <= rxv_s;
      rxc_s <= rx_ctl; rxc_d <= rxc_s;
      rxd_s <= rxd;    rxd_d <= rxd_s;
    end
  end
  wire rxv_edge = rxv_s ^ rxv_d;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_wr <= '0; rx_half <= 1'b0; rx_hi <= '0;
    end else if (rxv_edge) begin
      if (rxc_d) begin
        if (!rx_half) begin
          rx_hi   <= rxd_d;
          rx_half <= 1'b1;
        end else begin
          rxq[rx_wr[3:0]] <= {rx_hi, rxd_d};
          rx_wr   <= rx_wr + 1'b1;
          rx_half <= 1'b0;
        end
      end else begin
        rx_half <= 1'b0;
      end
    end
  end

  assign count = rx_wr;
  assign rdata = rxq[raddr[3:0]];
  assign irq   = (rx_wr != 0) && ren;

endmodule
""",
tb="""// Self-checking testbench: RGMII loopback (rxd=txd, rx_ctl=tx_ctl, rx_clk=tx_clk)
`timescale 1ns/1ps
module RGMII_tb;
  logic clk = 0, rst_n = 0;
  logic tx_clk = 0, rx_clk;
  logic [3:0] txd, rxd;
  logic tx_ctl, rx_ctl;
  logic wen = 0, ren = 0;
  logic [3:0] waddr = 0, raddr = 0;
  logic [7:0] wdata = 0, rdata;
  logic [4:0] count;
  int errors = 0;

  RGMII_top dut (
    .clk(clk), .rst_n(rst_n), .tx_clk(tx_clk), .txd(txd), .tx_ctl(tx_ctl),
    .rx_clk(rx_clk), .rxd(rxd), .rx_ctl(rx_ctl),
    .wen(wen), .waddr(waddr), .wdata(wdata),
    .ren(ren), .raddr(raddr), .rdata(rdata), .count(count), .irq());

  always #5 clk = ~clk;
  always #40 tx_clk = ~tx_clk;         // 12.5 MHz -> 25 MHz nibble rate
  assign rx_clk  = tx_clk;
  assign rxd     = txd;
  assign rx_ctl  = tx_ctl;

  task automatic wr(input logic [7:0] d);
    begin
      @(negedge clk); wen <= 1'b1; waddr <= 4'd0; wdata <= d;
      @(negedge clk); wen <= 1'b0;
    end
  endtask
  task automatic rd(input logic [3:0] a, output logic [7:0] d);
    begin
      @(negedge clk); ren <= 1'b1; raddr <= a;
      #1 d = rdata;
      @(negedge clk); ren <= 1'b0;
    end
  endtask

  logic [7:0] got;
  logic [7:0] exp [0:7];
  initial begin
    for (int i = 0; i < 8; i++) exp[i] = 8'h10 + i * 8'h11;
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);

    for (int i = 0; i < 8; i++) wr(exp[i]);
    // wait for all 8 bytes received (2 nibbles each -> 16 edges)
    wait (count == 5'd8);
    repeat(10) @(posedge clk);
    for (int i = 0; i < 8; i++) begin
      rd(i[3:0], got);
      if (got !== exp[i]) begin
        errors++; $display("ERROR: RGMII rxq[%0d] got=%h exp=%h", i, got, exp[i]);
      end
    end

    if (errors == 0) $display("TEST PASSED: RGMII");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #2_000_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")

CUSTOM["GMII"] = dict(
rtl="""// ============================================================================
// GMII MAC datapath: 8-bit SDR TX + RX with FIFOs
// TX: bytes from host FIFO -> txd/tx_en on tx_clk; RX: rxd/rx_dv -> FIFO
// Loopback-compatible. OpenCores ethernet/mac style.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module GMII_top #(
  parameter int DEPTH = 16
)(
  input  logic       clk,
  input  logic       rst_n,
  input  logic       tx_clk,
  output logic [7:0] txd,
  output logic       tx_en,
  output logic       tx_er,
  input  logic       rx_clk,
  input  logic [7:0] rxd,
  input  logic       rx_dv,
  input  logic       rx_er,
  input  logic       wen,
  input  logic [3:0] waddr,
  input  logic [7:0] wdata,
  input  logic       ren,
  input  logic [3:0] raddr,
  output logic [7:0] rdata,
  output logic [4:0] count,
  output logic       irq
);
  logic [7:0] txq [0:7];
  logic [2:0] tx_wr, tx_rd;
  logic       txen_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin tx_wr <= '0; tx_rd <= '0; end
    else if (wen && waddr == 4'd0) begin
      txq[tx_wr] <= wdata;
      tx_wr <= tx_wr + 1'b1;
    end
  end

  always @(posedge tx_clk) begin
    if (!rst_n) begin
      txd <= 8'h0; txen_q <= 1'b0; tx_rd <= '0;
    end else if (tx_wr != tx_rd) begin
      txd <= txq[tx_rd];
      txen_q <= 1'b1;
      tx_rd <= tx_rd + 1'b1;
    end else begin
      txen_q <= 1'b0;
    end
  end
  assign tx_en = txen_q;
  assign tx_er = 1'b0;

  logic [7:0] rxq [0:DEPTH-1];
  logic [4:0] rx_wr;
  logic       rxclk_s, rxclk_d, rxdv_d;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rxclk_s <= 1'b0; rxclk_d <= 1'b0; rxdv_d <= 1'b0; end
    else begin rxclk_s <= rx_clk; rxclk_d <= rxclk_s; rxdv_d <= rx_dv; end
  end
  wire rxv_rise = rxclk_s & ~rxclk_d;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rx_wr <= '0; end
    else if (rxv_rise && rxdv_d) begin
      rxq[rx_wr[3:0]] <= rxd;
      rx_wr <= rx_wr + 1'b1;
    end
  end

  assign count = rx_wr;
  assign rdata = rxq[raddr[3:0]];
  assign irq   = (rx_wr != 0) && ren;

endmodule
""",
tb="""// Self-checking testbench: GMII loopback -- SystemVerilog
`timescale 1ns/1ps
module GMII_tb;
  logic clk = 0, rst_n = 0;
  logic tx_clk = 0, rx_clk;
  logic [7:0] txd, rxd;
  logic tx_en, rx_dv;
  logic wen = 0, ren = 0;
  logic [3:0] waddr = 0, raddr = 0;
  logic [7:0] wdata = 0, rdata;
  logic [4:0] count;
  int errors = 0;

  GMII_top dut (
    .clk(clk), .rst_n(rst_n), .tx_clk(tx_clk), .txd(txd), .tx_en(tx_en),
    .tx_er(), .rx_clk(rx_clk), .rxd(rxd), .rx_dv(rx_dv), .rx_er(1'b0),
    .wen(wen), .waddr(waddr), .wdata(wdata),
    .ren(ren), .raddr(raddr), .rdata(rdata), .count(count), .irq());

  always #5 clk = ~clk;
  always #40 tx_clk = ~tx_clk;
  assign rx_clk = tx_clk;
  assign rxd    = txd;
  assign rx_dv  = tx_en;

  task automatic wr(input logic [7:0] d);
    begin
      @(negedge clk); wen <= 1'b1; waddr <= 4'd0; wdata <= d;
      @(negedge clk); wen <= 1'b0;
    end
  endtask
  task automatic rd(input logic [3:0] a, output logic [7:0] d);
    begin
      @(negedge clk); ren <= 1'b1; raddr <= a;
      #1 d = rdata;
      @(negedge clk); ren <= 1'b0;
    end
  endtask

  logic [7:0] got;
  logic [7:0] exp [0:7];
  initial begin
    for (int i = 0; i < 8; i++) exp[i] = 8'h80 + i * 8'h7;
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);

    for (int i = 0; i < 8; i++) wr(exp[i]);
    wait (count == 5'd8);
    repeat(10) @(posedge clk);
    for (int i = 0; i < 8; i++) begin
      rd(i[3:0], got);
      if (got !== exp[i]) begin
        errors++; $display("ERROR: GMII rxq[%0d] got=%h exp=%h", i, got, exp[i]);
      end
    end

    if (errors == 0) $display("TEST PASSED: GMII");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #2_000_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")




CUSTOM["XGMII"] = dict(
rtl="""// ============================================================================
// XGMII MAC datapath: 32-bit SDR TX + RX with term/error column (txc/rxc)
// TX: bytes from host FIFO -> txd on tx_clk with txc column markers
// RX: rxd/rxc on rx_clk -> FIFO; rxc != 0 marks control/Delim
// Loopback-compatible. OpenCores ethernet/xgmii style.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module XGMII_top #(
  parameter int DEPTH = 16
)(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        tx_clk,
  output logic [31:0] txd,
  output logic [3:0]  txc,
  input  logic        rx_clk,
  input  logic [31:0] rxd,
  input  logic [3:0]  rxc,
  input  logic        wen,
  input  logic [3:0]  waddr,     // 0: data
  input  logic [7:0]  wdata,
  input  logic        ren,
  input  logic [3:0]  raddr,
  output logic [7:0]  rdata,
  output logic [4:0]  count,
  output logic        irq
);
  logic [7:0] txq [0:7];
  logic [2:0] tx_wr, tx_rd;
  logic       txen_q;
  logic [1:0] lane;              // 32-bit word = 4 host bytes

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin tx_wr <= '0; tx_rd <= '0; lane <= '0; end
    else if (wen && waddr == 4'd0) begin
      txq[tx_wr] <= wdata;
      tx_wr <= tx_wr + 1'b1;
    end
  end

  always @(posedge tx_clk) begin
    if (!rst_n) begin
      txd <= 32'h0; txc <= 4'hF; txen_q <= 1'b0; tx_rd <= '0; lane <= '0;
    end else if (tx_wr - tx_rd >= 3'd4) begin
      // assemble 4 bytes into one 32-bit word (little-lane order: byte0 -> [7:0])
      txd <= {txq[tx_rd+3'd3], txq[tx_rd+3'd2], txq[tx_rd+3'd1], txq[tx_rd]};
      txc <= 4'h0;                     // all data lanes
      txen_q <= 1'b1;
      tx_rd <= tx_rd + 3'd4;
    end else begin
      txc <= 4'hF;                     // idle: all control lanes -> RX ignores
      txen_q <= 1'b0;
    end
  end

  logic [7:0] rxq [0:DEPTH-1];
  logic [4:0] rx_wr;
  logic       rxclk_s, rxclk_d;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rxclk_s <= 1'b0; rxclk_d <= 1'b0; end
    else begin rxclk_s <= rx_clk; rxclk_d <= rxclk_s; end
  end
  wire rxv_rise = rxclk_s & ~rxclk_d;

  // capture each data lane per rx_clk (ignore control lanes rxc!=0).
  // Lane i writes at rx_wr+i (constant offsets; all NBAs read old rx_wr),
  // then rx_wr advances by the number of data lanes.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) rx_wr <= '0;
    else if (rxv_rise && rxc == 4'h0) begin
      if (!rxc[0]) rxq[rx_wr[3:0]]        <= rxd[7:0];
      if (!rxc[1]) rxq[rx_wr[3:0] + 4'd1] <= rxd[15:8];
      if (!rxc[2]) rxq[rx_wr[3:0] + 4'd2] <= rxd[23:16];
      if (!rxc[3]) rxq[rx_wr[3:0] + 4'd3] <= rxd[31:24];
      casez (rxc)
        4'b0000: rx_wr <= rx_wr + 5'd4;
        4'b0001: rx_wr <= rx_wr + 5'd3;
        4'b0010: rx_wr <= rx_wr + 5'd3;
        4'b0100: rx_wr <= rx_wr + 5'd3;
        4'b1000: rx_wr <= rx_wr + 5'd3;
        4'b0101: rx_wr <= rx_wr + 5'd2;
        4'b0110: rx_wr <= rx_wr + 5'd2;
        4'b1001: rx_wr <= rx_wr + 5'd2;
        4'b1010: rx_wr <= rx_wr + 5'd2;
        4'b1100: rx_wr <= rx_wr + 5'd2;
        default: rx_wr <= rx_wr + 5'd1;
      endcase
    end
  end

  assign count = rx_wr;
  assign rdata = rxq[raddr[3:0]];
  assign irq   = (rx_wr != 0) && ren;

endmodule
""",
tb="""// Self-checking testbench: XGMII loopback -- SystemVerilog
`timescale 1ns/1ps
module XGMII_tb;
  logic clk = 0, rst_n = 0;
  logic tx_clk = 0, rx_clk;
  logic [31:0] txd, rxd;
  logic [3:0] txc, rxc;
  logic wen = 0, ren = 0;
  logic [3:0] waddr = 0, raddr = 0;
  logic [7:0] wdata = 0, rdata;
  logic [4:0] count;
  int errors = 0;

  XGMII_top dut (
    .clk(clk), .rst_n(rst_n), .tx_clk(tx_clk), .txd(txd), .txc(txc),
    .rx_clk(rx_clk), .rxd(rxd), .rxc(rxc),
    .wen(wen), .waddr(waddr), .wdata(wdata),
    .ren(ren), .raddr(raddr), .rdata(rdata), .count(count), .irq());

  always #5 clk = ~clk;
  always #40 tx_clk = ~tx_clk;
  assign rx_clk = tx_clk;
  assign rxd    = txd;
  assign rxc    = txc;

  task automatic wr(input logic [7:0] d);
    begin
      @(negedge clk); wen <= 1'b1; waddr <= 4'd0; wdata <= d;
      @(negedge clk); wen <= 1'b0;
    end
  endtask
  task automatic rd(input logic [3:0] a, output logic [7:0] d);
    begin
      @(negedge clk); ren <= 1'b1; raddr <= a;
      #1 d = rdata;
      @(negedge clk); ren <= 1'b0;
    end
  endtask

  logic [7:0] got;
  logic [7:0] exp [0:7];
  initial begin
    for (int i = 0; i < 8; i++) exp[i] = 8'h5A + i * 8'h9;
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);

    for (int i = 0; i < 8; i++) wr(exp[i]);
    wait (count == 5'd8);
    repeat(10) @(posedge clk);
    for (int i = 0; i < 8; i++) begin
      rd(i[3:0], got);
      if (got !== exp[i]) begin
        errors++; $display("ERROR: XGMII rxq[%0d] got=%h exp=%h", i, got, exp[i]);
      end
    end

    if (errors == 0) $display("TEST PASSED: XGMII");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #2_000_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")

CUSTOM["ATB"] = dict(
rtl="""// ============================================================================
// CoreSight ATB slave: atvalid/atready handshake, 32-bit data + 7-bit ID
// Sink with 16-deep FIFO capture; fifo flush on atid change or AFREADY.
// OpenCreensight/atb funnel style.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module ATB_top #(
  parameter int DW = 32,
  parameter int DEPTH = 16
)(
  input  logic            clk,
  input  logic            rst_n,
  input  logic            atvalid,
  output logic            atready,
  input  logic [DW-1:0]   atdata,
  input  logic [6:0]      atid,
  input  logic            atlast,
  input  logic            afvalid,
  output logic            afready,
  input  logic            ren,
  input  logic [3:0]      raddr,
  output logic [DW-1:0]   rdata,
  output logic [4:0]      count,
  output logic [6:0]      last_id,
  output logic            irq
);
  logic [DW-1:0] mem [0:DEPTH-1];
  logic [4:0]    wr_ptr;
  logic [6:0]    cur_id;
  logic          id_change;

  assign atready = (wr_ptr < DEPTH);
  assign afready = 1'b1;                     // always accept flush
  assign count   = wr_ptr;
  assign irq     = atvalid && atready && atlast;

  // flush FIFO when AFVALID with new ID (simplified funnel behavior)
  assign id_change = afvalid && (atid != cur_id);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_ptr <= '0; cur_id <= '0; last_id <= '0;
    end else begin
      if (id_change) begin
        wr_ptr <= '0;                 // flush on id change
        cur_id <= atid;
      end else if (atvalid && atready) begin
        mem[wr_ptr[3:0]] <= atdata;
        wr_ptr <= wr_ptr + 1'b1;
        if (atlast) last_id <= atid;
      end
    end
  end

  assign rdata = mem[raddr[3:0]];

endmodule
""",
tb="""// Self-checking testbench for ATB_top -- SystemVerilog
`timescale 1ns/1ps
module ATB_tb;
  logic clk = 0, rst_n = 0;
  logic atvalid = 0, atready;
  logic [31:0] atdata = 0;
  logic [6:0] atid = 0;
  logic atlast = 0;
  logic afvalid = 0, afready;
  logic ren = 0;
  logic [3:0] raddr = 0;
  logic [31:0] rdata;
  logic [4:0] count;
  logic [6:0] last_id;
  logic irq;
  logic irq_seen = 0;
  int errors = 0;

  ATB_top dut (
    .clk(clk), .rst_n(rst_n), .atvalid(atvalid), .atready(atready),
    .atdata(atdata), .atid(atid), .atlast(atlast),
    .afvalid(afvalid), .afready(afready),
    .ren(ren), .raddr(raddr), .rdata(rdata), .count(count),
    .last_id(last_id), .irq(irq));

  always #5 clk = ~clk;
  always @(posedge clk) if (irq) irq_seen <= 1'b1;

  task automatic send(input logic [31:0] d, input logic [6:0] id, input logic last);
    begin
      wait (atready === 1'b1);
      @(negedge clk);
      atdata <= d; atid <= id; atlast <= last; atvalid <= 1'b1;
      @(posedge clk); #1;
      @(negedge clk);
      atvalid <= 1'b0; atlast <= 1'b0;
    end
  endtask

  logic [31:0] exp [0:3];
  initial begin
    exp[0] = 32'hDEAD_BEEF; exp[1] = 32'h1234_5678;
    exp[2] = 32'hCAFE_F00D; exp[3] = 32'h0BAD_C0DE;
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);

    // first trace burst, id=0x12
    for (int i = 0; i < 4; i++) send(exp[i], 7'h12, i == 3);
    repeat(2) @(posedge clk);
    if (count !== 5'd4) begin errors++; $display("ERROR: ATB count=%0d exp=4", count); end
    if (!irq_seen) begin errors++; $display("ERROR: ATB irq never fired"); end
    if (last_id !== 7'h12) begin errors++; $display("ERROR: ATB last_id=%h", last_id); end
    for (int i = 0; i < 4; i++) begin
      @(negedge clk); ren <= 1'b1; raddr <= i[3:0];
      #1;
      if (rdata !== exp[i]) begin errors++; $display("ERROR: ATB mem[%0d] got=%h exp=%h", i, rdata, exp[i]); end
      @(negedge clk); ren <= 1'b0;
    end

    // flush with new id -> FIFO empties
    @(negedge clk); afvalid <= 1'b1; atid <= 7'h34;
    @(posedge clk); #1;
    @(negedge clk); afvalid <= 1'b0;
    repeat(2) @(posedge clk);
    if (count !== 5'd0) begin errors++; $display("ERROR: ATB flush count=%0d exp=0", count); end

    if (errors == 0) $display("TEST PASSED: ATB");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #500_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")




CUSTOM["USB2.0"] = dict(
rtl="""// ============================================================================
// USB 2.0 full-speed device controller, echo mode (FS, addr 0 / ep 0 subset)
// RX: K-edge resync, NRZI decode, SYNC, de-stuffing, PID check, CRC16, EOP
// TX: CAN-style serializer; NRZI; bit stuffing; SYNC/PID/payload/CRC16; SE0 EOP
// Turn-around delay + self-transmit RX gating for pin-shared echo.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module USB2_0_top #(
  parameter int BAUD_DIV = 20,        // clk per half-bit (bit = 2*BAUD_DIV)
  parameter int MAXB     = 8          // max payload bytes
)(
  input  logic        clk,
  input  logic        rst_n,
  inout  tri          dp,
  inout  tri          dm,
  output logic        busy,
  output logic        irq
);
  // ---------------- bit timer (2 phases per bit) ----------------
  logic [15:0] tmr;
  logic        phase;
  wire         tick = (tmr == BAUD_DIV-1);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin tmr <= '0; phase <= 1'b0; end
    else if (tick) begin tmr <= '0; phase <= ~phase; end
    else tmr <= tmr + 1'b1;
  end

  // ---------------- line sampling ----------------
  logic dps, dms;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin dps <= 1'b1; dms <= 1'b0; end
    else begin dps <= dp; dms <= dm; end
  end
  wire line_j   =  dps & ~dms;
  wire line_k   = ~dps &  dms;
  wire line_se0 = ~dps & ~dms;

  function automatic logic [15:0] crc16_u(input logic [15:0] c, input logic b);
    logic fb;
    begin
      fb = c[0] ^ b;
      crc16_u = c >> 1;
      if (fb) crc16_u = crc16_u ^ 16'h8005;
    end
  endfunction

  // ---------------- TX ----------------
  typedef enum logic [1:0] {T_IDLE, T_PKT, T_EOP0, T_EOPJ} tx_t;
  tx_t         tstate;
  logic [7:0]  tx_shift;
  logic [15:0] tx_crc;
  logic [5:0]  tbit;
  logic [2:0]  tbyte;
  logic [1:0]  tfld;          // 0=SYNC 1=PID 2=DATA 3=CRC
  logic [3:0]  run_cnt;
  logic [7:0]  tx_mem [0:MAXB-1];
  logic [3:0]  tx_pid;
  logic [4:0]  tx_len;
  logic        tx_go;
  logic        oe_q, dp_q, dm_q;

  wire [7:0] sync_b = 8'h80;
  wire [7:0] pid_b  = {~tx_pid, tx_pid};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tstate <= T_IDLE; tfld <= '0; tbit <= '0; tbyte <= '0;
      run_cnt <= '0; oe_q <= 1'b0; dp_q <= 1'b1; dm_q <= 1'b0;
      tx_crc <= '0; tx_shift <= '0; tx_go <= 1'b0; tx_len <= '0; tx_pid <= '0;
      for (int i = 0; i < MAXB; i++) tx_mem[i] <= '0;
    end else begin
      if (tick && !phase) begin                 // drive point
        case (tstate)
          T_IDLE: if (tx_go) begin
            tx_go   <= 1'b0;
            tfld    <= 2'd0; tbit <= '0;
            run_cnt <= '0;
            tx_crc  <= '0;
            tx_shift<= sync_b >> 1;             // bit0 pre-driven below
            oe_q    <= 1'b1;
            dp_q    <= 1'b0; dm_q <= 1'b1;      // SYNC bit0 = K
            tstate  <= T_PKT;
          end
          T_PKT: begin
            if (run_cnt == 4'd6 && tfld != 2'd0) begin
              dp_q <= ~dp_q; dm_q <= ~dm_q;     // stuff bit = 0 -> toggle
              run_cnt <= 4'd1;
            end else begin
              if (tfld == 2'd3) begin           // CRC: send ~tx_crc[0]
                if (tx_crc[0] == 1'b1) begin dp_q <= ~dp_q; dm_q <= ~dm_q; end
                run_cnt <= (~tx_crc[0]) ? run_cnt + 1'b1 : 4'd1;
                tx_crc  <= tx_crc >> 1;
              end else begin
                if (tx_shift[0] == 1'b0) begin dp_q <= ~dp_q; dm_q <= ~dm_q; end
                if (tfld == 2'd2) tx_crc <= crc16_u(tx_crc, tx_shift[0]);
                run_cnt <= tx_shift[0] ? run_cnt + 1'b1 : 4'd1;
                tx_shift <= tx_shift >> 1;
              end
              if (tfld == 2'd0) begin
                if (tbit == 6'd6) begin tfld <= 2'd1; tx_shift <= pid_b; tbit <= '0; end
                else tbit <= tbit + 1'b1;
              end else if (tfld == 2'd1) begin
                if (tbit == 6'd7) begin
                  tbit <= '0;
                  if (tx_len == 5'd0) tfld <= 2'd3;
                  else begin tfld <= 2'd2; tbyte <= '0; tx_shift <= tx_mem[0]; end
                end else tbit <= tbit + 1'b1;
              end else if (tfld == 2'd2) begin
                if (tbit == 6'd7) begin
                  tbit <= '0;
                  if (tbyte == tx_len[2:0] - 3'd1) tfld <= 2'd3;
                  else begin tbyte <= tbyte + 3'd1; tx_shift <= tx_mem[tbyte + 3'd1]; end
                end else tbit <= tbit + 1'b1;
              end else begin
                if (tbit == 6'd15) tstate <= T_EOP0;
                else tbit <= tbit + 1'b1;
              end
            end
          end
          T_EOP0: begin
            oe_q <= 1'b1; dp_q <= 1'b0; dm_q <= 1'b0;   // SE0
            tstate <= T_EOPJ;
          end
          T_EOPJ: begin
            oe_q <= 1'b0;                               // release to J
            tstate <= T_IDLE;
          end
          default: tstate <= T_IDLE;
        endcase
      end
    end
  end

  assign dp = oe_q ? dp_q : 1'bz;
  assign dm = oe_q ? dm_q : 1'bz;

  // ---------------- RX ----------------
  typedef enum logic [1:0] {R_IDLE, R_SYNC, R_PKT} rx_t;
  rx_t         rstate;
  logic [2:0]  rbit;
  logic [7:0]  rshift;
  logic [5:0]  ridx;
  logic [3:0]  rrun;
  logic        rdstf;
  logic [7:0]  buf_mem [0:19];
  logic        rprev_j;
  logic        rx_err, rx_done;
  logic        k_now, k_d;
  logic [15:0] rtmr;
  logic        rphase;
  logic [3:0]  ta_cnt;
  logic        ta_arm;
  wire         rtick  = (rtmr == BAUD_DIV-1);
  wire         k_rise = k_now & ~k_d;
  wire         rx_sample_bit = (line_j == rprev_j);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rtmr <= '0; rphase <= 1'b0; k_now <= 1'b0; k_d <= 1'b0;
      ta_cnt <= '0; ta_arm <= 1'b0;
    end else begin
      k_now <= line_k; k_d <= k_now;
      if (ta_cnt != 0 && tick) ta_cnt <= ta_cnt - 1'b1;
      if (ta_cnt == 0 && ta_arm) begin tx_go <= 1'b1; ta_arm <= 1'b0; end
      if (rstate == R_IDLE && k_rise && tstate == T_IDLE) begin
        rtmr   <= BAUD_DIV/2;               // first sample half bit after K edge
        rphase <= 1'b1;
      end else if (rtick) begin
        rtmr <= '0;
        rphase <= ~rphase;
      end else rtmr <= rtmr + 1'b1;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rstate <= R_IDLE; rbit <= '0; rshift <= '0; ridx <= '0;
      rrun <= '0; rdstf <= 1'b0; rprev_j <= 1'b1;
      rx_err <= 1'b0; rx_done <= 1'b0; buf_mem[0] <= '0;
      tx_len <= '0; tx_pid <= '0;
    end else begin
      rx_done <= 1'b0;

      if (rtick && rphase) begin
        case (rstate)
          R_IDLE: if (line_k && tstate == T_IDLE) begin
            // this sample IS sync bit 0 (K); consume it, count from 1
            rstate <= R_SYNC; rbit <= 3'd1; rprev_j <= 1'b0;
            rrun <= '0; rdstf <= 1'b0; ridx <= '0;
          end
          R_SYNC: begin
            rprev_j <= line_j;
            if (rbit == 3'd7) begin
              rstate <= R_PKT; rbit <= '0; rshift <= '0; ridx <= '0;
              rdstf <= 1'b1; rrun <= '0;
            end else rbit <= rbit + 1'b1;
          end
          R_PKT: begin
            if (line_se0) begin
              rstate <= R_IDLE;
              if (ridx >= 6'd3) begin
                logic [3:0] p; p = buf_mem[0][3:0];
                if (buf_mem[0][7:4] !== ~p) rx_err <= 1'b1;
                else begin
                  logic [15:0] c; c = 16'hFFFF;
                  for (int i = 1; i < 20; i++) begin
                    if (i <= ridx-3)
                      for (int j = 0; j < 8; j++)
                        c = crc16_u(c, buf_mem[i][j]);
                  end
                  // first received CRC byte is the LOW byte
                  if ({buf_mem[ridx-1], buf_mem[ridx-2]} !== ~c) rx_err <= 1'b1;
                  else begin
                    tx_len  <= (ridx - 6'd3);
                    tx_pid  <= p;
                    for (int i = 1; i < 20; i++)
                      if (i <= ridx-3) tx_mem[i-1] <= buf_mem[i];
                    rx_done <= 1'b1;
                    ta_cnt  <= 4'd6;            // turn-around: 6 bit times
                    ta_arm  <= 1'b1;
                  end
                end
              end else rx_err <= 1'b1;
            end else begin
              rprev_j <= line_j;
              if (rdstf && rrun == 4'd6) begin
                if (rx_sample_bit !== 1'b0) rx_err <= 1'b1;
                rrun <= 4'd1;                   // stuff bit counts as 1 (breaks run)
              end else begin
                rshift <= {rx_sample_bit, rshift[7:1]};
                if (rx_sample_bit) rrun <= rrun + 1'b1;
                else rrun <= 4'd1;
                if (rbit == 3'd7) begin
                  buf_mem[ridx[5:0]] <= {rx_sample_bit, rshift[7:1]};
                  ridx <= ridx + 6'd1;
                  rbit <= '0;
                end else rbit <= rbit + 1'b1;
              end
            end
          end
          default: rstate <= R_IDLE;
        endcase
      end
    end
  end

  assign busy = (rstate != R_IDLE) || (tstate != T_IDLE);
  assign irq  = rx_done;

endmodule
""",
tb="""// Self-checking testbench: host bit-bangs USB FS packets; device echoes.
`timescale 1ns/1ps
module USB2_0_tb;
  localparam int BIT = 400;
  logic clk = 0, rst_n = 0;
  tri1 dp, dm;
  logic h_oe = 0, h_dp = 1, h_dm = 0;
  int errors = 0;

  USB2_0_top #(.BAUD_DIV(20)) dut (
    .clk(clk), .rst_n(rst_n), .dp(dp), .dm(dm), .busy(), .irq());

  always #5 clk = ~clk;
  assign dp = h_oe ? h_dp : 1'bz;
  assign dm = h_oe ? h_dm : 1'bz;

  logic hl = 1;
  logic [3:0] hrun = 0;
  task automatic h_bit(input logic b);
    begin
      if (!b) hl = ~hl;
      h_oe = 1; h_dp = hl; h_dm = ~hl;
      #(BIT);
    end
  endtask
  task automatic h_bit_stuffed(input logic b);
    begin
      if (hrun == 6) begin h_bit(1'b0); hrun = 1; end
      h_bit(b);
      if (b) hrun = hrun + 1; else hrun = 1;
    end
  endtask

  function automatic logic [15:0] crc(input logic [15:0] cc, input logic b);
    logic fb;
    begin
      fb = cc[0] ^ b;
      crc = cc >> 1;
      if (fb) crc = crc ^ 16'h8005;
    end
  endfunction

  logic [7:0] txp [0:7];
  logic [7:0] rxp [0:7];
  logic [7:0] sync_b, pid_b, pl_b;
  task automatic host_send_data(input logic [3:0] pid, input int len);
    logic [15:0] c;
    begin
      hrun = 0;
      sync_b = 8'h80;
      pid_b  = {~pid, pid};
      for (int i = 0; i < 8; i++) h_bit(sync_b[i]);
      for (int i = 0; i < 8; i++) h_bit_stuffed(pid_b[i]);
      c = 16'hFFFF;
      for (int i = 0; i < len; i++) begin
        pl_b = txp[i];
        for (int j = 0; j < 8; j++) begin
          h_bit_stuffed(pl_b[j]);
          c = crc(c, pl_b[j]);
        end
      end
      c = ~c;
      for (int i = 0; i < 16; i++) h_bit_stuffed(c[i]);
      h_oe = 1; h_dp = 0; h_dm = 0; #(BIT*2);
      hl = 1; h_dp = 1; h_dm = 0; #(BIT);
      h_oe = 0;
    end
  endtask

  task automatic host_recv(output logic [3:0] pid, output int len);
    logic prev, b;
    logic [7:0] sh;
    int n;
    logic [3:0] run;
    begin
      len = 0; pid = 0; n = 0; sh = 0; run = 0;
      wait (dp === 1'b0 && dm === 1'b1);
      #(BIT/2);
      prev = 1'b1;
      for (int i = 0; i < 8; i++) begin
        b = ((dp === 1'b1) == prev);
        prev = (dp === 1'b1);
        #(BIT);
      end
      while (!(dp === 1'b0 && dm === 1'b0)) begin
        b = ((dp === 1'b1) == prev);
        prev = (dp === 1'b1);
        if (run == 6) begin
          run = 1;
        end else begin
          if (b) run = run + 1; else run = 1;
          sh = {b, sh[7:1]};
          if (n % 8 == 7) begin
            if (n / 8 == 0) pid = sh[3:0];
            else if (n/8 <= 8) rxp[(n/8)-1] = sh;
          end
          n = n + 1;
        end
        #(BIT);
      end
      #(BIT*3);
      len = (n / 8) - 3;  // minus PID(1) + CRC16(2) bytes
    end
  endtask

  logic [3:0] rpid;
  int rlen;
  initial begin
    for (int i = 0; i < 8; i++) txp[i] = 8'hA0 + i * 8'h11;
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(20) @(posedge clk);

    host_send_data(4'h3, 4);
    host_recv(rpid, rlen);
    if (rpid !== 4'h3) begin errors++; $display("ERROR: USB pid got=%h exp=3", rpid); end
    if (rlen !== 4) begin errors++; $display("ERROR: USB len got=%0d exp=4", rlen); end
    for (int i = 0; i < 4; i++) begin
      if (rxp[i] !== txp[i]) begin errors++; $display("ERROR: USB b%0d got=%h exp=%h", i, rxp[i], txp[i]); end
    end
    if (dut.rx_err !== 1'b0) begin errors++; $display("ERROR: USB rx_err set"); end

    repeat (50) @(posedge clk);

    txp[0] = 8'hFF;
    host_send_data(4'hB, 1);
    host_recv(rpid, rlen);
    if (rpid !== 4'hB) begin errors++; $display("ERROR: USB pid2 got=%h exp=B", rpid); end
    if (rlen !== 1) begin errors++; $display("ERROR: USB len2 got=%0d exp=1", rlen); end
    if (rxp[0] !== 8'hFF) begin errors++; $display("ERROR: USB b0 got=%h exp=FF", rxp[0]); end
    if (dut.rx_err !== 1'b0) begin errors++; $display("ERROR: USB rx_err2 set"); end

    if (errors == 0) $display("TEST PASSED: USB2.0");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #10_000_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")



CUSTOM["DDR4"] = dict(
rtl="""// ============================================================================
// DDR4: single-channel over the MEMCH_top multi-channel wrapper (PROTOCOL=0, NCH=1 (single-channel)).
// Educational slice of DDR4; gem5 trace port unchanged.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module DDR4_top (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        hvalid,
  output logic        hready,
  input  logic [2:0]  hcmd,
  input  logic [31:0] haddr,
  input  logic [15:0] hwdata,
  output logic [15:0] hrdata,
  output logic        hdone,
  output logic        ck_t, ck_c,
    output logic [16:0] addr,
  output logic        ras_n, cas_n, we_n,

  inout  tri [15:0]   dq,
  inout  tri [1:0]    dqs,
  output logic        cke,
  output logic        trace_valid,
  output logic [2:0]  trace_cmd,
  output logic [31:0] trace_addr
);
  MEMCH_top #(.PROTOCOL(0), .NCH(1), .CL(15), .TRCD(15), .TRP(15)) core (.*);
endmodule
""",
tb="""// DDR4 TB: ch0 read/write + channel isolation.
`timescale 1ns/1ps
module DDR4_tb;
  logic clk = 0, rst_n = 0;
  logic hvalid = 0, hready;
  logic [2:0] hcmd = 0;
  logic [31:0] haddr = 0;
  logic [15:0] hwdata = 0, hrdata;
  logic hdone;
  logic ck_t, ck_c;
  logic [16:0] addr; logic ras_n, cas_n, we_n;
  tri [15:0] dq; tri [1:0] dqs; logic cke;
  logic trace_valid; logic [2:0] trace_cmd; logic [31:0] trace_addr;
  int errors = 0;

  DDR4_top dut (.*);
  always #5 clk = ~clk;

  task automatic cmd(input logic [2:0] c, input logic [31:0] a, input logic [15:0] d);
    begin
      wait (hready === 1'b1);
      @(negedge clk);
      hcmd <= c; haddr <= a; hwdata <= d; hvalid <= 1'b1;
      @(negedge clk);
      hvalid <= 1'b0;
    end
  endtask

  logic [15:0] got;
  initial begin
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);
    cmd(3'd1, 32'h000, 16'h0);
    repeat(3) @(posedge clk);
    for (int i = 0; i < 4; i++) cmd(3'd3, i, 16'h1000 + i * 8'h11);
    for (int i = 0; i < 4; i++) begin
      cmd(3'd2, i, 16'h0);
      wait (hdone === 1'b1); @(posedge clk); #1;
      got = hrdata;
      if (got !== 16'h1000 + i * 8'h11) begin
        errors++; $display("ERROR: DDR4 ch0[%0d] got=%h", i, got);
      end
    end
    if (errors == 0) $display("TEST PASSED: DDR4");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #500_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")

CUSTOM["DDR5"] = dict(
rtl="""// ============================================================================
// DDR5: 2-channel over the MEMCH_top multi-channel wrapper (PROTOCOL=1, NCH=2 (2-channel)).
// Educational slice of DDR5; gem5 trace port unchanged.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module DDR5_top (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        hvalid,
  output logic        hready,
  input  logic [2:0]  hcmd,
  input  logic [31:0] haddr,
  input  logic [15:0] hwdata,
  output logic [15:0] hrdata,
  output logic        hdone,
  output logic        ck_t, ck_c,
    output logic [16:0] addr,
  output logic        ras_n, cas_n, we_n,

  inout  tri [31:0]   dq,
  inout  tri [1:0]    dqs,
  output logic        cke,
  output logic        trace_valid,
  output logic [2:0]  trace_cmd,
  output logic [31:0] trace_addr
);
  MEMCH_top #(.PROTOCOL(1), .NCH(2), .CL(22), .TRCD(14), .TRP(14)) core (.*);
endmodule
""",
tb="""// DDR5 TB: ch0 read/write + ch1 isolation + channel isolation.
`timescale 1ns/1ps
module DDR5_tb;
  logic clk = 0, rst_n = 0;
  logic hvalid = 0, hready;
  logic [2:0] hcmd = 0;
  logic [31:0] haddr = 0;
  logic [15:0] hwdata = 0, hrdata;
  logic hdone;
  logic ck_t, ck_c;
  logic [16:0] addr; logic ras_n, cas_n, we_n;
  tri [31:0] dq; tri [1:0] dqs; logic cke;
  logic trace_valid; logic [2:0] trace_cmd; logic [31:0] trace_addr;
  int errors = 0;

  DDR5_top dut (.*);
  always #5 clk = ~clk;

  task automatic cmd(input logic [2:0] c, input logic [31:0] a, input logic [15:0] d);
    begin
      wait (hready === 1'b1);
      @(negedge clk);
      hcmd <= c; haddr <= a; hwdata <= d; hvalid <= 1'b1;
      @(negedge clk);
      hvalid <= 1'b0;
    end
  endtask

  logic [15:0] got;
  initial begin
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);
    cmd(3'd1, 32'h000, 16'h0);
    repeat(3) @(posedge clk);
    for (int i = 0; i < 4; i++) cmd(3'd3, i, 16'h1111 + i * 8'h11);
    for (int i = 0; i < 4; i++) begin
      cmd(3'd2, i, 16'h0);
      wait (hdone === 1'b1); @(posedge clk); #1;
      got = hrdata;
      if (got !== 16'h1111 + i * 8'h11) begin
        errors++; $display("ERROR: DDR5 ch0[%0d] got=%h", i, got);
      end
    end
    // channel 1 (haddr[8]=1): distinct data, same column -> isolation check
    cmd(3'd1, 32'h100, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd3, 32'h100, 16'h111101);
    cmd(3'd1, 32'h100, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd2, 32'h100, 16'h0);
    wait (hdone === 1'b1); @(posedge clk); #1;
    got = hrdata;
    if (got !== 16'h111101) begin
      errors++; $display("ERROR: DDR5 ch1[0] got=%h exp=111101", got);
    end
    // channel 0 data must be untouched
    cmd(3'd1, 32'h000, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd2, 32'h000, 16'h0);
    wait (hdone === 1'b1); @(posedge clk); #1;
    got = hrdata;
    if (got !== 16'h1111) begin
      errors++; $display("ERROR: DDR5 ch0[0] after ch1 traffic got=%h exp=1111", got);
    end
    if (errors == 0) $display("TEST PASSED: DDR5");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #500_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")

CUSTOM["DDR6"] = dict(
rtl="""// ============================================================================
// DDR6: 2-channel over the MEMCH_top multi-channel wrapper (PROTOCOL=4, NCH=2 (2-channel)).
// Educational slice of DDR6; gem5 trace port unchanged.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module DDR6_top (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        hvalid,
  output logic        hready,
  input  logic [2:0]  hcmd,
  input  logic [31:0] haddr,
  input  logic [15:0] hwdata,
  output logic [15:0] hrdata,
  output logic        hdone,
  output logic        ck_t, ck_c,
    output logic [16:0] addr,
  output logic        ras_n, cas_n, we_n,

  inout  tri [31:0]   dq,
  inout  tri [1:0]    dqs,
  output logic        cke,
  output logic        trace_valid,
  output logic [2:0]  trace_cmd,
  output logic [31:0] trace_addr
);
  MEMCH_top #(.PROTOCOL(4), .NCH(2), .CL(20), .TRCD(12), .TRP(12)) core (.*);
endmodule
""",
tb="""// DDR6 TB: ch0 read/write + ch1 isolation + channel isolation.
`timescale 1ns/1ps
module DDR6_tb;
  logic clk = 0, rst_n = 0;
  logic hvalid = 0, hready;
  logic [2:0] hcmd = 0;
  logic [31:0] haddr = 0;
  logic [15:0] hwdata = 0, hrdata;
  logic hdone;
  logic ck_t, ck_c;
  logic [16:0] addr; logic ras_n, cas_n, we_n;
  tri [31:0] dq; tri [1:0] dqs; logic cke;
  logic trace_valid; logic [2:0] trace_cmd; logic [31:0] trace_addr;
  int errors = 0;

  DDR6_top dut (.*);
  always #5 clk = ~clk;

  task automatic cmd(input logic [2:0] c, input logic [31:0] a, input logic [15:0] d);
    begin
      wait (hready === 1'b1);
      @(negedge clk);
      hcmd <= c; haddr <= a; hwdata <= d; hvalid <= 1'b1;
      @(negedge clk);
      hvalid <= 1'b0;
    end
  endtask

  logic [15:0] got;
  initial begin
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);
    cmd(3'd1, 32'h000, 16'h0);
    repeat(3) @(posedge clk);
    for (int i = 0; i < 4; i++) cmd(3'd3, i, 16'h1444 + i * 8'h11);
    for (int i = 0; i < 4; i++) begin
      cmd(3'd2, i, 16'h0);
      wait (hdone === 1'b1); @(posedge clk); #1;
      got = hrdata;
      if (got !== 16'h1444 + i * 8'h11) begin
        errors++; $display("ERROR: DDR6 ch0[%0d] got=%h", i, got);
      end
    end
    // channel 1 (haddr[8]=1): distinct data, same column -> isolation check
    cmd(3'd1, 32'h100, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd3, 32'h100, 16'h154501);
    cmd(3'd1, 32'h100, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd2, 32'h100, 16'h0);
    wait (hdone === 1'b1); @(posedge clk); #1;
    got = hrdata;
    if (got !== 16'h154501) begin
      errors++; $display("ERROR: DDR6 ch1[0] got=%h exp=154501", got);
    end
    // channel 0 data must be untouched
    cmd(3'd1, 32'h000, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd2, 32'h000, 16'h0);
    wait (hdone === 1'b1); @(posedge clk); #1;
    got = hrdata;
    if (got !== 16'h1444) begin
      errors++; $display("ERROR: DDR6 ch0[0] after ch1 traffic got=%h exp=1444", got);
    end
    if (errors == 0) $display("TEST PASSED: DDR6");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #500_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")

CUSTOM["LPDDR4"] = dict(
rtl="""// ============================================================================
// LPDDR4: 2-channel over the MEMCH_top multi-channel wrapper (PROTOCOL=2, NCH=2 (2-channel)).
// Educational slice of LPDDR4; gem5 trace port unchanged.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module LPDDR4_top (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        hvalid,
  output logic        hready,
  input  logic [2:0]  hcmd,
  input  logic [31:0] haddr,
  input  logic [15:0] hwdata,
  output logic [15:0] hrdata,
  output logic        hdone,
  output logic        ck_t, ck_c,
    output logic [5:0]  ca,
  output logic        cs_n,

  inout  tri [31:0]   dq,
  inout  tri [1:0]    dqs,
  output logic        cke,
  output logic        trace_valid,
  output logic [2:0]  trace_cmd,
  output logic [31:0] trace_addr
);
  logic [16:0] addr_full;
  logic ras_n, cas_n, we_n;

  MEMCH_top #(.PROTOCOL(2), .NCH(2), .CL(15), .TRCD(6), .TRP(6)) core (
    .clk(clk), .rst_n(rst_n),
    .hvalid(hvalid), .hready(hready), .hcmd(hcmd), .haddr(haddr),
    .hwdata(hwdata), .hrdata(hrdata), .hdone(hdone),
    .ck_t(ck_t), .ck_c(ck_c), .addr(addr_full),
    .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
    .dq(dq), .dqs(dqs), .cke(cke),
    .trace_valid(trace_valid), .trace_cmd(trace_cmd), .trace_addr(trace_addr));

  assign ca = {2'b00, ras_n, cas_n, we_n, addr_full[2:0]};
  assign cs_n = ras_n & cas_n & we_n;
endmodule
""",
tb="""// LPDDR4 TB: ch0 read/write + ch1 isolation + channel isolation.
`timescale 1ns/1ps
module LPDDR4_tb;
  logic clk = 0, rst_n = 0;
  logic hvalid = 0, hready;
  logic [2:0] hcmd = 0;
  logic [31:0] haddr = 0;
  logic [15:0] hwdata = 0, hrdata;
  logic hdone;
  logic ck_t, ck_c;
  logic [5:0] ca; logic cs_n;
  tri [31:0] dq; tri [1:0] dqs; logic cke;
  logic trace_valid; logic [2:0] trace_cmd; logic [31:0] trace_addr;
  int errors = 0;

  LPDDR4_top dut (.*);
  always #5 clk = ~clk;

  task automatic cmd(input logic [2:0] c, input logic [31:0] a, input logic [15:0] d);
    begin
      wait (hready === 1'b1);
      @(negedge clk);
      hcmd <= c; haddr <= a; hwdata <= d; hvalid <= 1'b1;
      @(negedge clk);
      hvalid <= 1'b0;
    end
  endtask

  logic [15:0] got;
  initial begin
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);
    cmd(3'd1, 32'h000, 16'h0);
    repeat(3) @(posedge clk);
    for (int i = 0; i < 4; i++) cmd(3'd3, i, 16'h1222 + i * 8'h11);
    for (int i = 0; i < 4; i++) begin
      cmd(3'd2, i, 16'h0);
      wait (hdone === 1'b1); @(posedge clk); #1;
      got = hrdata;
      if (got !== 16'h1222 + i * 8'h11) begin
        errors++; $display("ERROR: LPDDR4 ch0[%0d] got=%h", i, got);
      end
    end
    // channel 1 (haddr[8]=1): distinct data, same column -> isolation check
    cmd(3'd1, 32'h100, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd3, 32'h100, 16'h132301);
    cmd(3'd1, 32'h100, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd2, 32'h100, 16'h0);
    wait (hdone === 1'b1); @(posedge clk); #1;
    got = hrdata;
    if (got !== 16'h132301) begin
      errors++; $display("ERROR: LPDDR4 ch1[0] got=%h exp=132301", got);
    end
    // channel 0 data must be untouched
    cmd(3'd1, 32'h000, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd2, 32'h000, 16'h0);
    wait (hdone === 1'b1); @(posedge clk); #1;
    got = hrdata;
    if (got !== 16'h1222) begin
      errors++; $display("ERROR: LPDDR4 ch0[0] after ch1 traffic got=%h exp=1222", got);
    end
    if (errors == 0) $display("TEST PASSED: LPDDR4");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #500_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")

CUSTOM["LPDDR5"] = dict(
rtl="""// ============================================================================
// LPDDR5: 2-channel over the MEMCH_top multi-channel wrapper (PROTOCOL=3, NCH=2 (2-channel)).
// Educational slice of LPDDR5; gem5 trace port unchanged.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module LPDDR5_top (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        hvalid,
  output logic        hready,
  input  logic [2:0]  hcmd,
  input  logic [31:0] haddr,
  input  logic [15:0] hwdata,
  output logic [15:0] hrdata,
  output logic        hdone,
  output logic        ck_t, ck_c,
    output logic [6:0]  ca,
  output logic        cs_n,

  inout  tri [31:0]   dq,
  inout  tri [1:0]    dqs,
  output logic        cke,
  output logic        trace_valid,
  output logic [2:0]  trace_cmd,
  output logic [31:0] trace_addr
);
  logic [16:0] addr_full;
  logic ras_n, cas_n, we_n;

  MEMCH_top #(.PROTOCOL(3), .NCH(2), .CL(15), .TRCD(5), .TRP(5)) core (
    .clk(clk), .rst_n(rst_n),
    .hvalid(hvalid), .hready(hready), .hcmd(hcmd), .haddr(haddr),
    .hwdata(hwdata), .hrdata(hrdata), .hdone(hdone),
    .ck_t(ck_t), .ck_c(ck_c), .addr(addr_full),
    .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
    .dq(dq), .dqs(dqs), .cke(cke),
    .trace_valid(trace_valid), .trace_cmd(trace_cmd), .trace_addr(trace_addr));

  assign ca = {1'b0, ras_n, cas_n, we_n, addr_full[2:0]};
  assign cs_n = ras_n & cas_n & we_n;
endmodule
""",
tb="""// LPDDR5 TB: ch0 read/write + ch1 isolation + channel isolation.
`timescale 1ns/1ps
module LPDDR5_tb;
  logic clk = 0, rst_n = 0;
  logic hvalid = 0, hready;
  logic [2:0] hcmd = 0;
  logic [31:0] haddr = 0;
  logic [15:0] hwdata = 0, hrdata;
  logic hdone;
  logic ck_t, ck_c;
  logic [6:0] ca; logic cs_n;
  tri [31:0] dq; tri [1:0] dqs; logic cke;
  logic trace_valid; logic [2:0] trace_cmd; logic [31:0] trace_addr;
  int errors = 0;

  LPDDR5_top dut (.*);
  always #5 clk = ~clk;

  task automatic cmd(input logic [2:0] c, input logic [31:0] a, input logic [15:0] d);
    begin
      wait (hready === 1'b1);
      @(negedge clk);
      hcmd <= c; haddr <= a; hwdata <= d; hvalid <= 1'b1;
      @(negedge clk);
      hvalid <= 1'b0;
    end
  endtask

  logic [15:0] got;
  initial begin
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);
    cmd(3'd1, 32'h000, 16'h0);
    repeat(3) @(posedge clk);
    for (int i = 0; i < 4; i++) cmd(3'd3, i, 16'h1333 + i * 8'h11);
    for (int i = 0; i < 4; i++) begin
      cmd(3'd2, i, 16'h0);
      wait (hdone === 1'b1); @(posedge clk); #1;
      got = hrdata;
      if (got !== 16'h1333 + i * 8'h11) begin
        errors++; $display("ERROR: LPDDR5 ch0[%0d] got=%h", i, got);
      end
    end
    // channel 1 (haddr[8]=1): distinct data, same column -> isolation check
    cmd(3'd1, 32'h100, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd3, 32'h100, 16'h133301);
    cmd(3'd1, 32'h100, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd2, 32'h100, 16'h0);
    wait (hdone === 1'b1); @(posedge clk); #1;
    got = hrdata;
    if (got !== 16'h133301) begin
      errors++; $display("ERROR: LPDDR5 ch1[0] got=%h exp=133301", got);
    end
    // channel 0 data must be untouched
    cmd(3'd1, 32'h000, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd2, 32'h000, 16'h0);
    wait (hdone === 1'b1); @(posedge clk); #1;
    got = hrdata;
    if (got !== 16'h1333) begin
      errors++; $display("ERROR: LPDDR5 ch0[0] after ch1 traffic got=%h exp=1333", got);
    end
    if (errors == 0) $display("TEST PASSED: LPDDR5");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #500_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")

CUSTOM["LPDDR5X"] = dict(
rtl="""// ============================================================================
// LPDDR5X: 2-channel over the MEMCH_top multi-channel wrapper (PROTOCOL=5, NCH=2 (2-channel)).
// Educational slice of LPDDR5X; gem5 trace port unchanged.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module LPDDR5X_top (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        hvalid,
  output logic        hready,
  input  logic [2:0]  hcmd,
  input  logic [31:0] haddr,
  input  logic [15:0] hwdata,
  output logic [15:0] hrdata,
  output logic        hdone,
  output logic        ck_t, ck_c,
    output logic [6:0]  ca,
  output logic        cs_n,

  inout  tri [31:0]   dq,
  inout  tri [1:0]    dqs,
  output logic        cke,
  output logic        trace_valid,
  output logic [2:0]  trace_cmd,
  output logic [31:0] trace_addr
);
  logic [16:0] addr_full;
  logic ras_n, cas_n, we_n;

  MEMCH_top #(.PROTOCOL(5), .NCH(2), .CL(15), .TRCD(4), .TRP(4)) core (
    .clk(clk), .rst_n(rst_n),
    .hvalid(hvalid), .hready(hready), .hcmd(hcmd), .haddr(haddr),
    .hwdata(hwdata), .hrdata(hrdata), .hdone(hdone),
    .ck_t(ck_t), .ck_c(ck_c), .addr(addr_full),
    .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
    .dq(dq), .dqs(dqs), .cke(cke),
    .trace_valid(trace_valid), .trace_cmd(trace_cmd), .trace_addr(trace_addr));

  assign ca = {1'b0, ras_n, cas_n, we_n, addr_full[2:0]};
  assign cs_n = ras_n & cas_n & we_n;
endmodule
""",
tb="""// LPDDR5X TB: ch0 read/write + ch1 isolation + channel isolation.
`timescale 1ns/1ps
module LPDDR5X_tb;
  logic clk = 0, rst_n = 0;
  logic hvalid = 0, hready;
  logic [2:0] hcmd = 0;
  logic [31:0] haddr = 0;
  logic [15:0] hwdata = 0, hrdata;
  logic hdone;
  logic ck_t, ck_c;
  logic [6:0] ca; logic cs_n;
  tri [31:0] dq; tri [1:0] dqs; logic cke;
  logic trace_valid; logic [2:0] trace_cmd; logic [31:0] trace_addr;
  int errors = 0;

  LPDDR5X_top dut (.*);
  always #5 clk = ~clk;

  task automatic cmd(input logic [2:0] c, input logic [31:0] a, input logic [15:0] d);
    begin
      wait (hready === 1'b1);
      @(negedge clk);
      hcmd <= c; haddr <= a; hwdata <= d; hvalid <= 1'b1;
      @(negedge clk);
      hvalid <= 1'b0;
    end
  endtask

  logic [15:0] got;
  initial begin
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);
    cmd(3'd1, 32'h000, 16'h0);
    repeat(3) @(posedge clk);
    for (int i = 0; i < 4; i++) cmd(3'd3, i, 16'h1555 + i * 8'h11);
    for (int i = 0; i < 4; i++) begin
      cmd(3'd2, i, 16'h0);
      wait (hdone === 1'b1); @(posedge clk); #1;
      got = hrdata;
      if (got !== 16'h1555 + i * 8'h11) begin
        errors++; $display("ERROR: LPDDR5X ch0[%0d] got=%h", i, got);
      end
    end
    // channel 1 (haddr[8]=1): distinct data, same column -> isolation check
    cmd(3'd1, 32'h100, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd3, 32'h100, 16'h155501);
    cmd(3'd1, 32'h100, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd2, 32'h100, 16'h0);
    wait (hdone === 1'b1); @(posedge clk); #1;
    got = hrdata;
    if (got !== 16'h155501) begin
      errors++; $display("ERROR: LPDDR5X ch1[0] got=%h exp=155501", got);
    end
    // channel 0 data must be untouched
    cmd(3'd1, 32'h000, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd2, 32'h000, 16'h0);
    wait (hdone === 1'b1); @(posedge clk); #1;
    got = hrdata;
    if (got !== 16'h1555) begin
      errors++; $display("ERROR: LPDDR5X ch0[0] after ch1 traffic got=%h exp=1555", got);
    end
    if (errors == 0) $display("TEST PASSED: LPDDR5X");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #500_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")

CUSTOM["LPDDR6"] = dict(
rtl="""// ============================================================================
// LPDDR6: 2-channel over the MEMCH_top multi-channel wrapper (PROTOCOL=6, NCH=2 (2-channel)).
// Educational slice of LPDDR6; gem5 trace port unchanged.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module LPDDR6_top (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        hvalid,
  output logic        hready,
  input  logic [2:0]  hcmd,
  input  logic [31:0] haddr,
  input  logic [15:0] hwdata,
  output logic [15:0] hrdata,
  output logic        hdone,
  output logic        ck_t, ck_c,
    output logic [7:0]  ca,
  output logic        cs_n,

  inout  tri [31:0]   dq,
  inout  tri [1:0]    dqs,
  output logic        cke,
  output logic        trace_valid,
  output logic [2:0]  trace_cmd,
  output logic [31:0] trace_addr
);
  logic [16:0] addr_full;
  logic ras_n, cas_n, we_n;

  MEMCH_top #(.PROTOCOL(6), .NCH(2), .CL(12), .TRCD(4), .TRP(4)) core (
    .clk(clk), .rst_n(rst_n),
    .hvalid(hvalid), .hready(hready), .hcmd(hcmd), .haddr(haddr),
    .hwdata(hwdata), .hrdata(hrdata), .hdone(hdone),
    .ck_t(ck_t), .ck_c(ck_c), .addr(addr_full),
    .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
    .dq(dq), .dqs(dqs), .cke(cke),
    .trace_valid(trace_valid), .trace_cmd(trace_cmd), .trace_addr(trace_addr));

  assign ca = {2'b00, ras_n, cas_n, we_n, addr_full[2:0]};
  assign cs_n = ras_n & cas_n & we_n;
endmodule
""",
tb="""// LPDDR6 TB: ch0 read/write + ch1 isolation + channel isolation.
`timescale 1ns/1ps
module LPDDR6_tb;
  logic clk = 0, rst_n = 0;
  logic hvalid = 0, hready;
  logic [2:0] hcmd = 0;
  logic [31:0] haddr = 0;
  logic [15:0] hwdata = 0, hrdata;
  logic hdone;
  logic ck_t, ck_c;
  logic [7:0] ca; logic cs_n;
  tri [31:0] dq; tri [1:0] dqs; logic cke;
  logic trace_valid; logic [2:0] trace_cmd; logic [31:0] trace_addr;
  int errors = 0;

  LPDDR6_top dut (.*);
  always #5 clk = ~clk;

  task automatic cmd(input logic [2:0] c, input logic [31:0] a, input logic [15:0] d);
    begin
      wait (hready === 1'b1);
      @(negedge clk);
      hcmd <= c; haddr <= a; hwdata <= d; hvalid <= 1'b1;
      @(negedge clk);
      hvalid <= 1'b0;
    end
  endtask

  logic [15:0] got;
  initial begin
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);
    cmd(3'd1, 32'h000, 16'h0);
    repeat(3) @(posedge clk);
    for (int i = 0; i < 4; i++) cmd(3'd3, i, 16'h1666 + i * 8'h11);
    for (int i = 0; i < 4; i++) begin
      cmd(3'd2, i, 16'h0);
      wait (hdone === 1'b1); @(posedge clk); #1;
      got = hrdata;
      if (got !== 16'h1666 + i * 8'h11) begin
        errors++; $display("ERROR: LPDDR6 ch0[%0d] got=%h", i, got);
      end
    end
    // channel 1 (haddr[8]=1): distinct data, same column -> isolation check
    cmd(3'd1, 32'h100, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd3, 32'h100, 16'h176701);
    cmd(3'd1, 32'h100, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd2, 32'h100, 16'h0);
    wait (hdone === 1'b1); @(posedge clk); #1;
    got = hrdata;
    if (got !== 16'h176701) begin
      errors++; $display("ERROR: LPDDR6 ch1[0] got=%h exp=176701", got);
    end
    // channel 0 data must be untouched
    cmd(3'd1, 32'h000, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd2, 32'h000, 16'h0);
    wait (hdone === 1'b1); @(posedge clk); #1;
    got = hrdata;
    if (got !== 16'h1666) begin
      errors++; $display("ERROR: LPDDR6 ch0[0] after ch1 traffic got=%h exp=1666", got);
    end
    if (errors == 0) $display("TEST PASSED: LPDDR6");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #500_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")

CUSTOM["HBM"] = dict(
rtl="""// ============================================================================
// HBM: 8-channel over the MEMCH_top multi-channel wrapper (PROTOCOL=7, NCH=8 (8-channel)).
// Educational slice of HBM; gem5 trace port unchanged.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module HBM_top (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        hvalid,
  output logic        hready,
  input  logic [2:0]  hcmd,
  input  logic [31:0] haddr,
  input  logic [15:0] hwdata,
  output logic [15:0] hrdata,
  output logic        hdone,
  output logic        ck_t, ck_c,
    output logic [16:0] addr,
  output logic        ras_n, cas_n, we_n,

  inout  tri [127:0]   dq,
  inout  tri [1:0]    dqs,
  output logic        cke,
  output logic        trace_valid,
  output logic [2:0]  trace_cmd,
  output logic [31:0] trace_addr
);
  MEMCH_top #(.PROTOCOL(7), .NCH(8), .CL(14), .TRCD(7), .TRP(7)) core (.*);
endmodule
""",
tb="""// HBM TB: ch0 read/write + ch1 isolation + channel isolation.
`timescale 1ns/1ps
module HBM_tb;
  logic clk = 0, rst_n = 0;
  logic hvalid = 0, hready;
  logic [2:0] hcmd = 0;
  logic [31:0] haddr = 0;
  logic [15:0] hwdata = 0, hrdata;
  logic hdone;
  logic ck_t, ck_c;
  logic [16:0] addr; logic ras_n, cas_n, we_n;
  tri [127:0] dq; tri [1:0] dqs; logic cke;
  logic trace_valid; logic [2:0] trace_cmd; logic [31:0] trace_addr;
  int errors = 0;

  HBM_top dut (.*);
  always #5 clk = ~clk;

  task automatic cmd(input logic [2:0] c, input logic [31:0] a, input logic [15:0] d);
    begin
      wait (hready === 1'b1);
      @(negedge clk);
      hcmd <= c; haddr <= a; hwdata <= d; hvalid <= 1'b1;
      @(negedge clk);
      hvalid <= 1'b0;
    end
  endtask

  logic [15:0] got;
  initial begin
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);
    cmd(3'd1, 32'h000, 16'h0);
    repeat(3) @(posedge clk);
    for (int i = 0; i < 4; i++) cmd(3'd3, i, 16'h1777 + i * 8'h11);
    for (int i = 0; i < 4; i++) begin
      cmd(3'd2, i, 16'h0);
      wait (hdone === 1'b1); @(posedge clk); #1;
      got = hrdata;
      if (got !== 16'h1777 + i * 8'h11) begin
        errors++; $display("ERROR: HBM ch0[%0d] got=%h", i, got);
      end
    end
    // channel 1 (haddr[8]=1): distinct data, same column -> isolation check
    cmd(3'd1, 32'h100, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd3, 32'h100, 16'h177701);
    cmd(3'd1, 32'h100, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd2, 32'h100, 16'h0);
    wait (hdone === 1'b1); @(posedge clk); #1;
    got = hrdata;
    if (got !== 16'h177701) begin
      errors++; $display("ERROR: HBM ch1[0] got=%h exp=177701", got);
    end
    // channel 0 data must be untouched
    cmd(3'd1, 32'h000, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd2, 32'h000, 16'h0);
    wait (hdone === 1'b1); @(posedge clk); #1;
    got = hrdata;
    if (got !== 16'h1777) begin
      errors++; $display("ERROR: HBM ch0[0] after ch1 traffic got=%h exp=1777", got);
    end
    if (errors == 0) $display("TEST PASSED: HBM");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #500_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")

CUSTOM["HBM3"] = dict(
rtl="""// ============================================================================
// HBM3: 8-channel over the MEMCH_top multi-channel wrapper (PROTOCOL=9, NCH=8 (8-channel)).
// Educational slice of HBM3; gem5 trace port unchanged.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module HBM3_top (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        hvalid,
  output logic        hready,
  input  logic [2:0]  hcmd,
  input  logic [31:0] haddr,
  input  logic [15:0] hwdata,
  output logic [15:0] hrdata,
  output logic        hdone,
  output logic        ck_t, ck_c,
    output logic [16:0] addr,
  output logic        ras_n, cas_n, we_n,

  inout  tri [127:0]   dq,
  inout  tri [1:0]    dqs,
  output logic        cke,
  output logic        trace_valid,
  output logic [2:0]  trace_cmd,
  output logic [31:0] trace_addr
);
  MEMCH_top #(.PROTOCOL(9), .NCH(8), .CL(16), .TRCD(8), .TRP(8)) core (.*);
endmodule
""",
tb="""// HBM3 TB: ch0 read/write + ch1 isolation + channel isolation.
`timescale 1ns/1ps
module HBM3_tb;
  logic clk = 0, rst_n = 0;
  logic hvalid = 0, hready;
  logic [2:0] hcmd = 0;
  logic [31:0] haddr = 0;
  logic [15:0] hwdata = 0, hrdata;
  logic hdone;
  logic ck_t, ck_c;
  logic [16:0] addr; logic ras_n, cas_n, we_n;
  tri [127:0] dq; tri [1:0] dqs; logic cke;
  logic trace_valid; logic [2:0] trace_cmd; logic [31:0] trace_addr;
  int errors = 0;

  HBM3_top dut (.*);
  always #5 clk = ~clk;

  task automatic cmd(input logic [2:0] c, input logic [31:0] a, input logic [15:0] d);
    begin
      wait (hready === 1'b1);
      @(negedge clk);
      hcmd <= c; haddr <= a; hwdata <= d; hvalid <= 1'b1;
      @(negedge clk);
      hvalid <= 1'b0;
    end
  endtask

  logic [15:0] got;
  initial begin
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);
    cmd(3'd1, 32'h000, 16'h0);
    repeat(3) @(posedge clk);
    for (int i = 0; i < 4; i++) cmd(3'd3, i, 16'h1999 + i * 8'h11);
    for (int i = 0; i < 4; i++) begin
      cmd(3'd2, i, 16'h0);
      wait (hdone === 1'b1); @(posedge clk); #1;
      got = hrdata;
      if (got !== 16'h1999 + i * 8'h11) begin
        errors++; $display("ERROR: HBM3 ch0[%0d] got=%h", i, got);
      end
    end
    // channel 1 (haddr[8]=1): distinct data, same column -> isolation check
    cmd(3'd1, 32'h100, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd3, 32'h100, 16'h199901);
    cmd(3'd1, 32'h100, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd2, 32'h100, 16'h0);
    wait (hdone === 1'b1); @(posedge clk); #1;
    got = hrdata;
    if (got !== 16'h199901) begin
      errors++; $display("ERROR: HBM3 ch1[0] got=%h exp=199901", got);
    end
    // channel 0 data must be untouched
    cmd(3'd1, 32'h000, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd2, 32'h000, 16'h0);
    wait (hdone === 1'b1); @(posedge clk); #1;
    got = hrdata;
    if (got !== 16'h1999) begin
      errors++; $display("ERROR: HBM3 ch0[0] after ch1 traffic got=%h exp=1999", got);
    end
    if (errors == 0) $display("TEST PASSED: HBM3");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #500_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")

CUSTOM["HBM3E"] = dict(
rtl="""// ============================================================================
// HBM3E: 8-channel over the MEMCH_top multi-channel wrapper (PROTOCOL=10, NCH=8 (8-channel)).
// Educational slice of HBM3E; gem5 trace port unchanged.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module HBM3E_top (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        hvalid,
  output logic        hready,
  input  logic [2:0]  hcmd,
  input  logic [31:0] haddr,
  input  logic [15:0] hwdata,
  output logic [15:0] hrdata,
  output logic        hdone,
  output logic        ck_t, ck_c,
    output logic [16:0] addr,
  output logic        ras_n, cas_n, we_n,

  inout  tri [127:0]   dq,
  inout  tri [1:0]    dqs,
  output logic        cke,
  output logic        trace_valid,
  output logic [2:0]  trace_cmd,
  output logic [31:0] trace_addr
);
  MEMCH_top #(.PROTOCOL(10), .NCH(8), .CL(14), .TRCD(7), .TRP(7)) core (.*);
endmodule
""",
tb="""// HBM3E TB: ch0 read/write + ch1 isolation + channel isolation.
`timescale 1ns/1ps
module HBM3E_tb;
  logic clk = 0, rst_n = 0;
  logic hvalid = 0, hready;
  logic [2:0] hcmd = 0;
  logic [31:0] haddr = 0;
  logic [15:0] hwdata = 0, hrdata;
  logic hdone;
  logic ck_t, ck_c;
  logic [16:0] addr; logic ras_n, cas_n, we_n;
  tri [127:0] dq; tri [1:0] dqs; logic cke;
  logic trace_valid; logic [2:0] trace_cmd; logic [31:0] trace_addr;
  int errors = 0;

  HBM3E_top dut (.*);
  always #5 clk = ~clk;

  task automatic cmd(input logic [2:0] c, input logic [31:0] a, input logic [15:0] d);
    begin
      wait (hready === 1'b1);
      @(negedge clk);
      hcmd <= c; haddr <= a; hwdata <= d; hvalid <= 1'b1;
      @(negedge clk);
      hvalid <= 1'b0;
    end
  endtask

  logic [15:0] got;
  initial begin
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);
    cmd(3'd1, 32'h000, 16'h0);
    repeat(3) @(posedge clk);
    for (int i = 0; i < 4; i++) cmd(3'd3, i, 16'h1aaa + i * 8'h11);
    for (int i = 0; i < 4; i++) begin
      cmd(3'd2, i, 16'h0);
      wait (hdone === 1'b1); @(posedge clk); #1;
      got = hrdata;
      if (got !== 16'h1aaa + i * 8'h11) begin
        errors++; $display("ERROR: HBM3E ch0[%0d] got=%h", i, got);
      end
    end
    // channel 1 (haddr[8]=1): distinct data, same column -> isolation check
    cmd(3'd1, 32'h100, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd3, 32'h100, 16'h1bab01);
    cmd(3'd1, 32'h100, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd2, 32'h100, 16'h0);
    wait (hdone === 1'b1); @(posedge clk); #1;
    got = hrdata;
    if (got !== 16'h1bab01) begin
      errors++; $display("ERROR: HBM3E ch1[0] got=%h exp=1bab01", got);
    end
    // channel 0 data must be untouched
    cmd(3'd1, 32'h000, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd2, 32'h000, 16'h0);
    wait (hdone === 1'b1); @(posedge clk); #1;
    got = hrdata;
    if (got !== 16'h1aaa) begin
      errors++; $display("ERROR: HBM3E ch0[0] after ch1 traffic got=%h exp=1aaa", got);
    end
    if (errors == 0) $display("TEST PASSED: HBM3E");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #500_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")

CUSTOM["HBM4"] = dict(
rtl="""// ============================================================================
// HBM4: 16-channel over the MEMCH_top multi-channel wrapper (PROTOCOL=11, NCH=16 (16-channel)).
// Educational slice of HBM4; gem5 trace port unchanged.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module HBM4_top (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        hvalid,
  output logic        hready,
  input  logic [2:0]  hcmd,
  input  logic [31:0] haddr,
  input  logic [15:0] hwdata,
  output logic [15:0] hrdata,
  output logic        hdone,
  output logic        ck_t, ck_c,
    output logic [16:0] addr,
  output logic        ras_n, cas_n, we_n,

  inout  tri [255:0]   dq,
  inout  tri [1:0]    dqs,
  output logic        cke,
  output logic        trace_valid,
  output logic [2:0]  trace_cmd,
  output logic [31:0] trace_addr
);
  MEMCH_top #(.PROTOCOL(11), .NCH(16), .CL(12), .TRCD(6), .TRP(6)) core (.*);
endmodule
""",
tb="""// HBM4 TB: ch0 read/write + ch1 isolation + channel isolation.
`timescale 1ns/1ps
module HBM4_tb;
  logic clk = 0, rst_n = 0;
  logic hvalid = 0, hready;
  logic [2:0] hcmd = 0;
  logic [31:0] haddr = 0;
  logic [15:0] hwdata = 0, hrdata;
  logic hdone;
  logic ck_t, ck_c;
  logic [16:0] addr; logic ras_n, cas_n, we_n;
  tri [255:0] dq; tri [1:0] dqs; logic cke;
  logic trace_valid; logic [2:0] trace_cmd; logic [31:0] trace_addr;
  int errors = 0;

  HBM4_top dut (.*);
  always #5 clk = ~clk;

  task automatic cmd(input logic [2:0] c, input logic [31:0] a, input logic [15:0] d);
    begin
      wait (hready === 1'b1);
      @(negedge clk);
      hcmd <= c; haddr <= a; hwdata <= d; hvalid <= 1'b1;
      @(negedge clk);
      hvalid <= 1'b0;
    end
  endtask

  logic [15:0] got;
  initial begin
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);
    cmd(3'd1, 32'h000, 16'h0);
    repeat(3) @(posedge clk);
    for (int i = 0; i < 4; i++) cmd(3'd3, i, 16'h1bbb + i * 8'h11);
    for (int i = 0; i < 4; i++) begin
      cmd(3'd2, i, 16'h0);
      wait (hdone === 1'b1); @(posedge clk); #1;
      got = hrdata;
      if (got !== 16'h1bbb + i * 8'h11) begin
        errors++; $display("ERROR: HBM4 ch0[%0d] got=%h", i, got);
      end
    end
    // channel 1 (haddr[8]=1): distinct data, same column -> isolation check
    cmd(3'd1, 32'h100, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd3, 32'h100, 16'h1bbb01);
    cmd(3'd1, 32'h100, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd2, 32'h100, 16'h0);
    wait (hdone === 1'b1); @(posedge clk); #1;
    got = hrdata;
    if (got !== 16'h1bbb01) begin
      errors++; $display("ERROR: HBM4 ch1[0] got=%h exp=1bbb01", got);
    end
    // channel 0 data must be untouched
    cmd(3'd1, 32'h000, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd2, 32'h000, 16'h0);
    wait (hdone === 1'b1); @(posedge clk); #1;
    got = hrdata;
    if (got !== 16'h1bbb) begin
      errors++; $display("ERROR: HBM4 ch0[0] after ch1 traffic got=%h exp=1bbb", got);
    end
    if (errors == 0) $display("TEST PASSED: HBM4");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #500_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")
CUSTOM["HBM5"] = dict(
rtl="""// ============================================================================
// HBM5: 16-channel over the MEMCH_top multi-channel wrapper (PROTOCOL=14, NCH=16 (16-channel)).
// Educational projection of HBM5 (post-HBM4); gem5 trace port unchanged.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module HBM5_top (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        hvalid,
  output logic        hready,
  input  logic [2:0]  hcmd,
  input  logic [31:0] haddr,
  input  logic [15:0] hwdata,
  output logic [15:0] hrdata,
  output logic        hdone,
  output logic        ck_t, ck_c,
    output logic [16:0] addr,
  output logic        ras_n, cas_n, we_n,

  inout  tri [255:0]   dq,
  inout  tri [1:0]    dqs,
  output logic        cke,
  output logic        trace_valid,
  output logic [2:0]  trace_cmd,
  output logic [31:0] trace_addr
);
  MEMCH_top #(.PROTOCOL(14), .NCH(16), .CL(10), .TRCD(5), .TRP(5)) core (.*);
endmodule
""",
tb="""// HBM4 TB: ch0 read/write + ch1 isolation + channel isolation.
`timescale 1ns/1ps
module HBM5_tb;
  logic clk = 0, rst_n = 0;
  logic hvalid = 0, hready;
  logic [2:0] hcmd = 0;
  logic [31:0] haddr = 0;
  logic [15:0] hwdata = 0, hrdata;
  logic hdone;
  logic ck_t, ck_c;
  logic [16:0] addr; logic ras_n, cas_n, we_n;
  tri [255:0] dq; tri [1:0] dqs; logic cke;
  logic trace_valid; logic [2:0] trace_cmd; logic [31:0] trace_addr;
  int errors = 0;

  HBM5_top dut (.*);
  always #5 clk = ~clk;

  task automatic cmd(input logic [2:0] c, input logic [31:0] a, input logic [15:0] d);
    begin
      wait (hready === 1'b1);
      @(negedge clk);
      hcmd <= c; haddr <= a; hwdata <= d; hvalid <= 1'b1;
      @(negedge clk);
      hvalid <= 1'b0;
    end
  endtask

  logic [15:0] got;
  initial begin
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);
    cmd(3'd1, 32'h000, 16'h0);
    repeat(3) @(posedge clk);
    for (int i = 0; i < 4; i++) cmd(3'd3, i, 16'h1bbb + i * 8'h11);
    for (int i = 0; i < 4; i++) begin
      cmd(3'd2, i, 16'h0);
      wait (hdone === 1'b1); @(posedge clk); #1;
      got = hrdata;
      if (got !== 16'h1bbb + i * 8'h11) begin
        errors++; $display("ERROR: HBM5 ch0[%0d] got=%h", i, got);
      end
    end
    // channel 1 (haddr[8]=1): distinct data, same column -> isolation check
    cmd(3'd1, 32'h100, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd3, 32'h100, 16'h1bbb01);
    cmd(3'd1, 32'h100, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd2, 32'h100, 16'h0);
    wait (hdone === 1'b1); @(posedge clk); #1;
    got = hrdata;
    if (got !== 16'h1bbb01) begin
      errors++; $display("ERROR: HBM5 ch1[0] got=%h exp=1bbb01", got);
    end
    // channel 0 data must be untouched
    cmd(3'd1, 32'h000, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd2, 32'h000, 16'h0);
    wait (hdone === 1'b1); @(posedge clk); #1;
    got = hrdata;
    if (got !== 16'h1bbb) begin
      errors++; $display("ERROR: HBM5 ch0[0] after ch1 traffic got=%h exp=1bbb", got);
    end
    if (errors == 0) $display("TEST PASSED: HBM5");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #500_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")

CUSTOM["GDDR5"] = dict(
rtl="""// ============================================================================
// GDDR5: single-channel over the MEMCH_top multi-channel wrapper (PROTOCOL=12, NCH=1 (single-channel)).
// Educational slice of GDDR5; gem5 trace port unchanged.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module GDDR5_top (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        hvalid,
  output logic        hready,
  input  logic [2:0]  hcmd,
  input  logic [31:0] haddr,
  input  logic [15:0] hwdata,
  output logic [15:0] hrdata,
  output logic        hdone,
  output logic        ck_t, ck_c,
    output logic [16:0] addr,
  output logic        ras_n, cas_n, we_n,

  inout  tri [15:0]   dq,
  inout  tri [1:0]    dqs,
  output logic        cke,
  output logic        trace_valid,
  output logic [2:0]  trace_cmd,
  output logic [31:0] trace_addr
);
  MEMCH_top #(.PROTOCOL(12), .NCH(1), .CL(12), .TRCD(12), .TRP(12)) core (.*);
endmodule
""",
tb="""// GDDR5 TB: ch0 read/write + channel isolation.
`timescale 1ns/1ps
module GDDR5_tb;
  logic clk = 0, rst_n = 0;
  logic hvalid = 0, hready;
  logic [2:0] hcmd = 0;
  logic [31:0] haddr = 0;
  logic [15:0] hwdata = 0, hrdata;
  logic hdone;
  logic ck_t, ck_c;
  logic [16:0] addr; logic ras_n, cas_n, we_n;
  tri [15:0] dq; tri [1:0] dqs; logic cke;
  logic trace_valid; logic [2:0] trace_cmd; logic [31:0] trace_addr;
  int errors = 0;

  GDDR5_top dut (.*);
  always #5 clk = ~clk;

  task automatic cmd(input logic [2:0] c, input logic [31:0] a, input logic [15:0] d);
    begin
      wait (hready === 1'b1);
      @(negedge clk);
      hcmd <= c; haddr <= a; hwdata <= d; hvalid <= 1'b1;
      @(negedge clk);
      hvalid <= 1'b0;
    end
  endtask

  logic [15:0] got;
  initial begin
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);
    cmd(3'd1, 32'h000, 16'h0);
    repeat(3) @(posedge clk);
    for (int i = 0; i < 4; i++) cmd(3'd3, i, 16'h1ccc + i * 8'h11);
    for (int i = 0; i < 4; i++) begin
      cmd(3'd2, i, 16'h0);
      wait (hdone === 1'b1); @(posedge clk); #1;
      got = hrdata;
      if (got !== 16'h1ccc + i * 8'h11) begin
        errors++; $display("ERROR: GDDR5 ch0[%0d] got=%h", i, got);
      end
    end
    if (errors == 0) $display("TEST PASSED: GDDR5");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #500_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")

CUSTOM["GDDR6"] = dict(
rtl="""// ============================================================================
// GDDR6: 2-channel over the MEMCH_top multi-channel wrapper (PROTOCOL=8, NCH=2 (2-channel)).
// Educational slice of GDDR6; gem5 trace port unchanged.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module GDDR6_top (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        hvalid,
  output logic        hready,
  input  logic [2:0]  hcmd,
  input  logic [31:0] haddr,
  input  logic [15:0] hwdata,
  output logic [15:0] hrdata,
  output logic        hdone,
  output logic        ck_t, ck_c,
    output logic [16:0] addr,
  output logic        ras_n, cas_n, we_n,

  inout  tri [31:0]   dq,
  inout  tri [1:0]    dqs,
  output logic        cke,
  output logic        trace_valid,
  output logic [2:0]  trace_cmd,
  output logic [31:0] trace_addr
);
  MEMCH_top #(.PROTOCOL(8), .NCH(2), .CL(10), .TRCD(10), .TRP(10)) core (.*);
endmodule
""",
tb="""// GDDR6 TB: ch0 read/write + ch1 isolation + channel isolation.
`timescale 1ns/1ps
module GDDR6_tb;
  logic clk = 0, rst_n = 0;
  logic hvalid = 0, hready;
  logic [2:0] hcmd = 0;
  logic [31:0] haddr = 0;
  logic [15:0] hwdata = 0, hrdata;
  logic hdone;
  logic ck_t, ck_c;
  logic [16:0] addr; logic ras_n, cas_n, we_n;
  tri [31:0] dq; tri [1:0] dqs; logic cke;
  logic trace_valid; logic [2:0] trace_cmd; logic [31:0] trace_addr;
  int errors = 0;

  GDDR6_top dut (.*);
  always #5 clk = ~clk;

  task automatic cmd(input logic [2:0] c, input logic [31:0] a, input logic [15:0] d);
    begin
      wait (hready === 1'b1);
      @(negedge clk);
      hcmd <= c; haddr <= a; hwdata <= d; hvalid <= 1'b1;
      @(negedge clk);
      hvalid <= 1'b0;
    end
  endtask

  logic [15:0] got;
  initial begin
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);
    cmd(3'd1, 32'h000, 16'h0);
    repeat(3) @(posedge clk);
    for (int i = 0; i < 4; i++) cmd(3'd3, i, 16'h1888 + i * 8'h11);
    for (int i = 0; i < 4; i++) begin
      cmd(3'd2, i, 16'h0);
      wait (hdone === 1'b1); @(posedge clk); #1;
      got = hrdata;
      if (got !== 16'h1888 + i * 8'h11) begin
        errors++; $display("ERROR: GDDR6 ch0[%0d] got=%h", i, got);
      end
    end
    // channel 1 (haddr[8]=1): distinct data, same column -> isolation check
    cmd(3'd1, 32'h100, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd3, 32'h100, 16'h198901);
    cmd(3'd1, 32'h100, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd2, 32'h100, 16'h0);
    wait (hdone === 1'b1); @(posedge clk); #1;
    got = hrdata;
    if (got !== 16'h198901) begin
      errors++; $display("ERROR: GDDR6 ch1[0] got=%h exp=198901", got);
    end
    // channel 0 data must be untouched
    cmd(3'd1, 32'h000, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd2, 32'h000, 16'h0);
    wait (hdone === 1'b1); @(posedge clk); #1;
    got = hrdata;
    if (got !== 16'h1888) begin
      errors++; $display("ERROR: GDDR6 ch0[0] after ch1 traffic got=%h exp=1888", got);
    end
    if (errors == 0) $display("TEST PASSED: GDDR6");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #500_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")

CUSTOM["GDDR7"] = dict(
rtl="""// ============================================================================
// GDDR7: 2-channel over the MEMCH_top multi-channel wrapper (PROTOCOL=13, NCH=2 (2-channel)).
// Educational slice of GDDR7; gem5 trace port unchanged.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module GDDR7_top (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        hvalid,
  output logic        hready,
  input  logic [2:0]  hcmd,
  input  logic [31:0] haddr,
  input  logic [15:0] hwdata,
  output logic [15:0] hrdata,
  output logic        hdone,
  output logic        ck_t, ck_c,
    output logic [16:0] addr,
  output logic        ras_n, cas_n, we_n,

  inout  tri [31:0]   dq,
  inout  tri [1:0]    dqs,
  output logic        cke,
  output logic        trace_valid,
  output logic [2:0]  trace_cmd,
  output logic [31:0] trace_addr
);
  MEMCH_top #(.PROTOCOL(13), .NCH(2), .CL(9), .TRCD(9), .TRP(9)) core (.*);
endmodule
""",
tb="""// GDDR7 TB: ch0 read/write + ch1 isolation + channel isolation.
`timescale 1ns/1ps
module GDDR7_tb;
  logic clk = 0, rst_n = 0;
  logic hvalid = 0, hready;
  logic [2:0] hcmd = 0;
  logic [31:0] haddr = 0;
  logic [15:0] hwdata = 0, hrdata;
  logic hdone;
  logic ck_t, ck_c;
  logic [16:0] addr; logic ras_n, cas_n, we_n;
  tri [31:0] dq; tri [1:0] dqs; logic cke;
  logic trace_valid; logic [2:0] trace_cmd; logic [31:0] trace_addr;
  int errors = 0;

  GDDR7_top dut (.*);
  always #5 clk = ~clk;

  task automatic cmd(input logic [2:0] c, input logic [31:0] a, input logic [15:0] d);
    begin
      wait (hready === 1'b1);
      @(negedge clk);
      hcmd <= c; haddr <= a; hwdata <= d; hvalid <= 1'b1;
      @(negedge clk);
      hvalid <= 1'b0;
    end
  endtask

  logic [15:0] got;
  initial begin
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);
    cmd(3'd1, 32'h000, 16'h0);
    repeat(3) @(posedge clk);
    for (int i = 0; i < 4; i++) cmd(3'd3, i, 16'h1ddd + i * 8'h11);
    for (int i = 0; i < 4; i++) begin
      cmd(3'd2, i, 16'h0);
      wait (hdone === 1'b1); @(posedge clk); #1;
      got = hrdata;
      if (got !== 16'h1ddd + i * 8'h11) begin
        errors++; $display("ERROR: GDDR7 ch0[%0d] got=%h", i, got);
      end
    end
    // channel 1 (haddr[8]=1): distinct data, same column -> isolation check
    cmd(3'd1, 32'h100, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd3, 32'h100, 16'h1ddd01);
    cmd(3'd1, 32'h100, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd2, 32'h100, 16'h0);
    wait (hdone === 1'b1); @(posedge clk); #1;
    got = hrdata;
    if (got !== 16'h1ddd01) begin
      errors++; $display("ERROR: GDDR7 ch1[0] got=%h exp=1ddd01", got);
    end
    // channel 0 data must be untouched
    cmd(3'd1, 32'h000, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd2, 32'h000, 16'h0);
    wait (hdone === 1'b1); @(posedge clk); #1;
    got = hrdata;
    if (got !== 16'h1ddd) begin
      errors++; $display("ERROR: GDDR7 ch0[0] after ch1 traffic got=%h exp=1ddd", got);
    end
    if (errors == 0) $display("TEST PASSED: GDDR7");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #500_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")



CUSTOM["PCIe"] = dict(
rtl="""// ============================================================================
// PCIe simplified: serial TLP frame TX/RX with echo (educational).
// Frame: START(1b 0) + STP + LEN + HDR[8] + payload(LEN-8) + CRC32 + END.
// Raw NRZ both ways; length-based framing; STP=0xFB, END=0xFD.
// Differential pair modeled single-ended. LCRC = zlib CRC32.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module PCIe_top #(
  parameter int BAUD_DIV = 20,
  parameter int MAXB     = 8
)(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        refclk,
  input  logic        rx,
  output logic        tx,
  output logic        busy,
  output logic        irq
);
  localparam logic [7:0] STP = 8'hFB, END_B = 8'hFD;
  localparam int HB = 8;

  function automatic logic [31:0] crc32_u(input logic [31:0] c, input logic b);
    logic fb;
    begin fb = c[0]^b; crc32_u = c>>1; if (fb) crc32_u = crc32_u ^ 32'hEDB88320; end
  endfunction

  logic [15:0] tmr; logic phase;
  wire tick = (tmr == BAUD_DIV-1);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin tmr <= '0; phase <= 1'b0; end
    else if (tick) begin tmr <= '0; phase <= ~phase; end
    else tmr <= tmr + 1'b1;
  end

  // ---------------- TX (CAN-style field serializer) ----------------
  typedef enum logic [1:0] {T_IDLE, T_PKT, T_END} t_t;
  t_t          tstate;
  logic [7:0]  tx_shift;
  logic [31:0] tx_crc, crc_snap;
  logic [5:0]  tbit;
  logic [3:0]  tcur;
  logic [5:0]  tlen;
  logic [2:0]  tfld;           // 0=STP 1=LEN 2=HDR 3=DATA 4=CRC 5=END
  logic [7:0]  tx_mem [0:15];
  logic        tx_go, oe_q, out_q;
  logic [3:0]  ta_cnt; logic ta_arm;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tstate <= T_IDLE; tbit <= '0; tfld <= '0; tlen <= '0; tcur <= '0;
      tx_crc <= '0; crc_snap <= '0; tx_shift <= '0; tx_go <= 1'b0;
      oe_q <= 1'b0; out_q <= 1'b1; ta_cnt <= '0; ta_arm <= 1'b0;
    end else begin
      if (ta_cnt != 0 && tick) ta_cnt <= ta_cnt - 1'b1;
      if (ta_cnt == 0 && ta_arm) begin tx_go <= 1'b1; ta_arm <= 1'b0; end
      if (tick && !phase) begin
        case (tstate)
          T_IDLE: if (tx_go) begin
            tx_go <= 1'b0; oe_q <= 1'b1; out_q <= 1'b0;
            tbit <= '0; tfld <= '0;
            tstate <= T_PKT;
          end
          T_PKT: begin
            oe_q <= 1'b1;
            if (tfld == 3'd4) begin
              out_q    <= ~crc_snap[0];
              crc_snap <= crc_snap >> 1;
            end else begin
              out_q <= tx_shift[0];
              if (tfld == 3'd2 || tfld == 3'd3)
                tx_crc <= crc32_u(tx_crc, tx_shift[0]);
              tx_shift <= tx_shift >> 1;
            end
            if (tfld == 3'd4) begin
              if (tbit == 6'd31) begin tfld <= 3'd5; tbit <= '0; tx_shift <= END_B; end
              else tbit <= tbit + 1'b1;
            end else if (tbit == 6'd7) begin
              tbit <= '0;
              case (tfld)
                3'd0: begin tx_shift <= {2'b0, tlen}; tfld <= 3'd1; end
                3'd1: begin tx_shift <= tx_mem[0]; tfld <= 3'd2;
                            tx_crc <= 32'hFFFFFFFF; tcur <= '0; end
                3'd2: begin
                  if (tcur == 4'd7) begin tx_shift <= tx_mem[8]; tfld <= 3'd3; tcur <= 4'd8; end
                  else begin tcur <= tcur + 4'd1; tx_shift <= tx_mem[tcur + 4'd1]; end
                end
                3'd3: begin
                  if (tcur == (tlen[3:0] - 4'd1)) begin
                    tfld <= 3'd4;
                    crc_snap <= crc32_u(tx_crc, tx_shift[0]);
                  end
                  else begin tcur <= tcur + 4'd1; tx_shift <= tx_mem[tcur + 4'd1]; end
                end
                3'd5: tstate <= T_END;
                default: ;
              endcase
            end else tbit <= tbit + 1'b1;
          end
          T_END: begin oe_q <= 1'b0; out_q <= 1'b1; tstate <= T_IDLE; end
          default: tstate <= T_IDLE;
        endcase
      end
    end
  end

  assign tx   = oe_q ? out_q : 1'bz;
  assign busy = (rstate != R_IDLE) || (tstate != T_IDLE);

  // ---------------- RX (length-based framing, start-bit resync) ----------------
  typedef enum logic [1:0] {R_IDLE, R_BYTE} r_t;
  r_t          rstate;
  logic        rxs, rxs_d;
  logic        rtmr_en, rphase;
  logic [15:0] rtmr;
  logic [2:0]  rbitc;
  logic [7:0]  rsh;
  logic [5:0]  ridx;
  logic [5:0]  len_q;
  logic [7:0]  buf_mem [0:HB+MAXB+7];
  logic        rx_err, rx_done;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rxs <= 1'b1; rxs_d <= 1'b1; end
    else begin rxs <= rx; rxs_d <= rxs; end
  end
  wire start_edge = rxs_d & ~rxs;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rtmr_en <= 1'b0; rtmr <= '0; rphase <= 1'b0; end
    else begin
      if (rstate == R_IDLE && start_edge && tstate == T_IDLE) begin
        rtmr_en <= 1'b1; rtmr <= BAUD_DIV/2; rphase <= 1'b1;   // first sample = START bit (discarded)
      end else if (rtmr_en && (rtmr == BAUD_DIV-1)) begin
        rtmr <= '0; rphase <= ~rphase;
      end else if (rtmr_en) rtmr <= rtmr + 1'b1;
    end
  end
  wire rsample = rtmr_en && (rtmr == BAUD_DIV-1) && rphase;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rstate <= R_IDLE; rbitc <= '0; rsh <= '0; ridx <= '0; len_q <= '0;
      rx_err <= 1'b0; rx_done <= 1'b0; buf_mem[0] <= '0;
    end else begin
      rx_done <= 1'b0;
      if (rsample) begin
        case (rstate)
          R_IDLE: begin
            // this sample is the START bit: discard, begin STP at next sample
            rstate <= R_BYTE; rbitc <= '0; ridx <= '0; rsh <= '0;
          end
          R_BYTE: begin
            rsh <= {rxs, rsh[7:1]};
            if (rbitc == 3'd7) begin
              logic [7:0] nb; nb = {rxs, rsh[7:1]};
              if (ridx == 0) begin
                if (nb !== STP) rx_err <= 1'b1;
                ridx <= 1;
              end else if (ridx == 1) begin
                buf_mem[1] <= nb; len_q <= nb[5:0]; ridx <= 2;
              end else if (ridx == (6'd2 + len_q + 6'd4)) begin
                if (nb !== END_B) rx_err <= 1'b1;
                else begin
                  logic [31:0] c; c = 32'hFFFFFFFF;
                  for (int i = 2; i < HB + MAXB + 8; i++) begin
                    if (i <= 6'd1 + len_q)
                      for (int j = 0; j < 8; j++)
                        c = crc32_u(c, buf_mem[i][j]);
                  end
                  c = c ^ 32'hFFFFFFFF;
                  if ({buf_mem[6'd5+len_q], buf_mem[6'd4+len_q],
                       buf_mem[6'd3+len_q], buf_mem[6'd2+len_q]} !== c)
                    rx_err <= 1'b1;
                  else rx_done <= 1'b1;
                end
                rstate <= R_IDLE; ridx <= '0; rtmr_en <= 1'b0;
              end else begin
                buf_mem[ridx[5:0]] <= nb;
                ridx <= ridx + 6'd1;
              end
              rbitc <= '0;
            end else rbitc <= rbitc + 3'd1;
          end
          default: rstate <= R_IDLE;
        endcase
      end
    end
  end

  // echo: retransmit received content (HDR+payload identical frame)
  always_ff @(posedge clk) begin
    if (rx_done) begin
      tlen <= len_q;
      for (int i = 2; i < HB + MAXB + 6; i++)
        tx_mem[i-2] <= buf_mem[i];
      ta_cnt <= 4'd6; ta_arm <= 1'b1;
    end
  end

  assign irq = rx_done;

endmodule
""",
tb="""// PCIe TB: host sends TLP, device echoes, host verifies payload.
`timescale 1ns/1ps
module PCIe_tb;
  localparam int BIT = 400;
  localparam int HB  = 8;
  logic clk = 0, rst_n = 0;
  logic host_val = 1'b1, host_oe = 1'b0;
  tri1  rx, tx;
  int errors = 0;

  PCIe_top #(.BAUD_DIV(20)) dut (
    .clk(clk), .rst_n(rst_n), .refclk(clk), .rx(rx), .tx(tx), .busy(), .irq());
  always #5 clk = ~clk;
  assign rx = host_oe ? host_val : tx;

  function automatic logic [31:0] crc32(input logic [31:0] c, input logic b);
    logic fb; begin fb=c[0]^b; crc32=c>>1; if(fb) crc32=crc32^32'hEDB88320; end
  endfunction

  logic [7:0] hdr [0:7];
  logic [7:0] pl  [0:7];
  task automatic send_tlp(input int plen);
    logic [31:0] c; logic [7:0] fb;
    begin
      host_oe = 1; host_val = 1'b0; #(BIT);
      fb = 8'hFB; for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; #(BIT); end
      fb = HB + plen; for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; #(BIT); end
      c = 32'hFFFFFFFF;
      for (int i=0;i<HB;i++) begin
        fb = hdr[i];
        for (int j=0;j<8;j++) begin host_val=fb[0]; c=crc32(c,fb[0]); fb=fb>>1; #(BIT); end
      end
      for (int i=0;i<plen;i++) begin
        fb = pl[i];
        for (int j=0;j<8;j++) begin host_val=fb[0]; c=crc32(c,fb[0]); fb=fb>>1; #(BIT); end
      end
      c = ~c;
      for (int i=0;i<32;i++) begin host_val=c[0]; c=c>>1; #(BIT); end
      fb = 8'hFD; for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; #(BIT); end
      host_oe = 0;
    end
  endtask

  logic b; logic [7:0] sh;
  task automatic recv_tlp(output int plen);
    begin
      plen = 0; sh = 0;
      wait (tx === 1'b0);
      #(BIT + BIT/2);
      for (int i=0;i<8;i++) begin b=tx; sh={b,sh[7:1]}; #(BIT); end
      sh = 0;
      for (int i=0;i<8;i++) begin b=tx; sh={b,sh[7:1]}; if(i==7) plen = sh - HB; #(BIT); end
      for (int i=0;i<HB+plen;i++) begin
        sh = 0;
        for (int j=0;j<8;j++) begin
          b = tx; sh = {b, sh[7:1]};
          if (j == 7) begin
            if (i < HB) hdr[i] = sh;
            else        pl[i-HB] = sh;
          end
          #(BIT);
        end
      end
      #(BIT*40);
    end
  endtask

  int rlen;
  initial begin
    for (int i=0;i<8;i++) begin hdr[i] = 8'h10 + i; pl[i] = 8'hA0 + i * 8'h11; end
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(20) @(posedge clk);
    send_tlp(4);
    recv_tlp(rlen);
    if (rlen !== 4) begin errors++; $display("ERROR: PCIe plen got=%0d exp=4", rlen); end
    for (int i=0;i<4;i++) begin
      if (pl[i] !== 8'hA0 + i * 8'h11) begin
        errors++; $display("ERROR: PCIe pl[%0d] got=%h exp=%h", i, pl[i], 8'hA0 + i*8'h11);
      end
    end
    if (dut.rx_err !== 1'b0) begin errors++; $display("ERROR: PCIe rx_err set"); end
    if (errors == 0) $display("TEST PASSED: PCIe");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end
  initial begin #10_000_000; $display("TIMEOUT"); $finish; end
endmodule
""")

CUSTOM["CXL"] = dict(
rtl="""// ============================================================================
// CXL 2.0 simplified: flit over serial frame with echo (educational).
// Frame: START(1b 0) + STP + LEN + HDR[8] + payload(LEN-8) + CRC32 + END.
// Raw NRZ both ways; length-based framing; STP=0xFB, END=0xFD.
// Differential pair modeled single-ended. LCRC = zlib CRC32.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module CXL_top #(
  parameter int BAUD_DIV = 20,
  parameter int MAXB     = 8
)(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        refclk,
  input  logic        rx,
  output logic        tx,
  output logic        busy,
  output logic        irq
);
  localparam logic [7:0] STP = 8'h5C, END_B = 8'h5D;
  localparam int HB = 8;

  function automatic logic [31:0] crc32_u(input logic [31:0] c, input logic b);
    logic fb;
    begin fb = c[0]^b; crc32_u = c>>1; if (fb) crc32_u = crc32_u ^ 32'hEDB88320; end
  endfunction

  logic [15:0] tmr; logic phase;
  wire tick = (tmr == BAUD_DIV-1);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin tmr <= '0; phase <= 1'b0; end
    else if (tick) begin tmr <= '0; phase <= ~phase; end
    else tmr <= tmr + 1'b1;
  end

  // ---------------- TX (CAN-style field serializer) ----------------
  typedef enum logic [1:0] {T_IDLE, T_PKT, T_END} t_t;
  t_t          tstate;
  logic [7:0]  tx_shift;
  logic [31:0] tx_crc, crc_snap;
  logic [5:0]  tbit;
  logic [3:0]  tcur;
  logic [5:0]  tlen;
  logic [2:0]  tfld;           // 0=STP 1=LEN 2=HDR 3=DATA 4=CRC 5=END
  logic [7:0]  tx_mem [0:15];
  logic        tx_go, oe_q, out_q;
  logic [3:0]  ta_cnt; logic ta_arm;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tstate <= T_IDLE; tbit <= '0; tfld <= '0; tlen <= '0; tcur <= '0;
      tx_crc <= '0; crc_snap <= '0; tx_shift <= '0; tx_go <= 1'b0;
      oe_q <= 1'b0; out_q <= 1'b1; ta_cnt <= '0; ta_arm <= 1'b0;
    end else begin
      if (ta_cnt != 0 && tick) ta_cnt <= ta_cnt - 1'b1;
      if (ta_cnt == 0 && ta_arm) begin tx_go <= 1'b1; ta_arm <= 1'b0; end
      if (tick && !phase) begin
        case (tstate)
          T_IDLE: if (tx_go) begin
            tx_go <= 1'b0; oe_q <= 1'b1; out_q <= 1'b0;
            tbit <= '0; tfld <= '0;
            tstate <= T_PKT;
          end
          T_PKT: begin
            oe_q <= 1'b1;
            if (tfld == 3'd4) begin
              out_q    <= ~crc_snap[0];
              crc_snap <= crc_snap >> 1;
            end else begin
              out_q <= tx_shift[0];
              if (tfld == 3'd2 || tfld == 3'd3)
                tx_crc <= crc32_u(tx_crc, tx_shift[0]);
              tx_shift <= tx_shift >> 1;
            end
            if (tfld == 3'd4) begin
              if (tbit == 6'd31) begin tfld <= 3'd5; tbit <= '0; tx_shift <= END_B; end
              else tbit <= tbit + 1'b1;
            end else if (tbit == 6'd7) begin
              tbit <= '0;
              case (tfld)
                3'd0: begin tx_shift <= {2'b0, tlen}; tfld <= 3'd1; end
                3'd1: begin tx_shift <= tx_mem[0]; tfld <= 3'd2;
                            tx_crc <= 32'hFFFFFFFF; tcur <= '0; end
                3'd2: begin
                  if (tcur == 4'd7) begin tx_shift <= tx_mem[8]; tfld <= 3'd3; tcur <= 4'd8; end
                  else begin tcur <= tcur + 4'd1; tx_shift <= tx_mem[tcur + 4'd1]; end
                end
                3'd3: begin
                  if (tcur == (tlen[3:0] - 4'd1)) begin
                    tfld <= 3'd4;
                    crc_snap <= crc32_u(tx_crc, tx_shift[0]);
                  end
                  else begin tcur <= tcur + 4'd1; tx_shift <= tx_mem[tcur + 4'd1]; end
                end
                3'd5: tstate <= T_END;
                default: ;
              endcase
            end else tbit <= tbit + 1'b1;
          end
          T_END: begin oe_q <= 1'b0; out_q <= 1'b1; tstate <= T_IDLE; end
          default: tstate <= T_IDLE;
        endcase
      end
    end
  end

  assign tx   = oe_q ? out_q : 1'bz;
  assign busy = (rstate != R_IDLE) || (tstate != T_IDLE);

  // ---------------- RX (length-based framing, start-bit resync) ----------------
  typedef enum logic [1:0] {R_IDLE, R_BYTE} r_t;
  r_t          rstate;
  logic        rxs, rxs_d;
  logic        rtmr_en, rphase;
  logic [15:0] rtmr;
  logic [2:0]  rbitc;
  logic [7:0]  rsh;
  logic [5:0]  ridx;
  logic [5:0]  len_q;
  logic [7:0]  buf_mem [0:HB+MAXB+7];
  logic        rx_err, rx_done;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rxs <= 1'b1; rxs_d <= 1'b1; end
    else begin rxs <= rx; rxs_d <= rxs; end
  end
  wire start_edge = rxs_d & ~rxs;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rtmr_en <= 1'b0; rtmr <= '0; rphase <= 1'b0; end
    else begin
      if (rstate == R_IDLE && start_edge && tstate == T_IDLE) begin
        rtmr_en <= 1'b1; rtmr <= BAUD_DIV/2; rphase <= 1'b1;   // first sample = START bit (discarded)
      end else if (rtmr_en && (rtmr == BAUD_DIV-1)) begin
        rtmr <= '0; rphase <= ~rphase;
      end else if (rtmr_en) rtmr <= rtmr + 1'b1;
    end
  end
  wire rsample = rtmr_en && (rtmr == BAUD_DIV-1) && rphase;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rstate <= R_IDLE; rbitc <= '0; rsh <= '0; ridx <= '0; len_q <= '0;
      rx_err <= 1'b0; rx_done <= 1'b0; buf_mem[0] <= '0;
    end else begin
      rx_done <= 1'b0;
      if (rsample) begin
        case (rstate)
          R_IDLE: begin
            // this sample is the START bit: discard, begin STP at next sample
            rstate <= R_BYTE; rbitc <= '0; ridx <= '0; rsh <= '0;
          end
          R_BYTE: begin
            rsh <= {rxs, rsh[7:1]};
            if (rbitc == 3'd7) begin
              logic [7:0] nb; nb = {rxs, rsh[7:1]};
              if (ridx == 0) begin
                if (nb !== STP) rx_err <= 1'b1;
                ridx <= 1;
              end else if (ridx == 1) begin
                buf_mem[1] <= nb; len_q <= nb[5:0]; ridx <= 2;
              end else if (ridx == (6'd2 + len_q + 6'd4)) begin
                if (nb !== END_B) rx_err <= 1'b1;
                else begin
                  logic [31:0] c; c = 32'hFFFFFFFF;
                  for (int i = 2; i < HB + MAXB + 8; i++) begin
                    if (i <= 6'd1 + len_q)
                      for (int j = 0; j < 8; j++)
                        c = crc32_u(c, buf_mem[i][j]);
                  end
                  c = c ^ 32'hFFFFFFFF;
                  if ({buf_mem[6'd5+len_q], buf_mem[6'd4+len_q],
                       buf_mem[6'd3+len_q], buf_mem[6'd2+len_q]} !== c)
                    rx_err <= 1'b1;
                  else rx_done <= 1'b1;
                end
                rstate <= R_IDLE; ridx <= '0; rtmr_en <= 1'b0;
              end else begin
                buf_mem[ridx[5:0]] <= nb;
                ridx <= ridx + 6'd1;
              end
              rbitc <= '0;
            end else rbitc <= rbitc + 3'd1;
          end
          default: rstate <= R_IDLE;
        endcase
      end
    end
  end

  // echo: retransmit received content (HDR+payload identical frame)
  always_ff @(posedge clk) begin
    if (rx_done) begin
      tlen <= len_q;
      for (int i = 2; i < HB + MAXB + 6; i++)
        tx_mem[i-2] <= buf_mem[i];
      ta_cnt <= 4'd6; ta_arm <= 1'b1;
    end
  end

  assign irq = rx_done;

endmodule
""",
tb="""// PCIe TB: host sends TLP, device echoes, host verifies payload.
`timescale 1ns/1ps
module CXL_tb;
  localparam int BIT = 400;
  localparam int HB  = 8;
  logic clk = 0, rst_n = 0;
  logic host_val = 1'b1, host_oe = 1'b0;
  tri1  rx, tx;
  int errors = 0;

  CXL_top #(.BAUD_DIV(20)) dut (
    .clk(clk), .rst_n(rst_n), .refclk(clk), .rx(rx), .tx(tx), .busy(), .irq());
  always #5 clk = ~clk;
  assign rx = host_oe ? host_val : tx;

  function automatic logic [31:0] crc32(input logic [31:0] c, input logic b);
    logic fb; begin fb=c[0]^b; crc32=c>>1; if(fb) crc32=crc32^32'hEDB88320; end
  endfunction

  logic [7:0] hdr [0:7];
  logic [7:0] pl  [0:7];
  task automatic send_tlp(input int plen);
    logic [31:0] c; logic [7:0] fb;
    begin
      host_oe = 1; host_val = 1'b0; #(BIT);
      fb = 8'h5C; for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; #(BIT); end
      fb = HB + plen; for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; #(BIT); end
      c = 32'hFFFFFFFF;
      for (int i=0;i<HB;i++) begin
        fb = hdr[i];
        for (int j=0;j<8;j++) begin host_val=fb[0]; c=crc32(c,fb[0]); fb=fb>>1; #(BIT); end
      end
      for (int i=0;i<plen;i++) begin
        fb = pl[i];
        for (int j=0;j<8;j++) begin host_val=fb[0]; c=crc32(c,fb[0]); fb=fb>>1; #(BIT); end
      end
      c = ~c;
      for (int i=0;i<32;i++) begin host_val=c[0]; c=c>>1; #(BIT); end
      fb = 8'h5D; for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; #(BIT); end
      host_oe = 0;
    end
  endtask

  logic b; logic [7:0] sh;
  task automatic recv_tlp(output int plen);
    begin
      plen = 0; sh = 0;
      wait (tx === 1'b0);
      #(BIT + BIT/2);
      for (int i=0;i<8;i++) begin b=tx; sh={b,sh[7:1]}; #(BIT); end
      sh = 0;
      for (int i=0;i<8;i++) begin b=tx; sh={b,sh[7:1]}; if(i==7) plen = sh - HB; #(BIT); end
      for (int i=0;i<HB+plen;i++) begin
        sh = 0;
        for (int j=0;j<8;j++) begin
          b = tx; sh = {b, sh[7:1]};
          if (j == 7) begin
            if (i < HB) hdr[i] = sh;
            else        pl[i-HB] = sh;
          end
          #(BIT);
        end
      end
      #(BIT*40);
    end
  endtask

  int rlen;
  initial begin
    for (int i=0;i<8;i++) begin hdr[i] = 8'h10 + i; pl[i] = 8'hA0 + i * 8'h11; end
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(20) @(posedge clk);
    send_tlp(4);
    recv_tlp(rlen);
    if (rlen !== 4) begin errors++; $display("ERROR: CXL plen got=%0d exp=4", rlen); end
    for (int i=0;i<4;i++) begin
      if (pl[i] !== 8'hA0 + i * 8'h11) begin
        errors++; $display("ERROR: CXL pl[%0d] got=%h exp=%h", i, pl[i], 8'hA0 + i*8'h11);
      end
    end
    if (dut.rx_err !== 1'b0) begin errors++; $display("ERROR: CXL rx_err set"); end
    if (errors == 0) $display("TEST PASSED: CXL");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end
  initial begin #10_000_000; $display("TIMEOUT"); $finish; end
endmodule
""")

CUSTOM["USB3.2"] = dict(
rtl="""// ============================================================================
// USB 3.2 simplified: framed packets over serial lane with echo (educational).
// Frame: START(1b 0) + STP + LEN + HDR[8] + payload(LEN-8) + CRC32 + END.
// Raw NRZ both ways; length-based framing; STP=0xFB, END=0xFD.
// Differential pair modeled single-ended. LCRC = zlib CRC32.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module USB3_2_top #(
  parameter int BAUD_DIV = 20,
  parameter int MAXB     = 8
)(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        refclk,
  input  logic        rx,
  output logic        tx,
  output logic        busy,
  output logic        irq
);
  localparam logic [7:0] STP = 8'hB3, END_B = 8'hB4;
  localparam int HB = 8;

  function automatic logic [31:0] crc32_u(input logic [31:0] c, input logic b);
    logic fb;
    begin fb = c[0]^b; crc32_u = c>>1; if (fb) crc32_u = crc32_u ^ 32'hEDB88320; end
  endfunction

  logic [15:0] tmr; logic phase;
  wire tick = (tmr == BAUD_DIV-1);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin tmr <= '0; phase <= 1'b0; end
    else if (tick) begin tmr <= '0; phase <= ~phase; end
    else tmr <= tmr + 1'b1;
  end

  // ---------------- TX (CAN-style field serializer) ----------------
  typedef enum logic [1:0] {T_IDLE, T_PKT, T_END} t_t;
  t_t          tstate;
  logic [7:0]  tx_shift;
  logic [31:0] tx_crc, crc_snap;
  logic [5:0]  tbit;
  logic [3:0]  tcur;
  logic [5:0]  tlen;
  logic [2:0]  tfld;           // 0=STP 1=LEN 2=HDR 3=DATA 4=CRC 5=END
  logic [7:0]  tx_mem [0:15];
  logic        tx_go, oe_q, out_q;
  logic [3:0]  ta_cnt; logic ta_arm;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tstate <= T_IDLE; tbit <= '0; tfld <= '0; tlen <= '0; tcur <= '0;
      tx_crc <= '0; crc_snap <= '0; tx_shift <= '0; tx_go <= 1'b0;
      oe_q <= 1'b0; out_q <= 1'b1; ta_cnt <= '0; ta_arm <= 1'b0;
    end else begin
      if (ta_cnt != 0 && tick) ta_cnt <= ta_cnt - 1'b1;
      if (ta_cnt == 0 && ta_arm) begin tx_go <= 1'b1; ta_arm <= 1'b0; end
      if (tick && !phase) begin
        case (tstate)
          T_IDLE: if (tx_go) begin
            tx_go <= 1'b0; oe_q <= 1'b1; out_q <= 1'b0;
            tbit <= '0; tfld <= '0;
            tstate <= T_PKT;
          end
          T_PKT: begin
            oe_q <= 1'b1;
            if (tfld == 3'd4) begin
              out_q    <= ~crc_snap[0];
              crc_snap <= crc_snap >> 1;
            end else begin
              out_q <= tx_shift[0];
              if (tfld == 3'd2 || tfld == 3'd3)
                tx_crc <= crc32_u(tx_crc, tx_shift[0]);
              tx_shift <= tx_shift >> 1;
            end
            if (tfld == 3'd4) begin
              if (tbit == 6'd31) begin tfld <= 3'd5; tbit <= '0; tx_shift <= END_B; end
              else tbit <= tbit + 1'b1;
            end else if (tbit == 6'd7) begin
              tbit <= '0;
              case (tfld)
                3'd0: begin tx_shift <= {2'b0, tlen}; tfld <= 3'd1; end
                3'd1: begin tx_shift <= tx_mem[0]; tfld <= 3'd2;
                            tx_crc <= 32'hFFFFFFFF; tcur <= '0; end
                3'd2: begin
                  if (tcur == 4'd7) begin tx_shift <= tx_mem[8]; tfld <= 3'd3; tcur <= 4'd8; end
                  else begin tcur <= tcur + 4'd1; tx_shift <= tx_mem[tcur + 4'd1]; end
                end
                3'd3: begin
                  if (tcur == (tlen[3:0] - 4'd1)) begin
                    tfld <= 3'd4;
                    crc_snap <= crc32_u(tx_crc, tx_shift[0]);
                  end
                  else begin tcur <= tcur + 4'd1; tx_shift <= tx_mem[tcur + 4'd1]; end
                end
                3'd5: tstate <= T_END;
                default: ;
              endcase
            end else tbit <= tbit + 1'b1;
          end
          T_END: begin oe_q <= 1'b0; out_q <= 1'b1; tstate <= T_IDLE; end
          default: tstate <= T_IDLE;
        endcase
      end
    end
  end

  assign tx   = oe_q ? out_q : 1'bz;
  assign busy = (rstate != R_IDLE) || (tstate != T_IDLE);

  // ---------------- RX (length-based framing, start-bit resync) ----------------
  typedef enum logic [1:0] {R_IDLE, R_BYTE} r_t;
  r_t          rstate;
  logic        rxs, rxs_d;
  logic        rtmr_en, rphase;
  logic [15:0] rtmr;
  logic [2:0]  rbitc;
  logic [7:0]  rsh;
  logic [5:0]  ridx;
  logic [5:0]  len_q;
  logic [7:0]  buf_mem [0:HB+MAXB+7];
  logic        rx_err, rx_done;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rxs <= 1'b1; rxs_d <= 1'b1; end
    else begin rxs <= rx; rxs_d <= rxs; end
  end
  wire start_edge = rxs_d & ~rxs;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rtmr_en <= 1'b0; rtmr <= '0; rphase <= 1'b0; end
    else begin
      if (rstate == R_IDLE && start_edge && tstate == T_IDLE) begin
        rtmr_en <= 1'b1; rtmr <= BAUD_DIV/2; rphase <= 1'b1;   // first sample = START bit (discarded)
      end else if (rtmr_en && (rtmr == BAUD_DIV-1)) begin
        rtmr <= '0; rphase <= ~rphase;
      end else if (rtmr_en) rtmr <= rtmr + 1'b1;
    end
  end
  wire rsample = rtmr_en && (rtmr == BAUD_DIV-1) && rphase;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rstate <= R_IDLE; rbitc <= '0; rsh <= '0; ridx <= '0; len_q <= '0;
      rx_err <= 1'b0; rx_done <= 1'b0; buf_mem[0] <= '0;
    end else begin
      rx_done <= 1'b0;
      if (rsample) begin
        case (rstate)
          R_IDLE: begin
            // this sample is the START bit: discard, begin STP at next sample
            rstate <= R_BYTE; rbitc <= '0; ridx <= '0; rsh <= '0;
          end
          R_BYTE: begin
            rsh <= {rxs, rsh[7:1]};
            if (rbitc == 3'd7) begin
              logic [7:0] nb; nb = {rxs, rsh[7:1]};
              if (ridx == 0) begin
                if (nb !== STP) rx_err <= 1'b1;
                ridx <= 1;
              end else if (ridx == 1) begin
                buf_mem[1] <= nb; len_q <= nb[5:0]; ridx <= 2;
              end else if (ridx == (6'd2 + len_q + 6'd4)) begin
                if (nb !== END_B) rx_err <= 1'b1;
                else begin
                  logic [31:0] c; c = 32'hFFFFFFFF;
                  for (int i = 2; i < HB + MAXB + 8; i++) begin
                    if (i <= 6'd1 + len_q)
                      for (int j = 0; j < 8; j++)
                        c = crc32_u(c, buf_mem[i][j]);
                  end
                  c = c ^ 32'hFFFFFFFF;
                  if ({buf_mem[6'd5+len_q], buf_mem[6'd4+len_q],
                       buf_mem[6'd3+len_q], buf_mem[6'd2+len_q]} !== c)
                    rx_err <= 1'b1;
                  else rx_done <= 1'b1;
                end
                rstate <= R_IDLE; ridx <= '0; rtmr_en <= 1'b0;
              end else begin
                buf_mem[ridx[5:0]] <= nb;
                ridx <= ridx + 6'd1;
              end
              rbitc <= '0;
            end else rbitc <= rbitc + 3'd1;
          end
          default: rstate <= R_IDLE;
        endcase
      end
    end
  end

  // echo: retransmit received content (HDR+payload identical frame)
  always_ff @(posedge clk) begin
    if (rx_done) begin
      tlen <= len_q;
      for (int i = 2; i < HB + MAXB + 6; i++)
        tx_mem[i-2] <= buf_mem[i];
      ta_cnt <= 4'd6; ta_arm <= 1'b1;
    end
  end

  assign irq = rx_done;

endmodule
""",
tb="""// PCIe TB: host sends TLP, device echoes, host verifies payload.
`timescale 1ns/1ps
module USB3_2_tb;
  localparam int BIT = 400;
  localparam int HB  = 8;
  logic clk = 0, rst_n = 0;
  logic host_val = 1'b1, host_oe = 1'b0;
  tri1  rx, tx;
  int errors = 0;

  USB3_2_top #(.BAUD_DIV(20)) dut (
    .clk(clk), .rst_n(rst_n), .refclk(clk), .rx(rx), .tx(tx), .busy(), .irq());
  always #5 clk = ~clk;
  assign rx = host_oe ? host_val : tx;

  function automatic logic [31:0] crc32(input logic [31:0] c, input logic b);
    logic fb; begin fb=c[0]^b; crc32=c>>1; if(fb) crc32=crc32^32'hEDB88320; end
  endfunction

  logic [7:0] hdr [0:7];
  logic [7:0] pl  [0:7];
  task automatic send_tlp(input int plen);
    logic [31:0] c; logic [7:0] fb;
    begin
      host_oe = 1; host_val = 1'b0; #(BIT);
      fb = 8'hB3; for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; #(BIT); end
      fb = HB + plen; for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; #(BIT); end
      c = 32'hFFFFFFFF;
      for (int i=0;i<HB;i++) begin
        fb = hdr[i];
        for (int j=0;j<8;j++) begin host_val=fb[0]; c=crc32(c,fb[0]); fb=fb>>1; #(BIT); end
      end
      for (int i=0;i<plen;i++) begin
        fb = pl[i];
        for (int j=0;j<8;j++) begin host_val=fb[0]; c=crc32(c,fb[0]); fb=fb>>1; #(BIT); end
      end
      c = ~c;
      for (int i=0;i<32;i++) begin host_val=c[0]; c=c>>1; #(BIT); end
      fb = 8'hB4; for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; #(BIT); end
      host_oe = 0;
    end
  endtask

  logic b; logic [7:0] sh;
  task automatic recv_tlp(output int plen);
    begin
      plen = 0; sh = 0;
      wait (tx === 1'b0);
      #(BIT + BIT/2);
      for (int i=0;i<8;i++) begin b=tx; sh={b,sh[7:1]}; #(BIT); end
      sh = 0;
      for (int i=0;i<8;i++) begin b=tx; sh={b,sh[7:1]}; if(i==7) plen = sh - HB; #(BIT); end
      for (int i=0;i<HB+plen;i++) begin
        sh = 0;
        for (int j=0;j<8;j++) begin
          b = tx; sh = {b, sh[7:1]};
          if (j == 7) begin
            if (i < HB) hdr[i] = sh;
            else        pl[i-HB] = sh;
          end
          #(BIT);
        end
      end
      #(BIT*40);
    end
  endtask

  int rlen;
  initial begin
    for (int i=0;i<8;i++) begin hdr[i] = 8'h10 + i; pl[i] = 8'hA0 + i * 8'h11; end
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(20) @(posedge clk);
    send_tlp(4);
    recv_tlp(rlen);
    if (rlen !== 4) begin errors++; $display("ERROR: USB3_2 plen got=%0d exp=4", rlen); end
    for (int i=0;i<4;i++) begin
      if (pl[i] !== 8'hA0 + i * 8'h11) begin
        errors++; $display("ERROR: USB3_2 pl[%0d] got=%h exp=%h", i, pl[i], 8'hA0 + i*8'h11);
      end
    end
    if (dut.rx_err !== 1'b0) begin errors++; $display("ERROR: USB3_2 rx_err set"); end
    if (errors == 0) $display("TEST PASSED: USB3_2");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end
  initial begin #10_000_000; $display("TIMEOUT"); $finish; end
endmodule
""")

CUSTOM["CHI"] = dict(
rtl="""// ============================================================================
// CHI simplified slave: request flit RX (with credit), response flit TX.
// Req flit 44b: {addr[31:0], txnID[11:0], opcode[7:0]... simplified:
//   [43:32]=txnID [31:0]=addr
// Rsp flit 34b: {[33:29]=opcode(5'b00001=OK) [28:17]=txnID [16:1]=data16
//               [0]=respValidTag}
// Credit-based flow control both directions. OpenCores chi / AMBA CHI spec
// (Issue A/B) simplified style.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module CHI_top #(
  parameter int CRD_MAX  = 8,
  parameter int RSP_LAT  = 4
)(
  input  logic        clk,
  input  logic        rst_n,
  // request channel (from master into us)
  input  logic [43:0] txreqflit,
  input  logic        txreqflitv,
  output logic        txreqlcrdv,
  // response channel (from us to master)
  output logic [33:0] rxrspflit,
  output logic        rxrspflitv,
  input  logic        rxrsplcrdv,
  output logic        busy,
  output logic        irq
);
  // credits we grant to master (acceptance capacity)
  logic [3:0] rx_crd;
  // credits master grants us (for our responses)
  logic [3:0] tx_crd;
  logic [3:0] crd_timer;

  typedef enum logic [1:0] {C_IDLE, C_LAT, C_SEND} c_t;
  c_t         cstate;
  logic [43:0] req_q;
  logic [3:0]  lat_cnt;

  assign txreqlcrdv  = (crd_timer == 4'd0);
  assign rxrspflitv  = (cstate == C_SEND) && (tx_crd != 0);
  assign rxrspflit   = {5'b00001, req_q[43:32], req_q[15:0], 1'b1};
  assign busy        = (cstate != C_IDLE);
  assign irq         = (cstate == C_SEND) && (tx_crd != 0);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_crd <= CRD_MAX[3:0]; tx_crd <= '0; crd_timer <= '0;
      cstate <= C_IDLE; req_q <= '0; lat_cnt <= '0;
    end else begin
      // credit return to master (acceptance credit replenishment)
      if (txreqlcrdv) begin
        if (rx_crd < CRD_MAX[3:0]) rx_crd <= rx_crd + 1'b1;
        crd_timer <= 4'd7;
      end else crd_timer <= crd_timer - 1'b1;

      // master grants us response credit
      if (rxrsplcrdv && tx_crd < CRD_MAX[3:0]) tx_crd <= tx_crd + 1'b1;

      case (cstate)
        C_IDLE: if (txreqflitv && rx_crd != 0) begin
          req_q  <= txreqflit;
          rx_crd <= rx_crd - 1'b1;
          cstate <= C_LAT; lat_cnt <= RSP_LAT[3:0];
        end
        C_LAT: if (lat_cnt == 0) cstate <= C_SEND;
        else lat_cnt <= lat_cnt - 1'b1;
        C_SEND: if (tx_crd != 0) begin
          tx_crd <= tx_crd - 1'b1;
          cstate <= C_IDLE;
        end
        default: cstate <= C_IDLE;
      endcase
    end
  end

endmodule
""",
tb="""// Self-checking TB: master drives req flit with credits; checks rsp flit.
`timescale 1ns/1ps
module CHI_tb;
  logic clk = 0, rst_n = 0;
  logic [43:0] txreqflit = '0;
  logic        txreqflitv = 0;
  logic        txreqlcrdv;
  logic [33:0] rxrspflit;
  logic        rxrspflitv;
  logic        rxrsplcrdv = 0;
  int errors = 0;

  CHI_top dut (
    .clk(clk), .rst_n(rst_n),
    .txreqflit(txreqflit), .txreqflitv(txreqflitv), .txreqlcrdv(txreqlcrdv),
    .rxrspflit(rxrspflit), .rxrspflitv(rxrspflitv), .rxrsplcrdv(rxrsplcrdv),
    .busy(), .irq());

  always #5 clk = ~clk;

  // grant response credits periodically (master side)
  initial begin
    rxrsplcrdv = 0;
    repeat(4) @(posedge clk);
    forever begin
      repeat(8) @(posedge clk);
      rxrsplcrdv <= 1;
      @(posedge clk);
      rxrsplcrdv <= 0;
    end
  end

  task automatic send_req(input logic [11:0] txn, input logic [31:0] addr);
    begin
      // wait for an acceptance credit from the slave
      @(posedge clk);
      while (!txreqlcrdv) @(posedge clk);
      txreqflit  <= {txn, addr};
      txreqflitv <= 1'b1;
      @(posedge clk);
      txreqflitv <= 1'b0;
      txreqflit  <= '0;
    end
  endtask

  task automatic expect_rsp(input logic [11:0] txn, input logic [15:0] data);
    logic [33:0] r;
    begin
      r = '0;
      wait (rxrspflitv === 1'b1);
      @(posedge clk); #1;
      r = rxrspflit;
      if (r[28:17] !== txn) begin
        errors++; $display("ERROR: CHI rsp txn got=%h exp=%h", r[28:17], txn);
      end
      if (r[16:1] !== data) begin
        errors++; $display("ERROR: CHI rsp data got=%h exp=%h", r[16:1], data);
      end
      if (r[33:29] !== 5'b00001) begin
        errors++; $display("ERROR: CHI rsp opcode got=%b", r[33:29]);
      end
    end
  endtask

  initial begin
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(20) @(posedge clk);

    send_req(12'hA5A, 32'hDEAD_BEEF);
    expect_rsp(12'hA5A, 16'hBEEF);
    repeat(10) @(posedge clk);
    send_req(12'h123, 32'hCAFE_0001);
    expect_rsp(12'h123, 16'h0001);

    if (errors == 0) $display("TEST PASSED: CHI");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #500_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")


CUSTOM["UCIe"] = dict(
rtl="""// ============================================================================
// UCIe simplified: die-to-die flit (CHI-style).
// Req flit 44b: {addr[31:0], txnID[11:0], opcode[7:0]... simplified:
//   [43:32]=txnID [31:0]=addr
// Rsp flit 34b: {[33:29]=opcode(5'b00001=OK) [28:17]=txnID [16:1]=data16
//               [0]=respValidTag}
// Credit-based flow control both directions. OpenCores chi / AMBA CHI spec
// (Issue A/B) simplified style.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module UCIe_top #(
  parameter int CRD_MAX  = 8,
  parameter int RSP_LAT  = 4
)(
  input  logic        clk,
  input  logic        rst_n,
  // request channel (from master into us)
  input  logic [43:0] txreqflit,
  input  logic        txreqflitv,
  output logic        txreqlcrdv,
  // response channel (from us to master)
  output logic [33:0] rxrspflit,
  output logic        rxrspflitv,
  input  logic        rxrsplcrdv,
  output logic        busy,
  output logic        irq
);
  // credits we grant to master (acceptance capacity)
  logic [3:0] rx_crd;
  // credits master grants us (for our responses)
  logic [3:0] tx_crd;
  logic [3:0] crd_timer;

  typedef enum logic [1:0] {C_IDLE, C_LAT, C_SEND} c_t;
  c_t         cstate;
  logic [43:0] req_q;
  logic [3:0]  lat_cnt;

  assign txreqlcrdv  = (crd_timer == 4'd0);
  assign rxrspflitv  = (cstate == C_SEND) && (tx_crd != 0);
  assign rxrspflit   = {5'b00001, req_q[43:32], req_q[15:0], 1'b1};
  assign busy        = (cstate != C_IDLE);
  assign irq         = (cstate == C_SEND) && (tx_crd != 0);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_crd <= CRD_MAX[3:0]; tx_crd <= '0; crd_timer <= '0;
      cstate <= C_IDLE; req_q <= '0; lat_cnt <= '0;
    end else begin
      // credit return to master (acceptance credit replenishment)
      if (txreqlcrdv) begin
        if (rx_crd < CRD_MAX[3:0]) rx_crd <= rx_crd + 1'b1;
        crd_timer <= 4'd7;
      end else crd_timer <= crd_timer - 1'b1;

      // master grants us response credit
      if (rxrsplcrdv && tx_crd < CRD_MAX[3:0]) tx_crd <= tx_crd + 1'b1;

      case (cstate)
        C_IDLE: if (txreqflitv && rx_crd != 0) begin
          req_q  <= txreqflit;
          rx_crd <= rx_crd - 1'b1;
          cstate <= C_LAT; lat_cnt <= RSP_LAT[3:0];
        end
        C_LAT: if (lat_cnt == 0) cstate <= C_SEND;
        else lat_cnt <= lat_cnt - 1'b1;
        C_SEND: if (tx_crd != 0) begin
          tx_crd <= tx_crd - 1'b1;
          cstate <= C_IDLE;
        end
        default: cstate <= C_IDLE;
      endcase
    end
  end

endmodule
""",
tb="""// Self-checking TB: master drives req flit with credits; checks rsp flit.
`timescale 1ns/1ps
module UCIe_tb;
  logic clk = 0, rst_n = 0;
  logic [43:0] txreqflit = '0;
  logic        txreqflitv = 0;
  logic        txreqlcrdv;
  logic [33:0] rxrspflit;
  logic        rxrspflitv;
  logic        rxrsplcrdv = 0;
  int errors = 0;

  UCIe_top dut (
    .clk(clk), .rst_n(rst_n),
    .txreqflit(txreqflit), .txreqflitv(txreqflitv), .txreqlcrdv(txreqlcrdv),
    .rxrspflit(rxrspflit), .rxrspflitv(rxrspflitv), .rxrsplcrdv(rxrsplcrdv),
    .busy(), .irq());

  always #5 clk = ~clk;

  // grant response credits periodically (master side)
  initial begin
    rxrsplcrdv = 0;
    repeat(4) @(posedge clk);
    forever begin
      repeat(8) @(posedge clk);
      rxrsplcrdv <= 1;
      @(posedge clk);
      rxrsplcrdv <= 0;
    end
  end

  task automatic send_req(input logic [11:0] txn, input logic [31:0] addr);
    begin
      // wait for an acceptance credit from the slave
      @(posedge clk);
      while (!txreqlcrdv) @(posedge clk);
      txreqflit  <= {txn, addr};
      txreqflitv <= 1'b1;
      @(posedge clk);
      txreqflitv <= 1'b0;
      txreqflit  <= '0;
    end
  endtask

  task automatic expect_rsp(input logic [11:0] txn, input logic [15:0] data);
    logic [33:0] r;
    begin
      r = '0;
      wait (rxrspflitv === 1'b1);
      @(posedge clk); #1;
      r = rxrspflit;
      if (r[28:17] !== txn) begin
        errors++; $display("ERROR: UCIe rsp txn got=%h exp=%h", r[28:17], txn);
      end
      if (r[16:1] !== data) begin
        errors++; $display("ERROR: UCIe rsp data got=%h exp=%h", r[16:1], data);
      end
      if (r[33:29] !== 5'b00001) begin
        errors++; $display("ERROR: UCIe rsp opcode got=%b", r[33:29]);
      end
    end
  endtask

  initial begin
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(20) @(posedge clk);

    send_req(12'hA5A, 32'hDEAD_BEEF);
    expect_rsp(12'hA5A, 16'hBEEF);
    repeat(10) @(posedge clk);
    send_req(12'h123, 32'hCAFE_0001);
    expect_rsp(12'h123, 16'h0001);

    if (errors == 0) $display("TEST PASSED: UCIe");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #500_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")


CUSTOM["UALink"] = dict(
rtl="""// ============================================================================
// UALink simplified: AI scale-up flit (CHI-style).
// Req flit 44b: {addr[31:0], txnID[11:0], opcode[7:0]... simplified:
//   [43:32]=txnID [31:0]=addr
// Rsp flit 34b: {[33:29]=opcode(5'b00001=OK) [28:17]=txnID [16:1]=data16
//               [0]=respValidTag}
// Credit-based flow control both directions. OpenCores chi / AMBA CHI spec
// (Issue A/B) simplified style.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module UALink_top #(
  parameter int CRD_MAX  = 8,
  parameter int RSP_LAT  = 4
)(
  input  logic        clk,
  input  logic        rst_n,
  // request channel (from master into us)
  input  logic [43:0] txreqflit,
  input  logic        txreqflitv,
  output logic        txreqlcrdv,
  // response channel (from us to master)
  output logic [33:0] rxrspflit,
  output logic        rxrspflitv,
  input  logic        rxrsplcrdv,
  output logic        busy,
  output logic        irq
);
  // credits we grant to master (acceptance capacity)
  logic [3:0] rx_crd;
  // credits master grants us (for our responses)
  logic [3:0] tx_crd;
  logic [3:0] crd_timer;

  typedef enum logic [1:0] {C_IDLE, C_LAT, C_SEND} c_t;
  c_t         cstate;
  logic [43:0] req_q;
  logic [3:0]  lat_cnt;

  assign txreqlcrdv  = (crd_timer == 4'd0);
  assign rxrspflitv  = (cstate == C_SEND) && (tx_crd != 0);
  assign rxrspflit   = {5'b00001, req_q[43:32], req_q[15:0], 1'b1};
  assign busy        = (cstate != C_IDLE);
  assign irq         = (cstate == C_SEND) && (tx_crd != 0);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_crd <= CRD_MAX[3:0]; tx_crd <= '0; crd_timer <= '0;
      cstate <= C_IDLE; req_q <= '0; lat_cnt <= '0;
    end else begin
      // credit return to master (acceptance credit replenishment)
      if (txreqlcrdv) begin
        if (rx_crd < CRD_MAX[3:0]) rx_crd <= rx_crd + 1'b1;
        crd_timer <= 4'd7;
      end else crd_timer <= crd_timer - 1'b1;

      // master grants us response credit
      if (rxrsplcrdv && tx_crd < CRD_MAX[3:0]) tx_crd <= tx_crd + 1'b1;

      case (cstate)
        C_IDLE: if (txreqflitv && rx_crd != 0) begin
          req_q  <= txreqflit;
          rx_crd <= rx_crd - 1'b1;
          cstate <= C_LAT; lat_cnt <= RSP_LAT[3:0];
        end
        C_LAT: if (lat_cnt == 0) cstate <= C_SEND;
        else lat_cnt <= lat_cnt - 1'b1;
        C_SEND: if (tx_crd != 0) begin
          tx_crd <= tx_crd - 1'b1;
          cstate <= C_IDLE;
        end
        default: cstate <= C_IDLE;
      endcase
    end
  end

endmodule
""",
tb="""// Self-checking TB: master drives req flit with credits; checks rsp flit.
`timescale 1ns/1ps
module UALink_tb;
  logic clk = 0, rst_n = 0;
  logic [43:0] txreqflit = '0;
  logic        txreqflitv = 0;
  logic        txreqlcrdv;
  logic [33:0] rxrspflit;
  logic        rxrspflitv;
  logic        rxrsplcrdv = 0;
  int errors = 0;

  UALink_top dut (
    .clk(clk), .rst_n(rst_n),
    .txreqflit(txreqflit), .txreqflitv(txreqflitv), .txreqlcrdv(txreqlcrdv),
    .rxrspflit(rxrspflit), .rxrspflitv(rxrspflitv), .rxrsplcrdv(rxrsplcrdv),
    .busy(), .irq());

  always #5 clk = ~clk;

  // grant response credits periodically (master side)
  initial begin
    rxrsplcrdv = 0;
    repeat(4) @(posedge clk);
    forever begin
      repeat(8) @(posedge clk);
      rxrsplcrdv <= 1;
      @(posedge clk);
      rxrsplcrdv <= 0;
    end
  end

  task automatic send_req(input logic [11:0] txn, input logic [31:0] addr);
    begin
      // wait for an acceptance credit from the slave
      @(posedge clk);
      while (!txreqlcrdv) @(posedge clk);
      txreqflit  <= {txn, addr};
      txreqflitv <= 1'b1;
      @(posedge clk);
      txreqflitv <= 1'b0;
      txreqflit  <= '0;
    end
  endtask

  task automatic expect_rsp(input logic [11:0] txn, input logic [15:0] data);
    logic [33:0] r;
    begin
      r = '0;
      wait (rxrspflitv === 1'b1);
      @(posedge clk); #1;
      r = rxrspflit;
      if (r[28:17] !== txn) begin
        errors++; $display("ERROR: UALink rsp txn got=%h exp=%h", r[28:17], txn);
      end
      if (r[16:1] !== data) begin
        errors++; $display("ERROR: UALink rsp data got=%h exp=%h", r[16:1], data);
      end
      if (r[33:29] !== 5'b00001) begin
        errors++; $display("ERROR: UALink rsp opcode got=%b", r[33:29]);
      end
    end
  endtask

  initial begin
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(20) @(posedge clk);

    send_req(12'hA5A, 32'hDEAD_BEEF);
    expect_rsp(12'hA5A, 16'hBEEF);
    repeat(10) @(posedge clk);
    send_req(12'h123, 32'hCAFE_0001);
    expect_rsp(12'h123, 16'h0001);

    if (errors == 0) $display("TEST PASSED: UALink");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #500_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")


CUSTOM["CCIX Cache Coherent Interconnect"] = dict(
rtl="""// ============================================================================
// CCIX simplified: coherent flit channel.
// Req flit 44b: {addr[31:0], txnID[11:0], opcode[7:0]... simplified:
//   [43:32]=txnID [31:0]=addr
// Rsp flit 34b: {[33:29]=opcode(5'b00001=OK) [28:17]=txnID [16:1]=data16
//               [0]=respValidTag}
// Credit-based flow control both directions. OpenCores chi / AMBA CHI spec
// (Issue A/B) simplified style.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module CCIX_Cache_Coherent_Interconnect_top #(
  parameter int CRD_MAX  = 8,
  parameter int RSP_LAT  = 4
)(
  input  logic        clk,
  input  logic        rst_n,
  // request channel (from master into us)
  input  logic [43:0] txreqflit,
  input  logic        txreqflitv,
  output logic        txreqlcrdv,
  // response channel (from us to master)
  output logic [33:0] rxrspflit,
  output logic        rxrspflitv,
  input  logic        rxrsplcrdv,
  output logic        busy,
  output logic        irq
);
  // credits we grant to master (acceptance capacity)
  logic [3:0] rx_crd;
  // credits master grants us (for our responses)
  logic [3:0] tx_crd;
  logic [3:0] crd_timer;

  typedef enum logic [1:0] {C_IDLE, C_LAT, C_SEND} c_t;
  c_t         cstate;
  logic [43:0] req_q;
  logic [3:0]  lat_cnt;

  assign txreqlcrdv  = (crd_timer == 4'd0);
  assign rxrspflitv  = (cstate == C_SEND) && (tx_crd != 0);
  assign rxrspflit   = {5'b00001, req_q[43:32], req_q[15:0], 1'b1};
  assign busy        = (cstate != C_IDLE);
  assign irq         = (cstate == C_SEND) && (tx_crd != 0);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_crd <= CRD_MAX[3:0]; tx_crd <= '0; crd_timer <= '0;
      cstate <= C_IDLE; req_q <= '0; lat_cnt <= '0;
    end else begin
      // credit return to master (acceptance credit replenishment)
      if (txreqlcrdv) begin
        if (rx_crd < CRD_MAX[3:0]) rx_crd <= rx_crd + 1'b1;
        crd_timer <= 4'd7;
      end else crd_timer <= crd_timer - 1'b1;

      // master grants us response credit
      if (rxrsplcrdv && tx_crd < CRD_MAX[3:0]) tx_crd <= tx_crd + 1'b1;

      case (cstate)
        C_IDLE: if (txreqflitv && rx_crd != 0) begin
          req_q  <= txreqflit;
          rx_crd <= rx_crd - 1'b1;
          cstate <= C_LAT; lat_cnt <= RSP_LAT[3:0];
        end
        C_LAT: if (lat_cnt == 0) cstate <= C_SEND;
        else lat_cnt <= lat_cnt - 1'b1;
        C_SEND: if (tx_crd != 0) begin
          tx_crd <= tx_crd - 1'b1;
          cstate <= C_IDLE;
        end
        default: cstate <= C_IDLE;
      endcase
    end
  end

endmodule
""",
tb="""// Self-checking TB: master drives req flit with credits; checks rsp flit.
`timescale 1ns/1ps
module CCIX_Cache_Coherent_Interconnect_tb;
  logic clk = 0, rst_n = 0;
  logic [43:0] txreqflit = '0;
  logic        txreqflitv = 0;
  logic        txreqlcrdv;
  logic [33:0] rxrspflit;
  logic        rxrspflitv;
  logic        rxrsplcrdv = 0;
  int errors = 0;

  CCIX_Cache_Coherent_Interconnect_top dut (
    .clk(clk), .rst_n(rst_n),
    .txreqflit(txreqflit), .txreqflitv(txreqflitv), .txreqlcrdv(txreqlcrdv),
    .rxrspflit(rxrspflit), .rxrspflitv(rxrspflitv), .rxrsplcrdv(rxrsplcrdv),
    .busy(), .irq());

  always #5 clk = ~clk;

  // grant response credits periodically (master side)
  initial begin
    rxrsplcrdv = 0;
    repeat(4) @(posedge clk);
    forever begin
      repeat(8) @(posedge clk);
      rxrsplcrdv <= 1;
      @(posedge clk);
      rxrsplcrdv <= 0;
    end
  end

  task automatic send_req(input logic [11:0] txn, input logic [31:0] addr);
    begin
      // wait for an acceptance credit from the slave
      @(posedge clk);
      while (!txreqlcrdv) @(posedge clk);
      txreqflit  <= {txn, addr};
      txreqflitv <= 1'b1;
      @(posedge clk);
      txreqflitv <= 1'b0;
      txreqflit  <= '0;
    end
  endtask

  task automatic expect_rsp(input logic [11:0] txn, input logic [15:0] data);
    logic [33:0] r;
    begin
      r = '0;
      wait (rxrspflitv === 1'b1);
      @(posedge clk); #1;
      r = rxrspflit;
      if (r[28:17] !== txn) begin
        errors++; $display("ERROR: CCIX Cache Coherent Interconnect rsp txn got=%h exp=%h", r[28:17], txn);
      end
      if (r[16:1] !== data) begin
        errors++; $display("ERROR: CCIX Cache Coherent Interconnect rsp data got=%h exp=%h", r[16:1], data);
      end
      if (r[33:29] !== 5'b00001) begin
        errors++; $display("ERROR: CCIX Cache Coherent Interconnect rsp opcode got=%b", r[33:29]);
      end
    end
  endtask

  initial begin
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(20) @(posedge clk);

    send_req(12'hA5A, 32'hDEAD_BEEF);
    expect_rsp(12'hA5A, 16'hBEEF);
    repeat(10) @(posedge clk);
    send_req(12'h123, 32'hCAFE_0001);
    expect_rsp(12'h123, 16'h0001);

    if (errors == 0) $display("TEST PASSED: CCIX Cache Coherent Interconnect");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #500_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")


CUSTOM["CXS CCIX Stream Interface"] = dict(
rtl="""// ============================================================================
// CXS simplified: CCIX streaming flit.
// Req flit 44b: {addr[31:0], txnID[11:0], opcode[7:0]... simplified:
//   [43:32]=txnID [31:0]=addr
// Rsp flit 34b: {[33:29]=opcode(5'b00001=OK) [28:17]=txnID [16:1]=data16
//               [0]=respValidTag}
// Credit-based flow control both directions. OpenCores chi / AMBA CHI spec
// (Issue A/B) simplified style.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module CXS_CCIX_Stream_Interface_top #(
  parameter int CRD_MAX  = 8,
  parameter int RSP_LAT  = 4
)(
  input  logic        clk,
  input  logic        rst_n,
  // request channel (from master into us)
  input  logic [43:0] txreqflit,
  input  logic        txreqflitv,
  output logic        txreqlcrdv,
  // response channel (from us to master)
  output logic [33:0] rxrspflit,
  output logic        rxrspflitv,
  input  logic        rxrsplcrdv,
  output logic        busy,
  output logic        irq
);
  // credits we grant to master (acceptance capacity)
  logic [3:0] rx_crd;
  // credits master grants us (for our responses)
  logic [3:0] tx_crd;
  logic [3:0] crd_timer;

  typedef enum logic [1:0] {C_IDLE, C_LAT, C_SEND} c_t;
  c_t         cstate;
  logic [43:0] req_q;
  logic [3:0]  lat_cnt;

  assign txreqlcrdv  = (crd_timer == 4'd0);
  assign rxrspflitv  = (cstate == C_SEND) && (tx_crd != 0);
  assign rxrspflit   = {5'b00001, req_q[43:32], req_q[15:0], 1'b1};
  assign busy        = (cstate != C_IDLE);
  assign irq         = (cstate == C_SEND) && (tx_crd != 0);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_crd <= CRD_MAX[3:0]; tx_crd <= '0; crd_timer <= '0;
      cstate <= C_IDLE; req_q <= '0; lat_cnt <= '0;
    end else begin
      // credit return to master (acceptance credit replenishment)
      if (txreqlcrdv) begin
        if (rx_crd < CRD_MAX[3:0]) rx_crd <= rx_crd + 1'b1;
        crd_timer <= 4'd7;
      end else crd_timer <= crd_timer - 1'b1;

      // master grants us response credit
      if (rxrsplcrdv && tx_crd < CRD_MAX[3:0]) tx_crd <= tx_crd + 1'b1;

      case (cstate)
        C_IDLE: if (txreqflitv && rx_crd != 0) begin
          req_q  <= txreqflit;
          rx_crd <= rx_crd - 1'b1;
          cstate <= C_LAT; lat_cnt <= RSP_LAT[3:0];
        end
        C_LAT: if (lat_cnt == 0) cstate <= C_SEND;
        else lat_cnt <= lat_cnt - 1'b1;
        C_SEND: if (tx_crd != 0) begin
          tx_crd <= tx_crd - 1'b1;
          cstate <= C_IDLE;
        end
        default: cstate <= C_IDLE;
      endcase
    end
  end

endmodule
""",
tb="""// Self-checking TB: master drives req flit with credits; checks rsp flit.
`timescale 1ns/1ps
module CXS_CCIX_Stream_Interface_tb;
  logic clk = 0, rst_n = 0;
  logic [43:0] txreqflit = '0;
  logic        txreqflitv = 0;
  logic        txreqlcrdv;
  logic [33:0] rxrspflit;
  logic        rxrspflitv;
  logic        rxrsplcrdv = 0;
  int errors = 0;

  CXS_CCIX_Stream_Interface_top dut (
    .clk(clk), .rst_n(rst_n),
    .txreqflit(txreqflit), .txreqflitv(txreqflitv), .txreqlcrdv(txreqlcrdv),
    .rxrspflit(rxrspflit), .rxrspflitv(rxrspflitv), .rxrsplcrdv(rxrsplcrdv),
    .busy(), .irq());

  always #5 clk = ~clk;

  // grant response credits periodically (master side)
  initial begin
    rxrsplcrdv = 0;
    repeat(4) @(posedge clk);
    forever begin
      repeat(8) @(posedge clk);
      rxrsplcrdv <= 1;
      @(posedge clk);
      rxrsplcrdv <= 0;
    end
  end

  task automatic send_req(input logic [11:0] txn, input logic [31:0] addr);
    begin
      // wait for an acceptance credit from the slave
      @(posedge clk);
      while (!txreqlcrdv) @(posedge clk);
      txreqflit  <= {txn, addr};
      txreqflitv <= 1'b1;
      @(posedge clk);
      txreqflitv <= 1'b0;
      txreqflit  <= '0;
    end
  endtask

  task automatic expect_rsp(input logic [11:0] txn, input logic [15:0] data);
    logic [33:0] r;
    begin
      r = '0;
      wait (rxrspflitv === 1'b1);
      @(posedge clk); #1;
      r = rxrspflit;
      if (r[28:17] !== txn) begin
        errors++; $display("ERROR: CXS CCIX Stream Interface rsp txn got=%h exp=%h", r[28:17], txn);
      end
      if (r[16:1] !== data) begin
        errors++; $display("ERROR: CXS CCIX Stream Interface rsp data got=%h exp=%h", r[16:1], data);
      end
      if (r[33:29] !== 5'b00001) begin
        errors++; $display("ERROR: CXS CCIX Stream Interface rsp opcode got=%b", r[33:29]);
      end
    end
  endtask

  initial begin
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(20) @(posedge clk);

    send_req(12'hA5A, 32'hDEAD_BEEF);
    expect_rsp(12'hA5A, 16'hBEEF);
    repeat(10) @(posedge clk);
    send_req(12'h123, 32'hCAFE_0001);
    expect_rsp(12'h123, 16'h0001);

    if (errors == 0) $display("TEST PASSED: CXS CCIX Stream Interface");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #500_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")


CUSTOM["ARM Local Translation Interface"] = dict(
rtl="""// ============================================================================
// LTI simplified: translation flit channel.
// Req flit 44b: {addr[31:0], txnID[11:0], opcode[7:0]... simplified:
//   [43:32]=txnID [31:0]=addr
// Rsp flit 34b: {[33:29]=opcode(5'b00001=OK) [28:17]=txnID [16:1]=data16
//               [0]=respValidTag}
// Credit-based flow control both directions. OpenCores chi / AMBA CHI spec
// (Issue A/B) simplified style.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module ARM_Local_Translation_Interface_top #(
  parameter int CRD_MAX  = 8,
  parameter int RSP_LAT  = 4
)(
  input  logic        clk,
  input  logic        rst_n,
  // request channel (from master into us)
  input  logic [43:0] txreqflit,
  input  logic        txreqflitv,
  output logic        txreqlcrdv,
  // response channel (from us to master)
  output logic [33:0] rxrspflit,
  output logic        rxrspflitv,
  input  logic        rxrsplcrdv,
  output logic        busy,
  output logic        irq
);
  // credits we grant to master (acceptance capacity)
  logic [3:0] rx_crd;
  // credits master grants us (for our responses)
  logic [3:0] tx_crd;
  logic [3:0] crd_timer;

  typedef enum logic [1:0] {C_IDLE, C_LAT, C_SEND} c_t;
  c_t         cstate;
  logic [43:0] req_q;
  logic [3:0]  lat_cnt;

  assign txreqlcrdv  = (crd_timer == 4'd0);
  assign rxrspflitv  = (cstate == C_SEND) && (tx_crd != 0);
  assign rxrspflit   = {5'b00001, req_q[43:32], req_q[15:0], 1'b1};
  assign busy        = (cstate != C_IDLE);
  assign irq         = (cstate == C_SEND) && (tx_crd != 0);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_crd <= CRD_MAX[3:0]; tx_crd <= '0; crd_timer <= '0;
      cstate <= C_IDLE; req_q <= '0; lat_cnt <= '0;
    end else begin
      // credit return to master (acceptance credit replenishment)
      if (txreqlcrdv) begin
        if (rx_crd < CRD_MAX[3:0]) rx_crd <= rx_crd + 1'b1;
        crd_timer <= 4'd7;
      end else crd_timer <= crd_timer - 1'b1;

      // master grants us response credit
      if (rxrsplcrdv && tx_crd < CRD_MAX[3:0]) tx_crd <= tx_crd + 1'b1;

      case (cstate)
        C_IDLE: if (txreqflitv && rx_crd != 0) begin
          req_q  <= txreqflit;
          rx_crd <= rx_crd - 1'b1;
          cstate <= C_LAT; lat_cnt <= RSP_LAT[3:0];
        end
        C_LAT: if (lat_cnt == 0) cstate <= C_SEND;
        else lat_cnt <= lat_cnt - 1'b1;
        C_SEND: if (tx_crd != 0) begin
          tx_crd <= tx_crd - 1'b1;
          cstate <= C_IDLE;
        end
        default: cstate <= C_IDLE;
      endcase
    end
  end

endmodule
""",
tb="""// Self-checking TB: master drives req flit with credits; checks rsp flit.
`timescale 1ns/1ps
module ARM_Local_Translation_Interface_tb;
  logic clk = 0, rst_n = 0;
  logic [43:0] txreqflit = '0;
  logic        txreqflitv = 0;
  logic        txreqlcrdv;
  logic [33:0] rxrspflit;
  logic        rxrspflitv;
  logic        rxrsplcrdv = 0;
  int errors = 0;

  ARM_Local_Translation_Interface_top dut (
    .clk(clk), .rst_n(rst_n),
    .txreqflit(txreqflit), .txreqflitv(txreqflitv), .txreqlcrdv(txreqlcrdv),
    .rxrspflit(rxrspflit), .rxrspflitv(rxrspflitv), .rxrsplcrdv(rxrsplcrdv),
    .busy(), .irq());

  always #5 clk = ~clk;

  // grant response credits periodically (master side)
  initial begin
    rxrsplcrdv = 0;
    repeat(4) @(posedge clk);
    forever begin
      repeat(8) @(posedge clk);
      rxrsplcrdv <= 1;
      @(posedge clk);
      rxrsplcrdv <= 0;
    end
  end

  task automatic send_req(input logic [11:0] txn, input logic [31:0] addr);
    begin
      // wait for an acceptance credit from the slave
      @(posedge clk);
      while (!txreqlcrdv) @(posedge clk);
      txreqflit  <= {txn, addr};
      txreqflitv <= 1'b1;
      @(posedge clk);
      txreqflitv <= 1'b0;
      txreqflit  <= '0;
    end
  endtask

  task automatic expect_rsp(input logic [11:0] txn, input logic [15:0] data);
    logic [33:0] r;
    begin
      r = '0;
      wait (rxrspflitv === 1'b1);
      @(posedge clk); #1;
      r = rxrspflit;
      if (r[28:17] !== txn) begin
        errors++; $display("ERROR: ARM Local Translation Interface rsp txn got=%h exp=%h", r[28:17], txn);
      end
      if (r[16:1] !== data) begin
        errors++; $display("ERROR: ARM Local Translation Interface rsp data got=%h exp=%h", r[16:1], data);
      end
      if (r[33:29] !== 5'b00001) begin
        errors++; $display("ERROR: ARM Local Translation Interface rsp opcode got=%b", r[33:29]);
      end
    end
  endtask

  initial begin
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(20) @(posedge clk);

    send_req(12'hA5A, 32'hDEAD_BEEF);
    expect_rsp(12'hA5A, 16'hBEEF);
    repeat(10) @(posedge clk);
    send_req(12'h123, 32'hCAFE_0001);
    expect_rsp(12'h123, 16'h0001);

    if (errors == 0) $display("TEST PASSED: ARM Local Translation Interface");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #500_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")


CUSTOM["Ethernet"] = dict(
rtl="""// ============================================================================
// Ethernet simplified: framed packet echo.
// Frame: START(1b 0) + STP + LEN + HDR[8] + payload(LEN-8) + CRC32 + END.
// Raw NRZ both ways; length-based framing; STP=0xFB, END=0xFD.
// Differential pair modeled single-ended. LCRC = zlib CRC32.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module Ethernet_top #(
  parameter int BAUD_DIV = 20,
  parameter int MAXB     = 8
)(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        refclk,
  input  logic        rx,
  output logic        tx,
  output logic        busy,
  output logic        irq
);
  localparam logic [7:0] STP = 8'hFB, END_B = 8'hFD;
  localparam int HB = 8;

  function automatic logic [31:0] crc32_u(input logic [31:0] c, input logic b);
    logic fb;
    begin fb = c[0]^b; crc32_u = c>>1; if (fb) crc32_u = crc32_u ^ 32'hEDB88320; end
  endfunction

  logic [15:0] tmr; logic phase;
  wire tick = (tmr == BAUD_DIV-1);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin tmr <= '0; phase <= 1'b0; end
    else if (tick) begin tmr <= '0; phase <= ~phase; end
    else tmr <= tmr + 1'b1;
  end

  // ---------------- TX (CAN-style field serializer) ----------------
  typedef enum logic [1:0] {T_IDLE, T_PKT, T_END} t_t;
  t_t          tstate;
  logic [7:0]  tx_shift;
  logic [31:0] tx_crc, crc_snap;
  logic [5:0]  tbit;
  logic [3:0]  tcur;
  logic [5:0]  tlen;
  logic [2:0]  tfld;           // 0=STP 1=LEN 2=HDR 3=DATA 4=CRC 5=END
  logic [7:0]  tx_mem [0:15];
  logic        tx_go, oe_q, out_q;
  logic [3:0]  ta_cnt; logic ta_arm;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tstate <= T_IDLE; tbit <= '0; tfld <= '0; tlen <= '0; tcur <= '0;
      tx_crc <= '0; crc_snap <= '0; tx_shift <= '0; tx_go <= 1'b0;
      oe_q <= 1'b0; out_q <= 1'b1; ta_cnt <= '0; ta_arm <= 1'b0;
    end else begin
      if (ta_cnt != 0 && tick) ta_cnt <= ta_cnt - 1'b1;
      if (ta_cnt == 0 && ta_arm) begin tx_go <= 1'b1; ta_arm <= 1'b0; end
      if (tick && !phase) begin
        case (tstate)
          T_IDLE: if (tx_go) begin
            tx_go <= 1'b0; oe_q <= 1'b1; out_q <= 1'b0;
            tbit <= '0; tfld <= '0;
            tstate <= T_PKT;
          end
          T_PKT: begin
            oe_q <= 1'b1;
            if (tfld == 3'd4) begin
              out_q    <= ~crc_snap[0];
              crc_snap <= crc_snap >> 1;
            end else begin
              out_q <= tx_shift[0];
              if (tfld == 3'd2 || tfld == 3'd3)
                tx_crc <= crc32_u(tx_crc, tx_shift[0]);
              tx_shift <= tx_shift >> 1;
            end
            if (tfld == 3'd4) begin
              if (tbit == 6'd31) begin tfld <= 3'd5; tbit <= '0; tx_shift <= END_B; end
              else tbit <= tbit + 1'b1;
            end else if (tbit == 6'd7) begin
              tbit <= '0;
              case (tfld)
                3'd0: begin tx_shift <= {2'b0, tlen}; tfld <= 3'd1; end
                3'd1: begin tx_shift <= tx_mem[0]; tfld <= 3'd2;
                            tx_crc <= 32'hFFFFFFFF; tcur <= '0; end
                3'd2: begin
                  if (tcur == 4'd7) begin tx_shift <= tx_mem[8]; tfld <= 3'd3; tcur <= 4'd8; end
                  else begin tcur <= tcur + 4'd1; tx_shift <= tx_mem[tcur + 4'd1]; end
                end
                3'd3: begin
                  if (tcur == (tlen[3:0] - 4'd1)) begin
                    tfld <= 3'd4;
                    crc_snap <= crc32_u(tx_crc, tx_shift[0]);
                  end
                  else begin tcur <= tcur + 4'd1; tx_shift <= tx_mem[tcur + 4'd1]; end
                end
                3'd5: tstate <= T_END;
                default: ;
              endcase
            end else tbit <= tbit + 1'b1;
          end
          T_END: begin oe_q <= 1'b0; out_q <= 1'b1; tstate <= T_IDLE; end
          default: tstate <= T_IDLE;
        endcase
      end
    end
  end

  assign tx   = oe_q ? out_q : 1'bz;
  assign busy = (rstate != R_IDLE) || (tstate != T_IDLE);

  // ---------------- RX (length-based framing, start-bit resync) ----------------
  typedef enum logic [1:0] {R_IDLE, R_BYTE} r_t;
  r_t          rstate;
  logic        rxs, rxs_d;
  logic        rtmr_en, rphase;
  logic [15:0] rtmr;
  logic [2:0]  rbitc;
  logic [7:0]  rsh;
  logic [5:0]  ridx;
  logic [5:0]  len_q;
  logic [7:0]  buf_mem [0:HB+MAXB+7];
  logic        rx_err, rx_done;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rxs <= 1'b1; rxs_d <= 1'b1; end
    else begin rxs <= rx; rxs_d <= rxs; end
  end
  wire start_edge = rxs_d & ~rxs;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rtmr_en <= 1'b0; rtmr <= '0; rphase <= 1'b0; end
    else begin
      if (rstate == R_IDLE && start_edge && tstate == T_IDLE) begin
        rtmr_en <= 1'b1; rtmr <= BAUD_DIV/2; rphase <= 1'b1;   // first sample = START bit (discarded)
      end else if (rtmr_en && (rtmr == BAUD_DIV-1)) begin
        rtmr <= '0; rphase <= ~rphase;
      end else if (rtmr_en) rtmr <= rtmr + 1'b1;
    end
  end
  wire rsample = rtmr_en && (rtmr == BAUD_DIV-1) && rphase;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rstate <= R_IDLE; rbitc <= '0; rsh <= '0; ridx <= '0; len_q <= '0;
      rx_err <= 1'b0; rx_done <= 1'b0; buf_mem[0] <= '0;
    end else begin
      rx_done <= 1'b0;
      if (rsample) begin
        case (rstate)
          R_IDLE: begin
            // this sample is the START bit: discard, begin STP at next sample
            rstate <= R_BYTE; rbitc <= '0; ridx <= '0; rsh <= '0;
          end
          R_BYTE: begin
            rsh <= {rxs, rsh[7:1]};
            if (rbitc == 3'd7) begin
              logic [7:0] nb; nb = {rxs, rsh[7:1]};
              if (ridx == 0) begin
                if (nb !== STP) rx_err <= 1'b1;
                ridx <= 1;
              end else if (ridx == 1) begin
                buf_mem[1] <= nb; len_q <= nb[5:0]; ridx <= 2;
              end else if (ridx == (6'd2 + len_q + 6'd4)) begin
                if (nb !== END_B) rx_err <= 1'b1;
                else begin
                  logic [31:0] c; c = 32'hFFFFFFFF;
                  for (int i = 2; i < HB + MAXB + 8; i++) begin
                    if (i <= 6'd1 + len_q)
                      for (int j = 0; j < 8; j++)
                        c = crc32_u(c, buf_mem[i][j]);
                  end
                  c = c ^ 32'hFFFFFFFF;
                  if ({buf_mem[6'd5+len_q], buf_mem[6'd4+len_q],
                       buf_mem[6'd3+len_q], buf_mem[6'd2+len_q]} !== c)
                    rx_err <= 1'b1;
                  else rx_done <= 1'b1;
                end
                rstate <= R_IDLE; ridx <= '0; rtmr_en <= 1'b0;
              end else begin
                buf_mem[ridx[5:0]] <= nb;
                ridx <= ridx + 6'd1;
              end
              rbitc <= '0;
            end else rbitc <= rbitc + 3'd1;
          end
          default: rstate <= R_IDLE;
        endcase
      end
    end
  end

  // echo: retransmit received content (HDR+payload identical frame)
  always_ff @(posedge clk) begin
    if (rx_done) begin
      tlen <= len_q;
      for (int i = 2; i < HB + MAXB + 6; i++)
        tx_mem[i-2] <= buf_mem[i];
      ta_cnt <= 4'd6; ta_arm <= 1'b1;
    end
  end

  assign irq = rx_done;

endmodule
""",
tb="""// PCIe TB: host sends TLP, device echoes, host verifies payload.
`timescale 1ns/1ps
module Ethernet_tb;
  localparam int BIT = 400;
  localparam int HB  = 8;
  logic clk = 0, rst_n = 0;
  logic host_val = 1'b1, host_oe = 1'b0;
  tri1  rx, tx;
  int errors = 0;

  Ethernet_top #(.BAUD_DIV(20)) dut (
    .clk(clk), .rst_n(rst_n), .refclk(clk), .rx(rx), .tx(tx), .busy(), .irq());
  always #5 clk = ~clk;
  assign rx = host_oe ? host_val : tx;

  function automatic logic [31:0] crc32(input logic [31:0] c, input logic b);
    logic fb; begin fb=c[0]^b; crc32=c>>1; if(fb) crc32=crc32^32'hEDB88320; end
  endfunction

  logic [7:0] hdr [0:7];
  logic [7:0] pl  [0:7];
  task automatic send_tlp(input int plen);
    logic [31:0] c; logic [7:0] fb;
    begin
      host_oe = 1; host_val = 1'b0; #(BIT);
      fb = 8'hFB; for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; #(BIT); end
      fb = HB + plen; for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; #(BIT); end
      c = 32'hFFFFFFFF;
      for (int i=0;i<HB;i++) begin
        fb = hdr[i];
        for (int j=0;j<8;j++) begin host_val=fb[0]; c=crc32(c,fb[0]); fb=fb>>1; #(BIT); end
      end
      for (int i=0;i<plen;i++) begin
        fb = pl[i];
        for (int j=0;j<8;j++) begin host_val=fb[0]; c=crc32(c,fb[0]); fb=fb>>1; #(BIT); end
      end
      c = ~c;
      for (int i=0;i<32;i++) begin host_val=c[0]; c=c>>1; #(BIT); end
      fb = 8'hFD; for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; #(BIT); end
      host_oe = 0;
    end
  endtask

  logic b; logic [7:0] sh;
  task automatic recv_tlp(output int plen);
    begin
      plen = 0; sh = 0;
      wait (tx === 1'b0);
      #(BIT + BIT/2);
      for (int i=0;i<8;i++) begin b=tx; sh={b,sh[7:1]}; #(BIT); end
      sh = 0;
      for (int i=0;i<8;i++) begin b=tx; sh={b,sh[7:1]}; if(i==7) plen = sh - HB; #(BIT); end
      for (int i=0;i<HB+plen;i++) begin
        sh = 0;
        for (int j=0;j<8;j++) begin
          b = tx; sh = {b, sh[7:1]};
          if (j == 7) begin
            if (i < HB) hdr[i] = sh;
            else        pl[i-HB] = sh;
          end
          #(BIT);
        end
      end
      #(BIT*40);
    end
  endtask

  int rlen;
  initial begin
    for (int i=0;i<8;i++) begin hdr[i] = 8'h10 + i; pl[i] = 8'hA0 + i * 8'h11; end
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(20) @(posedge clk);
    send_tlp(4);
    recv_tlp(rlen);
    if (rlen !== 4) begin errors++; $display("ERROR: Ethernet plen got=%0d exp=4", rlen); end
    for (int i=0;i<4;i++) begin
      if (pl[i] !== 8'hA0 + i * 8'h11) begin
        errors++; $display("ERROR: Ethernet pl[%0d] got=%h exp=%h", i, pl[i], 8'hA0 + i*8'h11);
      end
    end
    if (dut.rx_err !== 1'b0) begin errors++; $display("ERROR: Ethernet rx_err set"); end
    if (errors == 0) $display("TEST PASSED: Ethernet");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end
  initial begin #10_000_000; $display("TIMEOUT"); $finish; end
endmodule
""")

CUSTOM["FC"] = dict(
rtl="""// ============================================================================
// Fibre Channel simplified: framed echo.
// Frame: START(1b 0) + STP + LEN + HDR[8] + payload(LEN-8) + CRC32 + END.
// Raw NRZ both ways; length-based framing; STP=0xFB, END=0xFD.
// Differential pair modeled single-ended. LCRC = zlib CRC32.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module FC_top #(
  parameter int BAUD_DIV = 20,
  parameter int MAXB     = 8
)(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        refclk,
  input  logic        rx,
  output logic        tx,
  output logic        busy,
  output logic        irq
);
  localparam logic [7:0] STP = 8'hFB, END_B = 8'hFD;
  localparam int HB = 8;

  function automatic logic [31:0] crc32_u(input logic [31:0] c, input logic b);
    logic fb;
    begin fb = c[0]^b; crc32_u = c>>1; if (fb) crc32_u = crc32_u ^ 32'hEDB88320; end
  endfunction

  logic [15:0] tmr; logic phase;
  wire tick = (tmr == BAUD_DIV-1);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin tmr <= '0; phase <= 1'b0; end
    else if (tick) begin tmr <= '0; phase <= ~phase; end
    else tmr <= tmr + 1'b1;
  end

  // ---------------- TX (CAN-style field serializer) ----------------
  typedef enum logic [1:0] {T_IDLE, T_PKT, T_END} t_t;
  t_t          tstate;
  logic [7:0]  tx_shift;
  logic [31:0] tx_crc, crc_snap;
  logic [5:0]  tbit;
  logic [3:0]  tcur;
  logic [5:0]  tlen;
  logic [2:0]  tfld;           // 0=STP 1=LEN 2=HDR 3=DATA 4=CRC 5=END
  logic [7:0]  tx_mem [0:15];
  logic        tx_go, oe_q, out_q;
  logic [3:0]  ta_cnt; logic ta_arm;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tstate <= T_IDLE; tbit <= '0; tfld <= '0; tlen <= '0; tcur <= '0;
      tx_crc <= '0; crc_snap <= '0; tx_shift <= '0; tx_go <= 1'b0;
      oe_q <= 1'b0; out_q <= 1'b1; ta_cnt <= '0; ta_arm <= 1'b0;
    end else begin
      if (ta_cnt != 0 && tick) ta_cnt <= ta_cnt - 1'b1;
      if (ta_cnt == 0 && ta_arm) begin tx_go <= 1'b1; ta_arm <= 1'b0; end
      if (tick && !phase) begin
        case (tstate)
          T_IDLE: if (tx_go) begin
            tx_go <= 1'b0; oe_q <= 1'b1; out_q <= 1'b0;
            tbit <= '0; tfld <= '0;
            tstate <= T_PKT;
          end
          T_PKT: begin
            oe_q <= 1'b1;
            if (tfld == 3'd4) begin
              out_q    <= ~crc_snap[0];
              crc_snap <= crc_snap >> 1;
            end else begin
              out_q <= tx_shift[0];
              if (tfld == 3'd2 || tfld == 3'd3)
                tx_crc <= crc32_u(tx_crc, tx_shift[0]);
              tx_shift <= tx_shift >> 1;
            end
            if (tfld == 3'd4) begin
              if (tbit == 6'd31) begin tfld <= 3'd5; tbit <= '0; tx_shift <= END_B; end
              else tbit <= tbit + 1'b1;
            end else if (tbit == 6'd7) begin
              tbit <= '0;
              case (tfld)
                3'd0: begin tx_shift <= {2'b0, tlen}; tfld <= 3'd1; end
                3'd1: begin tx_shift <= tx_mem[0]; tfld <= 3'd2;
                            tx_crc <= 32'hFFFFFFFF; tcur <= '0; end
                3'd2: begin
                  if (tcur == 4'd7) begin tx_shift <= tx_mem[8]; tfld <= 3'd3; tcur <= 4'd8; end
                  else begin tcur <= tcur + 4'd1; tx_shift <= tx_mem[tcur + 4'd1]; end
                end
                3'd3: begin
                  if (tcur == (tlen[3:0] - 4'd1)) begin
                    tfld <= 3'd4;
                    crc_snap <= crc32_u(tx_crc, tx_shift[0]);
                  end
                  else begin tcur <= tcur + 4'd1; tx_shift <= tx_mem[tcur + 4'd1]; end
                end
                3'd5: tstate <= T_END;
                default: ;
              endcase
            end else tbit <= tbit + 1'b1;
          end
          T_END: begin oe_q <= 1'b0; out_q <= 1'b1; tstate <= T_IDLE; end
          default: tstate <= T_IDLE;
        endcase
      end
    end
  end

  assign tx   = oe_q ? out_q : 1'bz;
  assign busy = (rstate != R_IDLE) || (tstate != T_IDLE);

  // ---------------- RX (length-based framing, start-bit resync) ----------------
  typedef enum logic [1:0] {R_IDLE, R_BYTE} r_t;
  r_t          rstate;
  logic        rxs, rxs_d;
  logic        rtmr_en, rphase;
  logic [15:0] rtmr;
  logic [2:0]  rbitc;
  logic [7:0]  rsh;
  logic [5:0]  ridx;
  logic [5:0]  len_q;
  logic [7:0]  buf_mem [0:HB+MAXB+7];
  logic        rx_err, rx_done;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rxs <= 1'b1; rxs_d <= 1'b1; end
    else begin rxs <= rx; rxs_d <= rxs; end
  end
  wire start_edge = rxs_d & ~rxs;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rtmr_en <= 1'b0; rtmr <= '0; rphase <= 1'b0; end
    else begin
      if (rstate == R_IDLE && start_edge && tstate == T_IDLE) begin
        rtmr_en <= 1'b1; rtmr <= BAUD_DIV/2; rphase <= 1'b1;   // first sample = START bit (discarded)
      end else if (rtmr_en && (rtmr == BAUD_DIV-1)) begin
        rtmr <= '0; rphase <= ~rphase;
      end else if (rtmr_en) rtmr <= rtmr + 1'b1;
    end
  end
  wire rsample = rtmr_en && (rtmr == BAUD_DIV-1) && rphase;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rstate <= R_IDLE; rbitc <= '0; rsh <= '0; ridx <= '0; len_q <= '0;
      rx_err <= 1'b0; rx_done <= 1'b0; buf_mem[0] <= '0;
    end else begin
      rx_done <= 1'b0;
      if (rsample) begin
        case (rstate)
          R_IDLE: begin
            // this sample is the START bit: discard, begin STP at next sample
            rstate <= R_BYTE; rbitc <= '0; ridx <= '0; rsh <= '0;
          end
          R_BYTE: begin
            rsh <= {rxs, rsh[7:1]};
            if (rbitc == 3'd7) begin
              logic [7:0] nb; nb = {rxs, rsh[7:1]};
              if (ridx == 0) begin
                if (nb !== STP) rx_err <= 1'b1;
                ridx <= 1;
              end else if (ridx == 1) begin
                buf_mem[1] <= nb; len_q <= nb[5:0]; ridx <= 2;
              end else if (ridx == (6'd2 + len_q + 6'd4)) begin
                if (nb !== END_B) rx_err <= 1'b1;
                else begin
                  logic [31:0] c; c = 32'hFFFFFFFF;
                  for (int i = 2; i < HB + MAXB + 8; i++) begin
                    if (i <= 6'd1 + len_q)
                      for (int j = 0; j < 8; j++)
                        c = crc32_u(c, buf_mem[i][j]);
                  end
                  c = c ^ 32'hFFFFFFFF;
                  if ({buf_mem[6'd5+len_q], buf_mem[6'd4+len_q],
                       buf_mem[6'd3+len_q], buf_mem[6'd2+len_q]} !== c)
                    rx_err <= 1'b1;
                  else rx_done <= 1'b1;
                end
                rstate <= R_IDLE; ridx <= '0; rtmr_en <= 1'b0;
              end else begin
                buf_mem[ridx[5:0]] <= nb;
                ridx <= ridx + 6'd1;
              end
              rbitc <= '0;
            end else rbitc <= rbitc + 3'd1;
          end
          default: rstate <= R_IDLE;
        endcase
      end
    end
  end

  // echo: retransmit received content (HDR+payload identical frame)
  always_ff @(posedge clk) begin
    if (rx_done) begin
      tlen <= len_q;
      for (int i = 2; i < HB + MAXB + 6; i++)
        tx_mem[i-2] <= buf_mem[i];
      ta_cnt <= 4'd6; ta_arm <= 1'b1;
    end
  end

  assign irq = rx_done;

endmodule
""",
tb="""// PCIe TB: host sends TLP, device echoes, host verifies payload.
`timescale 1ns/1ps
module FC_tb;
  localparam int BIT = 400;
  localparam int HB  = 8;
  logic clk = 0, rst_n = 0;
  logic host_val = 1'b1, host_oe = 1'b0;
  tri1  rx, tx;
  int errors = 0;

  FC_top #(.BAUD_DIV(20)) dut (
    .clk(clk), .rst_n(rst_n), .refclk(clk), .rx(rx), .tx(tx), .busy(), .irq());
  always #5 clk = ~clk;
  assign rx = host_oe ? host_val : tx;

  function automatic logic [31:0] crc32(input logic [31:0] c, input logic b);
    logic fb; begin fb=c[0]^b; crc32=c>>1; if(fb) crc32=crc32^32'hEDB88320; end
  endfunction

  logic [7:0] hdr [0:7];
  logic [7:0] pl  [0:7];
  task automatic send_tlp(input int plen);
    logic [31:0] c; logic [7:0] fb;
    begin
      host_oe = 1; host_val = 1'b0; #(BIT);
      fb = 8'hFB; for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; #(BIT); end
      fb = HB + plen; for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; #(BIT); end
      c = 32'hFFFFFFFF;
      for (int i=0;i<HB;i++) begin
        fb = hdr[i];
        for (int j=0;j<8;j++) begin host_val=fb[0]; c=crc32(c,fb[0]); fb=fb>>1; #(BIT); end
      end
      for (int i=0;i<plen;i++) begin
        fb = pl[i];
        for (int j=0;j<8;j++) begin host_val=fb[0]; c=crc32(c,fb[0]); fb=fb>>1; #(BIT); end
      end
      c = ~c;
      for (int i=0;i<32;i++) begin host_val=c[0]; c=c>>1; #(BIT); end
      fb = 8'hFD; for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; #(BIT); end
      host_oe = 0;
    end
  endtask

  logic b; logic [7:0] sh;
  task automatic recv_tlp(output int plen);
    begin
      plen = 0; sh = 0;
      wait (tx === 1'b0);
      #(BIT + BIT/2);
      for (int i=0;i<8;i++) begin b=tx; sh={b,sh[7:1]}; #(BIT); end
      sh = 0;
      for (int i=0;i<8;i++) begin b=tx; sh={b,sh[7:1]}; if(i==7) plen = sh - HB; #(BIT); end
      for (int i=0;i<HB+plen;i++) begin
        sh = 0;
        for (int j=0;j<8;j++) begin
          b = tx; sh = {b, sh[7:1]};
          if (j == 7) begin
            if (i < HB) hdr[i] = sh;
            else        pl[i-HB] = sh;
          end
          #(BIT);
        end
      end
      #(BIT*40);
    end
  endtask

  int rlen;
  initial begin
    for (int i=0;i<8;i++) begin hdr[i] = 8'h10 + i; pl[i] = 8'hA0 + i * 8'h11; end
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(20) @(posedge clk);
    send_tlp(4);
    recv_tlp(rlen);
    if (rlen !== 4) begin errors++; $display("ERROR: FC plen got=%0d exp=4", rlen); end
    for (int i=0;i<4;i++) begin
      if (pl[i] !== 8'hA0 + i * 8'h11) begin
        errors++; $display("ERROR: FC pl[%0d] got=%h exp=%h", i, pl[i], 8'hA0 + i*8'h11);
      end
    end
    if (dut.rx_err !== 1'b0) begin errors++; $display("ERROR: FC rx_err set"); end
    if (errors == 0) $display("TEST PASSED: FC");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end
  initial begin #10_000_000; $display("TIMEOUT"); $finish; end
endmodule
""")

CUSTOM["UEC"] = dict(
rtl="""// ============================================================================
// UEC simplified: framed echo.
// Frame: START(1b 0) + STP + LEN + HDR[8] + payload(LEN-8) + CRC32 + END.
// Raw NRZ both ways; length-based framing; STP=0xFB, END=0xFD.
// Differential pair modeled single-ended. LCRC = zlib CRC32.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module UEC_top #(
  parameter int BAUD_DIV = 20,
  parameter int MAXB     = 8
)(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        refclk,
  input  logic        rx,
  output logic        tx,
  output logic        busy,
  output logic        irq
);
  localparam logic [7:0] STP = 8'hFB, END_B = 8'hFD;
  localparam int HB = 8;

  function automatic logic [31:0] crc32_u(input logic [31:0] c, input logic b);
    logic fb;
    begin fb = c[0]^b; crc32_u = c>>1; if (fb) crc32_u = crc32_u ^ 32'hEDB88320; end
  endfunction

  logic [15:0] tmr; logic phase;
  wire tick = (tmr == BAUD_DIV-1);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin tmr <= '0; phase <= 1'b0; end
    else if (tick) begin tmr <= '0; phase <= ~phase; end
    else tmr <= tmr + 1'b1;
  end

  // ---------------- TX (CAN-style field serializer) ----------------
  typedef enum logic [1:0] {T_IDLE, T_PKT, T_END} t_t;
  t_t          tstate;
  logic [7:0]  tx_shift;
  logic [31:0] tx_crc, crc_snap;
  logic [5:0]  tbit;
  logic [3:0]  tcur;
  logic [5:0]  tlen;
  logic [2:0]  tfld;           // 0=STP 1=LEN 2=HDR 3=DATA 4=CRC 5=END
  logic [7:0]  tx_mem [0:15];
  logic        tx_go, oe_q, out_q;
  logic [3:0]  ta_cnt; logic ta_arm;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tstate <= T_IDLE; tbit <= '0; tfld <= '0; tlen <= '0; tcur <= '0;
      tx_crc <= '0; crc_snap <= '0; tx_shift <= '0; tx_go <= 1'b0;
      oe_q <= 1'b0; out_q <= 1'b1; ta_cnt <= '0; ta_arm <= 1'b0;
    end else begin
      if (ta_cnt != 0 && tick) ta_cnt <= ta_cnt - 1'b1;
      if (ta_cnt == 0 && ta_arm) begin tx_go <= 1'b1; ta_arm <= 1'b0; end
      if (tick && !phase) begin
        case (tstate)
          T_IDLE: if (tx_go) begin
            tx_go <= 1'b0; oe_q <= 1'b1; out_q <= 1'b0;
            tbit <= '0; tfld <= '0;
            tstate <= T_PKT;
          end
          T_PKT: begin
            oe_q <= 1'b1;
            if (tfld == 3'd4) begin
              out_q    <= ~crc_snap[0];
              crc_snap <= crc_snap >> 1;
            end else begin
              out_q <= tx_shift[0];
              if (tfld == 3'd2 || tfld == 3'd3)
                tx_crc <= crc32_u(tx_crc, tx_shift[0]);
              tx_shift <= tx_shift >> 1;
            end
            if (tfld == 3'd4) begin
              if (tbit == 6'd31) begin tfld <= 3'd5; tbit <= '0; tx_shift <= END_B; end
              else tbit <= tbit + 1'b1;
            end else if (tbit == 6'd7) begin
              tbit <= '0;
              case (tfld)
                3'd0: begin tx_shift <= {2'b0, tlen}; tfld <= 3'd1; end
                3'd1: begin tx_shift <= tx_mem[0]; tfld <= 3'd2;
                            tx_crc <= 32'hFFFFFFFF; tcur <= '0; end
                3'd2: begin
                  if (tcur == 4'd7) begin tx_shift <= tx_mem[8]; tfld <= 3'd3; tcur <= 4'd8; end
                  else begin tcur <= tcur + 4'd1; tx_shift <= tx_mem[tcur + 4'd1]; end
                end
                3'd3: begin
                  if (tcur == (tlen[3:0] - 4'd1)) begin
                    tfld <= 3'd4;
                    crc_snap <= crc32_u(tx_crc, tx_shift[0]);
                  end
                  else begin tcur <= tcur + 4'd1; tx_shift <= tx_mem[tcur + 4'd1]; end
                end
                3'd5: tstate <= T_END;
                default: ;
              endcase
            end else tbit <= tbit + 1'b1;
          end
          T_END: begin oe_q <= 1'b0; out_q <= 1'b1; tstate <= T_IDLE; end
          default: tstate <= T_IDLE;
        endcase
      end
    end
  end

  assign tx   = oe_q ? out_q : 1'bz;
  assign busy = (rstate != R_IDLE) || (tstate != T_IDLE);

  // ---------------- RX (length-based framing, start-bit resync) ----------------
  typedef enum logic [1:0] {R_IDLE, R_BYTE} r_t;
  r_t          rstate;
  logic        rxs, rxs_d;
  logic        rtmr_en, rphase;
  logic [15:0] rtmr;
  logic [2:0]  rbitc;
  logic [7:0]  rsh;
  logic [5:0]  ridx;
  logic [5:0]  len_q;
  logic [7:0]  buf_mem [0:HB+MAXB+7];
  logic        rx_err, rx_done;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rxs <= 1'b1; rxs_d <= 1'b1; end
    else begin rxs <= rx; rxs_d <= rxs; end
  end
  wire start_edge = rxs_d & ~rxs;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rtmr_en <= 1'b0; rtmr <= '0; rphase <= 1'b0; end
    else begin
      if (rstate == R_IDLE && start_edge && tstate == T_IDLE) begin
        rtmr_en <= 1'b1; rtmr <= BAUD_DIV/2; rphase <= 1'b1;   // first sample = START bit (discarded)
      end else if (rtmr_en && (rtmr == BAUD_DIV-1)) begin
        rtmr <= '0; rphase <= ~rphase;
      end else if (rtmr_en) rtmr <= rtmr + 1'b1;
    end
  end
  wire rsample = rtmr_en && (rtmr == BAUD_DIV-1) && rphase;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rstate <= R_IDLE; rbitc <= '0; rsh <= '0; ridx <= '0; len_q <= '0;
      rx_err <= 1'b0; rx_done <= 1'b0; buf_mem[0] <= '0;
    end else begin
      rx_done <= 1'b0;
      if (rsample) begin
        case (rstate)
          R_IDLE: begin
            // this sample is the START bit: discard, begin STP at next sample
            rstate <= R_BYTE; rbitc <= '0; ridx <= '0; rsh <= '0;
          end
          R_BYTE: begin
            rsh <= {rxs, rsh[7:1]};
            if (rbitc == 3'd7) begin
              logic [7:0] nb; nb = {rxs, rsh[7:1]};
              if (ridx == 0) begin
                if (nb !== STP) rx_err <= 1'b1;
                ridx <= 1;
              end else if (ridx == 1) begin
                buf_mem[1] <= nb; len_q <= nb[5:0]; ridx <= 2;
              end else if (ridx == (6'd2 + len_q + 6'd4)) begin
                if (nb !== END_B) rx_err <= 1'b1;
                else begin
                  logic [31:0] c; c = 32'hFFFFFFFF;
                  for (int i = 2; i < HB + MAXB + 8; i++) begin
                    if (i <= 6'd1 + len_q)
                      for (int j = 0; j < 8; j++)
                        c = crc32_u(c, buf_mem[i][j]);
                  end
                  c = c ^ 32'hFFFFFFFF;
                  if ({buf_mem[6'd5+len_q], buf_mem[6'd4+len_q],
                       buf_mem[6'd3+len_q], buf_mem[6'd2+len_q]} !== c)
                    rx_err <= 1'b1;
                  else rx_done <= 1'b1;
                end
                rstate <= R_IDLE; ridx <= '0; rtmr_en <= 1'b0;
              end else begin
                buf_mem[ridx[5:0]] <= nb;
                ridx <= ridx + 6'd1;
              end
              rbitc <= '0;
            end else rbitc <= rbitc + 3'd1;
          end
          default: rstate <= R_IDLE;
        endcase
      end
    end
  end

  // echo: retransmit received content (HDR+payload identical frame)
  always_ff @(posedge clk) begin
    if (rx_done) begin
      tlen <= len_q;
      for (int i = 2; i < HB + MAXB + 6; i++)
        tx_mem[i-2] <= buf_mem[i];
      ta_cnt <= 4'd6; ta_arm <= 1'b1;
    end
  end

  assign irq = rx_done;

endmodule
""",
tb="""// PCIe TB: host sends TLP, device echoes, host verifies payload.
`timescale 1ns/1ps
module UEC_tb;
  localparam int BIT = 400;
  localparam int HB  = 8;
  logic clk = 0, rst_n = 0;
  logic host_val = 1'b1, host_oe = 1'b0;
  tri1  rx, tx;
  int errors = 0;

  UEC_top #(.BAUD_DIV(20)) dut (
    .clk(clk), .rst_n(rst_n), .refclk(clk), .rx(rx), .tx(tx), .busy(), .irq());
  always #5 clk = ~clk;
  assign rx = host_oe ? host_val : tx;

  function automatic logic [31:0] crc32(input logic [31:0] c, input logic b);
    logic fb; begin fb=c[0]^b; crc32=c>>1; if(fb) crc32=crc32^32'hEDB88320; end
  endfunction

  logic [7:0] hdr [0:7];
  logic [7:0] pl  [0:7];
  task automatic send_tlp(input int plen);
    logic [31:0] c; logic [7:0] fb;
    begin
      host_oe = 1; host_val = 1'b0; #(BIT);
      fb = 8'hFB; for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; #(BIT); end
      fb = HB + plen; for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; #(BIT); end
      c = 32'hFFFFFFFF;
      for (int i=0;i<HB;i++) begin
        fb = hdr[i];
        for (int j=0;j<8;j++) begin host_val=fb[0]; c=crc32(c,fb[0]); fb=fb>>1; #(BIT); end
      end
      for (int i=0;i<plen;i++) begin
        fb = pl[i];
        for (int j=0;j<8;j++) begin host_val=fb[0]; c=crc32(c,fb[0]); fb=fb>>1; #(BIT); end
      end
      c = ~c;
      for (int i=0;i<32;i++) begin host_val=c[0]; c=c>>1; #(BIT); end
      fb = 8'hFD; for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; #(BIT); end
      host_oe = 0;
    end
  endtask

  logic b; logic [7:0] sh;
  task automatic recv_tlp(output int plen);
    begin
      plen = 0; sh = 0;
      wait (tx === 1'b0);
      #(BIT + BIT/2);
      for (int i=0;i<8;i++) begin b=tx; sh={b,sh[7:1]}; #(BIT); end
      sh = 0;
      for (int i=0;i<8;i++) begin b=tx; sh={b,sh[7:1]}; if(i==7) plen = sh - HB; #(BIT); end
      for (int i=0;i<HB+plen;i++) begin
        sh = 0;
        for (int j=0;j<8;j++) begin
          b = tx; sh = {b, sh[7:1]};
          if (j == 7) begin
            if (i < HB) hdr[i] = sh;
            else        pl[i-HB] = sh;
          end
          #(BIT);
        end
      end
      #(BIT*40);
    end
  endtask

  int rlen;
  initial begin
    for (int i=0;i<8;i++) begin hdr[i] = 8'h10 + i; pl[i] = 8'hA0 + i * 8'h11; end
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(20) @(posedge clk);
    send_tlp(4);
    recv_tlp(rlen);
    if (rlen !== 4) begin errors++; $display("ERROR: UEC plen got=%0d exp=4", rlen); end
    for (int i=0;i<4;i++) begin
      if (pl[i] !== 8'hA0 + i * 8'h11) begin
        errors++; $display("ERROR: UEC pl[%0d] got=%h exp=%h", i, pl[i], 8'hA0 + i*8'h11);
      end
    end
    if (dut.rx_err !== 1'b0) begin errors++; $display("ERROR: UEC rx_err set"); end
    if (errors == 0) $display("TEST PASSED: UEC");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end
  initial begin #10_000_000; $display("TIMEOUT"); $finish; end
endmodule
""")

CUSTOM["Interlaken v1.2"] = dict(
rtl="""// ============================================================================
// Interlaken simplified: metaframe echo.
// Frame: START(1b 0) + STP + LEN + HDR[8] + payload(LEN-8) + CRC32 + END.
// Raw NRZ both ways; length-based framing; STP=0xFB, END=0xFD.
// Differential pair modeled single-ended. LCRC = zlib CRC32.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module Interlaken_v1_2_top #(
  parameter int BAUD_DIV = 20,
  parameter int MAXB     = 8
)(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        refclk,
  input  logic        rx,
  output logic        tx,
  output logic        busy,
  output logic        irq
);
  localparam logic [7:0] STP = 8'hFB, END_B = 8'hFD;
  localparam int HB = 8;

  function automatic logic [31:0] crc32_u(input logic [31:0] c, input logic b);
    logic fb;
    begin fb = c[0]^b; crc32_u = c>>1; if (fb) crc32_u = crc32_u ^ 32'hEDB88320; end
  endfunction

  logic [15:0] tmr; logic phase;
  wire tick = (tmr == BAUD_DIV-1);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin tmr <= '0; phase <= 1'b0; end
    else if (tick) begin tmr <= '0; phase <= ~phase; end
    else tmr <= tmr + 1'b1;
  end

  // ---------------- TX (CAN-style field serializer) ----------------
  typedef enum logic [1:0] {T_IDLE, T_PKT, T_END} t_t;
  t_t          tstate;
  logic [7:0]  tx_shift;
  logic [31:0] tx_crc, crc_snap;
  logic [5:0]  tbit;
  logic [3:0]  tcur;
  logic [5:0]  tlen;
  logic [2:0]  tfld;           // 0=STP 1=LEN 2=HDR 3=DATA 4=CRC 5=END
  logic [7:0]  tx_mem [0:15];
  logic        tx_go, oe_q, out_q;
  logic [3:0]  ta_cnt; logic ta_arm;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tstate <= T_IDLE; tbit <= '0; tfld <= '0; tlen <= '0; tcur <= '0;
      tx_crc <= '0; crc_snap <= '0; tx_shift <= '0; tx_go <= 1'b0;
      oe_q <= 1'b0; out_q <= 1'b1; ta_cnt <= '0; ta_arm <= 1'b0;
    end else begin
      if (ta_cnt != 0 && tick) ta_cnt <= ta_cnt - 1'b1;
      if (ta_cnt == 0 && ta_arm) begin tx_go <= 1'b1; ta_arm <= 1'b0; end
      if (tick && !phase) begin
        case (tstate)
          T_IDLE: if (tx_go) begin
            tx_go <= 1'b0; oe_q <= 1'b1; out_q <= 1'b0;
            tbit <= '0; tfld <= '0;
            tstate <= T_PKT;
          end
          T_PKT: begin
            oe_q <= 1'b1;
            if (tfld == 3'd4) begin
              out_q    <= ~crc_snap[0];
              crc_snap <= crc_snap >> 1;
            end else begin
              out_q <= tx_shift[0];
              if (tfld == 3'd2 || tfld == 3'd3)
                tx_crc <= crc32_u(tx_crc, tx_shift[0]);
              tx_shift <= tx_shift >> 1;
            end
            if (tfld == 3'd4) begin
              if (tbit == 6'd31) begin tfld <= 3'd5; tbit <= '0; tx_shift <= END_B; end
              else tbit <= tbit + 1'b1;
            end else if (tbit == 6'd7) begin
              tbit <= '0;
              case (tfld)
                3'd0: begin tx_shift <= {2'b0, tlen}; tfld <= 3'd1; end
                3'd1: begin tx_shift <= tx_mem[0]; tfld <= 3'd2;
                            tx_crc <= 32'hFFFFFFFF; tcur <= '0; end
                3'd2: begin
                  if (tcur == 4'd7) begin tx_shift <= tx_mem[8]; tfld <= 3'd3; tcur <= 4'd8; end
                  else begin tcur <= tcur + 4'd1; tx_shift <= tx_mem[tcur + 4'd1]; end
                end
                3'd3: begin
                  if (tcur == (tlen[3:0] - 4'd1)) begin
                    tfld <= 3'd4;
                    crc_snap <= crc32_u(tx_crc, tx_shift[0]);
                  end
                  else begin tcur <= tcur + 4'd1; tx_shift <= tx_mem[tcur + 4'd1]; end
                end
                3'd5: tstate <= T_END;
                default: ;
              endcase
            end else tbit <= tbit + 1'b1;
          end
          T_END: begin oe_q <= 1'b0; out_q <= 1'b1; tstate <= T_IDLE; end
          default: tstate <= T_IDLE;
        endcase
      end
    end
  end

  assign tx   = oe_q ? out_q : 1'bz;
  assign busy = (rstate != R_IDLE) || (tstate != T_IDLE);

  // ---------------- RX (length-based framing, start-bit resync) ----------------
  typedef enum logic [1:0] {R_IDLE, R_BYTE} r_t;
  r_t          rstate;
  logic        rxs, rxs_d;
  logic        rtmr_en, rphase;
  logic [15:0] rtmr;
  logic [2:0]  rbitc;
  logic [7:0]  rsh;
  logic [5:0]  ridx;
  logic [5:0]  len_q;
  logic [7:0]  buf_mem [0:HB+MAXB+7];
  logic        rx_err, rx_done;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rxs <= 1'b1; rxs_d <= 1'b1; end
    else begin rxs <= rx; rxs_d <= rxs; end
  end
  wire start_edge = rxs_d & ~rxs;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rtmr_en <= 1'b0; rtmr <= '0; rphase <= 1'b0; end
    else begin
      if (rstate == R_IDLE && start_edge && tstate == T_IDLE) begin
        rtmr_en <= 1'b1; rtmr <= BAUD_DIV/2; rphase <= 1'b1;   // first sample = START bit (discarded)
      end else if (rtmr_en && (rtmr == BAUD_DIV-1)) begin
        rtmr <= '0; rphase <= ~rphase;
      end else if (rtmr_en) rtmr <= rtmr + 1'b1;
    end
  end
  wire rsample = rtmr_en && (rtmr == BAUD_DIV-1) && rphase;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rstate <= R_IDLE; rbitc <= '0; rsh <= '0; ridx <= '0; len_q <= '0;
      rx_err <= 1'b0; rx_done <= 1'b0; buf_mem[0] <= '0;
    end else begin
      rx_done <= 1'b0;
      if (rsample) begin
        case (rstate)
          R_IDLE: begin
            // this sample is the START bit: discard, begin STP at next sample
            rstate <= R_BYTE; rbitc <= '0; ridx <= '0; rsh <= '0;
          end
          R_BYTE: begin
            rsh <= {rxs, rsh[7:1]};
            if (rbitc == 3'd7) begin
              logic [7:0] nb; nb = {rxs, rsh[7:1]};
              if (ridx == 0) begin
                if (nb !== STP) rx_err <= 1'b1;
                ridx <= 1;
              end else if (ridx == 1) begin
                buf_mem[1] <= nb; len_q <= nb[5:0]; ridx <= 2;
              end else if (ridx == (6'd2 + len_q + 6'd4)) begin
                if (nb !== END_B) rx_err <= 1'b1;
                else begin
                  logic [31:0] c; c = 32'hFFFFFFFF;
                  for (int i = 2; i < HB + MAXB + 8; i++) begin
                    if (i <= 6'd1 + len_q)
                      for (int j = 0; j < 8; j++)
                        c = crc32_u(c, buf_mem[i][j]);
                  end
                  c = c ^ 32'hFFFFFFFF;
                  if ({buf_mem[6'd5+len_q], buf_mem[6'd4+len_q],
                       buf_mem[6'd3+len_q], buf_mem[6'd2+len_q]} !== c)
                    rx_err <= 1'b1;
                  else rx_done <= 1'b1;
                end
                rstate <= R_IDLE; ridx <= '0; rtmr_en <= 1'b0;
              end else begin
                buf_mem[ridx[5:0]] <= nb;
                ridx <= ridx + 6'd1;
              end
              rbitc <= '0;
            end else rbitc <= rbitc + 3'd1;
          end
          default: rstate <= R_IDLE;
        endcase
      end
    end
  end

  // echo: retransmit received content (HDR+payload identical frame)
  always_ff @(posedge clk) begin
    if (rx_done) begin
      tlen <= len_q;
      for (int i = 2; i < HB + MAXB + 6; i++)
        tx_mem[i-2] <= buf_mem[i];
      ta_cnt <= 4'd6; ta_arm <= 1'b1;
    end
  end

  assign irq = rx_done;

endmodule
""",
tb="""// PCIe TB: host sends TLP, device echoes, host verifies payload.
`timescale 1ns/1ps
module Interlaken_v1_2_tb;
  localparam int BIT = 400;
  localparam int HB  = 8;
  logic clk = 0, rst_n = 0;
  logic host_val = 1'b1, host_oe = 1'b0;
  tri1  rx, tx;
  int errors = 0;

  Interlaken_v1_2_top #(.BAUD_DIV(20)) dut (
    .clk(clk), .rst_n(rst_n), .refclk(clk), .rx(rx), .tx(tx), .busy(), .irq());
  always #5 clk = ~clk;
  assign rx = host_oe ? host_val : tx;

  function automatic logic [31:0] crc32(input logic [31:0] c, input logic b);
    logic fb; begin fb=c[0]^b; crc32=c>>1; if(fb) crc32=crc32^32'hEDB88320; end
  endfunction

  logic [7:0] hdr [0:7];
  logic [7:0] pl  [0:7];
  task automatic send_tlp(input int plen);
    logic [31:0] c; logic [7:0] fb;
    begin
      host_oe = 1; host_val = 1'b0; #(BIT);
      fb = 8'hFB; for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; #(BIT); end
      fb = HB + plen; for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; #(BIT); end
      c = 32'hFFFFFFFF;
      for (int i=0;i<HB;i++) begin
        fb = hdr[i];
        for (int j=0;j<8;j++) begin host_val=fb[0]; c=crc32(c,fb[0]); fb=fb>>1; #(BIT); end
      end
      for (int i=0;i<plen;i++) begin
        fb = pl[i];
        for (int j=0;j<8;j++) begin host_val=fb[0]; c=crc32(c,fb[0]); fb=fb>>1; #(BIT); end
      end
      c = ~c;
      for (int i=0;i<32;i++) begin host_val=c[0]; c=c>>1; #(BIT); end
      fb = 8'hFD; for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; #(BIT); end
      host_oe = 0;
    end
  endtask

  logic b; logic [7:0] sh;
  task automatic recv_tlp(output int plen);
    begin
      plen = 0; sh = 0;
      wait (tx === 1'b0);
      #(BIT + BIT/2);
      for (int i=0;i<8;i++) begin b=tx; sh={b,sh[7:1]}; #(BIT); end
      sh = 0;
      for (int i=0;i<8;i++) begin b=tx; sh={b,sh[7:1]}; if(i==7) plen = sh - HB; #(BIT); end
      for (int i=0;i<HB+plen;i++) begin
        sh = 0;
        for (int j=0;j<8;j++) begin
          b = tx; sh = {b, sh[7:1]};
          if (j == 7) begin
            if (i < HB) hdr[i] = sh;
            else        pl[i-HB] = sh;
          end
          #(BIT);
        end
      end
      #(BIT*40);
    end
  endtask

  int rlen;
  initial begin
    for (int i=0;i<8;i++) begin hdr[i] = 8'h10 + i; pl[i] = 8'hA0 + i * 8'h11; end
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(20) @(posedge clk);
    send_tlp(4);
    recv_tlp(rlen);
    if (rlen !== 4) begin errors++; $display("ERROR: Interlaken v1.2 plen got=%0d exp=4", rlen); end
    for (int i=0;i<4;i++) begin
      if (pl[i] !== 8'hA0 + i * 8'h11) begin
        errors++; $display("ERROR: Interlaken v1.2 pl[%0d] got=%h exp=%h", i, pl[i], 8'hA0 + i*8'h11);
      end
    end
    if (dut.rx_err !== 1'b0) begin errors++; $display("ERROR: Interlaken v1.2 rx_err set"); end
    if (errors == 0) $display("TEST PASSED: Interlaken v1.2");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end
  initial begin #10_000_000; $display("TIMEOUT"); $finish; end
endmodule
""")

CUSTOM["JESD204C"] = dict(
rtl="""// ============================================================================
// JESD204C simplified: framed sample echo.
// Frame: START(1b 0) + STP + LEN + HDR[8] + payload(LEN-8) + CRC32 + END.
// Raw NRZ both ways; length-based framing; STP=0xFB, END=0xFD.
// Differential pair modeled single-ended. LCRC = zlib CRC32.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module JESD204C_top #(
  parameter int BAUD_DIV = 20,
  parameter int MAXB     = 8
)(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        refclk,
  input  logic        rx,
  output logic        tx,
  output logic        busy,
  output logic        irq
);
  localparam logic [7:0] STP = 8'hFB, END_B = 8'hFD;
  localparam int HB = 8;

  function automatic logic [31:0] crc32_u(input logic [31:0] c, input logic b);
    logic fb;
    begin fb = c[0]^b; crc32_u = c>>1; if (fb) crc32_u = crc32_u ^ 32'hEDB88320; end
  endfunction

  logic [15:0] tmr; logic phase;
  wire tick = (tmr == BAUD_DIV-1);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin tmr <= '0; phase <= 1'b0; end
    else if (tick) begin tmr <= '0; phase <= ~phase; end
    else tmr <= tmr + 1'b1;
  end

  // ---------------- TX (CAN-style field serializer) ----------------
  typedef enum logic [1:0] {T_IDLE, T_PKT, T_END} t_t;
  t_t          tstate;
  logic [7:0]  tx_shift;
  logic [31:0] tx_crc, crc_snap;
  logic [5:0]  tbit;
  logic [3:0]  tcur;
  logic [5:0]  tlen;
  logic [2:0]  tfld;           // 0=STP 1=LEN 2=HDR 3=DATA 4=CRC 5=END
  logic [7:0]  tx_mem [0:15];
  logic        tx_go, oe_q, out_q;
  logic [3:0]  ta_cnt; logic ta_arm;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tstate <= T_IDLE; tbit <= '0; tfld <= '0; tlen <= '0; tcur <= '0;
      tx_crc <= '0; crc_snap <= '0; tx_shift <= '0; tx_go <= 1'b0;
      oe_q <= 1'b0; out_q <= 1'b1; ta_cnt <= '0; ta_arm <= 1'b0;
    end else begin
      if (ta_cnt != 0 && tick) ta_cnt <= ta_cnt - 1'b1;
      if (ta_cnt == 0 && ta_arm) begin tx_go <= 1'b1; ta_arm <= 1'b0; end
      if (tick && !phase) begin
        case (tstate)
          T_IDLE: if (tx_go) begin
            tx_go <= 1'b0; oe_q <= 1'b1; out_q <= 1'b0;
            tbit <= '0; tfld <= '0;
            tstate <= T_PKT;
          end
          T_PKT: begin
            oe_q <= 1'b1;
            if (tfld == 3'd4) begin
              out_q    <= ~crc_snap[0];
              crc_snap <= crc_snap >> 1;
            end else begin
              out_q <= tx_shift[0];
              if (tfld == 3'd2 || tfld == 3'd3)
                tx_crc <= crc32_u(tx_crc, tx_shift[0]);
              tx_shift <= tx_shift >> 1;
            end
            if (tfld == 3'd4) begin
              if (tbit == 6'd31) begin tfld <= 3'd5; tbit <= '0; tx_shift <= END_B; end
              else tbit <= tbit + 1'b1;
            end else if (tbit == 6'd7) begin
              tbit <= '0;
              case (tfld)
                3'd0: begin tx_shift <= {2'b0, tlen}; tfld <= 3'd1; end
                3'd1: begin tx_shift <= tx_mem[0]; tfld <= 3'd2;
                            tx_crc <= 32'hFFFFFFFF; tcur <= '0; end
                3'd2: begin
                  if (tcur == 4'd7) begin tx_shift <= tx_mem[8]; tfld <= 3'd3; tcur <= 4'd8; end
                  else begin tcur <= tcur + 4'd1; tx_shift <= tx_mem[tcur + 4'd1]; end
                end
                3'd3: begin
                  if (tcur == (tlen[3:0] - 4'd1)) begin
                    tfld <= 3'd4;
                    crc_snap <= crc32_u(tx_crc, tx_shift[0]);
                  end
                  else begin tcur <= tcur + 4'd1; tx_shift <= tx_mem[tcur + 4'd1]; end
                end
                3'd5: tstate <= T_END;
                default: ;
              endcase
            end else tbit <= tbit + 1'b1;
          end
          T_END: begin oe_q <= 1'b0; out_q <= 1'b1; tstate <= T_IDLE; end
          default: tstate <= T_IDLE;
        endcase
      end
    end
  end

  assign tx   = oe_q ? out_q : 1'bz;
  assign busy = (rstate != R_IDLE) || (tstate != T_IDLE);

  // ---------------- RX (length-based framing, start-bit resync) ----------------
  typedef enum logic [1:0] {R_IDLE, R_BYTE} r_t;
  r_t          rstate;
  logic        rxs, rxs_d;
  logic        rtmr_en, rphase;
  logic [15:0] rtmr;
  logic [2:0]  rbitc;
  logic [7:0]  rsh;
  logic [5:0]  ridx;
  logic [5:0]  len_q;
  logic [7:0]  buf_mem [0:HB+MAXB+7];
  logic        rx_err, rx_done;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rxs <= 1'b1; rxs_d <= 1'b1; end
    else begin rxs <= rx; rxs_d <= rxs; end
  end
  wire start_edge = rxs_d & ~rxs;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rtmr_en <= 1'b0; rtmr <= '0; rphase <= 1'b0; end
    else begin
      if (rstate == R_IDLE && start_edge && tstate == T_IDLE) begin
        rtmr_en <= 1'b1; rtmr <= BAUD_DIV/2; rphase <= 1'b1;   // first sample = START bit (discarded)
      end else if (rtmr_en && (rtmr == BAUD_DIV-1)) begin
        rtmr <= '0; rphase <= ~rphase;
      end else if (rtmr_en) rtmr <= rtmr + 1'b1;
    end
  end
  wire rsample = rtmr_en && (rtmr == BAUD_DIV-1) && rphase;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rstate <= R_IDLE; rbitc <= '0; rsh <= '0; ridx <= '0; len_q <= '0;
      rx_err <= 1'b0; rx_done <= 1'b0; buf_mem[0] <= '0;
    end else begin
      rx_done <= 1'b0;
      if (rsample) begin
        case (rstate)
          R_IDLE: begin
            // this sample is the START bit: discard, begin STP at next sample
            rstate <= R_BYTE; rbitc <= '0; ridx <= '0; rsh <= '0;
          end
          R_BYTE: begin
            rsh <= {rxs, rsh[7:1]};
            if (rbitc == 3'd7) begin
              logic [7:0] nb; nb = {rxs, rsh[7:1]};
              if (ridx == 0) begin
                if (nb !== STP) rx_err <= 1'b1;
                ridx <= 1;
              end else if (ridx == 1) begin
                buf_mem[1] <= nb; len_q <= nb[5:0]; ridx <= 2;
              end else if (ridx == (6'd2 + len_q + 6'd4)) begin
                if (nb !== END_B) rx_err <= 1'b1;
                else begin
                  logic [31:0] c; c = 32'hFFFFFFFF;
                  for (int i = 2; i < HB + MAXB + 8; i++) begin
                    if (i <= 6'd1 + len_q)
                      for (int j = 0; j < 8; j++)
                        c = crc32_u(c, buf_mem[i][j]);
                  end
                  c = c ^ 32'hFFFFFFFF;
                  if ({buf_mem[6'd5+len_q], buf_mem[6'd4+len_q],
                       buf_mem[6'd3+len_q], buf_mem[6'd2+len_q]} !== c)
                    rx_err <= 1'b1;
                  else rx_done <= 1'b1;
                end
                rstate <= R_IDLE; ridx <= '0; rtmr_en <= 1'b0;
              end else begin
                buf_mem[ridx[5:0]] <= nb;
                ridx <= ridx + 6'd1;
              end
              rbitc <= '0;
            end else rbitc <= rbitc + 3'd1;
          end
          default: rstate <= R_IDLE;
        endcase
      end
    end
  end

  // echo: retransmit received content (HDR+payload identical frame)
  always_ff @(posedge clk) begin
    if (rx_done) begin
      tlen <= len_q;
      for (int i = 2; i < HB + MAXB + 6; i++)
        tx_mem[i-2] <= buf_mem[i];
      ta_cnt <= 4'd6; ta_arm <= 1'b1;
    end
  end

  assign irq = rx_done;

endmodule
""",
tb="""// PCIe TB: host sends TLP, device echoes, host verifies payload.
`timescale 1ns/1ps
module JESD204C_tb;
  localparam int BIT = 400;
  localparam int HB  = 8;
  logic clk = 0, rst_n = 0;
  logic host_val = 1'b1, host_oe = 1'b0;
  tri1  rx, tx;
  int errors = 0;

  JESD204C_top #(.BAUD_DIV(20)) dut (
    .clk(clk), .rst_n(rst_n), .refclk(clk), .rx(rx), .tx(tx), .busy(), .irq());
  always #5 clk = ~clk;
  assign rx = host_oe ? host_val : tx;

  function automatic logic [31:0] crc32(input logic [31:0] c, input logic b);
    logic fb; begin fb=c[0]^b; crc32=c>>1; if(fb) crc32=crc32^32'hEDB88320; end
  endfunction

  logic [7:0] hdr [0:7];
  logic [7:0] pl  [0:7];
  task automatic send_tlp(input int plen);
    logic [31:0] c; logic [7:0] fb;
    begin
      host_oe = 1; host_val = 1'b0; #(BIT);
      fb = 8'hFB; for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; #(BIT); end
      fb = HB + plen; for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; #(BIT); end
      c = 32'hFFFFFFFF;
      for (int i=0;i<HB;i++) begin
        fb = hdr[i];
        for (int j=0;j<8;j++) begin host_val=fb[0]; c=crc32(c,fb[0]); fb=fb>>1; #(BIT); end
      end
      for (int i=0;i<plen;i++) begin
        fb = pl[i];
        for (int j=0;j<8;j++) begin host_val=fb[0]; c=crc32(c,fb[0]); fb=fb>>1; #(BIT); end
      end
      c = ~c;
      for (int i=0;i<32;i++) begin host_val=c[0]; c=c>>1; #(BIT); end
      fb = 8'hFD; for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; #(BIT); end
      host_oe = 0;
    end
  endtask

  logic b; logic [7:0] sh;
  task automatic recv_tlp(output int plen);
    begin
      plen = 0; sh = 0;
      wait (tx === 1'b0);
      #(BIT + BIT/2);
      for (int i=0;i<8;i++) begin b=tx; sh={b,sh[7:1]}; #(BIT); end
      sh = 0;
      for (int i=0;i<8;i++) begin b=tx; sh={b,sh[7:1]}; if(i==7) plen = sh - HB; #(BIT); end
      for (int i=0;i<HB+plen;i++) begin
        sh = 0;
        for (int j=0;j<8;j++) begin
          b = tx; sh = {b, sh[7:1]};
          if (j == 7) begin
            if (i < HB) hdr[i] = sh;
            else        pl[i-HB] = sh;
          end
          #(BIT);
        end
      end
      #(BIT*40);
    end
  endtask

  int rlen;
  initial begin
    for (int i=0;i<8;i++) begin hdr[i] = 8'h10 + i; pl[i] = 8'hA0 + i * 8'h11; end
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(20) @(posedge clk);
    send_tlp(4);
    recv_tlp(rlen);
    if (rlen !== 4) begin errors++; $display("ERROR: JESD204C plen got=%0d exp=4", rlen); end
    for (int i=0;i<4;i++) begin
      if (pl[i] !== 8'hA0 + i * 8'h11) begin
        errors++; $display("ERROR: JESD204C pl[%0d] got=%h exp=%h", i, pl[i], 8'hA0 + i*8'h11);
      end
    end
    if (dut.rx_err !== 1'b0) begin errors++; $display("ERROR: JESD204C rx_err set"); end
    if (errors == 0) $display("TEST PASSED: JESD204C");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end
  initial begin #10_000_000; $display("TIMEOUT"); $finish; end
endmodule
""")

CUSTOM["NVMe"] = dict(
rtl="""// ============================================================================
// NVMe simplified: framed command echo.
// Frame: START(1b 0) + STP + LEN + HDR[8] + payload(LEN-8) + CRC32 + END.
// Raw NRZ both ways; length-based framing; STP=0xFB, END=0xFD.
// Differential pair modeled single-ended. LCRC = zlib CRC32.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module NVMe_top #(
  parameter int BAUD_DIV = 20,
  parameter int MAXB     = 8
)(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        refclk,
  input  logic        rx,
  output logic        tx,
  output logic        busy,
  output logic        irq
);
  localparam logic [7:0] STP = 8'hFB, END_B = 8'hFD;
  localparam int HB = 8;

  function automatic logic [31:0] crc32_u(input logic [31:0] c, input logic b);
    logic fb;
    begin fb = c[0]^b; crc32_u = c>>1; if (fb) crc32_u = crc32_u ^ 32'hEDB88320; end
  endfunction

  logic [15:0] tmr; logic phase;
  wire tick = (tmr == BAUD_DIV-1);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin tmr <= '0; phase <= 1'b0; end
    else if (tick) begin tmr <= '0; phase <= ~phase; end
    else tmr <= tmr + 1'b1;
  end

  // ---------------- TX (CAN-style field serializer) ----------------
  typedef enum logic [1:0] {T_IDLE, T_PKT, T_END} t_t;
  t_t          tstate;
  logic [7:0]  tx_shift;
  logic [31:0] tx_crc, crc_snap;
  logic [5:0]  tbit;
  logic [3:0]  tcur;
  logic [5:0]  tlen;
  logic [2:0]  tfld;           // 0=STP 1=LEN 2=HDR 3=DATA 4=CRC 5=END
  logic [7:0]  tx_mem [0:15];
  logic        tx_go, oe_q, out_q;
  logic [3:0]  ta_cnt; logic ta_arm;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tstate <= T_IDLE; tbit <= '0; tfld <= '0; tlen <= '0; tcur <= '0;
      tx_crc <= '0; crc_snap <= '0; tx_shift <= '0; tx_go <= 1'b0;
      oe_q <= 1'b0; out_q <= 1'b1; ta_cnt <= '0; ta_arm <= 1'b0;
    end else begin
      if (ta_cnt != 0 && tick) ta_cnt <= ta_cnt - 1'b1;
      if (ta_cnt == 0 && ta_arm) begin tx_go <= 1'b1; ta_arm <= 1'b0; end
      if (tick && !phase) begin
        case (tstate)
          T_IDLE: if (tx_go) begin
            tx_go <= 1'b0; oe_q <= 1'b1; out_q <= 1'b0;
            tbit <= '0; tfld <= '0;
            tstate <= T_PKT;
          end
          T_PKT: begin
            oe_q <= 1'b1;
            if (tfld == 3'd4) begin
              out_q    <= ~crc_snap[0];
              crc_snap <= crc_snap >> 1;
            end else begin
              out_q <= tx_shift[0];
              if (tfld == 3'd2 || tfld == 3'd3)
                tx_crc <= crc32_u(tx_crc, tx_shift[0]);
              tx_shift <= tx_shift >> 1;
            end
            if (tfld == 3'd4) begin
              if (tbit == 6'd31) begin tfld <= 3'd5; tbit <= '0; tx_shift <= END_B; end
              else tbit <= tbit + 1'b1;
            end else if (tbit == 6'd7) begin
              tbit <= '0;
              case (tfld)
                3'd0: begin tx_shift <= {2'b0, tlen}; tfld <= 3'd1; end
                3'd1: begin tx_shift <= tx_mem[0]; tfld <= 3'd2;
                            tx_crc <= 32'hFFFFFFFF; tcur <= '0; end
                3'd2: begin
                  if (tcur == 4'd7) begin tx_shift <= tx_mem[8]; tfld <= 3'd3; tcur <= 4'd8; end
                  else begin tcur <= tcur + 4'd1; tx_shift <= tx_mem[tcur + 4'd1]; end
                end
                3'd3: begin
                  if (tcur == (tlen[3:0] - 4'd1)) begin
                    tfld <= 3'd4;
                    crc_snap <= crc32_u(tx_crc, tx_shift[0]);
                  end
                  else begin tcur <= tcur + 4'd1; tx_shift <= tx_mem[tcur + 4'd1]; end
                end
                3'd5: tstate <= T_END;
                default: ;
              endcase
            end else tbit <= tbit + 1'b1;
          end
          T_END: begin oe_q <= 1'b0; out_q <= 1'b1; tstate <= T_IDLE; end
          default: tstate <= T_IDLE;
        endcase
      end
    end
  end

  assign tx   = oe_q ? out_q : 1'bz;
  assign busy = (rstate != R_IDLE) || (tstate != T_IDLE);

  // ---------------- RX (length-based framing, start-bit resync) ----------------
  typedef enum logic [1:0] {R_IDLE, R_BYTE} r_t;
  r_t          rstate;
  logic        rxs, rxs_d;
  logic        rtmr_en, rphase;
  logic [15:0] rtmr;
  logic [2:0]  rbitc;
  logic [7:0]  rsh;
  logic [5:0]  ridx;
  logic [5:0]  len_q;
  logic [7:0]  buf_mem [0:HB+MAXB+7];
  logic        rx_err, rx_done;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rxs <= 1'b1; rxs_d <= 1'b1; end
    else begin rxs <= rx; rxs_d <= rxs; end
  end
  wire start_edge = rxs_d & ~rxs;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rtmr_en <= 1'b0; rtmr <= '0; rphase <= 1'b0; end
    else begin
      if (rstate == R_IDLE && start_edge && tstate == T_IDLE) begin
        rtmr_en <= 1'b1; rtmr <= BAUD_DIV/2; rphase <= 1'b1;   // first sample = START bit (discarded)
      end else if (rtmr_en && (rtmr == BAUD_DIV-1)) begin
        rtmr <= '0; rphase <= ~rphase;
      end else if (rtmr_en) rtmr <= rtmr + 1'b1;
    end
  end
  wire rsample = rtmr_en && (rtmr == BAUD_DIV-1) && rphase;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rstate <= R_IDLE; rbitc <= '0; rsh <= '0; ridx <= '0; len_q <= '0;
      rx_err <= 1'b0; rx_done <= 1'b0; buf_mem[0] <= '0;
    end else begin
      rx_done <= 1'b0;
      if (rsample) begin
        case (rstate)
          R_IDLE: begin
            // this sample is the START bit: discard, begin STP at next sample
            rstate <= R_BYTE; rbitc <= '0; ridx <= '0; rsh <= '0;
          end
          R_BYTE: begin
            rsh <= {rxs, rsh[7:1]};
            if (rbitc == 3'd7) begin
              logic [7:0] nb; nb = {rxs, rsh[7:1]};
              if (ridx == 0) begin
                if (nb !== STP) rx_err <= 1'b1;
                ridx <= 1;
              end else if (ridx == 1) begin
                buf_mem[1] <= nb; len_q <= nb[5:0]; ridx <= 2;
              end else if (ridx == (6'd2 + len_q + 6'd4)) begin
                if (nb !== END_B) rx_err <= 1'b1;
                else begin
                  logic [31:0] c; c = 32'hFFFFFFFF;
                  for (int i = 2; i < HB + MAXB + 8; i++) begin
                    if (i <= 6'd1 + len_q)
                      for (int j = 0; j < 8; j++)
                        c = crc32_u(c, buf_mem[i][j]);
                  end
                  c = c ^ 32'hFFFFFFFF;
                  if ({buf_mem[6'd5+len_q], buf_mem[6'd4+len_q],
                       buf_mem[6'd3+len_q], buf_mem[6'd2+len_q]} !== c)
                    rx_err <= 1'b1;
                  else rx_done <= 1'b1;
                end
                rstate <= R_IDLE; ridx <= '0; rtmr_en <= 1'b0;
              end else begin
                buf_mem[ridx[5:0]] <= nb;
                ridx <= ridx + 6'd1;
              end
              rbitc <= '0;
            end else rbitc <= rbitc + 3'd1;
          end
          default: rstate <= R_IDLE;
        endcase
      end
    end
  end

  // echo: retransmit received content (HDR+payload identical frame)
  always_ff @(posedge clk) begin
    if (rx_done) begin
      tlen <= len_q;
      for (int i = 2; i < HB + MAXB + 6; i++)
        tx_mem[i-2] <= buf_mem[i];
      ta_cnt <= 4'd6; ta_arm <= 1'b1;
    end
  end

  assign irq = rx_done;

endmodule
""",
tb="""// PCIe TB: host sends TLP, device echoes, host verifies payload.
`timescale 1ns/1ps
module NVMe_tb;
  localparam int BIT = 400;
  localparam int HB  = 8;
  logic clk = 0, rst_n = 0;
  logic host_val = 1'b1, host_oe = 1'b0;
  tri1  rx, tx;
  int errors = 0;

  NVMe_top #(.BAUD_DIV(20)) dut (
    .clk(clk), .rst_n(rst_n), .refclk(clk), .rx(rx), .tx(tx), .busy(), .irq());
  always #5 clk = ~clk;
  assign rx = host_oe ? host_val : tx;

  function automatic logic [31:0] crc32(input logic [31:0] c, input logic b);
    logic fb; begin fb=c[0]^b; crc32=c>>1; if(fb) crc32=crc32^32'hEDB88320; end
  endfunction

  logic [7:0] hdr [0:7];
  logic [7:0] pl  [0:7];
  task automatic send_tlp(input int plen);
    logic [31:0] c; logic [7:0] fb;
    begin
      host_oe = 1; host_val = 1'b0; #(BIT);
      fb = 8'hFB; for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; #(BIT); end
      fb = HB + plen; for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; #(BIT); end
      c = 32'hFFFFFFFF;
      for (int i=0;i<HB;i++) begin
        fb = hdr[i];
        for (int j=0;j<8;j++) begin host_val=fb[0]; c=crc32(c,fb[0]); fb=fb>>1; #(BIT); end
      end
      for (int i=0;i<plen;i++) begin
        fb = pl[i];
        for (int j=0;j<8;j++) begin host_val=fb[0]; c=crc32(c,fb[0]); fb=fb>>1; #(BIT); end
      end
      c = ~c;
      for (int i=0;i<32;i++) begin host_val=c[0]; c=c>>1; #(BIT); end
      fb = 8'hFD; for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; #(BIT); end
      host_oe = 0;
    end
  endtask

  logic b; logic [7:0] sh;
  task automatic recv_tlp(output int plen);
    begin
      plen = 0; sh = 0;
      wait (tx === 1'b0);
      #(BIT + BIT/2);
      for (int i=0;i<8;i++) begin b=tx; sh={b,sh[7:1]}; #(BIT); end
      sh = 0;
      for (int i=0;i<8;i++) begin b=tx; sh={b,sh[7:1]}; if(i==7) plen = sh - HB; #(BIT); end
      for (int i=0;i<HB+plen;i++) begin
        sh = 0;
        for (int j=0;j<8;j++) begin
          b = tx; sh = {b, sh[7:1]};
          if (j == 7) begin
            if (i < HB) hdr[i] = sh;
            else        pl[i-HB] = sh;
          end
          #(BIT);
        end
      end
      #(BIT*40);
    end
  endtask

  int rlen;
  initial begin
    for (int i=0;i<8;i++) begin hdr[i] = 8'h10 + i; pl[i] = 8'hA0 + i * 8'h11; end
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(20) @(posedge clk);
    send_tlp(4);
    recv_tlp(rlen);
    if (rlen !== 4) begin errors++; $display("ERROR: NVMe plen got=%0d exp=4", rlen); end
    for (int i=0;i<4;i++) begin
      if (pl[i] !== 8'hA0 + i * 8'h11) begin
        errors++; $display("ERROR: NVMe pl[%0d] got=%h exp=%h", i, pl[i], 8'hA0 + i*8'h11);
      end
    end
    if (dut.rx_err !== 1'b0) begin errors++; $display("ERROR: NVMe rx_err set"); end
    if (errors == 0) $display("TEST PASSED: NVMe");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end
  initial begin #10_000_000; $display("TIMEOUT"); $finish; end
endmodule
""")

CUSTOM["USB4"] = dict(
rtl="""// ============================================================================
// USB4 simplified: tunneled frame echo.
// Frame: START(1b 0) + STP + LEN + HDR[8] + payload(LEN-8) + CRC32 + END.
// Raw NRZ both ways; length-based framing; STP=0xFB, END=0xFD.
// Differential pair modeled single-ended. LCRC = zlib CRC32.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module USB4_top #(
  parameter int BAUD_DIV = 20,
  parameter int MAXB     = 8
)(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        refclk,
  input  logic        rx,
  output logic        tx,
  output logic        busy,
  output logic        irq
);
  localparam logic [7:0] STP = 8'hFB, END_B = 8'hFD;
  localparam int HB = 8;

  function automatic logic [31:0] crc32_u(input logic [31:0] c, input logic b);
    logic fb;
    begin fb = c[0]^b; crc32_u = c>>1; if (fb) crc32_u = crc32_u ^ 32'hEDB88320; end
  endfunction

  logic [15:0] tmr; logic phase;
  wire tick = (tmr == BAUD_DIV-1);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin tmr <= '0; phase <= 1'b0; end
    else if (tick) begin tmr <= '0; phase <= ~phase; end
    else tmr <= tmr + 1'b1;
  end

  // ---------------- TX (CAN-style field serializer) ----------------
  typedef enum logic [1:0] {T_IDLE, T_PKT, T_END} t_t;
  t_t          tstate;
  logic [7:0]  tx_shift;
  logic [31:0] tx_crc, crc_snap;
  logic [5:0]  tbit;
  logic [3:0]  tcur;
  logic [5:0]  tlen;
  logic [2:0]  tfld;           // 0=STP 1=LEN 2=HDR 3=DATA 4=CRC 5=END
  logic [7:0]  tx_mem [0:15];
  logic        tx_go, oe_q, out_q;
  logic [3:0]  ta_cnt; logic ta_arm;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tstate <= T_IDLE; tbit <= '0; tfld <= '0; tlen <= '0; tcur <= '0;
      tx_crc <= '0; crc_snap <= '0; tx_shift <= '0; tx_go <= 1'b0;
      oe_q <= 1'b0; out_q <= 1'b1; ta_cnt <= '0; ta_arm <= 1'b0;
    end else begin
      if (ta_cnt != 0 && tick) ta_cnt <= ta_cnt - 1'b1;
      if (ta_cnt == 0 && ta_arm) begin tx_go <= 1'b1; ta_arm <= 1'b0; end
      if (tick && !phase) begin
        case (tstate)
          T_IDLE: if (tx_go) begin
            tx_go <= 1'b0; oe_q <= 1'b1; out_q <= 1'b0;
            tbit <= '0; tfld <= '0;
            tstate <= T_PKT;
          end
          T_PKT: begin
            oe_q <= 1'b1;
            if (tfld == 3'd4) begin
              out_q    <= ~crc_snap[0];
              crc_snap <= crc_snap >> 1;
            end else begin
              out_q <= tx_shift[0];
              if (tfld == 3'd2 || tfld == 3'd3)
                tx_crc <= crc32_u(tx_crc, tx_shift[0]);
              tx_shift <= tx_shift >> 1;
            end
            if (tfld == 3'd4) begin
              if (tbit == 6'd31) begin tfld <= 3'd5; tbit <= '0; tx_shift <= END_B; end
              else tbit <= tbit + 1'b1;
            end else if (tbit == 6'd7) begin
              tbit <= '0;
              case (tfld)
                3'd0: begin tx_shift <= {2'b0, tlen}; tfld <= 3'd1; end
                3'd1: begin tx_shift <= tx_mem[0]; tfld <= 3'd2;
                            tx_crc <= 32'hFFFFFFFF; tcur <= '0; end
                3'd2: begin
                  if (tcur == 4'd7) begin tx_shift <= tx_mem[8]; tfld <= 3'd3; tcur <= 4'd8; end
                  else begin tcur <= tcur + 4'd1; tx_shift <= tx_mem[tcur + 4'd1]; end
                end
                3'd3: begin
                  if (tcur == (tlen[3:0] - 4'd1)) begin
                    tfld <= 3'd4;
                    crc_snap <= crc32_u(tx_crc, tx_shift[0]);
                  end
                  else begin tcur <= tcur + 4'd1; tx_shift <= tx_mem[tcur + 4'd1]; end
                end
                3'd5: tstate <= T_END;
                default: ;
              endcase
            end else tbit <= tbit + 1'b1;
          end
          T_END: begin oe_q <= 1'b0; out_q <= 1'b1; tstate <= T_IDLE; end
          default: tstate <= T_IDLE;
        endcase
      end
    end
  end

  assign tx   = oe_q ? out_q : 1'bz;
  assign busy = (rstate != R_IDLE) || (tstate != T_IDLE);

  // ---------------- RX (length-based framing, start-bit resync) ----------------
  typedef enum logic [1:0] {R_IDLE, R_BYTE} r_t;
  r_t          rstate;
  logic        rxs, rxs_d;
  logic        rtmr_en, rphase;
  logic [15:0] rtmr;
  logic [2:0]  rbitc;
  logic [7:0]  rsh;
  logic [5:0]  ridx;
  logic [5:0]  len_q;
  logic [7:0]  buf_mem [0:HB+MAXB+7];
  logic        rx_err, rx_done;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rxs <= 1'b1; rxs_d <= 1'b1; end
    else begin rxs <= rx; rxs_d <= rxs; end
  end
  wire start_edge = rxs_d & ~rxs;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rtmr_en <= 1'b0; rtmr <= '0; rphase <= 1'b0; end
    else begin
      if (rstate == R_IDLE && start_edge && tstate == T_IDLE) begin
        rtmr_en <= 1'b1; rtmr <= BAUD_DIV/2; rphase <= 1'b1;   // first sample = START bit (discarded)
      end else if (rtmr_en && (rtmr == BAUD_DIV-1)) begin
        rtmr <= '0; rphase <= ~rphase;
      end else if (rtmr_en) rtmr <= rtmr + 1'b1;
    end
  end
  wire rsample = rtmr_en && (rtmr == BAUD_DIV-1) && rphase;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rstate <= R_IDLE; rbitc <= '0; rsh <= '0; ridx <= '0; len_q <= '0;
      rx_err <= 1'b0; rx_done <= 1'b0; buf_mem[0] <= '0;
    end else begin
      rx_done <= 1'b0;
      if (rsample) begin
        case (rstate)
          R_IDLE: begin
            // this sample is the START bit: discard, begin STP at next sample
            rstate <= R_BYTE; rbitc <= '0; ridx <= '0; rsh <= '0;
          end
          R_BYTE: begin
            rsh <= {rxs, rsh[7:1]};
            if (rbitc == 3'd7) begin
              logic [7:0] nb; nb = {rxs, rsh[7:1]};
              if (ridx == 0) begin
                if (nb !== STP) rx_err <= 1'b1;
                ridx <= 1;
              end else if (ridx == 1) begin
                buf_mem[1] <= nb; len_q <= nb[5:0]; ridx <= 2;
              end else if (ridx == (6'd2 + len_q + 6'd4)) begin
                if (nb !== END_B) rx_err <= 1'b1;
                else begin
                  logic [31:0] c; c = 32'hFFFFFFFF;
                  for (int i = 2; i < HB + MAXB + 8; i++) begin
                    if (i <= 6'd1 + len_q)
                      for (int j = 0; j < 8; j++)
                        c = crc32_u(c, buf_mem[i][j]);
                  end
                  c = c ^ 32'hFFFFFFFF;
                  if ({buf_mem[6'd5+len_q], buf_mem[6'd4+len_q],
                       buf_mem[6'd3+len_q], buf_mem[6'd2+len_q]} !== c)
                    rx_err <= 1'b1;
                  else rx_done <= 1'b1;
                end
                rstate <= R_IDLE; ridx <= '0; rtmr_en <= 1'b0;
              end else begin
                buf_mem[ridx[5:0]] <= nb;
                ridx <= ridx + 6'd1;
              end
              rbitc <= '0;
            end else rbitc <= rbitc + 3'd1;
          end
          default: rstate <= R_IDLE;
        endcase
      end
    end
  end

  // echo: retransmit received content (HDR+payload identical frame)
  always_ff @(posedge clk) begin
    if (rx_done) begin
      tlen <= len_q;
      for (int i = 2; i < HB + MAXB + 6; i++)
        tx_mem[i-2] <= buf_mem[i];
      ta_cnt <= 4'd6; ta_arm <= 1'b1;
    end
  end

  assign irq = rx_done;

endmodule
""",
tb="""// PCIe TB: host sends TLP, device echoes, host verifies payload.
`timescale 1ns/1ps
module USB4_tb;
  localparam int BIT = 400;
  localparam int HB  = 8;
  logic clk = 0, rst_n = 0;
  logic host_val = 1'b1, host_oe = 1'b0;
  tri1  rx, tx;
  int errors = 0;

  USB4_top #(.BAUD_DIV(20)) dut (
    .clk(clk), .rst_n(rst_n), .refclk(clk), .rx(rx), .tx(tx), .busy(), .irq());
  always #5 clk = ~clk;
  assign rx = host_oe ? host_val : tx;

  function automatic logic [31:0] crc32(input logic [31:0] c, input logic b);
    logic fb; begin fb=c[0]^b; crc32=c>>1; if(fb) crc32=crc32^32'hEDB88320; end
  endfunction

  logic [7:0] hdr [0:7];
  logic [7:0] pl  [0:7];
  task automatic send_tlp(input int plen);
    logic [31:0] c; logic [7:0] fb;
    begin
      host_oe = 1; host_val = 1'b0; #(BIT);
      fb = 8'hFB; for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; #(BIT); end
      fb = HB + plen; for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; #(BIT); end
      c = 32'hFFFFFFFF;
      for (int i=0;i<HB;i++) begin
        fb = hdr[i];
        for (int j=0;j<8;j++) begin host_val=fb[0]; c=crc32(c,fb[0]); fb=fb>>1; #(BIT); end
      end
      for (int i=0;i<plen;i++) begin
        fb = pl[i];
        for (int j=0;j<8;j++) begin host_val=fb[0]; c=crc32(c,fb[0]); fb=fb>>1; #(BIT); end
      end
      c = ~c;
      for (int i=0;i<32;i++) begin host_val=c[0]; c=c>>1; #(BIT); end
      fb = 8'hFD; for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; #(BIT); end
      host_oe = 0;
    end
  endtask

  logic b; logic [7:0] sh;
  task automatic recv_tlp(output int plen);
    begin
      plen = 0; sh = 0;
      wait (tx === 1'b0);
      #(BIT + BIT/2);
      for (int i=0;i<8;i++) begin b=tx; sh={b,sh[7:1]}; #(BIT); end
      sh = 0;
      for (int i=0;i<8;i++) begin b=tx; sh={b,sh[7:1]}; if(i==7) plen = sh - HB; #(BIT); end
      for (int i=0;i<HB+plen;i++) begin
        sh = 0;
        for (int j=0;j<8;j++) begin
          b = tx; sh = {b, sh[7:1]};
          if (j == 7) begin
            if (i < HB) hdr[i] = sh;
            else        pl[i-HB] = sh;
          end
          #(BIT);
        end
      end
      #(BIT*40);
    end
  endtask

  int rlen;
  initial begin
    for (int i=0;i<8;i++) begin hdr[i] = 8'h10 + i; pl[i] = 8'hA0 + i * 8'h11; end
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(20) @(posedge clk);
    send_tlp(4);
    recv_tlp(rlen);
    if (rlen !== 4) begin errors++; $display("ERROR: USB4 plen got=%0d exp=4", rlen); end
    for (int i=0;i<4;i++) begin
      if (pl[i] !== 8'hA0 + i * 8'h11) begin
        errors++; $display("ERROR: USB4 pl[%0d] got=%h exp=%h", i, pl[i], 8'hA0 + i*8'h11);
      end
    end
    if (dut.rx_err !== 1'b0) begin errors++; $display("ERROR: USB4 rx_err set"); end
    if (errors == 0) $display("TEST PASSED: USB4");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end
  initial begin #10_000_000; $display("TIMEOUT"); $finish; end
endmodule
""")

CUSTOM["ONFI"] = dict(
rtl="""// ============================================================================
// ONFI simplified: NAND command echo.
// Frame: START(1b 0) + STP + LEN + HDR[8] + payload(LEN-8) + CRC32 + END.
// Raw NRZ both ways; length-based framing; STP=0xFB, END=0xFD.
// Differential pair modeled single-ended. LCRC = zlib CRC32.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module ONFI_top #(
  parameter int BAUD_DIV = 20,
  parameter int MAXB     = 8
)(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        refclk,
  input  logic        rx,
  output logic        tx,
  output logic        busy,
  output logic        irq
);
  localparam logic [7:0] STP = 8'hFB, END_B = 8'hFD;
  localparam int HB = 8;

  function automatic logic [31:0] crc32_u(input logic [31:0] c, input logic b);
    logic fb;
    begin fb = c[0]^b; crc32_u = c>>1; if (fb) crc32_u = crc32_u ^ 32'hEDB88320; end
  endfunction

  logic [15:0] tmr; logic phase;
  wire tick = (tmr == BAUD_DIV-1);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin tmr <= '0; phase <= 1'b0; end
    else if (tick) begin tmr <= '0; phase <= ~phase; end
    else tmr <= tmr + 1'b1;
  end

  // ---------------- TX (CAN-style field serializer) ----------------
  typedef enum logic [1:0] {T_IDLE, T_PKT, T_END} t_t;
  t_t          tstate;
  logic [7:0]  tx_shift;
  logic [31:0] tx_crc, crc_snap;
  logic [5:0]  tbit;
  logic [3:0]  tcur;
  logic [5:0]  tlen;
  logic [2:0]  tfld;           // 0=STP 1=LEN 2=HDR 3=DATA 4=CRC 5=END
  logic [7:0]  tx_mem [0:15];
  logic        tx_go, oe_q, out_q;
  logic [3:0]  ta_cnt; logic ta_arm;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tstate <= T_IDLE; tbit <= '0; tfld <= '0; tlen <= '0; tcur <= '0;
      tx_crc <= '0; crc_snap <= '0; tx_shift <= '0; tx_go <= 1'b0;
      oe_q <= 1'b0; out_q <= 1'b1; ta_cnt <= '0; ta_arm <= 1'b0;
    end else begin
      if (ta_cnt != 0 && tick) ta_cnt <= ta_cnt - 1'b1;
      if (ta_cnt == 0 && ta_arm) begin tx_go <= 1'b1; ta_arm <= 1'b0; end
      if (tick && !phase) begin
        case (tstate)
          T_IDLE: if (tx_go) begin
            tx_go <= 1'b0; oe_q <= 1'b1; out_q <= 1'b0;
            tbit <= '0; tfld <= '0;
            tstate <= T_PKT;
          end
          T_PKT: begin
            oe_q <= 1'b1;
            if (tfld == 3'd4) begin
              out_q    <= ~crc_snap[0];
              crc_snap <= crc_snap >> 1;
            end else begin
              out_q <= tx_shift[0];
              if (tfld == 3'd2 || tfld == 3'd3)
                tx_crc <= crc32_u(tx_crc, tx_shift[0]);
              tx_shift <= tx_shift >> 1;
            end
            if (tfld == 3'd4) begin
              if (tbit == 6'd31) begin tfld <= 3'd5; tbit <= '0; tx_shift <= END_B; end
              else tbit <= tbit + 1'b1;
            end else if (tbit == 6'd7) begin
              tbit <= '0;
              case (tfld)
                3'd0: begin tx_shift <= {2'b0, tlen}; tfld <= 3'd1; end
                3'd1: begin tx_shift <= tx_mem[0]; tfld <= 3'd2;
                            tx_crc <= 32'hFFFFFFFF; tcur <= '0; end
                3'd2: begin
                  if (tcur == 4'd7) begin tx_shift <= tx_mem[8]; tfld <= 3'd3; tcur <= 4'd8; end
                  else begin tcur <= tcur + 4'd1; tx_shift <= tx_mem[tcur + 4'd1]; end
                end
                3'd3: begin
                  if (tcur == (tlen[3:0] - 4'd1)) begin
                    tfld <= 3'd4;
                    crc_snap <= crc32_u(tx_crc, tx_shift[0]);
                  end
                  else begin tcur <= tcur + 4'd1; tx_shift <= tx_mem[tcur + 4'd1]; end
                end
                3'd5: tstate <= T_END;
                default: ;
              endcase
            end else tbit <= tbit + 1'b1;
          end
          T_END: begin oe_q <= 1'b0; out_q <= 1'b1; tstate <= T_IDLE; end
          default: tstate <= T_IDLE;
        endcase
      end
    end
  end

  assign tx   = oe_q ? out_q : 1'bz;
  assign busy = (rstate != R_IDLE) || (tstate != T_IDLE);

  // ---------------- RX (length-based framing, start-bit resync) ----------------
  typedef enum logic [1:0] {R_IDLE, R_BYTE} r_t;
  r_t          rstate;
  logic        rxs, rxs_d;
  logic        rtmr_en, rphase;
  logic [15:0] rtmr;
  logic [2:0]  rbitc;
  logic [7:0]  rsh;
  logic [5:0]  ridx;
  logic [5:0]  len_q;
  logic [7:0]  buf_mem [0:HB+MAXB+7];
  logic        rx_err, rx_done;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rxs <= 1'b1; rxs_d <= 1'b1; end
    else begin rxs <= rx; rxs_d <= rxs; end
  end
  wire start_edge = rxs_d & ~rxs;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rtmr_en <= 1'b0; rtmr <= '0; rphase <= 1'b0; end
    else begin
      if (rstate == R_IDLE && start_edge && tstate == T_IDLE) begin
        rtmr_en <= 1'b1; rtmr <= BAUD_DIV/2; rphase <= 1'b1;   // first sample = START bit (discarded)
      end else if (rtmr_en && (rtmr == BAUD_DIV-1)) begin
        rtmr <= '0; rphase <= ~rphase;
      end else if (rtmr_en) rtmr <= rtmr + 1'b1;
    end
  end
  wire rsample = rtmr_en && (rtmr == BAUD_DIV-1) && rphase;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rstate <= R_IDLE; rbitc <= '0; rsh <= '0; ridx <= '0; len_q <= '0;
      rx_err <= 1'b0; rx_done <= 1'b0; buf_mem[0] <= '0;
    end else begin
      rx_done <= 1'b0;
      if (rsample) begin
        case (rstate)
          R_IDLE: begin
            // this sample is the START bit: discard, begin STP at next sample
            rstate <= R_BYTE; rbitc <= '0; ridx <= '0; rsh <= '0;
          end
          R_BYTE: begin
            rsh <= {rxs, rsh[7:1]};
            if (rbitc == 3'd7) begin
              logic [7:0] nb; nb = {rxs, rsh[7:1]};
              if (ridx == 0) begin
                if (nb !== STP) rx_err <= 1'b1;
                ridx <= 1;
              end else if (ridx == 1) begin
                buf_mem[1] <= nb; len_q <= nb[5:0]; ridx <= 2;
              end else if (ridx == (6'd2 + len_q + 6'd4)) begin
                if (nb !== END_B) rx_err <= 1'b1;
                else begin
                  logic [31:0] c; c = 32'hFFFFFFFF;
                  for (int i = 2; i < HB + MAXB + 8; i++) begin
                    if (i <= 6'd1 + len_q)
                      for (int j = 0; j < 8; j++)
                        c = crc32_u(c, buf_mem[i][j]);
                  end
                  c = c ^ 32'hFFFFFFFF;
                  if ({buf_mem[6'd5+len_q], buf_mem[6'd4+len_q],
                       buf_mem[6'd3+len_q], buf_mem[6'd2+len_q]} !== c)
                    rx_err <= 1'b1;
                  else rx_done <= 1'b1;
                end
                rstate <= R_IDLE; ridx <= '0; rtmr_en <= 1'b0;
              end else begin
                buf_mem[ridx[5:0]] <= nb;
                ridx <= ridx + 6'd1;
              end
              rbitc <= '0;
            end else rbitc <= rbitc + 3'd1;
          end
          default: rstate <= R_IDLE;
        endcase
      end
    end
  end

  // echo: retransmit received content (HDR+payload identical frame)
  always_ff @(posedge clk) begin
    if (rx_done) begin
      tlen <= len_q;
      for (int i = 2; i < HB + MAXB + 6; i++)
        tx_mem[i-2] <= buf_mem[i];
      ta_cnt <= 4'd6; ta_arm <= 1'b1;
    end
  end

  assign irq = rx_done;

endmodule
""",
tb="""// PCIe TB: host sends TLP, device echoes, host verifies payload.
`timescale 1ns/1ps
module ONFI_tb;
  localparam int BIT = 400;
  localparam int HB  = 8;
  logic clk = 0, rst_n = 0;
  logic host_val = 1'b1, host_oe = 1'b0;
  tri1  rx, tx;
  int errors = 0;

  ONFI_top #(.BAUD_DIV(20)) dut (
    .clk(clk), .rst_n(rst_n), .refclk(clk), .rx(rx), .tx(tx), .busy(), .irq());
  always #5 clk = ~clk;
  assign rx = host_oe ? host_val : tx;

  function automatic logic [31:0] crc32(input logic [31:0] c, input logic b);
    logic fb; begin fb=c[0]^b; crc32=c>>1; if(fb) crc32=crc32^32'hEDB88320; end
  endfunction

  logic [7:0] hdr [0:7];
  logic [7:0] pl  [0:7];
  task automatic send_tlp(input int plen);
    logic [31:0] c; logic [7:0] fb;
    begin
      host_oe = 1; host_val = 1'b0; #(BIT);
      fb = 8'hFB; for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; #(BIT); end
      fb = HB + plen; for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; #(BIT); end
      c = 32'hFFFFFFFF;
      for (int i=0;i<HB;i++) begin
        fb = hdr[i];
        for (int j=0;j<8;j++) begin host_val=fb[0]; c=crc32(c,fb[0]); fb=fb>>1; #(BIT); end
      end
      for (int i=0;i<plen;i++) begin
        fb = pl[i];
        for (int j=0;j<8;j++) begin host_val=fb[0]; c=crc32(c,fb[0]); fb=fb>>1; #(BIT); end
      end
      c = ~c;
      for (int i=0;i<32;i++) begin host_val=c[0]; c=c>>1; #(BIT); end
      fb = 8'hFD; for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; #(BIT); end
      host_oe = 0;
    end
  endtask

  logic b; logic [7:0] sh;
  task automatic recv_tlp(output int plen);
    begin
      plen = 0; sh = 0;
      wait (tx === 1'b0);
      #(BIT + BIT/2);
      for (int i=0;i<8;i++) begin b=tx; sh={b,sh[7:1]}; #(BIT); end
      sh = 0;
      for (int i=0;i<8;i++) begin b=tx; sh={b,sh[7:1]}; if(i==7) plen = sh - HB; #(BIT); end
      for (int i=0;i<HB+plen;i++) begin
        sh = 0;
        for (int j=0;j<8;j++) begin
          b = tx; sh = {b, sh[7:1]};
          if (j == 7) begin
            if (i < HB) hdr[i] = sh;
            else        pl[i-HB] = sh;
          end
          #(BIT);
        end
      end
      #(BIT*40);
    end
  endtask

  int rlen;
  initial begin
    for (int i=0;i<8;i++) begin hdr[i] = 8'h10 + i; pl[i] = 8'hA0 + i * 8'h11; end
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(20) @(posedge clk);
    send_tlp(4);
    recv_tlp(rlen);
    if (rlen !== 4) begin errors++; $display("ERROR: ONFI plen got=%0d exp=4", rlen); end
    for (int i=0;i<4;i++) begin
      if (pl[i] !== 8'hA0 + i * 8'h11) begin
        errors++; $display("ERROR: ONFI pl[%0d] got=%h exp=%h", i, pl[i], 8'hA0 + i*8'h11);
      end
    end
    if (dut.rx_err !== 1'b0) begin errors++; $display("ERROR: ONFI rx_err set"); end
    if (errors == 0) $display("TEST PASSED: ONFI");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end
  initial begin #10_000_000; $display("TIMEOUT"); $finish; end
endmodule
""")

CUSTOM["LIN"] = dict(
rtl="""// ============================================================================
// LIN 2.x slave (CAN architecture).
// - TX: bit stuffing (after 5 consecutive equal bits), CRC-15 (poly 0x4599)
// - RX: hard sync on SOF edge, de-stuffing, CRC check, ACK drive
// - Bus timing: 2 timer phases per bit; TX drives at phase 0, RX samples at 1
// Style follows OpenCores can_controller basics.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module LIN_top #(
  parameter int BAUD_DIV = 50              // clk cycles per phase
)(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        rxd,
  output logic        txd,
  input  logic        wen,
  input  logic [3:0]  waddr,   // 0: id[7:0]  1: {id[10:8],1'b0,dlc[3:0]}
  input  logic [7:0]  wdata,   // 2-9: data   10: go
  input  logic        ren,
  input  logic [3:0]  raddr,   // 0: rx id[7:0] 1: {rx_id[10:8],1'b0,rx_dlc}
  output logic [7:0]  rdata,   // 2-9: rx data  10: status
  output logic        irq
);
  // ---------------- registers ----------------
  logic [10:0] tx_id;
  logic [3:0]  tx_dlc;
  logic [7:0]  tx_mem [0:7];
  logic        tx_go, tx_busy;

  // ---------------- bit timer (2 phases per bit) ----------------
  logic [15:0] tmr;
  logic        phase;
  wire         tick = (tmr == BAUD_DIV-1);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin tmr <= '0; phase <= 1'b0; end
    else if (tick) begin tmr <= '0; phase <= ~phase; end
    else tmr <= tmr + 1'b1;
  end

  function automatic logic [14:0] crc_next(input logic [14:0] c, input logic b);
    logic fb;
    begin
      fb = b ^ c[14];
      crc_next = {c[13:0], 1'b0} ^ (fb ? 15'h4599 : 15'h0);
    end
  endfunction

  // ---------------- TX ----------------
  typedef enum logic [3:0] {
    TX_IDLE, TX_HDR, TX_DATA, TX_CRC, TX_CRCD, TX_ACK, TX_ACKD, TX_EOF
  } tx_t;
  tx_t        tstate;
  logic [4:0] tx_bit;
  logic [2:0] tx_byte;
  logic [17:0] tx_hdr;      // {id[10:0], rtr=0, ide=0, r0=0, dlc[3:0]}
  logic [14:0] tx_crc;
  logic [3:0]  run_cnt;
  logic        prev_bit;
  logic        can_out;

  wire [7:0]  tx_data_b = tx_mem[tx_byte];
  wire        tx_field_bit = (tstate == TX_HDR)  ? tx_hdr[17-tx_bit] :
                             (tstate == TX_DATA) ? tx_data_b[7-tx_bit[2:0]] :
                                                   tx_crc[14-tx_bit];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tstate <= TX_IDLE; tx_bit <= '0; tx_byte <= '0; run_cnt <= '0;
      prev_bit <= 1'b1; tx_crc <= '0; can_out <= 1'b1; tx_busy <= 1'b0;
      tx_go <= 1'b0; tx_id <= '0; tx_dlc <= '0;
      for (int i = 0; i < 8; i++) tx_mem[i] <= '0;
    end else begin
      if (wen && waddr == 4'd0) tx_id[7:0] <= wdata;
      if (wen && waddr == 4'd1) begin tx_id[10:8] <= wdata[7:5]; tx_dlc <= wdata[3:0]; end
      if (wen && waddr >= 4'd2 && waddr <= 4'd9) tx_mem[waddr[3:0] - 4'd2] <= wdata;
      if (wen && waddr == 4'd10 && wdata[0]) tx_go <= 1'b1;

      if (tick && !phase) begin                 // drive point
        case (tstate)
          TX_IDLE: if (tx_go) begin
            tx_go   <= 1'b0;
            tx_busy <= 1'b1;
            tx_hdr  <= {tx_id, 1'b0, 1'b0, 1'b0, tx_dlc};
            tx_crc  <= '0;
            run_cnt <= 4'd1;                    // SOF = first dominant bit
            prev_bit <= 1'b0;
            can_out <= 1'b0;                    // SOF
            tx_bit  <= '0; tx_byte <= '0;
            tstate  <= TX_HDR;
          end
          TX_HDR, TX_DATA, TX_CRC: begin
            if (run_cnt == 4'd5) begin
              // send stuff bit (opposite of previous); field not advanced
              can_out  <= ~prev_bit;
              prev_bit <= ~prev_bit;
              run_cnt  <= 4'd1;
            end else begin
              can_out <= tx_field_bit;
              if (tstate != TX_CRC)             // CRC over SOF..data (SOF adds 0: no-op)
                tx_crc <= crc_next(tx_crc, tx_field_bit);
              if (tx_field_bit == prev_bit) run_cnt <= run_cnt + 1'b1;
              else run_cnt <= 4'd1;
              prev_bit <= tx_field_bit;
              if (tstate == TX_HDR) begin
                if (tx_bit == 5'd17) begin
                  tx_bit <= '0;
                  tstate <= (tx_dlc == 0) ? TX_CRC : TX_DATA;
                end else tx_bit <= tx_bit + 1'b1;
              end else if (tstate == TX_DATA) begin
                if (tx_bit[2:0] == 3'd7) begin
                  tx_bit <= '0;
                  if (tx_byte == tx_dlc[2:0] - 3'd1) tstate <= TX_CRC;
                  else tx_byte <= tx_byte + 1'b1;
                end else tx_bit <= tx_bit + 1'b1;
              end else begin
                if (tx_bit == 5'd14) begin tx_bit <= '0; tstate <= TX_CRCD; end
                else tx_bit <= tx_bit + 1'b1;
              end
            end
          end
          TX_CRCD: begin can_out <= 1'b1; tstate <= TX_ACK; end
          TX_ACK:  begin can_out <= 1'b1; tstate <= TX_ACKD; end   // release for ACK
          TX_ACKD: begin can_out <= 1'b1; tstate <= TX_EOF; tx_bit <= '0; end
          TX_EOF: begin
            can_out <= 1'b1;
            if (tx_bit == 5'd6) begin
              tx_bit <= '0; tstate <= TX_IDLE; tx_busy <= 1'b0;
            end else tx_bit <= tx_bit + 1'b1;
          end
          default: tstate <= TX_IDLE;
        endcase
      end
    end
  end

  // ---------------- RX ----------------
  typedef enum logic [3:0] {
    RX_IDLE, RX_HDR, RX_DATA, RX_CRC, RX_CRCD, RX_ACK, RX_ACKD, RX_EOF
  } rx_t;
  rx_t         rstate;
  logic [4:0]  rx_bit;
  logic [2:0]  rx_byte;
  logic [17:0] rx_hdr_sh;
  logic [10:0] rx_id;
  logic [3:0]  rx_dlc;
  logic [7:0]  rx_mem [0:7];
  logic [14:0] rx_crc;
  logic [3:0]  rx_run;        // consecutive equal received bits
  logic        last_rx;       // last received bit (stuff bits included)
  logic        rx_bit_v;      // destuffed bit valid (pulse)
  logic        rx_err, rx_valid;
  logic        ack_drive;
  logic        rxed, rxed_d;
  logic        sof_wait;      // next sample is the SOF bit itself

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rxed <= 1'b1; rxed_d <= 1'b1; end
    else begin rxed <= rxd; rxed_d <= rxed; end
  end
  wire sof_det = rxed_d & ~rxed;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rstate <= RX_IDLE; rx_bit <= '0; rx_byte <= '0; rx_run <= '0;
      rx_crc <= '0; rx_bit_v <= 1'b0; rx_err <= 1'b0; rx_valid <= 1'b0;
      ack_drive <= 1'b0; last_rx <= 1'b1; rx_hdr_sh <= '0; sof_wait <= 1'b0;
      rx_id <= '0; rx_dlc <= '0;
      for (int i = 0; i < 8; i++) rx_mem[i] <= '0;
    end else begin
      rx_bit_v <= 1'b0;
      rx_valid <= 1'b0;

      if (sof_det && rstate == RX_IDLE && !sof_wait) begin
        // hard sync: SOF edge; consume SOF immediately (it is dominant)
        rstate   <= RX_HDR;
        rx_bit   <= '0; rx_byte <= '0; rx_run <= 4'd1; last_rx <= 1'b0;
        rx_crc   <= '0;                 // crc_next(*,0) on all-zero state = 0
        rx_err   <= 1'b0;
        sof_wait <= 1'b1;               // skip the mid-SOF sample (same bit)
      end

      if (tick && phase && rstate != RX_IDLE) begin
        if (sof_wait) begin
          sof_wait <= 1'b0;             // mid-SOF sample: already consumed
        end else if (rstate == RX_HDR || rstate == RX_DATA || rstate == RX_CRC) begin
          if (rx_run == 4'd5) begin
            // stuff bit: discard. It still counts as 1 received bit (it breaks
            // the run), so TX/RX run counters stay aligned.
            rx_run   <= 4'd1;
            last_rx  <= rxed;
          end else begin
            rx_bit_v <= 1'b1;
            if (rxed == last_rx) rx_run <= rx_run + 1'b1;
            else rx_run <= 4'd1;
            last_rx <= rxed;
          end
        end else begin
          rx_bit_v <= 1'b1;             // CRC delim / ACK / EOF: no stuffing
        end
      end

      if (rx_bit_v) begin
        case (rstate)
          RX_HDR: begin
            rx_hdr_sh <= {rx_hdr_sh[16:0], rxed};
            rx_crc    <= crc_next(rx_crc, rxed);
            if (rx_bit == 5'd17) begin
              rx_id  <= rx_hdr_sh[16:6];          // id[10:0] = hdr[17:7]
              rx_dlc <= {rx_hdr_sh[2:0], rxed};   // dlc[3:0] = hdr[3:0]
              rx_bit <= '0;
              rstate <= ({rx_hdr_sh[2:0], rxed} == 4'd0) ? RX_CRC : RX_DATA;
            end else rx_bit <= rx_bit + 1'b1;
          end
          RX_DATA: begin
            rx_mem[rx_byte][7-rx_bit[2:0]] <= rxed;
            rx_crc <= crc_next(rx_crc, rxed);
            if (rx_bit[2:0] == 3'd7) begin
              rx_bit <= '0;
              if (rx_byte == rx_dlc[2:0] - 3'd1) rstate <= RX_CRC;
              else rx_byte <= rx_byte + 1'b1;
            end else rx_bit <= rx_bit + 1'b1;
          end
          RX_CRC: begin
            if (rx_bit < 5'd15 && rxed != rx_crc[14-rx_bit]) rx_err <= 1'b1;
            if (rx_bit == 5'd14) begin rx_bit <= '0; rstate <= RX_CRCD; end
            else rx_bit <= rx_bit + 1'b1;
          end
          RX_CRCD: begin rx_bit <= '0; rstate <= RX_ACK; ack_drive <= !rx_err; end
          RX_ACK:  begin ack_drive <= 1'b0; rstate <= RX_ACKD; end
          RX_ACKD: rstate <= RX_EOF;
          RX_EOF: begin
            if (rx_bit == 5'd6) begin
              rx_bit <= '0; rstate <= RX_IDLE;
              if (!rx_err) rx_valid <= 1'b1;
            end else rx_bit <= rx_bit + 1'b1;
          end
          default: ;
        endcase
      end
    end
  end

  assign txd = can_out & ~ack_drive;   // RX ACK dominant-overrides during ACK slot
  assign irq = rx_valid;

  assign rdata = (raddr == 4'd0)  ? rx_id[7:0] :
                 (raddr == 4'd1)  ? {rx_id[10:8], 1'b0, rx_dlc} :
                 (raddr >= 4'd2 && raddr <= 4'd9) ? rx_mem[raddr[3:0] - 4'd2] :
                 (raddr == 4'd10) ? {2'b00, rx_err, 1'b0, 1'b0, tx_busy, 2'b00} :
                                    8'h00;

endmodule
""",
tb="""// Self-checking testbench: CAN loopback (rxd = txd) -- SystemVerilog
`timescale 1ns/1ps
module LIN_tb;
  logic clk = 0, rst_n = 0;
  logic rxd, txd;
  logic wen = 0, ren = 0;
  logic [3:0] waddr = 0, raddr = 0;
  logic [7:0] wdata = 0, rdata;
  int errors = 0;

  LIN_top #(.BAUD_DIV(20)) dut (
    .clk(clk), .rst_n(rst_n), .rxd(rxd), .txd(txd),
    .wen(wen), .waddr(waddr), .wdata(wdata),
    .ren(ren), .raddr(raddr), .rdata(rdata), .irq());

  always #5 clk = ~clk;
  assign rxd = txd;                          // loopback

  task automatic wr(input logic [3:0] a, input logic [7:0] d);
    begin
      @(negedge clk); wen <= 1'b1; waddr <= a; wdata <= d;
      @(negedge clk); wen <= 1'b0;
    end
  endtask
  task automatic rd(input logic [3:0] a, output logic [7:0] d);
    begin
      @(negedge clk); ren <= 1'b1; raddr <= a;
      #1 d = rdata;
      @(negedge clk); ren <= 1'b0;
    end
  endtask

  logic [7:0] idl, hdr, b0, b1, b2, b3, st;
  task automatic check_frame(input logic [10:0] id, input logic [3:0] dlc,
                             input logic [7:0] d0, input logic [7:0] d1,
                             input logic [7:0] d2, input logic [7:0] d3);
    begin
      wr(4'd0, id[7:0]);
      wr(4'd1, {id[10:8], 1'b0, dlc});
      wr(4'd2, d0); wr(4'd3, d1); wr(4'd4, d2); wr(4'd5, d3);
      wr(4'd10, 8'h01);
      wait (dut.rx_valid === 1'b1);
      @(posedge clk); #1;
      rd(4'd0, idl); rd(4'd1, hdr);
      rd(4'd2, b0); rd(4'd3, b1); rd(4'd4, b2); rd(4'd5, b3);
      rd(4'd10, st);
      if ({hdr[7:5], idl} !== id) begin
        errors++; $display("ERROR: LIN id got=%h_%h exp=%h", hdr[7:5], idl, id);
      end
      if (hdr[3:0] !== dlc) begin errors++; $display("ERROR: LIN dlc got=%0d exp=%0d", hdr[3:0], dlc); end
      if (dlc >= 1 && b0 !== d0) begin errors++; $display("ERROR: LIN b0 got=%h exp=%h", b0, d0); end
      if (dlc >= 2 && b1 !== d1) begin errors++; $display("ERROR: LIN b1 got=%h exp=%h", b1, d1); end
      if (dlc >= 3 && b2 !== d2) begin errors++; $display("ERROR: LIN b2 got=%h exp=%h", b2, d2); end
      if (dlc >= 4 && b3 !== d3) begin errors++; $display("ERROR: LIN b3 got=%h exp=%h", b3, d3); end
      if (st[5] !== 1'b0) begin errors++; $display("ERROR: LIN rx_err set (st=%h)", st); end
      repeat (50) @(posedge clk);          // inter-frame gap
    end
  endtask

  initial begin
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(20) @(posedge clk);

    check_frame(11'h1AB, 4'd4, 8'h55, 8'hAA, 8'h0F, 8'hF0);  // stuffing-heavy
    check_frame(11'h055, 4'd0, 8'h00, 8'h00, 8'h00, 8'h00);  // dataless
    check_frame(11'h7FF, 4'd2, 8'hFF, 8'hFF, 8'h00, 8'h00);  // worst-case stuff

    if (errors == 0) $display("TEST PASSED: LIN");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #8_000_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")




CUSTOM["FlexRay"] = dict(
rtl="""// ============================================================================
// FlexRay simplified static-slot frame.
// - TX: bit stuffing (after 5 consecutive equal bits), CRC-15 (poly 0x4599)
// - RX: hard sync on SOF edge, de-stuffing, CRC check, ACK drive
// - Bus timing: 2 timer phases per bit; TX drives at phase 0, RX samples at 1
// Style follows OpenCores can_controller basics.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module FlexRay_top #(
  parameter int BAUD_DIV = 50              // clk cycles per phase
)(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        rxd,
  output logic        txd,
  input  logic        wen,
  input  logic [3:0]  waddr,   // 0: id[7:0]  1: {id[10:8],1'b0,dlc[3:0]}
  input  logic [7:0]  wdata,   // 2-9: data   10: go
  input  logic        ren,
  input  logic [3:0]  raddr,   // 0: rx id[7:0] 1: {rx_id[10:8],1'b0,rx_dlc}
  output logic [7:0]  rdata,   // 2-9: rx data  10: status
  output logic        irq
);
  // ---------------- registers ----------------
  logic [10:0] tx_id;
  logic [3:0]  tx_dlc;
  logic [7:0]  tx_mem [0:7];
  logic        tx_go, tx_busy;

  // ---------------- bit timer (2 phases per bit) ----------------
  logic [15:0] tmr;
  logic        phase;
  wire         tick = (tmr == BAUD_DIV-1);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin tmr <= '0; phase <= 1'b0; end
    else if (tick) begin tmr <= '0; phase <= ~phase; end
    else tmr <= tmr + 1'b1;
  end

  function automatic logic [14:0] crc_next(input logic [14:0] c, input logic b);
    logic fb;
    begin
      fb = b ^ c[14];
      crc_next = {c[13:0], 1'b0} ^ (fb ? 15'h4599 : 15'h0);
    end
  endfunction

  // ---------------- TX ----------------
  typedef enum logic [3:0] {
    TX_IDLE, TX_HDR, TX_DATA, TX_CRC, TX_CRCD, TX_ACK, TX_ACKD, TX_EOF
  } tx_t;
  tx_t        tstate;
  logic [4:0] tx_bit;
  logic [2:0] tx_byte;
  logic [17:0] tx_hdr;      // {id[10:0], rtr=0, ide=0, r0=0, dlc[3:0]}
  logic [14:0] tx_crc;
  logic [3:0]  run_cnt;
  logic        prev_bit;
  logic        can_out;

  wire [7:0]  tx_data_b = tx_mem[tx_byte];
  wire        tx_field_bit = (tstate == TX_HDR)  ? tx_hdr[17-tx_bit] :
                             (tstate == TX_DATA) ? tx_data_b[7-tx_bit[2:0]] :
                                                   tx_crc[14-tx_bit];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tstate <= TX_IDLE; tx_bit <= '0; tx_byte <= '0; run_cnt <= '0;
      prev_bit <= 1'b1; tx_crc <= '0; can_out <= 1'b1; tx_busy <= 1'b0;
      tx_go <= 1'b0; tx_id <= '0; tx_dlc <= '0;
      for (int i = 0; i < 8; i++) tx_mem[i] <= '0;
    end else begin
      if (wen && waddr == 4'd0) tx_id[7:0] <= wdata;
      if (wen && waddr == 4'd1) begin tx_id[10:8] <= wdata[7:5]; tx_dlc <= wdata[3:0]; end
      if (wen && waddr >= 4'd2 && waddr <= 4'd9) tx_mem[waddr[3:0] - 4'd2] <= wdata;
      if (wen && waddr == 4'd10 && wdata[0]) tx_go <= 1'b1;

      if (tick && !phase) begin                 // drive point
        case (tstate)
          TX_IDLE: if (tx_go) begin
            tx_go   <= 1'b0;
            tx_busy <= 1'b1;
            tx_hdr  <= {tx_id, 1'b0, 1'b0, 1'b0, tx_dlc};
            tx_crc  <= '0;
            run_cnt <= 4'd1;                    // SOF = first dominant bit
            prev_bit <= 1'b0;
            can_out <= 1'b0;                    // SOF
            tx_bit  <= '0; tx_byte <= '0;
            tstate  <= TX_HDR;
          end
          TX_HDR, TX_DATA, TX_CRC: begin
            if (run_cnt == 4'd5) begin
              // send stuff bit (opposite of previous); field not advanced
              can_out  <= ~prev_bit;
              prev_bit <= ~prev_bit;
              run_cnt  <= 4'd1;
            end else begin
              can_out <= tx_field_bit;
              if (tstate != TX_CRC)             // CRC over SOF..data (SOF adds 0: no-op)
                tx_crc <= crc_next(tx_crc, tx_field_bit);
              if (tx_field_bit == prev_bit) run_cnt <= run_cnt + 1'b1;
              else run_cnt <= 4'd1;
              prev_bit <= tx_field_bit;
              if (tstate == TX_HDR) begin
                if (tx_bit == 5'd17) begin
                  tx_bit <= '0;
                  tstate <= (tx_dlc == 0) ? TX_CRC : TX_DATA;
                end else tx_bit <= tx_bit + 1'b1;
              end else if (tstate == TX_DATA) begin
                if (tx_bit[2:0] == 3'd7) begin
                  tx_bit <= '0;
                  if (tx_byte == tx_dlc[2:0] - 3'd1) tstate <= TX_CRC;
                  else tx_byte <= tx_byte + 1'b1;
                end else tx_bit <= tx_bit + 1'b1;
              end else begin
                if (tx_bit == 5'd14) begin tx_bit <= '0; tstate <= TX_CRCD; end
                else tx_bit <= tx_bit + 1'b1;
              end
            end
          end
          TX_CRCD: begin can_out <= 1'b1; tstate <= TX_ACK; end
          TX_ACK:  begin can_out <= 1'b1; tstate <= TX_ACKD; end   // release for ACK
          TX_ACKD: begin can_out <= 1'b1; tstate <= TX_EOF; tx_bit <= '0; end
          TX_EOF: begin
            can_out <= 1'b1;
            if (tx_bit == 5'd6) begin
              tx_bit <= '0; tstate <= TX_IDLE; tx_busy <= 1'b0;
            end else tx_bit <= tx_bit + 1'b1;
          end
          default: tstate <= TX_IDLE;
        endcase
      end
    end
  end

  // ---------------- RX ----------------
  typedef enum logic [3:0] {
    RX_IDLE, RX_HDR, RX_DATA, RX_CRC, RX_CRCD, RX_ACK, RX_ACKD, RX_EOF
  } rx_t;
  rx_t         rstate;
  logic [4:0]  rx_bit;
  logic [2:0]  rx_byte;
  logic [17:0] rx_hdr_sh;
  logic [10:0] rx_id;
  logic [3:0]  rx_dlc;
  logic [7:0]  rx_mem [0:7];
  logic [14:0] rx_crc;
  logic [3:0]  rx_run;        // consecutive equal received bits
  logic        last_rx;       // last received bit (stuff bits included)
  logic        rx_bit_v;      // destuffed bit valid (pulse)
  logic        rx_err, rx_valid;
  logic        ack_drive;
  logic        rxed, rxed_d;
  logic        sof_wait;      // next sample is the SOF bit itself

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rxed <= 1'b1; rxed_d <= 1'b1; end
    else begin rxed <= rxd; rxed_d <= rxed; end
  end
  wire sof_det = rxed_d & ~rxed;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rstate <= RX_IDLE; rx_bit <= '0; rx_byte <= '0; rx_run <= '0;
      rx_crc <= '0; rx_bit_v <= 1'b0; rx_err <= 1'b0; rx_valid <= 1'b0;
      ack_drive <= 1'b0; last_rx <= 1'b1; rx_hdr_sh <= '0; sof_wait <= 1'b0;
      rx_id <= '0; rx_dlc <= '0;
      for (int i = 0; i < 8; i++) rx_mem[i] <= '0;
    end else begin
      rx_bit_v <= 1'b0;
      rx_valid <= 1'b0;

      if (sof_det && rstate == RX_IDLE && !sof_wait) begin
        // hard sync: SOF edge; consume SOF immediately (it is dominant)
        rstate   <= RX_HDR;
        rx_bit   <= '0; rx_byte <= '0; rx_run <= 4'd1; last_rx <= 1'b0;
        rx_crc   <= '0;                 // crc_next(*,0) on all-zero state = 0
        rx_err   <= 1'b0;
        sof_wait <= 1'b1;               // skip the mid-SOF sample (same bit)
      end

      if (tick && phase && rstate != RX_IDLE) begin
        if (sof_wait) begin
          sof_wait <= 1'b0;             // mid-SOF sample: already consumed
        end else if (rstate == RX_HDR || rstate == RX_DATA || rstate == RX_CRC) begin
          if (rx_run == 4'd5) begin
            // stuff bit: discard. It still counts as 1 received bit (it breaks
            // the run), so TX/RX run counters stay aligned.
            rx_run   <= 4'd1;
            last_rx  <= rxed;
          end else begin
            rx_bit_v <= 1'b1;
            if (rxed == last_rx) rx_run <= rx_run + 1'b1;
            else rx_run <= 4'd1;
            last_rx <= rxed;
          end
        end else begin
          rx_bit_v <= 1'b1;             // CRC delim / ACK / EOF: no stuffing
        end
      end

      if (rx_bit_v) begin
        case (rstate)
          RX_HDR: begin
            rx_hdr_sh <= {rx_hdr_sh[16:0], rxed};
            rx_crc    <= crc_next(rx_crc, rxed);
            if (rx_bit == 5'd17) begin
              rx_id  <= rx_hdr_sh[16:6];          // id[10:0] = hdr[17:7]
              rx_dlc <= {rx_hdr_sh[2:0], rxed};   // dlc[3:0] = hdr[3:0]
              rx_bit <= '0;
              rstate <= ({rx_hdr_sh[2:0], rxed} == 4'd0) ? RX_CRC : RX_DATA;
            end else rx_bit <= rx_bit + 1'b1;
          end
          RX_DATA: begin
            rx_mem[rx_byte][7-rx_bit[2:0]] <= rxed;
            rx_crc <= crc_next(rx_crc, rxed);
            if (rx_bit[2:0] == 3'd7) begin
              rx_bit <= '0;
              if (rx_byte == rx_dlc[2:0] - 3'd1) rstate <= RX_CRC;
              else rx_byte <= rx_byte + 1'b1;
            end else rx_bit <= rx_bit + 1'b1;
          end
          RX_CRC: begin
            if (rx_bit < 5'd15 && rxed != rx_crc[14-rx_bit]) rx_err <= 1'b1;
            if (rx_bit == 5'd14) begin rx_bit <= '0; rstate <= RX_CRCD; end
            else rx_bit <= rx_bit + 1'b1;
          end
          RX_CRCD: begin rx_bit <= '0; rstate <= RX_ACK; ack_drive <= !rx_err; end
          RX_ACK:  begin ack_drive <= 1'b0; rstate <= RX_ACKD; end
          RX_ACKD: rstate <= RX_EOF;
          RX_EOF: begin
            if (rx_bit == 5'd6) begin
              rx_bit <= '0; rstate <= RX_IDLE;
              if (!rx_err) rx_valid <= 1'b1;
            end else rx_bit <= rx_bit + 1'b1;
          end
          default: ;
        endcase
      end
    end
  end

  assign txd = can_out & ~ack_drive;   // RX ACK dominant-overrides during ACK slot
  assign irq = rx_valid;

  assign rdata = (raddr == 4'd0)  ? rx_id[7:0] :
                 (raddr == 4'd1)  ? {rx_id[10:8], 1'b0, rx_dlc} :
                 (raddr >= 4'd2 && raddr <= 4'd9) ? rx_mem[raddr[3:0] - 4'd2] :
                 (raddr == 4'd10) ? {2'b00, rx_err, 1'b0, 1'b0, tx_busy, 2'b00} :
                                    8'h00;

endmodule
""",
tb="""// Self-checking testbench: CAN loopback (rxd = txd) -- SystemVerilog
`timescale 1ns/1ps
module FlexRay_tb;
  logic clk = 0, rst_n = 0;
  logic rxd, txd;
  logic wen = 0, ren = 0;
  logic [3:0] waddr = 0, raddr = 0;
  logic [7:0] wdata = 0, rdata;
  int errors = 0;

  FlexRay_top #(.BAUD_DIV(20)) dut (
    .clk(clk), .rst_n(rst_n), .rxd(rxd), .txd(txd),
    .wen(wen), .waddr(waddr), .wdata(wdata),
    .ren(ren), .raddr(raddr), .rdata(rdata), .irq());

  always #5 clk = ~clk;
  assign rxd = txd;                          // loopback

  task automatic wr(input logic [3:0] a, input logic [7:0] d);
    begin
      @(negedge clk); wen <= 1'b1; waddr <= a; wdata <= d;
      @(negedge clk); wen <= 1'b0;
    end
  endtask
  task automatic rd(input logic [3:0] a, output logic [7:0] d);
    begin
      @(negedge clk); ren <= 1'b1; raddr <= a;
      #1 d = rdata;
      @(negedge clk); ren <= 1'b0;
    end
  endtask

  logic [7:0] idl, hdr, b0, b1, b2, b3, st;
  task automatic check_frame(input logic [10:0] id, input logic [3:0] dlc,
                             input logic [7:0] d0, input logic [7:0] d1,
                             input logic [7:0] d2, input logic [7:0] d3);
    begin
      wr(4'd0, id[7:0]);
      wr(4'd1, {id[10:8], 1'b0, dlc});
      wr(4'd2, d0); wr(4'd3, d1); wr(4'd4, d2); wr(4'd5, d3);
      wr(4'd10, 8'h01);
      wait (dut.rx_valid === 1'b1);
      @(posedge clk); #1;
      rd(4'd0, idl); rd(4'd1, hdr);
      rd(4'd2, b0); rd(4'd3, b1); rd(4'd4, b2); rd(4'd5, b3);
      rd(4'd10, st);
      if ({hdr[7:5], idl} !== id) begin
        errors++; $display("ERROR: FlexRay id got=%h_%h exp=%h", hdr[7:5], idl, id);
      end
      if (hdr[3:0] !== dlc) begin errors++; $display("ERROR: FlexRay dlc got=%0d exp=%0d", hdr[3:0], dlc); end
      if (dlc >= 1 && b0 !== d0) begin errors++; $display("ERROR: FlexRay b0 got=%h exp=%h", b0, d0); end
      if (dlc >= 2 && b1 !== d1) begin errors++; $display("ERROR: FlexRay b1 got=%h exp=%h", b1, d1); end
      if (dlc >= 3 && b2 !== d2) begin errors++; $display("ERROR: FlexRay b2 got=%h exp=%h", b2, d2); end
      if (dlc >= 4 && b3 !== d3) begin errors++; $display("ERROR: FlexRay b3 got=%h exp=%h", b3, d3); end
      if (st[5] !== 1'b0) begin errors++; $display("ERROR: FlexRay rx_err set (st=%h)", st); end
      repeat (50) @(posedge clk);          // inter-frame gap
    end
  endtask

  initial begin
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(20) @(posedge clk);

    check_frame(11'h1AB, 4'd4, 8'h55, 8'hAA, 8'h0F, 8'hF0);  // stuffing-heavy
    check_frame(11'h055, 4'd0, 8'h00, 8'h00, 8'h00, 8'h00);  // dataless
    check_frame(11'h7FF, 4'd2, 8'hFF, 8'hFF, 8'h00, 8'h00);  // worst-case stuff

    if (errors == 0) $display("TEST PASSED: FlexRay");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #8_000_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")




CUSTOM["Ethernet-AVB-TSN"] = dict(
rtl="""// ============================================================================
// TSN simplified time-triggered frame.
// - TX: bit stuffing (after 5 consecutive equal bits), CRC-15 (poly 0x4599)
// - RX: hard sync on SOF edge, de-stuffing, CRC check, ACK drive
// - Bus timing: 2 timer phases per bit; TX drives at phase 0, RX samples at 1
// Style follows OpenCores can_controller basics.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module Ethernet_AVB_TSN_top #(
  parameter int BAUD_DIV = 50              // clk cycles per phase
)(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        rxd,
  output logic        txd,
  input  logic        wen,
  input  logic [3:0]  waddr,   // 0: id[7:0]  1: {id[10:8],1'b0,dlc[3:0]}
  input  logic [7:0]  wdata,   // 2-9: data   10: go
  input  logic        ren,
  input  logic [3:0]  raddr,   // 0: rx id[7:0] 1: {rx_id[10:8],1'b0,rx_dlc}
  output logic [7:0]  rdata,   // 2-9: rx data  10: status
  output logic        irq
);
  // ---------------- registers ----------------
  logic [10:0] tx_id;
  logic [3:0]  tx_dlc;
  logic [7:0]  tx_mem [0:7];
  logic        tx_go, tx_busy;

  // ---------------- bit timer (2 phases per bit) ----------------
  logic [15:0] tmr;
  logic        phase;
  wire         tick = (tmr == BAUD_DIV-1);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin tmr <= '0; phase <= 1'b0; end
    else if (tick) begin tmr <= '0; phase <= ~phase; end
    else tmr <= tmr + 1'b1;
  end

  function automatic logic [14:0] crc_next(input logic [14:0] c, input logic b);
    logic fb;
    begin
      fb = b ^ c[14];
      crc_next = {c[13:0], 1'b0} ^ (fb ? 15'h4599 : 15'h0);
    end
  endfunction

  // ---------------- TX ----------------
  typedef enum logic [3:0] {
    TX_IDLE, TX_HDR, TX_DATA, TX_CRC, TX_CRCD, TX_ACK, TX_ACKD, TX_EOF
  } tx_t;
  tx_t        tstate;
  logic [4:0] tx_bit;
  logic [2:0] tx_byte;
  logic [17:0] tx_hdr;      // {id[10:0], rtr=0, ide=0, r0=0, dlc[3:0]}
  logic [14:0] tx_crc;
  logic [3:0]  run_cnt;
  logic        prev_bit;
  logic        can_out;

  wire [7:0]  tx_data_b = tx_mem[tx_byte];
  wire        tx_field_bit = (tstate == TX_HDR)  ? tx_hdr[17-tx_bit] :
                             (tstate == TX_DATA) ? tx_data_b[7-tx_bit[2:0]] :
                                                   tx_crc[14-tx_bit];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tstate <= TX_IDLE; tx_bit <= '0; tx_byte <= '0; run_cnt <= '0;
      prev_bit <= 1'b1; tx_crc <= '0; can_out <= 1'b1; tx_busy <= 1'b0;
      tx_go <= 1'b0; tx_id <= '0; tx_dlc <= '0;
      for (int i = 0; i < 8; i++) tx_mem[i] <= '0;
    end else begin
      if (wen && waddr == 4'd0) tx_id[7:0] <= wdata;
      if (wen && waddr == 4'd1) begin tx_id[10:8] <= wdata[7:5]; tx_dlc <= wdata[3:0]; end
      if (wen && waddr >= 4'd2 && waddr <= 4'd9) tx_mem[waddr[3:0] - 4'd2] <= wdata;
      if (wen && waddr == 4'd10 && wdata[0]) tx_go <= 1'b1;

      if (tick && !phase) begin                 // drive point
        case (tstate)
          TX_IDLE: if (tx_go) begin
            tx_go   <= 1'b0;
            tx_busy <= 1'b1;
            tx_hdr  <= {tx_id, 1'b0, 1'b0, 1'b0, tx_dlc};
            tx_crc  <= '0;
            run_cnt <= 4'd1;                    // SOF = first dominant bit
            prev_bit <= 1'b0;
            can_out <= 1'b0;                    // SOF
            tx_bit  <= '0; tx_byte <= '0;
            tstate  <= TX_HDR;
          end
          TX_HDR, TX_DATA, TX_CRC: begin
            if (run_cnt == 4'd5) begin
              // send stuff bit (opposite of previous); field not advanced
              can_out  <= ~prev_bit;
              prev_bit <= ~prev_bit;
              run_cnt  <= 4'd1;
            end else begin
              can_out <= tx_field_bit;
              if (tstate != TX_CRC)             // CRC over SOF..data (SOF adds 0: no-op)
                tx_crc <= crc_next(tx_crc, tx_field_bit);
              if (tx_field_bit == prev_bit) run_cnt <= run_cnt + 1'b1;
              else run_cnt <= 4'd1;
              prev_bit <= tx_field_bit;
              if (tstate == TX_HDR) begin
                if (tx_bit == 5'd17) begin
                  tx_bit <= '0;
                  tstate <= (tx_dlc == 0) ? TX_CRC : TX_DATA;
                end else tx_bit <= tx_bit + 1'b1;
              end else if (tstate == TX_DATA) begin
                if (tx_bit[2:0] == 3'd7) begin
                  tx_bit <= '0;
                  if (tx_byte == tx_dlc[2:0] - 3'd1) tstate <= TX_CRC;
                  else tx_byte <= tx_byte + 1'b1;
                end else tx_bit <= tx_bit + 1'b1;
              end else begin
                if (tx_bit == 5'd14) begin tx_bit <= '0; tstate <= TX_CRCD; end
                else tx_bit <= tx_bit + 1'b1;
              end
            end
          end
          TX_CRCD: begin can_out <= 1'b1; tstate <= TX_ACK; end
          TX_ACK:  begin can_out <= 1'b1; tstate <= TX_ACKD; end   // release for ACK
          TX_ACKD: begin can_out <= 1'b1; tstate <= TX_EOF; tx_bit <= '0; end
          TX_EOF: begin
            can_out <= 1'b1;
            if (tx_bit == 5'd6) begin
              tx_bit <= '0; tstate <= TX_IDLE; tx_busy <= 1'b0;
            end else tx_bit <= tx_bit + 1'b1;
          end
          default: tstate <= TX_IDLE;
        endcase
      end
    end
  end

  // ---------------- RX ----------------
  typedef enum logic [3:0] {
    RX_IDLE, RX_HDR, RX_DATA, RX_CRC, RX_CRCD, RX_ACK, RX_ACKD, RX_EOF
  } rx_t;
  rx_t         rstate;
  logic [4:0]  rx_bit;
  logic [2:0]  rx_byte;
  logic [17:0] rx_hdr_sh;
  logic [10:0] rx_id;
  logic [3:0]  rx_dlc;
  logic [7:0]  rx_mem [0:7];
  logic [14:0] rx_crc;
  logic [3:0]  rx_run;        // consecutive equal received bits
  logic        last_rx;       // last received bit (stuff bits included)
  logic        rx_bit_v;      // destuffed bit valid (pulse)
  logic        rx_err, rx_valid;
  logic        ack_drive;
  logic        rxed, rxed_d;
  logic        sof_wait;      // next sample is the SOF bit itself

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rxed <= 1'b1; rxed_d <= 1'b1; end
    else begin rxed <= rxd; rxed_d <= rxed; end
  end
  wire sof_det = rxed_d & ~rxed;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rstate <= RX_IDLE; rx_bit <= '0; rx_byte <= '0; rx_run <= '0;
      rx_crc <= '0; rx_bit_v <= 1'b0; rx_err <= 1'b0; rx_valid <= 1'b0;
      ack_drive <= 1'b0; last_rx <= 1'b1; rx_hdr_sh <= '0; sof_wait <= 1'b0;
      rx_id <= '0; rx_dlc <= '0;
      for (int i = 0; i < 8; i++) rx_mem[i] <= '0;
    end else begin
      rx_bit_v <= 1'b0;
      rx_valid <= 1'b0;

      if (sof_det && rstate == RX_IDLE && !sof_wait) begin
        // hard sync: SOF edge; consume SOF immediately (it is dominant)
        rstate   <= RX_HDR;
        rx_bit   <= '0; rx_byte <= '0; rx_run <= 4'd1; last_rx <= 1'b0;
        rx_crc   <= '0;                 // crc_next(*,0) on all-zero state = 0
        rx_err   <= 1'b0;
        sof_wait <= 1'b1;               // skip the mid-SOF sample (same bit)
      end

      if (tick && phase && rstate != RX_IDLE) begin
        if (sof_wait) begin
          sof_wait <= 1'b0;             // mid-SOF sample: already consumed
        end else if (rstate == RX_HDR || rstate == RX_DATA || rstate == RX_CRC) begin
          if (rx_run == 4'd5) begin
            // stuff bit: discard. It still counts as 1 received bit (it breaks
            // the run), so TX/RX run counters stay aligned.
            rx_run   <= 4'd1;
            last_rx  <= rxed;
          end else begin
            rx_bit_v <= 1'b1;
            if (rxed == last_rx) rx_run <= rx_run + 1'b1;
            else rx_run <= 4'd1;
            last_rx <= rxed;
          end
        end else begin
          rx_bit_v <= 1'b1;             // CRC delim / ACK / EOF: no stuffing
        end
      end

      if (rx_bit_v) begin
        case (rstate)
          RX_HDR: begin
            rx_hdr_sh <= {rx_hdr_sh[16:0], rxed};
            rx_crc    <= crc_next(rx_crc, rxed);
            if (rx_bit == 5'd17) begin
              rx_id  <= rx_hdr_sh[16:6];          // id[10:0] = hdr[17:7]
              rx_dlc <= {rx_hdr_sh[2:0], rxed};   // dlc[3:0] = hdr[3:0]
              rx_bit <= '0;
              rstate <= ({rx_hdr_sh[2:0], rxed} == 4'd0) ? RX_CRC : RX_DATA;
            end else rx_bit <= rx_bit + 1'b1;
          end
          RX_DATA: begin
            rx_mem[rx_byte][7-rx_bit[2:0]] <= rxed;
            rx_crc <= crc_next(rx_crc, rxed);
            if (rx_bit[2:0] == 3'd7) begin
              rx_bit <= '0;
              if (rx_byte == rx_dlc[2:0] - 3'd1) rstate <= RX_CRC;
              else rx_byte <= rx_byte + 1'b1;
            end else rx_bit <= rx_bit + 1'b1;
          end
          RX_CRC: begin
            if (rx_bit < 5'd15 && rxed != rx_crc[14-rx_bit]) rx_err <= 1'b1;
            if (rx_bit == 5'd14) begin rx_bit <= '0; rstate <= RX_CRCD; end
            else rx_bit <= rx_bit + 1'b1;
          end
          RX_CRCD: begin rx_bit <= '0; rstate <= RX_ACK; ack_drive <= !rx_err; end
          RX_ACK:  begin ack_drive <= 1'b0; rstate <= RX_ACKD; end
          RX_ACKD: rstate <= RX_EOF;
          RX_EOF: begin
            if (rx_bit == 5'd6) begin
              rx_bit <= '0; rstate <= RX_IDLE;
              if (!rx_err) rx_valid <= 1'b1;
            end else rx_bit <= rx_bit + 1'b1;
          end
          default: ;
        endcase
      end
    end
  end

  assign txd = can_out & ~ack_drive;   // RX ACK dominant-overrides during ACK slot
  assign irq = rx_valid;

  assign rdata = (raddr == 4'd0)  ? rx_id[7:0] :
                 (raddr == 4'd1)  ? {rx_id[10:8], 1'b0, rx_dlc} :
                 (raddr >= 4'd2 && raddr <= 4'd9) ? rx_mem[raddr[3:0] - 4'd2] :
                 (raddr == 4'd10) ? {2'b00, rx_err, 1'b0, 1'b0, tx_busy, 2'b00} :
                                    8'h00;

endmodule
""",
tb="""// Self-checking testbench: CAN loopback (rxd = txd) -- SystemVerilog
`timescale 1ns/1ps
module Ethernet_AVB_TSN_tb;
  logic clk = 0, rst_n = 0;
  logic rxd, txd;
  logic wen = 0, ren = 0;
  logic [3:0] waddr = 0, raddr = 0;
  logic [7:0] wdata = 0, rdata;
  int errors = 0;

  Ethernet_AVB_TSN_top #(.BAUD_DIV(20)) dut (
    .clk(clk), .rst_n(rst_n), .rxd(rxd), .txd(txd),
    .wen(wen), .waddr(waddr), .wdata(wdata),
    .ren(ren), .raddr(raddr), .rdata(rdata), .irq());

  always #5 clk = ~clk;
  assign rxd = txd;                          // loopback

  task automatic wr(input logic [3:0] a, input logic [7:0] d);
    begin
      @(negedge clk); wen <= 1'b1; waddr <= a; wdata <= d;
      @(negedge clk); wen <= 1'b0;
    end
  endtask
  task automatic rd(input logic [3:0] a, output logic [7:0] d);
    begin
      @(negedge clk); ren <= 1'b1; raddr <= a;
      #1 d = rdata;
      @(negedge clk); ren <= 1'b0;
    end
  endtask

  logic [7:0] idl, hdr, b0, b1, b2, b3, st;
  task automatic check_frame(input logic [10:0] id, input logic [3:0] dlc,
                             input logic [7:0] d0, input logic [7:0] d1,
                             input logic [7:0] d2, input logic [7:0] d3);
    begin
      wr(4'd0, id[7:0]);
      wr(4'd1, {id[10:8], 1'b0, dlc});
      wr(4'd2, d0); wr(4'd3, d1); wr(4'd4, d2); wr(4'd5, d3);
      wr(4'd10, 8'h01);
      wait (dut.rx_valid === 1'b1);
      @(posedge clk); #1;
      rd(4'd0, idl); rd(4'd1, hdr);
      rd(4'd2, b0); rd(4'd3, b1); rd(4'd4, b2); rd(4'd5, b3);
      rd(4'd10, st);
      if ({hdr[7:5], idl} !== id) begin
        errors++; $display("ERROR: Ethernet-AVB-TSN id got=%h_%h exp=%h", hdr[7:5], idl, id);
      end
      if (hdr[3:0] !== dlc) begin errors++; $display("ERROR: Ethernet-AVB-TSN dlc got=%0d exp=%0d", hdr[3:0], dlc); end
      if (dlc >= 1 && b0 !== d0) begin errors++; $display("ERROR: Ethernet-AVB-TSN b0 got=%h exp=%h", b0, d0); end
      if (dlc >= 2 && b1 !== d1) begin errors++; $display("ERROR: Ethernet-AVB-TSN b1 got=%h exp=%h", b1, d1); end
      if (dlc >= 3 && b2 !== d2) begin errors++; $display("ERROR: Ethernet-AVB-TSN b2 got=%h exp=%h", b2, d2); end
      if (dlc >= 4 && b3 !== d3) begin errors++; $display("ERROR: Ethernet-AVB-TSN b3 got=%h exp=%h", b3, d3); end
      if (st[5] !== 1'b0) begin errors++; $display("ERROR: Ethernet-AVB-TSN rx_err set (st=%h)", st); end
      repeat (50) @(posedge clk);          // inter-frame gap
    end
  endtask

  initial begin
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(20) @(posedge clk);

    check_frame(11'h1AB, 4'd4, 8'h55, 8'hAA, 8'h0F, 8'hF0);  // stuffing-heavy
    check_frame(11'h055, 4'd0, 8'h00, 8'h00, 8'h00, 8'h00);  // dataless
    check_frame(11'h7FF, 4'd2, 8'hFF, 8'hFF, 8'h00, 8'h00);  // worst-case stuff

    if (errors == 0) $display("TEST PASSED: Ethernet-AVB-TSN");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #8_000_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")




CUSTOM["MIPI SoundWire"] = dict(
rtl="""// ============================================================================
// SoundWire simplified 2-wire reg r/w.
// Write (PC=0): master sends data; Read (PC=1): slave drives data (push-pull).
// OpenCores rffe/pmic style register interface.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module MIPI_SoundWire_top #(
  parameter logic [1:0] RFFE_ADDR = 2'b01
)(
  input  logic       clk,
  input  logic       rst_n,
  inout  tri         sdata,
  input  logic       sclk,
  output logic [7:0] rx_byte,        // {AD, data} register write captured
  output logic [7:0] rx_addr,
  output logic       rx_valid,
  input  logic [7:0] tx_byte,        // data returned for reads
  output logic       busy,
  output logic       irq
);
  logic sclk_s, sclk_d, sdata_s, sdata_d;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sclk_s <= 1'b0; sclk_d <= 1'b0; sdata_s <= 1'b1; sdata_d <= 1'b1;
    end else begin
      sclk_s <= sclk; sclk_d <= sclk_s;
      sdata_s <= sdata; sdata_d <= sdata_s;
    end
  end
  wire sclk_rise =  sclk_s & ~sclk_d;
  wire sclk_fall = ~sclk_s &  sclk_d;
  wire ssc_det   = ~sdata_s &  sdata_d & sclk_s;   // SSC: sdata falls while sclk high

  typedef enum logic [1:0] {ST_IDLE, ST_HEAD, ST_DATA, ST_PARK} st_t;
  st_t      state;
  logic [3:0] bit_cnt;     // HEAD: 0..2 (SA+PC), then AD folds into HEAD 3..7
  logic [7:0] shift;
  logic       rw;
  logic       sd_oe, sd_out;

  assign sdata   = sd_oe ? sd_out : 1'bz;
  assign busy    = (state != ST_IDLE);
  assign irq     = rx_valid;
  assign rx_addr = {3'b000, shift_hold};

  logic [4:0] shift_hold;  // captured register address

  wire [7:0] head_w = {shift[6:0], sdata_s};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= ST_IDLE; bit_cnt <= '0; shift <= '0; shift_hold <= '0;
      rw <= 1'b0; sd_oe <= 1'b0; sd_out <= 1'b1; rx_valid <= 1'b0;
    end else begin
      rx_valid <= 1'b0;
      if (ssc_det) begin
        state <= ST_HEAD; bit_cnt <= '0; sd_oe <= 1'b0;
      end else case (state)
        ST_HEAD: if (sclk_rise) begin
          shift <= head_w;
          if (bit_cnt == 4'd7) begin
            // head_w = {SA[1:0], PC, AD[4:0]}
            if (head_w[7:6] == RFFE_ADDR) begin
              rw <= head_w[5];
              shift_hold <= head_w[4:0];
              bit_cnt <= '0;
              state <= ST_DATA;
            end else state <= ST_IDLE;
          end else bit_cnt <= bit_cnt + 1'b1;
        end
        ST_DATA: begin
          if (!rw && sclk_rise) begin          // write: sample master's data
            shift <= head_w;
            if (bit_cnt == 4'd7) begin
              rx_byte <= head_w;
              bit_cnt <= '0; state <= ST_PARK; rx_valid <= 1'b1;
            end else bit_cnt <= bit_cnt + 1'b1;
          end else if (rw && sclk_fall) begin  // read: drive next data bit
            sd_oe <= 1'b1;
            sd_out <= tx_byte[7-bit_cnt];
            if (bit_cnt == 4'd7) begin
              bit_cnt <= '0; sd_oe <= 1'b0; state <= ST_PARK;
            end else bit_cnt <= bit_cnt + 1'b1;
          end
        end
        ST_PARK: if (sclk_fall) begin
          sd_oe <= 1'b0; state <= ST_IDLE;     // bus park then idle
        end
        default: state <= ST_IDLE;
      endcase
    end
  end

endmodule
""",
tb="""// Self-checking testbench: TB acts as RFFE master -- SystemVerilog
`timescale 1ns/1ps
module MIPI_SoundWire_tb;
  logic clk = 0, rst_n = 0;
  tri1  sdata;
  logic sclk = 0;
  logic m_oe = 0, m_val = 1;
  logic [7:0] rx_byte, rx_addr;
  logic rx_valid, busy;
  logic rx_seen = 0;
  int errors = 0;

  MIPI_SoundWire_top #(.RFFE_ADDR(2'b01)) dut (
    .clk(clk), .rst_n(rst_n), .sdata(sdata), .sclk(sclk),
    .rx_byte(rx_byte), .rx_addr(rx_addr), .rx_valid(rx_valid),
    .tx_byte(8'hC3), .busy(busy), .irq());

  always #5 clk = ~clk;
  assign sdata = m_oe ? m_val : 1'bz;
  always @(posedge clk) if (rx_valid) rx_seen <= 1'b1;

  task automatic rbit(input logic b);
    begin m_oe = 1; m_val = b; #300; sclk = 1; #600; sclk = 0; #300; end
  endtask
  task automatic rrelease_bit(output logic b);
    begin m_oe = 0; #300; sclk = 1; #300; b = sdata; #300; sclk = 0; #300; end
  endtask
  task automatic rssc;
    begin m_oe = 0; m_val = 1; sclk = 1; #300;   // SCLK high first
          m_oe = 1; m_val = 0; #300;             // SDATA falls while SCLK high
          sclk = 0; #300;
          m_oe = 0; #300; end
  endtask

  task automatic rffe_write(input logic [1:0] sa, input logic [4:0] ad,
                            input logic [7:0] data);
    begin
      rssc;
      rbit(sa[1]); rbit(sa[0]); rbit(1'b0);       // PC=0 write
      for (int i = 4; i >= 0; i--) rbit(ad[i]);
      for (int i = 7; i >= 0; i--) rbit(data[i]);
      rbit(1'b1);                                  // bus park
      m_oe = 0; #600;
    end
  endtask

  task automatic rffe_read(input logic [1:0] sa, input logic [4:0] ad,
                           output logic [7:0] data);
    logic b;
    begin
      rssc;
      rbit(sa[1]); rbit(sa[0]); rbit(1'b1);       // PC=1 read
      for (int i = 4; i >= 0; i--) rbit(ad[i]);
      for (int i = 7; i >= 0; i--) begin
        rrelease_bit(b);
        data[i] = b;
      end
      rbit(1'b1);
      m_oe = 0; #600;
    end
  endtask

  logic [7:0] rb;
  initial begin
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(10) @(posedge clk);

    rffe_write(2'b01, 5'h03, 8'h5A);
    repeat(5) @(posedge clk);
    if (!rx_seen) begin errors++; $display("ERROR: MIPI SoundWire rx_valid never pulsed"); end
    if (rx_byte !== 8'h5A) begin errors++; $display("ERROR: MIPI SoundWire rx=%h exp=5A", rx_byte); end
    if (rx_addr !== 5'h03) begin errors++; $display("ERROR: MIPI SoundWire rx_addr=%h exp=03", rx_addr); end

    rffe_read (2'b01, 5'h03, rb);
    if (rb !== 8'hC3) begin errors++; $display("ERROR: MIPI SoundWire read got=%h exp=C3", rb); end

    if (errors == 0) $display("TEST PASSED: MIPI SoundWire");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #3_000_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")

CUSTOM["MIPI SLIMbus"] = dict(
rtl="""// ============================================================================
// SLIMbus simplified 2-wire reg r/w.
// Write (PC=0): master sends data; Read (PC=1): slave drives data (push-pull).
// OpenCores rffe/pmic style register interface.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module MIPI_SLIMbus_top #(
  parameter logic [1:0] RFFE_ADDR = 2'b01
)(
  input  logic       clk,
  input  logic       rst_n,
  inout  tri         sdata,
  input  logic       sclk,
  output logic [7:0] rx_byte,        // {AD, data} register write captured
  output logic [7:0] rx_addr,
  output logic       rx_valid,
  input  logic [7:0] tx_byte,        // data returned for reads
  output logic       busy,
  output logic       irq
);
  logic sclk_s, sclk_d, sdata_s, sdata_d;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sclk_s <= 1'b0; sclk_d <= 1'b0; sdata_s <= 1'b1; sdata_d <= 1'b1;
    end else begin
      sclk_s <= sclk; sclk_d <= sclk_s;
      sdata_s <= sdata; sdata_d <= sdata_s;
    end
  end
  wire sclk_rise =  sclk_s & ~sclk_d;
  wire sclk_fall = ~sclk_s &  sclk_d;
  wire ssc_det   = ~sdata_s &  sdata_d & sclk_s;   // SSC: sdata falls while sclk high

  typedef enum logic [1:0] {ST_IDLE, ST_HEAD, ST_DATA, ST_PARK} st_t;
  st_t      state;
  logic [3:0] bit_cnt;     // HEAD: 0..2 (SA+PC), then AD folds into HEAD 3..7
  logic [7:0] shift;
  logic       rw;
  logic       sd_oe, sd_out;

  assign sdata   = sd_oe ? sd_out : 1'bz;
  assign busy    = (state != ST_IDLE);
  assign irq     = rx_valid;
  assign rx_addr = {3'b000, shift_hold};

  logic [4:0] shift_hold;  // captured register address

  wire [7:0] head_w = {shift[6:0], sdata_s};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= ST_IDLE; bit_cnt <= '0; shift <= '0; shift_hold <= '0;
      rw <= 1'b0; sd_oe <= 1'b0; sd_out <= 1'b1; rx_valid <= 1'b0;
    end else begin
      rx_valid <= 1'b0;
      if (ssc_det) begin
        state <= ST_HEAD; bit_cnt <= '0; sd_oe <= 1'b0;
      end else case (state)
        ST_HEAD: if (sclk_rise) begin
          shift <= head_w;
          if (bit_cnt == 4'd7) begin
            // head_w = {SA[1:0], PC, AD[4:0]}
            if (head_w[7:6] == RFFE_ADDR) begin
              rw <= head_w[5];
              shift_hold <= head_w[4:0];
              bit_cnt <= '0;
              state <= ST_DATA;
            end else state <= ST_IDLE;
          end else bit_cnt <= bit_cnt + 1'b1;
        end
        ST_DATA: begin
          if (!rw && sclk_rise) begin          // write: sample master's data
            shift <= head_w;
            if (bit_cnt == 4'd7) begin
              rx_byte <= head_w;
              bit_cnt <= '0; state <= ST_PARK; rx_valid <= 1'b1;
            end else bit_cnt <= bit_cnt + 1'b1;
          end else if (rw && sclk_fall) begin  // read: drive next data bit
            sd_oe <= 1'b1;
            sd_out <= tx_byte[7-bit_cnt];
            if (bit_cnt == 4'd7) begin
              bit_cnt <= '0; sd_oe <= 1'b0; state <= ST_PARK;
            end else bit_cnt <= bit_cnt + 1'b1;
          end
        end
        ST_PARK: if (sclk_fall) begin
          sd_oe <= 1'b0; state <= ST_IDLE;     // bus park then idle
        end
        default: state <= ST_IDLE;
      endcase
    end
  end

endmodule
""",
tb="""// Self-checking testbench: TB acts as RFFE master -- SystemVerilog
`timescale 1ns/1ps
module MIPI_SLIMbus_tb;
  logic clk = 0, rst_n = 0;
  tri1  sdata;
  logic sclk = 0;
  logic m_oe = 0, m_val = 1;
  logic [7:0] rx_byte, rx_addr;
  logic rx_valid, busy;
  logic rx_seen = 0;
  int errors = 0;

  MIPI_SLIMbus_top #(.RFFE_ADDR(2'b01)) dut (
    .clk(clk), .rst_n(rst_n), .sdata(sdata), .sclk(sclk),
    .rx_byte(rx_byte), .rx_addr(rx_addr), .rx_valid(rx_valid),
    .tx_byte(8'hC3), .busy(busy), .irq());

  always #5 clk = ~clk;
  assign sdata = m_oe ? m_val : 1'bz;
  always @(posedge clk) if (rx_valid) rx_seen <= 1'b1;

  task automatic rbit(input logic b);
    begin m_oe = 1; m_val = b; #300; sclk = 1; #600; sclk = 0; #300; end
  endtask
  task automatic rrelease_bit(output logic b);
    begin m_oe = 0; #300; sclk = 1; #300; b = sdata; #300; sclk = 0; #300; end
  endtask
  task automatic rssc;
    begin m_oe = 0; m_val = 1; sclk = 1; #300;   // SCLK high first
          m_oe = 1; m_val = 0; #300;             // SDATA falls while SCLK high
          sclk = 0; #300;
          m_oe = 0; #300; end
  endtask

  task automatic rffe_write(input logic [1:0] sa, input logic [4:0] ad,
                            input logic [7:0] data);
    begin
      rssc;
      rbit(sa[1]); rbit(sa[0]); rbit(1'b0);       // PC=0 write
      for (int i = 4; i >= 0; i--) rbit(ad[i]);
      for (int i = 7; i >= 0; i--) rbit(data[i]);
      rbit(1'b1);                                  // bus park
      m_oe = 0; #600;
    end
  endtask

  task automatic rffe_read(input logic [1:0] sa, input logic [4:0] ad,
                           output logic [7:0] data);
    logic b;
    begin
      rssc;
      rbit(sa[1]); rbit(sa[0]); rbit(1'b1);       // PC=1 read
      for (int i = 4; i >= 0; i--) rbit(ad[i]);
      for (int i = 7; i >= 0; i--) begin
        rrelease_bit(b);
        data[i] = b;
      end
      rbit(1'b1);
      m_oe = 0; #600;
    end
  endtask

  logic [7:0] rb;
  initial begin
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(10) @(posedge clk);

    rffe_write(2'b01, 5'h03, 8'h5A);
    repeat(5) @(posedge clk);
    if (!rx_seen) begin errors++; $display("ERROR: MIPI SLIMbus rx_valid never pulsed"); end
    if (rx_byte !== 8'h5A) begin errors++; $display("ERROR: MIPI SLIMbus rx=%h exp=5A", rx_byte); end
    if (rx_addr !== 5'h03) begin errors++; $display("ERROR: MIPI SLIMbus rx_addr=%h exp=03", rx_addr); end

    rffe_read (2'b01, 5'h03, rb);
    if (rb !== 8'hC3) begin errors++; $display("ERROR: MIPI SLIMbus read got=%h exp=C3", rb); end

    if (errors == 0) $display("TEST PASSED: MIPI SLIMbus");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #3_000_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")

CUSTOM["DigRF"] = dict(
rtl="""// ============================================================================
// DigRF simplified 2-wire reg r/w.
// Write (PC=0): master sends data; Read (PC=1): slave drives data (push-pull).
// OpenCores rffe/pmic style register interface.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module DigRF_top #(
  parameter logic [1:0] RFFE_ADDR = 2'b01
)(
  input  logic       clk,
  input  logic       rst_n,
  inout  tri         sdata,
  input  logic       sclk,
  output logic [7:0] rx_byte,        // {AD, data} register write captured
  output logic [7:0] rx_addr,
  output logic       rx_valid,
  input  logic [7:0] tx_byte,        // data returned for reads
  output logic       busy,
  output logic       irq
);
  logic sclk_s, sclk_d, sdata_s, sdata_d;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sclk_s <= 1'b0; sclk_d <= 1'b0; sdata_s <= 1'b1; sdata_d <= 1'b1;
    end else begin
      sclk_s <= sclk; sclk_d <= sclk_s;
      sdata_s <= sdata; sdata_d <= sdata_s;
    end
  end
  wire sclk_rise =  sclk_s & ~sclk_d;
  wire sclk_fall = ~sclk_s &  sclk_d;
  wire ssc_det   = ~sdata_s &  sdata_d & sclk_s;   // SSC: sdata falls while sclk high

  typedef enum logic [1:0] {ST_IDLE, ST_HEAD, ST_DATA, ST_PARK} st_t;
  st_t      state;
  logic [3:0] bit_cnt;     // HEAD: 0..2 (SA+PC), then AD folds into HEAD 3..7
  logic [7:0] shift;
  logic       rw;
  logic       sd_oe, sd_out;

  assign sdata   = sd_oe ? sd_out : 1'bz;
  assign busy    = (state != ST_IDLE);
  assign irq     = rx_valid;
  assign rx_addr = {3'b000, shift_hold};

  logic [4:0] shift_hold;  // captured register address

  wire [7:0] head_w = {shift[6:0], sdata_s};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= ST_IDLE; bit_cnt <= '0; shift <= '0; shift_hold <= '0;
      rw <= 1'b0; sd_oe <= 1'b0; sd_out <= 1'b1; rx_valid <= 1'b0;
    end else begin
      rx_valid <= 1'b0;
      if (ssc_det) begin
        state <= ST_HEAD; bit_cnt <= '0; sd_oe <= 1'b0;
      end else case (state)
        ST_HEAD: if (sclk_rise) begin
          shift <= head_w;
          if (bit_cnt == 4'd7) begin
            // head_w = {SA[1:0], PC, AD[4:0]}
            if (head_w[7:6] == RFFE_ADDR) begin
              rw <= head_w[5];
              shift_hold <= head_w[4:0];
              bit_cnt <= '0;
              state <= ST_DATA;
            end else state <= ST_IDLE;
          end else bit_cnt <= bit_cnt + 1'b1;
        end
        ST_DATA: begin
          if (!rw && sclk_rise) begin          // write: sample master's data
            shift <= head_w;
            if (bit_cnt == 4'd7) begin
              rx_byte <= head_w;
              bit_cnt <= '0; state <= ST_PARK; rx_valid <= 1'b1;
            end else bit_cnt <= bit_cnt + 1'b1;
          end else if (rw && sclk_fall) begin  // read: drive next data bit
            sd_oe <= 1'b1;
            sd_out <= tx_byte[7-bit_cnt];
            if (bit_cnt == 4'd7) begin
              bit_cnt <= '0; sd_oe <= 1'b0; state <= ST_PARK;
            end else bit_cnt <= bit_cnt + 1'b1;
          end
        end
        ST_PARK: if (sclk_fall) begin
          sd_oe <= 1'b0; state <= ST_IDLE;     // bus park then idle
        end
        default: state <= ST_IDLE;
      endcase
    end
  end

endmodule
""",
tb="""// Self-checking testbench: TB acts as RFFE master -- SystemVerilog
`timescale 1ns/1ps
module DigRF_tb;
  logic clk = 0, rst_n = 0;
  tri1  sdata;
  logic sclk = 0;
  logic m_oe = 0, m_val = 1;
  logic [7:0] rx_byte, rx_addr;
  logic rx_valid, busy;
  logic rx_seen = 0;
  int errors = 0;

  DigRF_top #(.RFFE_ADDR(2'b01)) dut (
    .clk(clk), .rst_n(rst_n), .sdata(sdata), .sclk(sclk),
    .rx_byte(rx_byte), .rx_addr(rx_addr), .rx_valid(rx_valid),
    .tx_byte(8'hC3), .busy(busy), .irq());

  always #5 clk = ~clk;
  assign sdata = m_oe ? m_val : 1'bz;
  always @(posedge clk) if (rx_valid) rx_seen <= 1'b1;

  task automatic rbit(input logic b);
    begin m_oe = 1; m_val = b; #300; sclk = 1; #600; sclk = 0; #300; end
  endtask
  task automatic rrelease_bit(output logic b);
    begin m_oe = 0; #300; sclk = 1; #300; b = sdata; #300; sclk = 0; #300; end
  endtask
  task automatic rssc;
    begin m_oe = 0; m_val = 1; sclk = 1; #300;   // SCLK high first
          m_oe = 1; m_val = 0; #300;             // SDATA falls while SCLK high
          sclk = 0; #300;
          m_oe = 0; #300; end
  endtask

  task automatic rffe_write(input logic [1:0] sa, input logic [4:0] ad,
                            input logic [7:0] data);
    begin
      rssc;
      rbit(sa[1]); rbit(sa[0]); rbit(1'b0);       // PC=0 write
      for (int i = 4; i >= 0; i--) rbit(ad[i]);
      for (int i = 7; i >= 0; i--) rbit(data[i]);
      rbit(1'b1);                                  // bus park
      m_oe = 0; #600;
    end
  endtask

  task automatic rffe_read(input logic [1:0] sa, input logic [4:0] ad,
                           output logic [7:0] data);
    logic b;
    begin
      rssc;
      rbit(sa[1]); rbit(sa[0]); rbit(1'b1);       // PC=1 read
      for (int i = 4; i >= 0; i--) rbit(ad[i]);
      for (int i = 7; i >= 0; i--) begin
        rrelease_bit(b);
        data[i] = b;
      end
      rbit(1'b1);
      m_oe = 0; #600;
    end
  endtask

  logic [7:0] rb;
  initial begin
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(10) @(posedge clk);

    rffe_write(2'b01, 5'h03, 8'h5A);
    repeat(5) @(posedge clk);
    if (!rx_seen) begin errors++; $display("ERROR: DigRF rx_valid never pulsed"); end
    if (rx_byte !== 8'h5A) begin errors++; $display("ERROR: DigRF rx=%h exp=5A", rx_byte); end
    if (rx_addr !== 5'h03) begin errors++; $display("ERROR: DigRF rx_addr=%h exp=03", rx_addr); end

    rffe_read (2'b01, 5'h03, rb);
    if (rb !== 8'hC3) begin errors++; $display("ERROR: DigRF read got=%h exp=C3", rb); end

    if (errors == 0) $display("TEST PASSED: DigRF");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #3_000_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")

CUSTOM["HSI"] = dict(
rtl="""// ============================================================================
// HSI simplified 2-wire reg r/w.
// Write (PC=0): master sends data; Read (PC=1): slave drives data (push-pull).
// OpenCores rffe/pmic style register interface.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module HSI_top #(
  parameter logic [1:0] RFFE_ADDR = 2'b01
)(
  input  logic       clk,
  input  logic       rst_n,
  inout  tri         sdata,
  input  logic       sclk,
  output logic [7:0] rx_byte,        // {AD, data} register write captured
  output logic [7:0] rx_addr,
  output logic       rx_valid,
  input  logic [7:0] tx_byte,        // data returned for reads
  output logic       busy,
  output logic       irq
);
  logic sclk_s, sclk_d, sdata_s, sdata_d;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sclk_s <= 1'b0; sclk_d <= 1'b0; sdata_s <= 1'b1; sdata_d <= 1'b1;
    end else begin
      sclk_s <= sclk; sclk_d <= sclk_s;
      sdata_s <= sdata; sdata_d <= sdata_s;
    end
  end
  wire sclk_rise =  sclk_s & ~sclk_d;
  wire sclk_fall = ~sclk_s &  sclk_d;
  wire ssc_det   = ~sdata_s &  sdata_d & sclk_s;   // SSC: sdata falls while sclk high

  typedef enum logic [1:0] {ST_IDLE, ST_HEAD, ST_DATA, ST_PARK} st_t;
  st_t      state;
  logic [3:0] bit_cnt;     // HEAD: 0..2 (SA+PC), then AD folds into HEAD 3..7
  logic [7:0] shift;
  logic       rw;
  logic       sd_oe, sd_out;

  assign sdata   = sd_oe ? sd_out : 1'bz;
  assign busy    = (state != ST_IDLE);
  assign irq     = rx_valid;
  assign rx_addr = {3'b000, shift_hold};

  logic [4:0] shift_hold;  // captured register address

  wire [7:0] head_w = {shift[6:0], sdata_s};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= ST_IDLE; bit_cnt <= '0; shift <= '0; shift_hold <= '0;
      rw <= 1'b0; sd_oe <= 1'b0; sd_out <= 1'b1; rx_valid <= 1'b0;
    end else begin
      rx_valid <= 1'b0;
      if (ssc_det) begin
        state <= ST_HEAD; bit_cnt <= '0; sd_oe <= 1'b0;
      end else case (state)
        ST_HEAD: if (sclk_rise) begin
          shift <= head_w;
          if (bit_cnt == 4'd7) begin
            // head_w = {SA[1:0], PC, AD[4:0]}
            if (head_w[7:6] == RFFE_ADDR) begin
              rw <= head_w[5];
              shift_hold <= head_w[4:0];
              bit_cnt <= '0;
              state <= ST_DATA;
            end else state <= ST_IDLE;
          end else bit_cnt <= bit_cnt + 1'b1;
        end
        ST_DATA: begin
          if (!rw && sclk_rise) begin          // write: sample master's data
            shift <= head_w;
            if (bit_cnt == 4'd7) begin
              rx_byte <= head_w;
              bit_cnt <= '0; state <= ST_PARK; rx_valid <= 1'b1;
            end else bit_cnt <= bit_cnt + 1'b1;
          end else if (rw && sclk_fall) begin  // read: drive next data bit
            sd_oe <= 1'b1;
            sd_out <= tx_byte[7-bit_cnt];
            if (bit_cnt == 4'd7) begin
              bit_cnt <= '0; sd_oe <= 1'b0; state <= ST_PARK;
            end else bit_cnt <= bit_cnt + 1'b1;
          end
        end
        ST_PARK: if (sclk_fall) begin
          sd_oe <= 1'b0; state <= ST_IDLE;     // bus park then idle
        end
        default: state <= ST_IDLE;
      endcase
    end
  end

endmodule
""",
tb="""// Self-checking testbench: TB acts as RFFE master -- SystemVerilog
`timescale 1ns/1ps
module HSI_tb;
  logic clk = 0, rst_n = 0;
  tri1  sdata;
  logic sclk = 0;
  logic m_oe = 0, m_val = 1;
  logic [7:0] rx_byte, rx_addr;
  logic rx_valid, busy;
  logic rx_seen = 0;
  int errors = 0;

  HSI_top #(.RFFE_ADDR(2'b01)) dut (
    .clk(clk), .rst_n(rst_n), .sdata(sdata), .sclk(sclk),
    .rx_byte(rx_byte), .rx_addr(rx_addr), .rx_valid(rx_valid),
    .tx_byte(8'hC3), .busy(busy), .irq());

  always #5 clk = ~clk;
  assign sdata = m_oe ? m_val : 1'bz;
  always @(posedge clk) if (rx_valid) rx_seen <= 1'b1;

  task automatic rbit(input logic b);
    begin m_oe = 1; m_val = b; #300; sclk = 1; #600; sclk = 0; #300; end
  endtask
  task automatic rrelease_bit(output logic b);
    begin m_oe = 0; #300; sclk = 1; #300; b = sdata; #300; sclk = 0; #300; end
  endtask
  task automatic rssc;
    begin m_oe = 0; m_val = 1; sclk = 1; #300;   // SCLK high first
          m_oe = 1; m_val = 0; #300;             // SDATA falls while SCLK high
          sclk = 0; #300;
          m_oe = 0; #300; end
  endtask

  task automatic rffe_write(input logic [1:0] sa, input logic [4:0] ad,
                            input logic [7:0] data);
    begin
      rssc;
      rbit(sa[1]); rbit(sa[0]); rbit(1'b0);       // PC=0 write
      for (int i = 4; i >= 0; i--) rbit(ad[i]);
      for (int i = 7; i >= 0; i--) rbit(data[i]);
      rbit(1'b1);                                  // bus park
      m_oe = 0; #600;
    end
  endtask

  task automatic rffe_read(input logic [1:0] sa, input logic [4:0] ad,
                           output logic [7:0] data);
    logic b;
    begin
      rssc;
      rbit(sa[1]); rbit(sa[0]); rbit(1'b1);       // PC=1 read
      for (int i = 4; i >= 0; i--) rbit(ad[i]);
      for (int i = 7; i >= 0; i--) begin
        rrelease_bit(b);
        data[i] = b;
      end
      rbit(1'b1);
      m_oe = 0; #600;
    end
  endtask

  logic [7:0] rb;
  initial begin
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(10) @(posedge clk);

    rffe_write(2'b01, 5'h03, 8'h5A);
    repeat(5) @(posedge clk);
    if (!rx_seen) begin errors++; $display("ERROR: HSI rx_valid never pulsed"); end
    if (rx_byte !== 8'h5A) begin errors++; $display("ERROR: HSI rx=%h exp=5A", rx_byte); end
    if (rx_addr !== 5'h03) begin errors++; $display("ERROR: HSI rx_addr=%h exp=03", rx_addr); end

    rffe_read (2'b01, 5'h03, rb);
    if (rb !== 8'hC3) begin errors++; $display("ERROR: HSI read got=%h exp=C3", rb); end

    if (errors == 0) $display("TEST PASSED: HSI");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #3_000_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")

CUSTOM["MIPI DBI (Display Bus Interface)"] = dict(
rtl="""// ============================================================================
// DBI simplified display-bus reg r/w.
// Write (PC=0): master sends data; Read (PC=1): slave drives data (push-pull).
// OpenCores rffe/pmic style register interface.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module MIPI_DBI__Display_Bus_Interface__top #(
  parameter logic [1:0] RFFE_ADDR = 2'b01
)(
  input  logic       clk,
  input  logic       rst_n,
  inout  tri         sdata,
  input  logic       sclk,
  output logic [7:0] rx_byte,        // {AD, data} register write captured
  output logic [7:0] rx_addr,
  output logic       rx_valid,
  input  logic [7:0] tx_byte,        // data returned for reads
  output logic       busy,
  output logic       irq
);
  logic sclk_s, sclk_d, sdata_s, sdata_d;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sclk_s <= 1'b0; sclk_d <= 1'b0; sdata_s <= 1'b1; sdata_d <= 1'b1;
    end else begin
      sclk_s <= sclk; sclk_d <= sclk_s;
      sdata_s <= sdata; sdata_d <= sdata_s;
    end
  end
  wire sclk_rise =  sclk_s & ~sclk_d;
  wire sclk_fall = ~sclk_s &  sclk_d;
  wire ssc_det   = ~sdata_s &  sdata_d & sclk_s;   // SSC: sdata falls while sclk high

  typedef enum logic [1:0] {ST_IDLE, ST_HEAD, ST_DATA, ST_PARK} st_t;
  st_t      state;
  logic [3:0] bit_cnt;     // HEAD: 0..2 (SA+PC), then AD folds into HEAD 3..7
  logic [7:0] shift;
  logic       rw;
  logic       sd_oe, sd_out;

  assign sdata   = sd_oe ? sd_out : 1'bz;
  assign busy    = (state != ST_IDLE);
  assign irq     = rx_valid;
  assign rx_addr = {3'b000, shift_hold};

  logic [4:0] shift_hold;  // captured register address

  wire [7:0] head_w = {shift[6:0], sdata_s};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= ST_IDLE; bit_cnt <= '0; shift <= '0; shift_hold <= '0;
      rw <= 1'b0; sd_oe <= 1'b0; sd_out <= 1'b1; rx_valid <= 1'b0;
    end else begin
      rx_valid <= 1'b0;
      if (ssc_det) begin
        state <= ST_HEAD; bit_cnt <= '0; sd_oe <= 1'b0;
      end else case (state)
        ST_HEAD: if (sclk_rise) begin
          shift <= head_w;
          if (bit_cnt == 4'd7) begin
            // head_w = {SA[1:0], PC, AD[4:0]}
            if (head_w[7:6] == RFFE_ADDR) begin
              rw <= head_w[5];
              shift_hold <= head_w[4:0];
              bit_cnt <= '0;
              state <= ST_DATA;
            end else state <= ST_IDLE;
          end else bit_cnt <= bit_cnt + 1'b1;
        end
        ST_DATA: begin
          if (!rw && sclk_rise) begin          // write: sample master's data
            shift <= head_w;
            if (bit_cnt == 4'd7) begin
              rx_byte <= head_w;
              bit_cnt <= '0; state <= ST_PARK; rx_valid <= 1'b1;
            end else bit_cnt <= bit_cnt + 1'b1;
          end else if (rw && sclk_fall) begin  // read: drive next data bit
            sd_oe <= 1'b1;
            sd_out <= tx_byte[7-bit_cnt];
            if (bit_cnt == 4'd7) begin
              bit_cnt <= '0; sd_oe <= 1'b0; state <= ST_PARK;
            end else bit_cnt <= bit_cnt + 1'b1;
          end
        end
        ST_PARK: if (sclk_fall) begin
          sd_oe <= 1'b0; state <= ST_IDLE;     // bus park then idle
        end
        default: state <= ST_IDLE;
      endcase
    end
  end

endmodule
""",
tb="""// Self-checking testbench: TB acts as RFFE master -- SystemVerilog
`timescale 1ns/1ps
module MIPI_DBI__Display_Bus_Interface__tb;
  logic clk = 0, rst_n = 0;
  tri1  sdata;
  logic sclk = 0;
  logic m_oe = 0, m_val = 1;
  logic [7:0] rx_byte, rx_addr;
  logic rx_valid, busy;
  logic rx_seen = 0;
  int errors = 0;

  MIPI_DBI__Display_Bus_Interface__top #(.RFFE_ADDR(2'b01)) dut (
    .clk(clk), .rst_n(rst_n), .sdata(sdata), .sclk(sclk),
    .rx_byte(rx_byte), .rx_addr(rx_addr), .rx_valid(rx_valid),
    .tx_byte(8'hC3), .busy(busy), .irq());

  always #5 clk = ~clk;
  assign sdata = m_oe ? m_val : 1'bz;
  always @(posedge clk) if (rx_valid) rx_seen <= 1'b1;

  task automatic rbit(input logic b);
    begin m_oe = 1; m_val = b; #300; sclk = 1; #600; sclk = 0; #300; end
  endtask
  task automatic rrelease_bit(output logic b);
    begin m_oe = 0; #300; sclk = 1; #300; b = sdata; #300; sclk = 0; #300; end
  endtask
  task automatic rssc;
    begin m_oe = 0; m_val = 1; sclk = 1; #300;   // SCLK high first
          m_oe = 1; m_val = 0; #300;             // SDATA falls while SCLK high
          sclk = 0; #300;
          m_oe = 0; #300; end
  endtask

  task automatic rffe_write(input logic [1:0] sa, input logic [4:0] ad,
                            input logic [7:0] data);
    begin
      rssc;
      rbit(sa[1]); rbit(sa[0]); rbit(1'b0);       // PC=0 write
      for (int i = 4; i >= 0; i--) rbit(ad[i]);
      for (int i = 7; i >= 0; i--) rbit(data[i]);
      rbit(1'b1);                                  // bus park
      m_oe = 0; #600;
    end
  endtask

  task automatic rffe_read(input logic [1:0] sa, input logic [4:0] ad,
                           output logic [7:0] data);
    logic b;
    begin
      rssc;
      rbit(sa[1]); rbit(sa[0]); rbit(1'b1);       // PC=1 read
      for (int i = 4; i >= 0; i--) rbit(ad[i]);
      for (int i = 7; i >= 0; i--) begin
        rrelease_bit(b);
        data[i] = b;
      end
      rbit(1'b1);
      m_oe = 0; #600;
    end
  endtask

  logic [7:0] rb;
  initial begin
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(10) @(posedge clk);

    rffe_write(2'b01, 5'h03, 8'h5A);
    repeat(5) @(posedge clk);
    if (!rx_seen) begin errors++; $display("ERROR: MIPI DBI (Display Bus Interface) rx_valid never pulsed"); end
    if (rx_byte !== 8'h5A) begin errors++; $display("ERROR: MIPI DBI (Display Bus Interface) rx=%h exp=5A", rx_byte); end
    if (rx_addr !== 5'h03) begin errors++; $display("ERROR: MIPI DBI (Display Bus Interface) rx_addr=%h exp=03", rx_addr); end

    rffe_read (2'b01, 5'h03, rb);
    if (rb !== 8'hC3) begin errors++; $display("ERROR: MIPI DBI (Display Bus Interface) read got=%h exp=C3", rb); end

    if (errors == 0) $display("TEST PASSED: MIPI DBI (Display Bus Interface)");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #3_000_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")

CUSTOM["ARM Serial Wire Debug"] = dict(
rtl="""// ============================================================================
// SWD simplified start+32b+parity frame.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module ARM_Serial_Wire_Debug_top #(
  parameter int CLK_FREQ = 50_000_000,
  parameter int BAUD     = 115_200
)(
  input  logic       clk,
  input  logic       rst_n,
  input  logic       rxd,
  output logic       txd,
  input  logic [7:0] tx_data,
  input  logic       tx_valid,
  output logic       tx_ready,
  output logic [7:0] rx_data,
  output logic       rx_valid,
  output logic       irq
);
  localparam int DIV16 = (CLK_FREQ / BAUD) / 16;

  // ---------------- 16x baud tick ----------------
  logic [15:0] div_cnt;
  logic        tick16;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      div_cnt <= '0;
      tick16  <= 1'b0;
    end else if (div_cnt == DIV16-1) begin
      div_cnt <= '0;
      tick16  <= 1'b1;
    end else begin
      div_cnt <= div_cnt + 1'b1;
      tick16  <= 1'b0;
    end
  end

  // ---------------- TX: 8N1 ----------------
  typedef enum logic [1:0] {TX_IDLE, TX_START, TX_DATA, TX_STOP} tx_t;
  tx_t        tstate;
  logic [3:0] tsub, tbit;
  logic [7:0] tshift;

  assign tx_ready = (tstate == TX_IDLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tstate <= TX_IDLE; txd <= 1'b1;
      tsub <= '0; tbit <= '0; tshift <= '0;
    end else case (tstate)
      TX_IDLE: if (tx_valid) begin
        tshift <= tx_data; tstate <= TX_START;
        txd <= 1'b0; tsub <= '0;
      end
      TX_START: if (tick16) begin
        if (tsub == 4'd15) begin
          tsub <= '0; tbit <= '0;
          txd <= tshift[0];
          tshift <= {1'b0, tshift[7:1]};
          tstate <= TX_DATA;
        end else tsub <= tsub + 1'b1;
      end
      TX_DATA: if (tick16) begin
        if (tsub == 4'd15) begin
          tsub <= '0;
          if (tbit == 4'd7) begin
            txd <= 1'b1;
            tstate <= TX_STOP;
          end else begin
            tbit <= tbit + 1'b1;
            txd <= tshift[0];
            tshift <= {1'b0, tshift[7:1]};
          end
        end else tsub <= tsub + 1'b1;
      end
      TX_STOP: if (tick16) begin
        if (tsub == 4'd15) begin
          tsub <= '0;
          tstate <= TX_IDLE;
        end else tsub <= tsub + 1'b1;
      end
      default: tstate <= TX_IDLE;
    endcase
  end

  // ---------------- RX: 8N1, 16x oversample ----------------
  logic rxd_s, rxd_d;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rxd_s <= 1'b1; rxd_d <= 1'b1; end
    else begin rxd_s <= rxd; rxd_d <= rxd_s; end
  end
  wire start_det = rxd_d & ~rxd_s;

  typedef enum logic [1:0] {RX_IDLE, RX_START, RX_DATA, RX_STOP} rx_t;
  rx_t        rstate;
  logic [3:0] rsub, rbit;
  logic [7:0] rshift;

  assign rx_valid = (rstate == RX_STOP) && tick16 && (rsub == 4'd7);
  assign irq      = rx_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rstate <= RX_IDLE; rsub <= '0; rbit <= '0;
      rshift <= '0; rx_data <= '0;
    end else case (rstate)
      RX_IDLE: if (start_det) begin
        rstate <= RX_START; rsub <= '0;
      end
      RX_START: if (tick16) begin
        if (rsub == 4'd7) begin
          rsub <= '0;
          rstate <= rxd_s ? RX_IDLE : RX_DATA;
        end else rsub <= rsub + 1'b1;
      end
      RX_DATA: if (tick16) begin
        if (rsub == 4'd15) begin
          rsub <= '0;
          rshift <= {rxd_s, rshift[7:1]};
          if (rbit == 4'd7) begin
            rbit <= '0;
            rx_data <= {rxd_s, rshift[7:1]};
            rstate <= RX_STOP;
          end else rbit <= rbit + 1'b1;
        end else rsub <= rsub + 1'b1;
      end
      RX_STOP: if (tick16) begin
        if (rsub == 4'd7) begin          // half stop bit: return to IDLE sooner
          rsub <= '0;
          rstate <= RX_IDLE;
        end else rsub <= rsub + 1'b1;
      end
      default: rstate <= RX_IDLE;
    endcase
  end

endmodule
""",
tb="""// Self-checking loopback testbench for UART_top -- SystemVerilog
`timescale 1ns/1ps
module ARM_Serial_Wire_Debug_tb;
  localparam int N = 8;
  logic clk = 0, rst_n = 0;
  logic rxd, txd;
  logic [7:0] tx_data;
  logic tx_valid, tx_ready;
  logic [7:0] rx_data;
  logic rx_valid;
  logic [7:0] sent [0:N-1];
  int errors = 0;

  ARM_Serial_Wire_Debug_top #(.CLK_FREQ(50_000_000), .BAUD(1_000_000)) dut (
    .clk(clk), .rst_n(rst_n), .rxd(rxd), .txd(txd),
    .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
    .rx_data(rx_data), .rx_valid(rx_valid), .irq());

  always #5 clk = ~clk;
  assign rxd = txd;    // loopback

  initial begin
    tx_valid = 0; tx_data = 0;
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(20) @(posedge clk);
    for (int i = 0; i < N; i++) begin
      sent[i] = 8'hA5 ^ (i * 8'h11);
      wait (tx_ready === 1'b1);        // ensure TX is idle before requesting
      @(negedge clk);
      tx_data  <= sent[i];
      tx_valid <= 1'b1;
      wait (tx_ready === 1'b0);        // now this edge means real acceptance
      @(negedge clk);
      tx_valid <= 1'b0;
      wait (rx_valid === 1'b1);
      @(posedge clk); #1;
      if (rx_data !== sent[i]) begin
        errors++;
        $display("ERROR: ARM Serial Wire Debug byte %0d got=%h exp=%h", i, rx_data, sent[i]);
      end
      repeat (40) @(posedge clk);   // inter-frame idle: RX back to IDLE
    end
    if (errors == 0) $display("TEST PASSED: ARM Serial Wire Debug");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #5_000_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")

CUSTOM["DDR7"] = dict(
rtl="""// ============================================================================
// DDR7: 2ch over MEMCH (PROTOCOL=15).
// Educational slice of DDR6; gem5 trace port unchanged.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module DDR7_top (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        hvalid,
  output logic        hready,
  input  logic [2:0]  hcmd,
  input  logic [31:0] haddr,
  input  logic [15:0] hwdata,
  output logic [15:0] hrdata,
  output logic        hdone,
  output logic        ck_t, ck_c,
    output logic [16:0] addr,
  output logic        ras_n, cas_n, we_n,

  inout  tri [31:0]   dq,
  inout  tri [1:0]    dqs,
  output logic        cke,
  output logic        trace_valid,
  output logic [2:0]  trace_cmd,
  output logic [31:0] trace_addr
);
  MEMCH_top #(.PROTOCOL(15), .NCH(2), .CL(20), .TRCD(12), .TRP(12)) core (.*);
endmodule
""",
tb="""// DDR6 TB: ch0 read/write + ch1 isolation + channel isolation.
`timescale 1ns/1ps
module DDR7_tb;
  logic clk = 0, rst_n = 0;
  logic hvalid = 0, hready;
  logic [2:0] hcmd = 0;
  logic [31:0] haddr = 0;
  logic [15:0] hwdata = 0, hrdata;
  logic hdone;
  logic ck_t, ck_c;
  logic [16:0] addr; logic ras_n, cas_n, we_n;
  tri [31:0] dq; tri [1:0] dqs; logic cke;
  logic trace_valid; logic [2:0] trace_cmd; logic [31:0] trace_addr;
  int errors = 0;

  DDR7_top dut (.*);
  always #5 clk = ~clk;

  task automatic cmd(input logic [2:0] c, input logic [31:0] a, input logic [15:0] d);
    begin
      wait (hready === 1'b1);
      @(negedge clk);
      hcmd <= c; haddr <= a; hwdata <= d; hvalid <= 1'b1;
      @(negedge clk);
      hvalid <= 1'b0;
    end
  endtask

  logic [15:0] got;
  initial begin
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);
    cmd(3'd1, 32'h000, 16'h0);
    repeat(3) @(posedge clk);
    for (int i = 0; i < 4; i++) cmd(3'd3, i, 16'h1444 + i * 8'h11);
    for (int i = 0; i < 4; i++) begin
      cmd(3'd2, i, 16'h0);
      wait (hdone === 1'b1); @(posedge clk); #1;
      got = hrdata;
      if (got !== 16'h1444 + i * 8'h11) begin
        errors++; $display("ERROR: DDR7 ch0[%0d] got=%h", i, got);
      end
    end
    // channel 1 (haddr[8]=1): distinct data, same column -> isolation check
    cmd(3'd1, 32'h100, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd3, 32'h100, 16'h154501);
    cmd(3'd1, 32'h100, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd2, 32'h100, 16'h0);
    wait (hdone === 1'b1); @(posedge clk); #1;
    got = hrdata;
    if (got !== 16'h154501) begin
      errors++; $display("ERROR: DDR7 ch1[0] got=%h exp=154501", got);
    end
    // channel 0 data must be untouched
    cmd(3'd1, 32'h000, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd2, 32'h000, 16'h0);
    wait (hdone === 1'b1); @(posedge clk); #1;
    got = hrdata;
    if (got !== 16'h1444) begin
      errors++; $display("ERROR: DDR7 ch0[0] after ch1 traffic got=%h exp=1444", got);
    end
    if (errors == 0) $display("TEST PASSED: DDR7");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #500_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")

CUSTOM["LPDDR7"] = dict(
rtl="""// ============================================================================
// LPDDR7: 2ch CA over MEMCH (PROTOCOL=16).
// Educational slice of LPDDR6; gem5 trace port unchanged.
// Auto-generated by gen_framework.py -- Apache-2.0
// ============================================================================
module LPDDR7_top (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        hvalid,
  output logic        hready,
  input  logic [2:0]  hcmd,
  input  logic [31:0] haddr,
  input  logic [15:0] hwdata,
  output logic [15:0] hrdata,
  output logic        hdone,
  output logic        ck_t, ck_c,
    output logic [7:0]  ca,
  output logic        cs_n,

  inout  tri [31:0]   dq,
  inout  tri [1:0]    dqs,
  output logic        cke,
  output logic        trace_valid,
  output logic [2:0]  trace_cmd,
  output logic [31:0] trace_addr
);
  logic [16:0] addr_full;
  logic ras_n, cas_n, we_n;

  MEMCH_top #(.PROTOCOL(16), .NCH(2), .CL(12), .TRCD(4), .TRP(4)) core (
    .clk(clk), .rst_n(rst_n),
    .hvalid(hvalid), .hready(hready), .hcmd(hcmd), .haddr(haddr),
    .hwdata(hwdata), .hrdata(hrdata), .hdone(hdone),
    .ck_t(ck_t), .ck_c(ck_c), .addr(addr_full),
    .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
    .dq(dq), .dqs(dqs), .cke(cke),
    .trace_valid(trace_valid), .trace_cmd(trace_cmd), .trace_addr(trace_addr));

  assign ca = {2'b00, ras_n, cas_n, we_n, addr_full[2:0]};
  assign cs_n = ras_n & cas_n & we_n;
endmodule
""",
tb="""// LPDDR6 TB: ch0 read/write + ch1 isolation + channel isolation.
`timescale 1ns/1ps
module LPDDR7_tb;
  logic clk = 0, rst_n = 0;
  logic hvalid = 0, hready;
  logic [2:0] hcmd = 0;
  logic [31:0] haddr = 0;
  logic [15:0] hwdata = 0, hrdata;
  logic hdone;
  logic ck_t, ck_c;
  logic [7:0] ca; logic cs_n;
  tri [31:0] dq; tri [1:0] dqs; logic cke;
  logic trace_valid; logic [2:0] trace_cmd; logic [31:0] trace_addr;
  int errors = 0;

  LPDDR7_top dut (.*);
  always #5 clk = ~clk;

  task automatic cmd(input logic [2:0] c, input logic [31:0] a, input logic [15:0] d);
    begin
      wait (hready === 1'b1);
      @(negedge clk);
      hcmd <= c; haddr <= a; hwdata <= d; hvalid <= 1'b1;
      @(negedge clk);
      hvalid <= 1'b0;
    end
  endtask

  logic [15:0] got;
  initial begin
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);
    cmd(3'd1, 32'h000, 16'h0);
    repeat(3) @(posedge clk);
    for (int i = 0; i < 4; i++) cmd(3'd3, i, 16'h1666 + i * 8'h11);
    for (int i = 0; i < 4; i++) begin
      cmd(3'd2, i, 16'h0);
      wait (hdone === 1'b1); @(posedge clk); #1;
      got = hrdata;
      if (got !== 16'h1666 + i * 8'h11) begin
        errors++; $display("ERROR: LPDDR7 ch0[%0d] got=%h", i, got);
      end
    end
    // channel 1 (haddr[8]=1): distinct data, same column -> isolation check
    cmd(3'd1, 32'h100, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd3, 32'h100, 16'h176701);
    cmd(3'd1, 32'h100, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd2, 32'h100, 16'h0);
    wait (hdone === 1'b1); @(posedge clk); #1;
    got = hrdata;
    if (got !== 16'h176701) begin
      errors++; $display("ERROR: LPDDR7 ch1[0] got=%h exp=176701", got);
    end
    // channel 0 data must be untouched
    cmd(3'd1, 32'h000, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd2, 32'h000, 16'h0);
    wait (hdone === 1'b1); @(posedge clk); #1;
    got = hrdata;
    if (got !== 16'h1666) begin
      errors++; $display("ERROR: LPDDR7 ch0[0] after ch1 traffic got=%h exp=1666", got);
    end
    if (errors == 0) $display("TEST PASSED: LPDDR7");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #500_000; $display("TIMEOUT"); $finish;
  end
endmodule
""")

if __name__ == "__main__":
    csv_path = sys.argv[1] if len(sys.argv) > 1 else "/mnt/agents/temp/table_1788849587.csv"
    plist = read_protocols(csv_path)
    for P in plist:
        generate(P)
        print("generated:", P)
