function route=flow_route(op)
% 1 HBM, 2 TMEM, 3 QUANT, 4 ACT, 5 MXU, 6 VPU; paths as in upstream otpu_slice / Lens.
% MM routes start at HBM (weights, K rows or V^T streamed on port B); ACT -> MXU is added by
% the viewers for every route through the MXU.
if any(strcmp(op,{'embedding'})), route=[1 2];                  % LD: HBM -> DMA -> TMEM
elseif strcmp(op,'logits_store'), route=[2 1];                  % ST: TMEM -> DMA -> HBM
elseif strcmp(op,'kv_write'), route=[2 3 1];                    % QST: TMEM -> QUANT -> HBM
elseif ~isempty(strfind(op,'_qact')), route=[2 3 4];            % QACT: TMEM -> QUANT -> ACT
elseif any(strcmp(op,{'q','k','v','o','gate','up','down','lm_head','attn_scores','attn_pv'}))
    route=[1 5 2];                                              % MM: HBM -> MXU -> TMEM
else, route=[2 6 2];                                            % VOP: TMEM -> VPU -> TMEM
end
end
