function [model,state] = llm_init(p,c)
% LLaMA-style causal decoder with GQA, RoPE, RMSNorm and SwiGLU.
% This is an architectural example, not the architecture/weights of Qwen3.5/LFM.
assert(mod(p.hidden,p.heads)==0 && mod(p.heads,p.kv_heads)==0);
assert(mod(p.hidden/p.heads,2)==0 && p.hidden>=c.D);
assert(mod(p.hidden,c.D)==0 && mod(p.intermediate,c.D)==0);
assert(max(p.hidden,p.intermediate)<=c.D*c.ACT_BLOCKS);
assert(p.layers>=1 && p.max_seq>=1 && p.vocab>=2);
assert(strcmp(p.weight_format,'int8'));
rng(p.seed); model.p=p; model.embedding=single(randn(p.vocab,p.hidden)/sqrt(p.hidden));
kv=p.kv_heads*(p.hidden/p.heads); model.weight_bytes=4*numel(model.embedding);
for l=1:p.layers
    b=struct();
    b.q=weight(p.hidden,p.hidden); b.k=weight(kv,p.hidden); b.v=weight(kv,p.hidden);
    b.o=weight(p.hidden,p.hidden); b.gate=weight(p.intermediate,p.hidden);
    b.up=weight(p.intermediate,p.hidden); b.down=weight(p.hidden,p.intermediate);
    b.attn_norm=ones(1,p.hidden,'single'); b.ffn_norm=ones(1,p.hidden,'single');
    names={'q','k','v','o','gate','up','down'};
    for j=1:numel(names)
        name=names{j}; b.quant.(name)=otpu.quantize(b.(name),c.D);
        [n,k]=size(b.(name));
        model.weight_bytes=model.weight_bytes+64*ceil(n*(k+4+k/c.D)/64);
    end
    model.weight_bytes=model.weight_bytes+8*p.hidden;
    model.blocks(l)=b;
end
model.final_norm=ones(1,p.hidden,'single');
model.head=otpu.quantize(model.embedding,c.D); % tied embedding/output head
model.weight_bytes=model.weight_bytes+64*ceil(p.vocab*(p.hidden+4+p.hidden/c.D)/64)+4*p.hidden;
kvb=otpu.kv_bytes(p,c,p.max_seq); model.kv_capacity_bytes=kvb.capacity;
assert(model.weight_bytes+model.kv_capacity_bytes <= 2*c.S*c.channel_bytes, 'HBM capacity exceeded');
state.pos=0; state.K=zeros(p.max_seq,kv,p.layers,'single');
state.V=zeros(p.max_seq,kv,p.layers,'single'); state.time_s=0;
state.trace=struct('token',{},'layer',{},'op',{},'read_bytes',{},'write_bytes',{}, ...
    'ops',{},'memory_s',{},'compute_s',{},'start_s',{},'finish_s',{});
    function x=weight(n,k), x=single(randn(n,k)/sqrt(k)); end
end
