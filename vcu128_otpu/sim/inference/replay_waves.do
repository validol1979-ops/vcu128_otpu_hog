add wave -divider {ARCHITECTURAL EVENT REPLAY / estimated time}
add wave -radix unsigned sim:/tb_llm_replay/event_index sim:/tb_llm_replay/token sim:/tb_llm_replay/layer
add wave sim:/tb_llm_replay/operation sim:/tb_llm_replay/active
add wave -divider {Nodes: 0 HBM, 1 TMEM, 2 QUANT, 3 ACT, 4 MXU, 5 VPU}
add wave -radix unsigned sim:/tb_llm_replay/source sim:/tb_llm_replay/destination sim:/tb_llm_replay/read_bytes sim:/tb_llm_replay/write_bytes
configure wave -namecolwidth 260
wave zoom full
