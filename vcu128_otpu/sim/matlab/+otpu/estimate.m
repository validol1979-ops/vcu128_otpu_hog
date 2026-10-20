function r = estimate(m,n,k,c)
% Roofline lower bound with padded matrix shape; not a compiled-program cycle count.
assert(all([m n k]>0) && all([m n k]==fix([m n k])));
r.ops=2*m*n*k; r.peak_GOPS=2*c.S*c.D*c.MCOLS*c.core_hz/1e9;
r.compute_cycles=ceil(m/c.MCOLS)*ceil(n/c.S)*ceil(k/c.D);
r.compute_s=r.compute_cycles/c.core_hz;
% Weights streamed once per MCOLS row group; row scales and offsets included.
r.weight_bytes=ceil(m/c.MCOLS)*n*(ceil(k/c.D)*c.D+4+ceil(k/c.D));
r.memory_Bps=c.S*2*min(64*c.uclk_hz,64*c.core_hz);
r.memory_s=r.weight_bytes/r.memory_Bps;
r.device_s=max(r.compute_s,r.memory_s);
r.GOPS=r.ops/r.device_s/1e9;
end
