function b = kv_bytes(p,c,t)
% HBM bytes of the KV cache in the upstream layout (qwen3.py Image, docs/isa.md QST/MM RSC):
% K token-major int8 rows padded to D + fp32 scale per token; V stored transposed (V^T rows
% [dh, cap], int8, 256-token tiles) + fp32 scale per token. Per layer, t = attended tokens.
dh=p.hidden/p.heads; krow=ceil(dh/c.D)*c.D; tile=256;
b.k_write=p.kv_heads*(krow+4);           % QST ROW: one K row + scale
b.v_write=p.kv_heads*(64*dh+4);          % QST V^T: one byte per dh rows, each its own beat (RMW)
b.k_read=p.kv_heads*t*(krow+4);          % MM RSC: K rows on port B, scales on port A
b.v_read=p.kv_heads*dh*ceil(t/c.D)*c.D;  % MM UNIT: V^T chunks (scales folded into P)
b.capacity=p.layers*p.kv_heads*(p.max_seq*(krow+8)+dh*ceil(p.max_seq/tile)*tile);
b.used=@(pos) p.layers*p.kv_heads*pos*(krow+dh+8);
end
