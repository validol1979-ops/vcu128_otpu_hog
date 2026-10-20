function [logits,state] = llm_step(id,model,state,c)
% Consume one token and return next-token logits; K/V persist in HBM model.
p=model.p; assert(id>=1 && id<=p.vocab && id==fix(id));
assert(state.pos<p.max_seq,'Context capacity exceeded');
state.pos=state.pos+1; t=state.pos; dh=p.hidden/p.heads;
x=model.embedding(id,:);
state=otpu.llm_event(state,c,0,'embedding',4*p.hidden,0,0,0);
for l=1:p.layers
    b=model.blocks(l); z=rms(x,b.attn_norm);
    vector_event('attn_rms',4*p.hidden,6*p.hidden);
    q=linear(z,b.quant.q,'q'); k=linear(z,b.quant.k,'k'); v=linear(z,b.quant.v,'v');
    q=rope(q,p.heads); k=rope(k,p.kv_heads);
    vector_event('rope',0,6*(numel(q)+numel(k)));
    state.K(t,:,l)=k; state.V(t,:,l)=v;
    state=otpu.llm_event(state,c,l,'kv_write',0,2*numel(k)*p.kv_bytes,0,0);
    att=zeros(1,p.hidden,'single');
    for h=1:p.heads
        kh=floor((h-1)/(p.heads/p.kv_heads))+1;
        qi=(h-1)*dh+(1:dh); ki=(kh-1)*dh+(1:dh);
        keys=reshape(state.K(1:t,ki,l),t,dh); vals=reshape(state.V(1:t,ki,l),t,dh);
        score=(double(keys)*double(q(qi))')/sqrt(dh);
        prob=exp(score-max(score)); prob=prob/sum(prob);
        att(qi)=single(prob'*double(vals));
    end
    % K/V fetched once, reused among query heads in each GQA group.
    ops=4*p.heads*t*dh+5*p.heads*t;
    state=otpu.llm_event(state,c,l,'attention_kv_read',2*t*numel(k)*p.kv_bytes,0,ops,ops/(c.S*c.LANES*c.core_hz));
    x=otpu.fp('add',x,linear(att,b.quant.o,'o')); vector_event('attn_residual',0,p.hidden);
    z=rms(x,b.ffn_norm); vector_event('ffn_rms',4*p.hidden,6*p.hidden);
    gate=linear(z,b.quant.gate,'gate'); up=linear(z,b.quant.up,'up');
    sw=single(double(gate)./(1+exp(-double(gate)))); z=otpu.fp('mul',sw,up);
    vector_event('swiglu',0,6*p.intermediate);
    x=otpu.fp('add',x,linear(z,b.quant.down,'down')); vector_event('ffn_residual',0,p.hidden);
end
x=rms(x,model.final_norm);
state=otpu.llm_event(state,c,0,'final_rms',4*p.hidden,0,6*p.hidden,6*p.hidden/(c.S*c.LANES*c.core_hz));
l=0; logits=linear(x,model.head,'lm_head');
    function y=linear(a,w,name)
        qa=otpu.quantize(a,c.D/4); r=otpu.mm(qa,w,c); y=r.out;
        [n,kdim]=size(w.codes); ops=2*n*kdim;
        cycles=ceil(n/c.S)*ceil(kdim/c.D); % M=1, three unused MCOLS
        quant_s=(3*kdim+10*ceil(kdim/(c.D/4)))/(c.LANES*c.core_hz);
        state=otpu.llm_event(state,c,l,[name '_qact'],0,0,3*kdim,quant_s);
        state=otpu.llm_event(state,c,l,name,n*(kdim+4+kdim/c.D),0,ops,cycles/c.core_hz);
    end
    function y=rms(a,w)
        y=single(double(a)/sqrt(mean(double(a).^2)+p.rms_eps)).*w;
    end
    function y=rope(a,heads)
        y=a; theta=(t-1)./(p.rope_base.^((0:2:dh-1)/dh));
        co=cos(theta); si=sin(theta);
        for head=1:heads
            ix=(head-1)*dh+(1:2:dh); iy=ix+1;
            u=double(a(ix)); v0=double(a(iy));
            y(ix)=single(u.*co-v0.*si); y(iy)=single(u.*si+v0.*co);
        end
    end
    function vector_event(name,bytes,ops)
        state=otpu.llm_event(state,c,l,name,bytes,0,ops,ops/(c.S*c.LANES*c.core_hz));
    end
end
