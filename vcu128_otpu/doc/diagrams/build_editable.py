#!/usr/bin/env python3
"""Editable diagrams.net pages plus Graphviz SVG/PDF from the same graph."""
from pathlib import Path
import subprocess
import xml.etree.ElementTree as X

HERE = Path(__file__).resolve().parent
# node id, label, grid x/y, kind; edges: source, destination, label, control
pages = [
('01 Platform', [
('host','ПК\nTokenizer / compiler / Board API\nEthTransport',0,0,'sw'),
('mac','QSFP1 / GTY quad 135\n40G MAC + PCS\nAXIS 256 bit',1,0,'io'),
('bridge','otpu_eth_bridge\nUDP / SEQ / retry cache\nAXI4 DMA + AXI-Lite',2,0,'io'),
('ereg','eth40_regs\n0x50000\nLink / RX / TX counters',3,0,'ctl'),
('cdc','axil_cdc\neth_clk → core_clk',2,1,'ctl'),
('jtag','jtag_axi_0\nDebug master',0,1,'ctl'),
('xbar','vcu128_axil_xbar\n2 masters / 3 windows',1,1,'ctl'),
('regs','Platform / MAC init\n0x40000 / 0x60000',3,1,'ctl'),
('board','otpu_bcu_sys / otpu_board\notpu_ctrl + trace + otpu_top\nS=1 slice, core=100 MHz',0,2,'core'),
('memch','otpu_mem_ch ×2\nCore / host arbitration, RMW\nCDC core / xclk / uclk',1,2,'mem'),
('port','otpu_hbm_port ×2\nRAW / WAR / WAW, RD / WD\n64-byte beats → AXI3',2,2,'mem'),
('hbm','hbm_0 / HBM2\n4 active AXI3 ports, 256 bit\n8 GiB physical / 4 GiB mapped',3,2,'mem'),
('clock','Clock / reset\nQDR4 100 → core100, uclk225 MHz\nDDR4 100 → HBM reference',0,3,'ctl')],
[('host','mac','40G DAC, UDP',False),('mac','bridge','AXIS RX / TX',False),('bridge','ereg','AXI-Lite',True),('bridge','cdc','AXI-Lite',True),('cdc','xbar','core_clk',True),('jtag','xbar','AXI-Lite',True),('xbar','regs','control / status',True),('xbar','board','0x00000, load / run',True),('bridge','memch','AXI4 DMA 128 bit / channel',False),('board','memch','native reads / writes',False),('memch','port','2 native ports / channel',False),('port','hbm','AXI3 256 bit, 225 MHz',False),('clock','board','clock / reset',True)]),
('02 Compute slice', [
('imem','IMEM\n32768 instructions\nLoader from DRAM',0,0,'mem'),
('seq','otpu_seq\nDispatch WIN=16 / scoreboard\nBAR, HALT, dependencies',1,0,'ctl'),
('coll','Collective / register reads\notpu_coll / RLD\nS=1: no inter-slice reduction',2,0,'core'),
('dma','otpu_dma\nLD / ST / DSTEP / STREAM\nTensor transfers / stream tail',0,1,'core'),
('quant','otpu_quant\nQACT: FP32 → ACT\nQST: FP32 → DRAM INT8 / scales',1,1,'core'),
('mxu','otpu_mxu\nD=128, MCOLS=4\nINT8 / 4-bit systolic dot products',2,1,'core'),
('vpu','otpu_vpu\n8 FP32 lanes, VPU_CL=2\nReductions / EXP / RECIP / RSQRT',3,1,'core'),
('tmem','otpu_tmem\n65536 FP32 words, 8 banks\nPer-unit read copies, TMEM_IMPL=0',0,2,'mem'),
('act','otpu_actram\n4 rows ×128 blocks ×128 INT8\nSa + group offsets per block',1,2,'mem'),
('fifo','MXU stream + scale FIFOs\nFIFO_DEPTH=1024 in target\nInteger accumulator / FP32 epilogue',2,2,'mem'),
('arb','Slice arbitration\nTMEM all-or-nothing grants\nDRAM B: DMA > MXU',3,2,'ctl'),
('dram','otpu_native_dram → mem_ch → HBM\nA: scale lines, B: chunks / DMA\nSW: QST scalar writes',1,3,'mem')],
[('imem','seq','instructions',False),('seq','dma','dispatch',True),('seq','quant','dispatch',True),('seq','mxu','start / go',True),('seq','vpu','dispatch',True),('seq','coll','dispatch',True),('dma','tmem','LD / ST FP32',False),('tmem','quant','FP32 input',False),('quant','act','INT8 codes / scale',False),('act','mxu','stationary activations',False),('dram','fifo','weights / scales',False),('fifo','mxu','prefetch / replay',False),('mxu','tmem','FP32 results',False),('vpu','tmem','FP32 reads / writes',False),('coll','tmem','read / write',False),('dma','dram','bulk data',False),('quant','dram','QST',False),('arb','tmem','bank grants',True),('arb','dram','port grants',True)]),
('03 LLM numerical model', [
('token','Token ID\nPrompt then greedy decode\nRandom deterministic weights',0,0,'sw'),
('embed','Embedding\nFP32 row from HBM',1,0,'mem'),
('norm1','Attention RMSNorm\nMathematical VPU approximation',2,0,'core'),
('qkv','Q / K / V projections\nQACT → INT8 MM → FP32',3,0,'core'),
('rope','RoPE\nQ and K, current position',3,1,'core'),
('cache','KV-cache INT8 + FP32 scale in HBM\nQST: TMEM → QUANT → HBM\nK rows, Vᵀ tiles, prefix 1..T',2,1,'mem'),
('attn','GQA causal attention\nMXU: q·Kᵀ (K streamed from HBM)\nVPU: softmax · MXU: P·Vᵀ',1,1,'core'),
('out','O projection + residual\nQACT → INT8 MM → add input',0,1,'core'),
('norm2','FFN RMSNorm',0,2,'core'),
('gate','Gate / Up projections\nQACT → INT8 MM',1,2,'core'),
('swiglu','SwiGLU\nSiLU(gate) × up',2,2,'core'),
('down','Down projection + residual\nINT8 MM → add input\nRepeat next layer',3,2,'core'),
('final','Final RMSNorm + LM head\nLogits → argmax → next ID',3,3,'core'),
('timing','llm_event / HBM estimate\n64-byte rounded tensor traffic\nduration=max(memory, compute)',1,3,'ctl')],
[('token','embed','token ID',False),('embed','norm1','hidden vector',False),('norm1','qkv','normalized FP32',False),('qkv','rope','Q,K; V bypass',False),('rope','cache','K,V current',False),('cache','attn','KV prefix; Q from RoPE',False),('attn','out','attention result',False),('out','norm2','residual result',False),('norm2','gate','normalized FP32',False),('gate','swiglu','gate,up',False),('swiglu','down','gated hidden',False),('down','norm1','next layer',True),('down','final','after last layer',False),('final','token','next token',True),('cache','timing','read / write bytes',True),('qkv','timing','weight bytes / compute ops',True)])]

