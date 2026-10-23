`timescale 1ns/1ps
// Real upstream MXU, with deterministic synchronous ACT and DRAM bus models.
module tb_mxu;
  import otpu_pkg::*;
  localparam D=128, MCOLS=4, LANES=8, KB=3, N=8;
  bit clk=0; always #5 clk=~clk;
  logic rst=1, start=0, go=0;
  cmd_t cmd='0;
  wire rdy,done,computing;
  wire [5:0] pf_level;
  wire pf_starve,pf_block,pf_u;
  wire [3:0][31:0] pf_uv;
  wire [15:0] act_blk,act_blk2;
  wire [MCOLS-1:0] act_hi,act_ren;
  wire [7:0] act_grp;
  logic [MCOLS*D*8-1:0] act_data='0;
  logic [MCOLS*64-1:0] act_scale='0;
  int cycle=0, writes=0, test_id=0, rows=1, fd;
  wire a_req,b_req;
  wire [31:0] a_addr,b_addr;
  wire a_gnt=1'b1;
  wire b_gnt=!rst && (cycle%5!=0);
  logic a_rvalid=0,b_rvalid=0;
  logic [255:0] a_rdata='0;
  logic [D*8-1:0] b_rdata='0;
  wire [LANES-1:0] t_ren,t_wen;
  wire [LANES-1:0][31:0] t_raddr,t_waddr,t_wdata;
  logic [LANES-1:0][31:0] t_rdata='0;
  wire t_gnt=rst || (cycle%7!=0);
  bit seen[MCOLS*N];
  logic [2:0] pending='0;
  logic [D*8-1:0] pipe_data[3];
  function automatic int activation(int row,int k,int i);
    return ((row*7+k*3+i)%17)-8;
  endfunction
  function automatic int weight_value(int n,int k,int i);
    return ((n*5+k*11+i*3)%19)-9;
  endfunction
  function automatic logic [31:0] expected_bits(int row,int n);
    int acc;
    shortreal f;
    acc=0;
    for(int k=0;k<KB;k++) for(int i=0;i<D;i++)
      acc+=activation(row,k,i)*weight_value(n,k,i);
    f=shortreal'(acc);
    return $shortrealtobits(f);
  endfunction
  otpu_mxu #(.D(D),.MCOLS(MCOLS),.DEPTH(32),.LANES(LANES)) dut (.*);
  always @(posedge clk) begin
    cycle<=cycle+1;
    pending<={pending[1:0],b_req && b_gnt};
    for(int j=1;j<3;j++) pipe_data[j]<=pipe_data[j-1];
    if(b_req && b_gnt) begin
      for(int i=0;i<D;i++) pipe_data[0][i*8+:8]<=8'(weight_value((b_addr*4/D)/KB,(b_addr*4/D)%KB,i));
      $fdisplay(fd,"%0d,HBM,MXU,weight_chunk,%0d,%0d",cycle,b_addr*4,D);
    end
    b_rvalid<=pending[2]; b_rdata<=pipe_data[2];
    a_rvalid<=a_req && a_gnt;
    // UNIT weights bypass scale memory; keep a valid response model for visibility.
    for(int j=0;j<8;j++) a_rdata[j*32+:32]<=32'h3f800000;
    for(int j=0;j<MCOLS;j++) if(act_ren[j]) begin
      for(int i=0;i<D;i++) act_data[(j*D+i)*8+:8]<=8'(activation(j,act_blk,i));
      act_scale[j*64+:64]<=64'h000000003f800000;
    end
    if(!rst && t_gnt) for(int j=0;j<LANES;j++) if(t_wen[j]) begin : check_output
      int addr,row,n;
      addr=int'(t_waddr[j]); row=addr/N; n=addr%N;
      if(addr>=rows*N || seen[addr]) $fatal(1,"duplicate/out-of-range TMEM address %0d",addr);
      if(t_wdata[j]!==expected_bits(row,n))
        $fatal(1,"test %0d row %0d n %0d got %h expected %h",test_id,row,n,t_wdata[j],expected_bits(row,n));
      seen[addr]=1; writes++;
      $fdisplay(fd,"%0d,MXU,TMEM,result_fp32,%0d,4",cycle,addr);
    end
    if(cycle>10000) $fatal(1,"watchdog");
  end
  initial begin
    fd=$fopen("mxu_flow.csv","w");
    if(!fd) $fatal(1,"cannot open trace");
    $fdisplay(fd,"cycle,source,destination,kind,address,bytes");
    // Flush reset-free systolic metadata delay lines before releasing reset.
    repeat(64) @(negedge clk); rst=0;
    for(int testno=0;testno<2;testno++) begin
      test_id=testno; rows=(testno==0)?1:4; writes=0;
      foreach(seen[i]) seen[i]=0;
      wait(rdy); @(negedge clk);
      cmd='0; cmd.op=OP_MM; cmd.flags=8'h01; // UNIT int8: Sw=Sa=1, offsets=0
      cmd.w4=(KB<<16)|N; cmd.w5=KB*D;
      cmd.w6=(rows<<16)|N; cmd.w7=8;
      start=1;
      @(negedge clk); start=0; go=1;
      @(negedge clk); go=0;
      wait(done); @(negedge clk);
      if(writes!=rows*N) $fatal(1,"missing writes %0d / %0d",writes,rows*N);
      $display("PASS MXU M=%0d N=%0d K=%0d: %0d FP32 outputs",rows,N,KB*D,writes);
      repeat(12) @(negedge clk);
    end
    $fclose(fd); $display("ALL MXU TESTS PASSED"); $finish;
  end
endmodule
