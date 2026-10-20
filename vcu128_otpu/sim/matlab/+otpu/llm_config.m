function p = llm_config()
% Small executable decoder; random weights, token IDs rather than a tokenizer.
p.hidden=128; p.intermediate=256; p.layers=2; p.heads=4; p.kv_heads=2;
p.vocab=256; p.max_seq=64; p.rope_base=10000; p.rms_eps=1e-5;
p.prompt=[1 7 23]; p.generate=8; p.seed=217;
p.weight_format='int8'; p.kv_bytes=4;
end
