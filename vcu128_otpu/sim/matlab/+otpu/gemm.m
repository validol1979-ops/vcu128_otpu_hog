function r = gemm(a, w, cfg)
% One INT8 MM, without PAIR/ACC/RSC: QACT D/4, QST D, W=16.
assert(size(a,2) == size(w,2) && mod(size(a,2),cfg.D) == 0);
assert(size(a,2)/cfg.D <= cfg.ACT_BLOCKS, 'Split K into separate MM instructions');
r.a = otpu.quantize(a,cfg.D/4); r.w = otpu.quantize(w,cfg.D);
core = otpu.mm(r.a,r.w,cfg);
r.acc = core.acc; r.dropped = core.dropped; r.out = core.out;
r.reference = double(a)*double(w)';
r.relative_error = norm(double(r.out)-r.reference,'fro')/max(realmin,norm(r.reference,'fro'));
end
