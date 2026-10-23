// Связка для теста: upstream otpu_mem_ch (как есть) + otpu_hbm_port; порты AXI3 HBM -- наружу,
// к Python-модели (hbm_model.py). Такты clk (ускоритель), xclk (XDMA/мост), uclk (HBM).
module tb_memch_hbm #(
  parameter int XIDW = 4,
  parameter int NS   = 1,             // AXI-портов HBM на native-порт (otpu_hbm_port NS)
  parameter int AQ   = 4,
  parameter int ARD  = 64,            // otpu_mem_ch: кредиты чтения ускорителя, beat
  parameter int RD   = 32,            // otpu_hbm_port: слоты чтения на AXI-порт
  parameter int PCB  = 3,             // otpu_hbm_port: log2 псевдоканалов в канале
  localparam int NA  = 2 * NS
) (
  input  logic              clk,
  input  logic              rst,
  input  logic              n_cvalid,
  output logic              n_cready,
  input  logic              n_cwe,
  input  logic [24:0]       n_caddr,
  input  logic              n_wvalid,
  output logic              n_wready,
  input  logic [511:0]      n_wdata,
  input  logic [63:0]       n_wmask,
  output logic              n_rvalid,
  output logic [511:0]      n_rdata,
  output logic [15:0]       n_wdone,
  output logic              n_err,
  input  logic              xclk,
  input  logic              xrst,
  input  logic              x_awvalid,
  output logic              x_awready,
  input  logic [XIDW-1:0]   x_awid,
  input  logic [31:0]       x_awaddr,
  input  logic [7:0]        x_awlen,
  input  logic [2:0]        x_awsize,        // нет у otpu_mem_ch: только проверка (16 байт, INCR)
  input  logic [1:0]        x_awburst,
  input  logic              x_wvalid,
  output logic              x_wready,
  input  logic [127:0]      x_wdata,
  input  logic [15:0]       x_wstrb,
  input  logic              x_wlast,
  output logic              x_bvalid,
  input  logic              x_bready,
  output logic [XIDW-1:0]   x_bid,
  output logic [1:0]        x_bresp,
  input  logic              x_arvalid,
  output logic              x_arready,
  input  logic [XIDW-1:0]   x_arid,
  input  logic [31:0]       x_araddr,
  input  logic [7:0]        x_arlen,
  input  logic [2:0]        x_arsize,
  input  logic [1:0]        x_arburst,
  output logic              x_rvalid,
  input  logic              x_rready,
  output logic [XIDW-1:0]   x_rid,
  output logic [127:0]      x_rdata,
  output logic [1:0]        x_rresp,
  output logic              x_rlast,
  input  logic              uclk,
  input  logic              urst,
  output logic [NA-1:0]        m_awvalid,
  input  logic [NA-1:0]        m_awready,
  output logic [NA-1:0][32:0]  m_awaddr,
  output logic [NA-1:0][5:0]   m_awid,
  output logic [NA-1:0][3:0]   m_awlen,
  output logic [NA-1:0][2:0]   m_awsize,
  output logic [NA-1:0][1:0]   m_awburst,
  output logic [NA-1:0]        m_wvalid,
  input  logic [NA-1:0]        m_wready,
  output logic [NA-1:0][255:0] m_wdata,
  output logic [NA-1:0][31:0]  m_wstrb,
  output logic [NA-1:0]        m_wlast,
  output logic [NA-1:0][5:0]   m_wid,
  output logic [NA-1:0][31:0]  m_wdata_parity,
  input  logic [NA-1:0]        m_bvalid,
  output logic [NA-1:0]        m_bready,
  input  logic [NA-1:0][5:0]   m_bid,
  input  logic [NA-1:0][1:0]   m_bresp,
  output logic [NA-1:0]        m_arvalid,
  input  logic [NA-1:0]        m_arready,
  output logic [NA-1:0][32:0]  m_araddr,
  output logic [NA-1:0][5:0]   m_arid,
  output logic [NA-1:0][3:0]   m_arlen,
  output logic [NA-1:0][2:0]   m_arsize,
  output logic [NA-1:0][1:0]   m_arburst,
  input  logic [NA-1:0]        m_rvalid,
  output logic [NA-1:0]        m_rready,
  input  logic [NA-1:0][5:0]   m_rid,
  input  logic [NA-1:0][255:0] m_rdata,
  input  logic [NA-1:0][1:0]   m_rresp,
  input  logic [NA-1:0]        m_rlast,
  output logic [NA-1:0][31:0]  st_rcmd,
  output logic [NA-1:0][31:0]  st_wcmd,
  output logic [NA-1:0][6:0]   st_rout,
  output logic [NA-1:0][6:0]   st_wout,
  output logic [NA-1:0][31:0]  st_dep,
  output logic [NA-1:0]        st_busy,
  output logic [15:0]       st_err_cnt,
  output logic              st_err,
  output logic              st_perr,
  output logic [1:0]        c_cmd_valid,     // наблюдение: сторона контроллера
  output logic [1:0]        c_cmd_ready,
  output logic [1:0]        c_rdata_valid
);
  logic [1:0]        c_cmd_we, c_wdata_valid, c_wdata_ready;
  logic [1:0][24:0]  c_cmd_addr;
  logic [1:0][511:0] c_wdata_data, c_rdata_data;
  logic [1:0][63:0]  c_wdata_we;

  otpu_mem_ch #(.XIDW(XIDW), .ARD(ARD)) u_ch (
    .clk, .rst, .n_cvalid, .n_cready, .n_cwe, .n_caddr, .n_wvalid, .n_wready, .n_wdata, .n_wmask,
    .n_rvalid, .n_rdata, .n_wdone, .n_err,
    .xclk, .xrst, .x_awvalid, .x_awready, .x_awid, .x_awaddr, .x_awlen, .x_wvalid, .x_wready,
    .x_wdata, .x_wstrb, .x_wlast, .x_bvalid, .x_bready, .x_bid, .x_bresp, .x_arvalid, .x_arready,
    .x_arid, .x_araddr, .x_arlen, .x_rvalid, .x_rready, .x_rid, .x_rdata, .x_rresp, .x_rlast,
    .uclk, .urst, .c_cmd_valid, .c_cmd_ready, .c_cmd_we, .c_cmd_addr, .c_wdata_valid,
    .c_wdata_ready, .c_wdata_data, .c_wdata_we, .c_rdata_valid, .c_rdata_data);

  otpu_hbm_port #(.NS(NS), .AQ(AQ), .RD(RD), .PCB(PCB)) u_hbm (
    .uclk, .urst, .c_cmd_valid, .c_cmd_ready, .c_cmd_we, .c_cmd_addr, .c_wdata_valid,
    .c_wdata_ready, .c_wdata_data, .c_wdata_we, .c_rdata_valid, .c_rdata_data,
    .m_awvalid, .m_awready, .m_awaddr, .m_awid, .m_awlen, .m_awsize, .m_awburst,
    .m_wvalid, .m_wready, .m_wdata, .m_wstrb, .m_wlast, .m_wid, .m_wdata_parity,
    .m_bvalid, .m_bready, .m_bid, .m_bresp,
    .m_arvalid, .m_arready, .m_araddr, .m_arid, .m_arlen, .m_arsize, .m_arburst,
    .m_rvalid, .m_rready, .m_rid, .m_rdata, .m_rresp, .m_rlast,
    .st_rcmd, .st_wcmd, .st_rout, .st_wout, .st_dep, .st_busy, .st_err_cnt, .st_err, .st_perr);

  always_ff @(posedge xclk) if (!xrst) begin
    if (x_awvalid && (x_awsize != 3'd4 || x_awburst != 2'b01))
      $error("tb_memch_hbm: XDMA AW не INCR по 16 байт");
    if (x_arvalid && (x_arsize != 3'd4 || x_arburst != 2'b01))
      $error("tb_memch_hbm: XDMA AR не INCR по 16 байт");
  end
endmodule
