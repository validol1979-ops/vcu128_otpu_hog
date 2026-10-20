function r = llm_profile(p,c,contexts)
% Symbolic one-token decode profile; no tensors allocated, supports large shapes.
% Same serial operation/streaming model as llm_step; not a compiler schedule.
h=p.hidden; f=p.intermediate; kv=p.kv_heads*(h/p.heads);
assert(mod(h,p.heads)==0 && mod(p.heads,p.kv_heads)==0);
assert(mod(h,c.D)==0 && mod(f,c.D)==0 && all(contexts>=1 & contexts==fix(contexts)));
assert(max(h,f)<=c.D*c.ACT_BLOCKS && p.kv_bytes==4);
dims=[h h;kv h;kv h;h h;f h;f h;h f];
names={'q','k','v','o','gate','up','down'};
weight=@(n,k)64*ceil(n*(k+4+k/c.D)/64);
r.weight_bytes=4*p.vocab*h+4*h+weight(p.vocab,h);
for i=1:7, r.weight_bytes=r.weight_bytes+p.layers*weight(dims(i,1),dims(i,2)); end
r.weight_bytes=r.weight_bytes+8*h*p.layers;
r.context=contexts(:); r.seconds=zeros(numel(contexts),1);
r.read_bytes=r.seconds; r.write_bytes=r.seconds; r.kv_bytes=r.seconds;
r.traces=cell(numel(contexts),1);
for j=1:numel(contexts)
    t=contexts(j); s=struct('pos',t,'time_s',0,'trace',struct('token',{},'layer',{}, ...
        'op',{},'read_bytes',{},'write_bytes',{},'ops',{},'memory_s',{}, ...
        'compute_s',{},'start_s',{},'finish_s',{}));
    s=otpu.llm_event(s,c,0,'embedding',4*h,0,0,0);
    for l=1:p.layers
        vec('attn_rms',4*h,6*h);
        for i=1:3, fc(dims(i,1),dims(i,2),names{i}); end
        vec('rope',0,6*(h+kv));
        s=otpu.llm_event(s,c,l,'kv_write',0,2*kv*p.kv_bytes,0,0);
        ops=4*t*h+5*p.heads*t;
        s=otpu.llm_event(s,c,l,'attention_kv_read',2*t*kv*p.kv_bytes,0,ops,ops/(c.S*c.LANES*c.core_hz));
        fc(h,h,'o'); vec('attn_residual',0,h); vec('ffn_rms',4*h,6*h);
        fc(f,h,'gate'); fc(f,h,'up'); vec('swiglu',0,6*f);
        fc(h,f,'down'); vec('ffn_residual',0,h);
    end
    l=0; vec('final_rms',4*h,6*h); fc(p.vocab,h,'lm_head');
    r.seconds(j)=s.time_s; r.read_bytes(j)=sum([s.trace.read_bytes]);
    r.write_bytes(j)=sum([s.trace.write_bytes]); r.kv_bytes(j)=2*t*kv*p.kv_bytes*p.layers;
    r.traces{j}=s.trace;
end
r.tokens_per_s=1./r.seconds;
r.fits_hbm=(r.weight_bytes+r.kv_bytes)<=2*c.S*c.channel_bytes;
    function vec(name,bytes,ops)
        s=otpu.llm_event(s,c,l,name,bytes,0,ops,ops/(c.S*c.LANES*c.core_hz));
    end
    function fc(n,k,name)
        qs=(3*k+10*ceil(k/(c.D/4)))/(c.LANES*c.core_hz);
        s=otpu.llm_event(s,c,l,[name '_qact'],0,0,3*k,qs);
        s=otpu.llm_event(s,c,l,name,n*(k+4+k/c.D),0,2*n*k,ceil(n/c.S)*ceil(k/c.D)/c.core_hz);
    end
end
