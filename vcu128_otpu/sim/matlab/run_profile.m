function r = run_profile(outdir,make_plots,p,c,contexts)
% Large generic decoder profile; no model download or tensor allocation.
here=fileparts(mfilename('fullpath')); addpath(here);
if nargin<1 || isempty(outdir), outdir=fullfile(here,'out'); end
if nargin<2, make_plots=true; end
if nargin<3
    p=otpu.llm_config(); p.hidden=1024; p.intermediate=4096;
    p.layers=24; p.heads=16; p.kv_heads=4; p.vocab=32000;
end
if nargin<4, c=otpu.config(); end
if nargin<5, contexts=[1 128 512 2048 8192 32768]; end
if ~exist(outdir,'dir'), mkdir(outdir); end
r=otpu.llm_profile(p,c,contexts);
fid=fopen(fullfile(outdir,'llm_profile.csv'),'w'); assert(fid>=0);
clean=onCleanup(@()fclose(fid));
fprintf(fid,'context,modeled_seconds,tokens_per_s,read_bytes,write_bytes,kv_bytes,fits_hbm\n');
fprintf(fid,'%d,%.12g,%.12g,%.0f,%.0f,%.0f,%d\n', ...
    [r.context r.seconds r.tokens_per_s r.read_bytes r.write_bytes r.kv_bytes r.fits_hbm]');
clear clean;
save(fullfile(outdir,'llm_profile.mat'),'r','p','c','-v7');
if make_plots
    f=figure('Visible','off','Position',[100 100 1000 420]);
    subplot(1,2,1); semilogx(r.context,r.tokens_per_s,'o-'); grid on;
    xlabel('Context tokens'); ylabel('Modeled tokens/s'); title('Generic decoder, INT8 + FP32 KV');
    subplot(1,2,2); semilogx(r.context,(r.weight_bytes+r.kv_bytes)/2^30,'o-'); hold on;
    plot(r.context,ones(size(r.context))*2*c.S*c.channel_bytes/2^30,'--'); grid on;
    xlabel('Context tokens'); ylabel('HBM GiB'); legend('Weights + KV','Active HBM capacity');
    print(f,fullfile(outdir,'llm_profile.png'),'-dpng','-r140'); close(f);
end
fprintf('Symbolic profile: %.3f MiB weights, %d context points; see llm_profile.csv\n', ...
    r.weight_bytes/2^20,numel(contexts));
end
