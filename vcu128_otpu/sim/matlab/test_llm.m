function test_llm()
c=otpu.config(); p=otpu.llm_config(); p.layers=1; p.vocab=32;
p.prompt=[1 7]; p.generate=3;
r=otpu.llm_generate(p,c);
assert(all(isfinite(r.logits(:))) && isequal(size(r.logits),[4 p.vocab]));
assert(r.state.pos==4 && r.kv_used_bytes==4*2*p.kv_heads*(p.hidden/p.heads)*4);
assert(all(r.generated>=1 & r.generated<=p.vocab));
trace=r.state.trace; assert(all([trace.finish_s]>=[trace.start_s]));
assert(all(abs([trace(2:end).start_s]-[trace(1:end-1).finish_s])<1e-14));
ix=strcmp({trace.op},'attention_kv_read'); kv=[trace(ix).read_bytes];
assert(isequal(kv,2*(1:4)*p.kv_heads*(p.hidden/p.heads)*4));
profile=otpu.llm_profile(p,c,1:4);
assert(max(abs(profile.seconds'-r.token_seconds))<1e-14);
assert(all(diff(profile.read_bytes)>0) && all(diff(profile.kv_bytes)>0));
assert(all(profile.fits_hbm));
% Causal cache: future data must never affect next-token logits.
[model,s]=otpu.llm_init(p,c); [~,s]=otpu.llm_step(1,model,s,c);
future=s; future.K(3:end,:,:)=1e6; future.V(3:end,:,:)=-1e6;
[a,sa]=otpu.llm_step(7,model,s,c); [b,sb]=otpu.llm_step(7,model,future,c);
assert(isequal(a,b) && isequal(sa.K(1:2,:,:),sb.K(1:2,:,:)));
assert(isequal(a,r.logits(2,:)));
% Hardware timing must affect time only, not functional results.
slow=c; slow.uclk_hz=c.uclk_hz/4; slow.core_hz=c.core_hz/4;
rr=otpu.llm_generate(p,slow);
assert(isequal(rr.generated,r.generated) && isequal(rr.logits,r.logits));
assert(rr.state.time_s>r.state.time_s);
% HBM capacity and maximum context are enforced.
bad=p; bad.max_seq=1; failed=false;
try, otpu.llm_generate(bad,c); catch, failed=true; end
assert(failed);
small=c; small.channel_bytes=64; failed=false;
try, otpu.llm_init(p,small); catch, failed=true; end
assert(failed);
fprintf('PASS LLM: greedy generation, GQA cache growth, causality, timing independence, capacity\n');
end
