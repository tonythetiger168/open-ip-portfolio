module width_probe;
      reg [11:0] a; reg [4:0] old_hit,new_hit,bad_hit;
      integer i,j,fd; integer aliases;
      initial begin
        aliases=0;
        for(i=0;i<4096;i=i+1) begin
          a=12'(i);old_hit=0;new_hit=0;bad_hit=0;
          if(a[1:0]==0 && a[11:2]<10'd5) old_hit[a[11:2]]=1;
          if(a[1:0]==0 && a[11:2]<10'd5) new_hit[a[4:2]]=1;
          if(a[1:0]==0 && a[4:2]<3'd5) bad_hit[a[4:2]]=1;
          if(old_hit!==new_hit) $fatal(1,"decode mismatch %h",a);
          if(old_hit!==bad_hit) aliases=aliases+1;
        end
        for(j=0;j<8;j=j+1) begin
          case(j)
            0:fd=0;1:fd=1;2:fd=-1;3:fd=32'h80000000;
            4:fd=32'h7fffffff;5:fd=32'h80000001;
            6:fd=32'h00010000;7:fd=32'hfffffffe;
          endcase
          if((!fd)!==(fd==0)) $fatal(1,"file handle mismatch");
        end
        if(aliases!=635) $fatal(1,"alias negative mutation missed");
        $display("PASS 4096 addresses, 8 signed handles, 635 alias negatives");
      end
    endmodule
