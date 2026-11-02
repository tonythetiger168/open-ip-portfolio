// SPDX-License-Identifier: Apache-2.0
#include "verilated.h"
#include "verilated_cov.h"
#include "verilated_vcd_c.h"
#include "Vnative_top.h"
#include <memory>
#include <string>
int main(int argc, char** argv) {
  auto context=std::make_unique<VerilatedContext>();
  context->commandArgs(argc,argv);context->traceEverOn(true);
  std::string cov="coverage.dat",wave="wave.vcd";
  for(int i=1;i<argc;++i) {
    std::string a=argv[i];
    if(a.rfind("+cov=",0)==0)cov=a.substr(5);
    if(a.rfind("+wave=",0)==0)wave=a.substr(6);
  }
  auto top=std::make_unique<Vnative_top>(context.get());
  auto trace=std::make_unique<VerilatedVcdC>();
  top->trace(trace.get(),4);trace->open(wave.c_str());
  while(!context->gotFinish()) {
    top->eval();trace->dump(context->time());trace->flush();
    if(!top->eventsPending())break;
    context->time(top->nextTimeSlot());
  }
  top->final();context->coveragep()->write(cov);trace->close();
  return context->gotFinish()?0:2;
}
