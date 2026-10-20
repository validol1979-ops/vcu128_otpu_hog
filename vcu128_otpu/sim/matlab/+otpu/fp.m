function y = fp(op, a, b)
% Binary32 arithmetic, RNE in host single, FTZ at each operation.
a = flush(single(a));
switch op
    case 'ftz', y = a;
    case 'mul', y = flush(a .* flush(single(b)));
    case 'add', y = flush(a + flush(single(b)));
    case 'sub', y = flush(a - flush(single(b)));
    case 'recip'
        sz = size(a); bits = reshape(typecast(a(:), 'uint32'), sz);
        ab = bitand(bits, uint32(hex2dec('7fffffff')));
        sig = bitor(uint32(127*2^23), bitand(ab, uint32(2^23-1)));
        x = reshape(typecast(sig(:), 'single'), sz);
        seed = uint32(hex2dec('7ef311c3')) - sig;
        y = reshape(typecast(seed(:), 'single'), sz);
        for j = 1:2
            y = otpu.fp('mul', y, otpu.fp('sub', 2, otpu.fp('mul', x, y)));
        end
        y = otpu.fp('add', otpu.fp('mul', y, ...
            otpu.fp('sub', 1, otpu.fp('mul', x, y))), y);
        exponent = 127 - double(bitshift(ab, -23));
        y = single(double(y) .* 2.^exponent);
        y(ab == 0 | ab >= uint32(hex2dec('7e800000'))) = 0;
        y = flush(y .* sign(a));
    otherwise, error('otpu:fp', 'Unknown operation');
end
end
function x = flush(x)
bits = typecast(x(:), 'uint32');
den = bitand(bits, uint32(hex2dec('7f800000'))) == 0;
bits(den) = bitand(bits(den), uint32(hex2dec('80000000')));
bits(isnan(x(:))) = uint32(hex2dec('7fc00000'));
x = reshape(typecast(bits, 'single'), size(x));
end
