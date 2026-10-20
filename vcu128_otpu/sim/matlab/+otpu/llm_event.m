function state = llm_event(state,c,layer,name,rd,wr,ops,compute_s)
% Coarse burst model: even striping across active channels, streaming overlap.
% Trace bytes are padded to native beats; KV/weight tensors need no full 8 GB array.
channels=2*c.S;
port_read=min(32*c.uclk_hz,64*c.read_slots*c.uclk_hz/(c.read_latency+9));
port_write=min(32*c.uclk_hz,64*c.write_slots*c.uclk_hz/(c.write_latency+7));
read_Bps=channels*min(64*c.core_hz,2*port_read);
write_Bps=channels*min(64*c.core_hz,2*port_write);
rd=64*ceil(rd/64); wr=64*ceil(wr/64);
mem=0;
if rd>0, mem=mem+(c.read_latency+9)/c.uclk_hz+rd/read_Bps; end
if wr>0, mem=mem+(c.write_latency+7)/c.uclk_hz+wr/write_Bps; end
entry=struct('token',state.pos,'layer',layer,'op',name,'read_bytes',rd,'write_bytes',wr, ...
    'ops',ops,'memory_s',mem,'compute_s',compute_s,'start_s',state.time_s, ...
    'finish_s',state.time_s+max(mem,compute_s));
state.trace(end+1)=entry; state.time_s=entry.finish_s;
end
