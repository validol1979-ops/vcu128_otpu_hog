function c = config()
% Read architecture from the repository target; timing assumptions are separate.
root = fileparts(fileparts(fileparts(fileparts(mfilename('fullpath')))));
c.target = fullfile(root,'target','vcu128.toml'); txt = fileread(c.target);
keys = {'S','D','MCOLS','ACT_BLOCKS','core_mhz','beat_bytes','channel_bytes','LANES'};
for j=1:numel(keys)
    v = regexp(txt,['(?m)^' keys{j} '\s*=\s*([0-9.]+)'],'tokens','once');
    assert(~isempty(v), ['Missing target key: ' keys{j}]);
    c.(keys{j}) = str2double(v{1});
end
c.core_hz = c.core_mhz*1e6; c.uclk_hz = 225e6;
c.pc_gran = 0; c.pc_xor = true;
c.read_slots = 32; c.write_slots = 32;
c.read_latency = 40; c.write_latency = 48; % uclk cycles, model assumptions
end
