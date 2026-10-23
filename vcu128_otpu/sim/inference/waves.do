onerror {resume}
add wave -divider {COMMAND: inference projection}
add wave sim:/tb_mxu/clk sim:/tb_mxu/rst sim:/tb_mxu/test_id sim:/tb_mxu/rows sim:/tb_mxu/start sim:/tb_mxu/go sim:/tb_mxu/rdy sim:/tb_mxu/done
add wave -divider {HBM -> weight FIFO -> systolic MXU}
add wave sim:/tb_mxu/b_req sim:/tb_mxu/b_gnt
add wave -radix unsigned sim:/tb_mxu/b_addr
add wave sim:/tb_mxu/b_rvalid sim:/tb_mxu/b_rdata
add wave -radix unsigned sim:/tb_mxu/pf_level
add wave sim:/tb_mxu/pf_starve sim:/tb_mxu/pf_block sim:/tb_mxu/computing
add wave -divider {ACT RAM -> MXU}
add wave -radix unsigned sim:/tb_mxu/act_blk
add wave sim:/tb_mxu/act_ren sim:/tb_mxu/act_data sim:/tb_mxu/act_scale
add wave -divider {MXU -> FP32 epilogue -> TMEM}
add wave sim:/tb_mxu/t_gnt sim:/tb_mxu/t_wen
add wave -radix unsigned sim:/tb_mxu/t_waddr
add wave -radix hexadecimal sim:/tb_mxu/t_wdata
configure wave -namecolwidth 260
wave zoom full
