// SPDX-License-Identifier: Apache-2.0
// Proposed bounded verification contract, not adopted SoC requirements.
`timescale 1ns/1ps
module memory_contract(
 input logic clk,rst,sel,en,wr,ready,
 input logic [11:0] addr,input logic [3:0] strb,
 input logic [31:0] awaddr,wd,araddr,rdata,
 input logic [3:0] ws,
 input logic av,wv,br,rv,rr,awready,wready,bvalid,arready,rvalid,
 input logic [1:0] bresp,rresp);
 integer order_code=0,bstalls=0,rstalls=0;
 bit seen_w=0,seen_aw=0;
 always @(posedge clk) begin
   if(!rst) begin seen_w<=0;seen_aw<=0;order_code<=0;bstalls<=0;rstalls<=0;end
   else begin
     if(wv && !seen_aw) seen_w<=1;
     if(av && awready) begin
       order_code<=seen_w?1:(wv?2:0);seen_aw<=1;
     end
     if(wv && wready) begin seen_w<=0;seen_aw<=0;end
     if(bvalid && !br) bstalls<=bstalls+1;
     if(bvalid && br) bstalls<=0;
     if(rvalid && !rr) rstalls<=rstalls+1;
     if(rvalid && rr) rstalls<=0;
   end
 end
 covergroup cg @(posedge clk);
   word_index:coverpoint awaddr[9:2] iff(rst && av && awready) {bins word_bin[]={[0:255]};}
   order_cp:coverpoint order_code iff(rst && wv && wready) {bins aw_first={0};bins w_first={1};bins simultaneous={2};}
   strobe_cp:coverpoint ws iff(rst && wv && wready) {bins lanes[]={[0:15]};}
   data_cp:coverpoint ((wd==0)?0:(wd==32'hffffffff)?1:((wd==32'haaaaaaaa)||(wd==32'h55555555))?2:3)
     iff(rst && wv && wready) {bins zero={0};bins ones={1};bins alternating={2};bins other={3};}
   bstall_cp:coverpoint ((bstalls==0)?0:(bstalls==1)?1:2) iff(rst && bvalid && br) {bins none={0};bins one={1};bins multiple={2};}
   rstall_cp:coverpoint ((rstalls==0)?0:(rstalls==1)?1:2) iff(rst && rvalid && rr) {bins none={0};bins one={1};bins multiple={2};}
   bresp_cp:coverpoint bresp iff(rst && bvalid && br) {bins okay={0};}
   rresp_cp:coverpoint rresp iff(rst && rvalid && rr) {bins okay={0};}
   csr_cp:coverpoint addr iff(rst && sel && en) {bins id={0};bins status={4};bins enable={8};bins scratch={16};}
   csr_strobe_cp:coverpoint strb iff(rst && sel && en && wr && addr==16) {bins lanes[]={[0:15]};}
   order_strobe:cross order_cp,strobe_cp iff(rst && wv && wready);
 endgroup
 cg functional=new;

 p_aw_hold:assert property(@(posedge clk) disable iff(!rst) av&&!awready |=> av&&$stable(awaddr));
 aw_hold_ante:cover property(@(posedge clk) disable iff(!rst) av&&!awready);
 aw_hold_done:cover property(@(posedge clk) disable iff(!rst) $past(av&&!awready)&&av&&$stable(awaddr));
 p_w_hold:assert property(@(posedge clk) disable iff(!rst) wv&&!wready |=> wv&&$stable(wd)&&$stable(ws));
 w_hold_ante:cover property(@(posedge clk) disable iff(!rst) wv&&!wready);
 w_hold_done:cover property(@(posedge clk) disable iff(!rst) $past(wv&&!wready)&&wv&&$stable(wd)&&$stable(ws));
 p_ar_hold:assert property(@(posedge clk) disable iff(!rst) rv&&!arready |=> rv&&$stable(araddr));
 ar_hold_ante:cover property(@(posedge clk) disable iff(!rst) rv&&!arready);
 ar_hold_done:cover property(@(posedge clk) disable iff(!rst) $past(rv&&!arready)&&rv&&$stable(araddr));
 p_b_hold:assert property(@(posedge clk) disable iff(!rst) bvalid&&!br |=> bvalid&&$stable(bresp));
 b_hold_ante:cover property(@(posedge clk) disable iff(!rst) bvalid&&!br);
 b_hold_done:cover property(@(posedge clk) disable iff(!rst) $past(bvalid&&!br)&&bvalid&&$stable(bresp));
 p_r_hold:assert property(@(posedge clk) disable iff(!rst) rvalid&&!rr |=> rvalid&&$stable(rresp)&&$stable(rdata));
 r_hold_ante:cover property(@(posedge clk) disable iff(!rst) rvalid&&!rr);
 r_hold_done:cover property(@(posedge clk) disable iff(!rst) $past(rvalid&&!rr)&&rvalid&&$stable(rresp)&&$stable(rdata));
 p_w_to_b:assert property(@(posedge clk) disable iff(!rst) wv&&wready |=> bvalid);
 w_to_b_ante:cover property(@(posedge clk) disable iff(!rst) wv&&wready);
 w_to_b_done:cover property(@(posedge clk) disable iff(!rst) $past(wv&&wready)&&bvalid);
 p_ar_to_r:assert property(@(posedge clk) disable iff(!rst) rv&&arready |=> rvalid);
 ar_to_r_ante:cover property(@(posedge clk) disable iff(!rst) rv&&arready);
 ar_to_r_done:cover property(@(posedge clk) disable iff(!rst) $past(rv&&arready)&&rvalid);
 p_apb_ready:assert property(@(posedge clk) disable iff(!rst) sel&&en |-> ready);
 apb_ready_ante:cover property(@(posedge clk) disable iff(!rst) sel&&en);
 apb_ready_done:cover property(@(posedge clk) disable iff(!rst) sel&&en&&ready);
endmodule
