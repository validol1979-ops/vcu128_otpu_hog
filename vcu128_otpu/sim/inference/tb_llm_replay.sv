`timescale 1ns/1ps
// Architectural event replay from the numerical MATLAB/Octave LLM, NOT RTL inference.
module tb_llm_replay;
  int token,layer,source,destination,read_bytes,write_bytes,event_index=0;
  string operation;
  realtime start_ns,finish_ns;
  bit active=0;
  int fd,rc,expected_token,expected_layer,src,dst,rd,wr;
  string op;
  real t0,t1,previous_finish=0;
  initial begin
    fd=$fopen("llm_events.txt","r");
    if(!fd) $fatal(1,"generate llm_events.txt first");
    while(!$feof(fd)) begin
      rc=$fscanf(fd,"%d %d %s %d %d %d %d %f %f\n",expected_token,expected_layer,op,src,dst,rd,wr,t0,t1);
      if(rc!=9) $fatal(1,"malformed event %0d",event_index);
      if(t0<previous_finish-0.001 || t1<t0) $fatal(1,"nonmonotonic trace");
      if(t0>$realtime) #(t0-$realtime);
      token=expected_token; layer=expected_layer; operation=op;
      source=src; destination=dst; read_bytes=rd; write_bytes=wr;
      start_ns=t0; finish_ns=t1; active=1; event_index++;
      #(t1-t0); active=0; previous_finish=t1;
    end
    $fclose(fd);
    if(event_index==0) $fatal(1,"empty replay");
    $display("ALL LLM EVENTS REPLAYED: %0d",event_index); $finish;
  end
endmodule
