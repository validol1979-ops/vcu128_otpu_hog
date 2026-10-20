function [address, pc, port] = hbm_address(beat, channel, c)
% Exact otpu_hbm_amap permutation (64-byte beat, 2 GiB per channel).
assert(all(beat(:)>=0 & beat(:)<2^25 & beat(:)==fix(beat(:))));
assert(isscalar(channel) && channel>=0 && channel<4 && channel==fix(channel));
g = c.pc_gran; assert(g>=0 && g<=22 && g==fix(g)); b = uint64(beat);
pc = bitand(bitshift(b,-g),uint64(7));
if c.pc_xor, pc = bitxor(pc,bitand(bitshift(b,-g-3),uint64(7))); end
off = bitor(bitshift(bitshift(b,-g-3),g),bitand(b,uint64(2^g-1)));
address = uint64(channel)*uint64(2^31)+bitshift(pc,28)+bitshift(off,6);
port = bitand(bitshift(b,-7),uint64(1));
end
