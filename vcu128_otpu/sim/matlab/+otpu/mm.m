function r = mm(a, w, c)
% MXU INT8 core on prequantized operands. a/w: codes, scale, offset.
m=size(a.codes,1); n=size(w.codes,1); k=size(a.codes,2);
assert(k==size(w.codes,2) && mod(k,c.D)==0 && k/c.D<=c.ACT_BLOCKS);
r.acc=zeros(m,n); r.dropped=zeros(m,n);
for g=1:k/(c.D/4)
    ix=(g-1)*(c.D/4)+(1:c.D/4);
    sh=16-double(a.offset(:,g))-double(w.offset(:,ceil(g/4)))';
    live=sh>=0; prod=double(a.codes(:,ix))*double(w.codes(:,ix))';
    r.acc=r.acc+prod.*2.^max(0,sh).*live; r.dropped=r.dropped+~live;
end
r.out=otpu.fp('mul',otpu.fp('mul',single(r.acc),w.scale'), ...
    otpu.fp('mul',a.scale,single(2^-16)));
end
