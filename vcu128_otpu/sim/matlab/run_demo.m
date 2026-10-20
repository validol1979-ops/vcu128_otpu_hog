function r = run_demo(outdir,make_plots,p,c)
% LLM + HBM experiment. No Ethernet. Parameters can be passed as structs.
here=fileparts(mfilename('fullpath')); addpath(here);
if nargin<1 || isempty(outdir), outdir=fullfile(here,'out'); end
if nargin<2, make_plots=true; end
if nargin<3, p=otpu.llm_config(); end
if nargin<4, c=otpu.config(); end
if ~exist(outdir,'dir'), mkdir(outdir); end
r=otpu.llm_generate(p,c); trace=r.state.trace;
save(fullfile(outdir,'llm_results.mat'),'r','-v7');
fid=fopen(fullfile(outdir,'llm_trace.csv'),'w'); assert(fid>=0);
clean=onCleanup(@() fclose(fid));
fprintf(fid,'token,layer,op,read_bytes,write_bytes,ops,memory_s,compute_s,start_s,finish_s\n');
for j=1:numel(trace)
    e=trace(j); fprintf(fid,'%d,%d,%s,%d,%d,%g,%.12g,%.12g,%.12g,%.12g\n', ...
        e.token,e.layer,e.op,e.read_bytes,e.write_bytes,e.ops,e.memory_s,e.compute_s,e.start_s,e.finish_s);
end
clear clean;
fid=fopen(fullfile(outdir,'llm_summary.txt'),'w'); assert(fid>=0);
clean=onCleanup(@() fclose(fid));
fprintf(fid,'LLM + HBM architectural simulation, random weights\n');
fprintf(fid,'LLaMA-style: layers=%d hidden=%d intermediate=%d Q_heads=%d KV_heads=%d vocab=%d\n', ...
    p.layers,p.hidden,p.intermediate,p.heads,p.kv_heads,p.vocab);
fprintf(fid,'Prompt token IDs: '); fprintf(fid,'%d ',p.prompt); fprintf(fid,'\n');
fprintf(fid,'Generated token IDs: '); fprintf(fid,'%d ',r.generated); fprintf(fid,'\n');
fprintf(fid,'Weight storage model: %d bytes; KV reserved %d bytes, used %d bytes\n', ...
    r.weight_bytes,r.kv_capacity_bytes,r.kv_used_bytes);
fprintf(fid,'Prefill (sequential): %.6g ms; modeled total %.6g ms\n',r.prefill_s*1e3,r.state.time_s*1e3);
fprintf(fid,'HBM read %.6g MB, write %.6g MB\n',sum([trace.read_bytes])/1e6,sum([trace.write_bytes])/1e6);
fprintf(fid,'Consumed position,modeled_ms\n');
fprintf(fid,'%d,%.8g\n',[(1:r.state.pos);r.token_seconds*1e3]);
clear clean;
if make_plots
    f=figure('Visible','off','Position',[100 100 1150 750]);
    subplot(2,2,1); plot(1:r.state.pos,r.token_seconds*1e3,'o-'); grid on;
    xlabel('Consumed token position'); ylabel('Modeled time, ms'); title('Sequential prefill and decode');
    subplot(2,2,2); kv=2*p.layers*p.kv_heads*(p.hidden/p.heads)*p.kv_bytes*(1:r.state.pos);
    plot(1:r.state.pos,kv/1024,'o-'); grid on; xlabel('Context tokens'); ylabel('KV-cache, KiB');
    subplot(2,2,3); names={'Weights/embedding/norm','KV read','KV write'};
    ix=strcmp({trace.op},'attention_kv_read'); iy=strcmp({trace.op},'kv_write');
    bar([sum([trace(~ix).read_bytes]),sum([trace(ix).read_bytes]),sum([trace(iy).write_bytes])]/1024);
    set(gca,'XTick',1:3,'XTickLabel',names); ylabel('KiB'); title('HBM traffic');
    subplot(2,2,4); e=trace([trace.token]==r.state.pos);
    bar([[e.memory_s]' [e.compute_s]']*1e6);
    xlabel('Operation index in last token'); ylabel('Estimated microseconds');
    legend('HBM','Compute'); title('Streaming overlap: duration = max(HBM, compute)');
    print(f,fullfile(outdir,'llm_overview.png'),'-dpng','-r140'); close(f);
end
fprintf('%s\n',fileread(fullfile(outdir,'llm_summary.txt')));
end
