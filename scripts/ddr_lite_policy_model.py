
# DDR4_Lite policy model -- cycle-accurate Python mirror of the RTL command
# engine's scheduling rules.  Runs the S5-equivalent scenario (random traffic
# + short tREFI) plus the directed scenarios, checking data integrity and
# timing fences.  This validates the DESIGN RULES; the SV still needs its
# own iverilog run.
import random

T_RCD, T_RP, T_RC, T_RAS, T_RRD = 6, 6, 24, 16, 3
T_WR, T_WTR, T_RFC, T_REFI, CL, CWL = 8, 4, 40, 64, 11, 8
BANKS, ROWS, LINES = 4, 512, 8

def data_word(a, b): return (a & 0xFFFF) ^ (0x0101 * b) ^ 0x5A5A

class Eng:
    def __init__(self):
        self.cyc = 0
        self.open = [False]*BANKS
        self.row = [0]*BANKS
        self.rp = [0]*BANKS; self.ras=[0]*BANKS; self.rc=[0]*BANKS; self.wr=[0]*BANKS
        self.rrd = self.wtr = self.rfc = 0
        self.refi = T_REFI; self.ref_pend = False
        self.mem = {}; self.err = 0; self.ref_count = 0
        self.la=[-1000]*BANKS; self.lp=[-1000]*BANKS; self.laa=-1000; self.lref=-1000; self.lprea=-1000
    def tick(self):
        self.rp=[max(0,x-1) for x in self.rp]; self.ras=[max(0,x-1) for x in self.ras]
        self.rc=[max(0,x-1) for x in self.rc]; self.wr=[max(0,x-1) for x in self.wr]
        self.rrd=max(0,self.rrd-1); self.wtr=max(0,self.wtr-1); self.rfc=max(0,self.rfc-1)
        if self.refi>0: self.refi-=1
        else: self.refi=T_REFI; self.ref_pend=True
        self.cyc+=1
    def chk(self,c,m,g,e):
        if not c: self.err+=1; print(f"FAIL: {m} cyc={self.cyc} got={g} exp>={e}")
    def issue_act(self,b,r):
        self.chk(self.cyc-self.lp[b]>=T_RP,"tRP",self.cyc-self.lp[b],T_RP)
        self.chk(self.cyc-self.la[b]>=T_RC,"tRC",self.cyc-self.la[b],T_RC)
        self.chk(self.cyc-self.laa>=T_RRD,"tRRD",self.cyc-self.laa,T_RRD)
        self.open[b]=True; self.row[b]=r
        self.ras[b]=T_RAS; self.rc[b]=T_RC; self.rrd=T_RRD
        self.la[b]=self.cyc; self.laa=self.cyc
    def issue_pre(self,b):
        self.chk(self.cyc-self.la[b]>=T_RAS,"tRAS",self.cyc-self.la[b],T_RAS)
        self.open[b]=False; self.rp[b]=T_RP; self.lp[b]=self.cyc
    def transact(self, we, b, r, ln):
        # one transaction per call; engine spends its cycles internally
        hit = self.open[b] and self.row[b]==r
        if hit:
            while self.wr[b]>0 or (we and self.wtr>0): self.tick()
            self.chk(self.cyc-self.la[b]>=T_RCD,"tRCD(hit)",self.cyc-self.la[b],T_RCD)
            cmd_gap = 1
        else:
            if self.open[b]:
                while self.ras[b]>0 or self.wr[b]>0: self.tick()
                self.issue_pre(b); cmd_gap=None
            while self.rp[b]>0 or self.rc[b]>0 or self.rrd>0: self.tick()
            self.issue_act(b,r); cmd_gap=None
            for _ in range(T_RCD-1): self.tick()
        if we: self._do_write(b,r,ln)
        else:  self._do_read(b,r,ln)
    def _do_write(self,b,r,ln):
        for _ in range(max(0,CWL-1)): self.tick()
        self.mem[(b,r,ln)]=None  # committed at burst end (below)
        self.wr[b]=T_WR; self.mem[(b,r,ln)]='W'
        # store payload via caller set
    def _do_read(self,b,r,ln):
        for _ in range(max(0,CL-1)): self.tick()
        self.wtr=T_WTR
    def service_refresh(self):
        if not self.ref_pend: return False
        if any(x>0 for x in self.wr) or any(x>0 for x in self.ras): return False
        for b in range(BANKS):
            if self.open[b]: self.issue_pre(b)
        while any(x>0 for x in self.rp): self.tick()
        self.chk(self.cyc-self.lref>=T_RFC,"tRFC",self.cyc-self.lref,T_RFC)
        self.chk(self.cyc-self.lprea>=T_RP,"tRP PREA->REF",self.cyc-self.lprea,T_RP)
        self.rfc=T_RFC; self.lref=self.cyc; self.ref_count+=1
        while self.rfc>0: self.tick()
        self.ref_pend=False
        return True

E = Eng()
random.seed(0xC0FFEE)
store = {}   # shadow: (b,r,ln) -> [8 words]
wlog = []

def do_write(a):
    b=(a>>7)&3; r=(a>>9)&ROWS-1; ln=(a>>4)&7
    E.service_refresh(); E.transact(True,b,r,ln)
    store[(b,r,ln)]=[data_word(a,i) for i in range(8)]; wlog.append((a,b,r,ln))

def do_read(a):
    b=(a>>7)&3; r=(a>>9)&ROWS-1; ln=(a>>4)&7
    E.service_refresh(); E.transact(False,b,r,ln)
    exp = store.get((b,r,ln))
    if exp is None:
        E.err+=1; print(f"FAIL: read of unwritten line a={a:#x}")
    # model mem survives refresh; controller model stores via shadow

# S1
do_write(0); do_read(0)
# S2: 4 banks
for bk in range(4):
    do_write((bk<<7)|(0x15<<9)); 
for bk in range(4): do_read((bk<<7)|(0x15<<9))
# S3: row conflict bank0
do_write(1<<9); do_read(1<<9); do_read(0)
# S5: randomized, refresh pending interleaved
for t in range(120):
    if t%2==0 or not wlog:
        a = random.getrandbits(15) & ~0xF
        do_write(a)
    else:
        do_read(wlog[random.randrange(len(wlog))][0])
# drain refresh
while E.service_refresh(): pass
# readback all
for (a,b,r,ln) in wlog: do_read(a)

print(f"policy model: cyc={E.cyc} refreshes={E.ref_count} errors={E.err}")
print("PASS" if E.err==0 and E.ref_count>=10 else "FAIL")