colors={'sw':'#fff1d6','io':'#dceeff','ctl':'#fff0d9','core':'#e3edf9','mem':'#def2e9'}
mxfile=X.Element('mxfile',host='app.diagrams.net',type='device')
for title,nodes,edges in pages:
    diagram=X.SubElement(mxfile,'diagram',name=title,id=title[:2])
    model=X.SubElement(diagram,'mxGraphModel',dx='1600',dy='1200',grid='1',gridSize='10',page='1',pageWidth='1600',pageHeight='1200')
    root=X.SubElement(model,'root');X.SubElement(root,'mxCell',id='0');X.SubElement(root,'mxCell',id='1',parent='0')
    cell=X.SubElement(root,'mxCell',id='title',value=title+' — VCU128 openTPU | target/vcu128.toml',style='text;fontSize=24;align=left;',vertex='1',parent='1')
    X.SubElement(cell,'mxGeometry',x='35',y='20',width='1500',height='50',**{'as':'geometry'})
    # json.dumps provides Graphviz-compatible escaped strings.
    import json
    q=lambda s:json.dumps(s,ensure_ascii=False)
    dot=['digraph G {',f'graph [rankdir=TB, nodesep=0.65, ranksep=1, pad=0.3, fontname="DejaVu Sans", label={q(title)}, labelloc=t, fontsize=24];','node [shape=box, style="rounded,filled", fontname="DejaVu Sans", fontsize=12, margin="0.2,0.15"];','edge [fontname="DejaVu Sans", fontsize=10, color="#3d6a8b"];']
    for ident,label,x,y,kind in nodes:
        cell=X.SubElement(root,'mxCell',id=ident,value=label,style=f'rounded=1;whiteSpace=wrap;html=0;fillColor={colors[kind]};strokeColor=#3d6a8b;fontSize=15;',vertex='1',parent='1')
        X.SubElement(cell,'mxGeometry',x=str(35+x*385),y=str(110+y*250),width='305',height='120',**{'as':'geometry'})
        dot.append(f'{ident} [label={q(label)},fillcolor="{colors[kind]}"];')
    for i,(a,b,label,ctl) in enumerate(edges):
        cell=X.SubElement(root,'mxCell',id='edge'+str(i),value=label,style='edgeStyle=orthogonalEdgeStyle;rounded=1;html=0;endArrow=block;'+('dashed=1;strokeColor=#ab651d;' if ctl else 'strokeColor=#2369a3;'),edge='1',parent='1',source=a,target=b)
        X.SubElement(cell,'mxGeometry',relative='1',**{'as':'geometry'})
        dot.append(f'{a} -> {b} [label={q(label)},style={"dashed" if ctl else "solid"}];')
    dot.append('}')
    stem=HERE/('structure_'+title[:2]);stem.with_suffix('.dot').write_text('\n'.join(dot))
    for fmt in ('svg','pdf'):
        subprocess.run(['dot','-T'+fmt,str(stem.with_suffix('.dot')),'-o',str(stem.with_suffix('.'+fmt))],check=True)
X.indent(mxfile)
X.ElementTree(mxfile).write(HERE/'project_structure.drawio',encoding='utf-8',xml_declaration=True)
print('3 editable pages, 3 SVG and 3 PDF generated')
