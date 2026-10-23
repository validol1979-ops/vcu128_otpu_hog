function r = run_flow(animate,delay_s)
% Numerical inference, followed by event animation. Works in MATLAB and Octave.
% Arrows are architectural tensor transfers, not measured AXI transactions.
if nargin<1, animate=true; end
if nargin<2, delay_s=0.12; end
here=fileparts(mfilename('fullpath')); addpath(here);
r=run_demo([],false); tr=r.state.trace;
names={'HBM: weights / KV','TMEM: FP32','QUANT: QACT / QST','ACT RAM: INT8','MXU: MM','VPU: VOP'};
xy=[.05 .65;.40 .65;.40 .35;.70 .35;.70 .65;.40 .05];
f=figure('Name','openTPU LLM architectural flow','Visible','off','Position',[60 60 1200 720]);
if animate, set(f,'Visible','on'); end
for k=1:numel(tr)
    if ~ishandle(f), break; end
    e=tr(k); clf(f); axes('Position',[.03 .20 .94 .70]); axis([0 1 0 1]); axis off; hold on;
    route=otpu.flow_route(e.op);
    active=route; if any(route==5), active=[active 4]; end
    for j=1:size(xy,1)
        col=[.90 .94 .97]; if any(active==j), col=[1 .82 .4]; end
        rectangle('Position',[xy(j,:) .24 .16],'FaceColor',col,'EdgeColor',[.2 .35 .5]);
        text(xy(j,1)+.12,xy(j,2)+.08,names{j},'HorizontalAlignment','center','FontSize',11);
    end
    edges=[route(1:end-1)' route(2:end)'];
    if any(route==5), edges(end+1,:)=[4 5]; end
    for j=1:size(edges,1)
        a=xy(edges(j,1),:)+[.12 .08]; b=xy(edges(j,2),:)+[.12 .08];
        d=b-a; len=sqrt(sum(d.^2));
        trim=.10; if abs(d(1))>abs(d(2)), trim=.14; end
        a=a+d/len*trim; b=b-d/len*trim;
        quiver(a(1),a(2),b(1)-a(1),b(2)-a(2),0,'Color',[.85 .25 .1],'LineWidth',2,'MaxHeadSize',.4);
    end
    title(sprintf('Token %d | layer %d | %s | event %d / %d',e.token,e.layer,e.op,k,numel(tr)), 'Interpreter','none');
    annotation('textbox',[.04 .09 .92 .06],'String',sprintf( ...
        'HBM read %d B | write %d B | %.3f ... %.3f us', ...
        e.read_bytes,e.write_bytes,e.start_s*1e6,e.finish_s*1e6), ...
        'EdgeColor','none','FontSize',11,'Interpreter','none');
    annotation('textbox',[.04 .03 .92 .06], ...
        'String','Architectural tensor flow; random weights, estimated time.', ...
        'EdgeColor','none','FontSize',10,'Interpreter','none');
    drawnow;
    if k==1, print(f,fullfile(here,'out','llm_flow.png'),'-dpng','-r120'); end
    if animate, pause(delay_s); else break; end
end
if ~animate && ishandle(f), close(f); end
end
