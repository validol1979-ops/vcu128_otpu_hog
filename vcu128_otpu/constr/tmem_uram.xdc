# TMEM in UltraRAM (synthesis only: sources.con noimpl). Every TMEM copy's banks
# (otpu_tmem g_port[p].g_copy.g_bank[b].mem, 8K x 32 each) as URAM288 instead of block RAM;
# the RTL is unchanged, so the simulations hold as they are.
# The property of upstream boards/bcu1525/vivado/tmem_uram.xdc (f237dab), without its `if`:
# Vivado does not take `if` in an .xdc ("Designutils 20-1307") and skips the whole block,
# which left the TMEM in block RAM in the 5f5ca63 build. No cell matched gives a warning.
set_property RAM_STYLE ULTRA [get_cells -hierarchical -filter {NAME =~ *u_tmem/g_port*.g_bank*.mem_reg*}]
