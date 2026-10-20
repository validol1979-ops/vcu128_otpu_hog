function r = llm_generate(p,c)
% Prefill is evaluated token by token; greedy decode, 1-based token IDs.
assert(~isempty(p.prompt) && p.generate>=1 && p.generate==fix(p.generate));
assert(numel(p.prompt)+p.generate-1<=p.max_seq);
[model,state]=otpu.llm_init(p,c); consumed=[]; r.logits=[]; r.token_seconds=[];
for id=p.prompt
    begin=state.time_s; [logit,state]=otpu.llm_step(id,model,state,c);
    consumed(end+1)=id; r.token_seconds(end+1)=state.time_s-begin;
    r.logits(end+1,:)=logit;
end
r.prefill_s=state.time_s; r.generated=zeros(1,p.generate);
for j=1:p.generate
    [~,id]=max(logit); r.generated(j)=id;
    if j<p.generate
        begin=state.time_s; [logit,state]=otpu.llm_step(id,model,state,c);
        consumed(end+1)=id; r.token_seconds(end+1)=state.time_s-begin;
        r.logits(end+1,:)=logit;
    end
end
r.consumed=consumed; r.state=state; r.weight_bytes=model.weight_bytes;
r.kv_capacity_bytes=model.kv_capacity_bytes;
r.kv_used_bytes=state.pos*p.layers*2*p.kv_heads*(p.hidden/p.heads)*p.kv_bytes;
r.config=p; r.hardware=c;
end
