function test_otpu()
% Fail-fast regression. No toolboxes, board, sockets or Vivado required.
here=fileparts(mfilename('fullpath')); addpath(here); c=otpu.config();
f=jsondecode(fileread(fullfile(here,'fixtures','int8_mx.json')));
for j=1:numel(f.cases)
    v=f.cases(j); r=otpu.gemm(single(v.a),single(v.w),c);
    assert(isequal(r.a.codes,int8(v.aq)) && isequal(r.w.codes,int8(v.wq)));
    assert(isequal(r.a.offset,uint8(v.da)) && isequal(r.w.offset,uint8(v.dw)));
    assert(isequal(bits(r.a.scale),uint32(v.sa_bits)));
    assert(isequal(bits(r.w.scale),uint32(v.sw_bits)));
    assert(isequal(r.acc,v.acc)); assert(isequal(bits(r.out),uint32(v.out_bits)));
    if strcmp(v.name,'dynamic'), assert(any(r.dropped(:)>0)); end
    fprintf('PASS MX INT8 %s: codes, offsets, scales, accumulator, FP32 bits\n',v.name);
end
% Exact address permutation/inverse, boundary beats, every PC_GRAN supported.
b=unique([0:8191 2^25-129:2^25-1]);
for g=[0 2 4 5 19 22]
    for x=[false true]
        c.pc_gran=g; c.pc_xor=x;
        for ch=0:3
            [addr,pc,port]=otpu.hbm_address(b,ch,c);
            off=bitshift(bitand(addr,uint64(2^28-1)),-6);
            upper=bitshift(off,-g); low=bitand(off,uint64(2^g-1));
            pick=pc; if x, pick=bitxor(pc,bitand(upper,uint64(7))); end
            back=bitshift(upper,g+3)+bitshift(pick,g)+low;
            assert(isequal(back,uint64(b)) && numel(unique(addr))==numel(b));
            assert(all(double(addr)>=ch*2^31 & double(addr)<(ch+1)*2^31));
            assert(isequal(port,bitand(bitshift(uint64(b),-7),uint64(1))));
        end
    end
end
fprintf('PASS HBM address: 6 granularities x 2 XOR modes x 4 channels\n');
c=otpu.config(); rng(99); proto=struct('beat',0,'write',false, ...
    'data',zeros(1,64,'uint8'),'mask',true(1,64)); cmd=repmat(proto,1,700);
ref=zeros(512,64,'uint8'); expected=zeros(700,64,'uint8');
for i=1:numel(cmd)
    cmd(i).beat=randi(512)-1; cmd(i).write=rand()<.55;
    cmd(i).data=uint8(randi(256,1,64)-1); cmd(i).mask=rand(1,64)<.7;
    b=cmd(i).beat+1;
    if cmd(i).write, ref(b,cmd(i).mask)=cmd(i).data(cmd(i).mask);
    else, expected(i,:)=ref(b,:); end
end
for slots=[1 4 32]
    c.read_slots=slots; c.write_slots=slots; r=otpu.hbm(cmd,c);
    rd=~[cmd.write]; assert(isequal(r.data(rd,:),expected(rd,:)));
    returns=r.return_cycle(rd); assert(numel(unique(returns))==sum(rd));
    for p=0:1
        ix=find(rd & bitand(bitshift([cmd.beat],-7),1)==p);
        assert(all(diff(r.return_cycle(ix))>0));
    end
    for b=unique([cmd.beat])
        if isKey(r.memory,b), actual=r.memory(b); else, actual=zeros(1,64,'uint8'); end
        assert(isequal(actual,ref(b+1,:)));
    end
end
% Deliberate same-beat RAW/WAR/WAW sequence, including partial WSTRB.
h=repmat(proto,1,5); h(1).write=true; h(1).data(:)=11;
h(3).write=true; h(3).data(:)=22; h(3).mask(33:64)=false;
h(4).write=true; h(4).data(:)=33; h(4).mask(1:32)=false;
r=otpu.hbm(h,c); assert(all(r.data(2,:)==11));
assert(isequal(r.data(5,:),uint8([22*ones(1,32) 33*ones(1,32)])));
assert(r.issue(3)>r.complete(2) && r.issue(4)>r.complete(3));
fprintf('PASS HBM ordering, masks, shared return and finite slots\n');
c=otpu.config(); e=otpu.estimate(16,2048,2048,c); assert(e.GOPS<=e.peak_GOPS);
test_llm;
fprintf('ALL TESTS PASSED\n');
end
function b=bits(x)
b=reshape(typecast(x(:),'uint32'),size(x));
end
