function r = hbm(cmd, c)
% Event scheduler: per-port ordering, RAW/WAR/WAW, finite slots and shared return.
% cmd fields: beat, write, data (1x64 uint8), mask (1x64 logical).
% Times in uclk cycles. No AXI signal/ID interleaving or CDC pipeline simulation.
n = numel(cmd); r.issue = zeros(n,1); r.complete = zeros(n,1);
r.return_cycle = nan(n,1); r.data = zeros(n,64,'uint8');
r.dep_wait = zeros(n,1); r.slot_wait = zeros(n,1);
port_ready = [0 0]; bus_read = [0 0]; bus_write = [0 0];
[~,~,ports] = otpu.hbm_address([cmd.beat],0,c); ports = double(ports)+1;
for i=1:n
    p = ports(i); prev = 1:i-1; same = prev(ports(prev)==p);
    t = port_ready(p);
    dep = same([cmd(same).beat] == cmd(i).beat & ...
        ([cmd(same).write] | cmd(i).write));
    if ~isempty(dep), t = max(t,max(r.complete(dep))+2); end
    r.dep_wait(i) = t-port_ready(p);
    typ = same([cmd(same).write] == cmd(i).write);
    slots = c.read_slots; if cmd(i).write, slots = c.write_slots; end
    % Read slots stay occupied until delivery to native, not merely AXI completion.
    release = r.complete(typ)+2;
    if ~cmd(i).write, release = r.return_cycle(typ)+1; end
    while sum(release>t)>=slots, t = min(release(release>t)); end
    r.slot_wait(i) = t-port_ready(p)-r.dep_wait(i);
    if cmd(i).write
        t = max(t,bus_write(p)); bus_write(p)=t+2; lat=c.write_latency;
    else
        t = max(t,bus_read(p)); bus_read(p)=t+2; lat=c.read_latency;
    end
    r.issue(i)=t; r.complete(i)=t+3+lat+2; port_ready(p)=t+1;
    if ~cmd(i).write
        ret = r.complete(i)+4;
        prior = same(~[cmd(same).write]);
        if ~isempty(prior), ret=max(ret,r.return_cycle(prior(end))+1); end
        % All previous scheduled read returns reserve the one shared output bus.
        while any(r.return_cycle(1:i-1)==ret), ret=ret+1; end
        r.return_cycle(i)=ret;
    end
end
% Replay operations at completion; dependency ordering preserves beat semantics.
mem = containers.Map('KeyType','double','ValueType','any');
[~,order]=sortrows([r.complete (1:n)'],[1 2]);
for j=1:n
    i=order(j); b=double(cmd(i).beat);
    if isKey(mem,b), v=mem(b); else, v=zeros(1,64,'uint8'); end
    if cmd(i).write
        assert(numel(cmd(i).data)==64 && numel(cmd(i).mask)==64);
        mask=logical(cmd(i).mask); v(mask)=cmd(i).data(mask); mem(b)=v;
    else, r.data(i,:)=v;
    end
end
r.memory=mem; r.cycles=max([0;r.complete;r.return_cycle(isfinite(r.return_cycle))])+1;
r.GBps=n*64/(r.cycles/c.uclk_hz)/1e9;
end
