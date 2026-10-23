function model=build_flow_simulink()
% Build a Simulink EVENT REPLAY dashboard from the numerical decoder's trace.
% Numerical LLM runs in run_demo; these blocks do not implement RTL/LLM math.
here=fileparts(mfilename('fullpath')); addpath(here);
assert(exist('new_system','file')~=0,'Simulink is required (Octave cannot build SLX)');
r=run_demo([],false); tr=r.state.trace; n=numel(tr);
% Two samples per event: hold the event values over its full duration.
time=zeros(2*n+1,1); values=zeros(2*n+1,8);
for k=1:n
    e=tr(k); route=otpu.flow_route(e.op); activity=zeros(1,6); activity(unique(route))=1;
    ix=2*k-1; time(ix)=e.start_s; time(ix+1)=e.finish_s;
    values(ix:ix+1,:)=repmat([activity e.read_bytes e.write_bytes],2,1);
end
time(end)=time(end-1)+1e-9; % return to idle after last event
% Duplicate boundary times intentionally describe discontinuities (ZOH).
flow_trace=[time values]; %#ok<NASGU>
out=fullfile(here,'out'); save(fullfile(out,'simulink_flow_input.mat'),'flow_trace');
model='otpu_llm_event_flow'; if bdIsLoaded(model), close_system(model,0); end
new_system(model); open_system(model);
input_file=strrep(fullfile(out,'simulink_flow_input.mat'),'''','''''');
set_param(model,'InitFcn',sprintf('load(''%s'',''flow_trace'');',input_file));
assignin('base','flow_trace',flow_trace);
set_param(model,'SolverType','Variable-step','Solver','ode45','StopTime',sprintf('%.15g',time(end)));
add_block('simulink/Sources/From Workspace',[model '/Numerical trace'], ...
    'VariableName','flow_trace','Interpolate','off','Position',[30 120 180 160]);
add_block('simulink/Signal Routing/Demux',[model '/Routes'],'Outputs','8','Position',[230 40 235 440]);
add_line(model,'Numerical trace/1','Routes/1');
names={'HBM','TMEM','QUANT','ACT','MXU','VPU','Read bytes','Write bytes'};
for j=1:8
    path=[model '/' names{j}];
    add_block('simulink/Sinks/Scope',path,'Position',[340 25+j*52 430 55+j*52]);
    add_line(model,sprintf('Routes/%d',j),[names{j} '/1']);
end
Simulink.Annotation(model,'EVENT REPLAY: activity + HBM bytes. Numerical model in run_demo; estimated time, random weights.');
save_system(model,fullfile(out,[model '.slx']));
end
