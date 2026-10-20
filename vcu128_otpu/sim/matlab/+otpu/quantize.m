function r = quantize(x, group)
% FeSens QACT/QST INT8: row scale, 5-bit group offsets, RNE codes.
x = otpu.fp('ftz', x);
assert(ismatrix(x) && ~isempty(x) && all(isfinite(x(:))), 'Finite nonempty matrix required');
assert(group >= 1 && group == fix(group) && mod(size(x,2), group) == 0);
[n,k] = size(x); ng = k/group;
mx = max(abs(x), [], 2);
r.scale = otpu.fp('mul', mx, single(1/127));
inv = otpu.fp('mul', 127, otpu.fp('recip', mx));
r.codes = zeros(n,k,'int8'); r.offset = zeros(n,ng,'uint8');
mb = reshape(typecast(mx(:),'uint32'),size(mx));
for g = 1:ng
    ix = (g-1)*group+(1:group); v = max(abs(x(:,ix)),[],2);
    vb = reshape(typecast(v(:),'uint32'),size(v));
    d = double(bitshift(mb,-23))-double(bitshift(vb,-23)) ...
        - double(bitand(vb,uint32(2^23-1)) > bitand(mb,uint32(2^23-1)));
    d = max(0,min(31,d)); d(v == 0) = 0;
    r.offset(:,g) = uint8(d);
    z = double(otpu.fp('mul',x(:,ix),otpu.fp('mul',inv,single(2.^d))));
    % MATLAB round uses ties away from zero; implement nearest even explicitly.
    z(isnan(z)) = 0; z = max(-127,min(127,z)); lo = floor(z); frac = z-lo;
    q = lo + (frac > .5 | (frac == .5 & mod(lo,2) ~= 0));
    r.codes(:,ix) = int8(max(-127,min(127,q)));
end
end
