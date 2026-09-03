// wrap_byte_dmac.v -- the REAL ADI axi_dmac (rx_byte_dma) for Verilator, 2026-08-28.
//
// Parameter set = rx_byte_dma in jupiter_byte_rxfifo4k_build system.bd (BD CONFIG.*,
// everything else at the IP default):
//   DMA_TYPE_SRC=1 (AXI-stream) DMA_TYPE_DEST=0 (AXI-MM) DMA_DATA_WIDTH_SRC/DEST=64
//   SYNC_TRANSFER_START=1  CYCLIC=1  CACHE_COHERENT=1  AXI_AXCACHE=4'b1111  AXI_AXPROT=3'b010
//   AXI_SLICE_SRC/DEST=0   DMA_2D_TRANSFER=0
//   defaults: DMA_LENGTH_WIDTH=24 FIFO_SIZE=8 MAX_BYTES_PER_BURST=128 DMA_AXI_ADDR_WIDTH=64
//             AXIS_TUSER_SYNC=1 ASYNC_CLK_*=1
// Clocks on silicon: s_axis_aclk=adc_1_clk (fabric), m_dest_axi_aclk=sys_250m_clk,
// s_axi_aclk=sys_cpu_clk. MODELLING SIMPLIFICATION: one clock drives all three here
// (the ASYNC_CLK CDC stages are kept, they just see the same clock).
// Witness taps reach into the source data mover (dmac_src/request_arb.v carries a
// one-line SIM SHIM: the stream-source generate block is labelled g_src_stream).
`timescale 1ns/1ps
module wrap_byte_dmac (
  input  wire        clk,
  input  wire        resetn,
  // AXI4-Lite regmap (host)
  input  wire        s_axi_awvalid, input wire [10:0] s_axi_awaddr, output wire s_axi_awready,
  input  wire        s_axi_wvalid,  input wire [31:0] s_axi_wdata,  output wire s_axi_wready,
  output wire        s_axi_bvalid,  input  wire s_axi_bready,
  input  wire        s_axi_arvalid, input wire [10:0] s_axi_araddr, output wire s_axi_arready,
  output wire        s_axi_rvalid,  input  wire s_axi_rready, output wire [31:0] s_axi_rdata,
  output wire        irq,
  // AXI-stream source (byte plane -> DMAC)
  input  wire        s_axis_valid, output wire s_axis_ready,
  input  wire [63:0] s_axis_data,  input wire s_axis_last, input wire s_axis_user,
  // AXI-MM dest write channel (DDR model)
  output wire        m_awvalid, input wire m_awready, output wire [63:0] m_awaddr, output wire [7:0] m_awlen,
  output wire        m_wvalid,  input wire m_wready,  output wire [63:0] m_wdata, output wire m_wlast,
  input  wire        m_bvalid,  output wire m_bready,
  // witnesses
  output wire        wit_needs_sync,
  output wire        wit_active,
  output wire        wit_pending_burst,
  output wire        wit_xfer_req
);
  wire [2:0] awsize; wire [1:0] awburst; wire [2:0] awprot; wire [3:0] awcache; wire [0:0] awid; wire [0:0] awlock;
  wire [7:0] wstrb; wire [0:0] wid;
  wire arvalid; wire [63:0] araddr; wire [7:0] arlen; wire [2:0] arsize; wire [1:0] arburst; wire [3:0] arcache; wire [2:0] arprot; wire rready; wire [0:0] arid; wire [0:0] arlock;
  wire [1:0] s_axi_bresp, s_axi_rresp;

  axi_dmac #(
    .ID(0),
    .DMA_DATA_WIDTH_SRC(64), .DMA_DATA_WIDTH_DEST(64),
    .DMA_LENGTH_WIDTH(24),
    .DMA_2D_TRANSFER(0), .DMA_SG_TRANSFER(0),
    .AXI_SLICE_DEST(0), .AXI_SLICE_SRC(0),
    .AXIS_TUSER_SYNC(1), .SYNC_TRANSFER_START(1),
    .CYCLIC(1),
    .DMA_TYPE_DEST(0), .DMA_TYPE_SRC(1),
    .DMA_AXI_ADDR_WIDTH(64),
    .MAX_BYTES_PER_BURST(128), .FIFO_SIZE(8),
    .CACHE_COHERENT(1), .AXI_AXCACHE(4'b1111), .AXI_AXPROT(3'b010)
  ) u_dmac (
    .s_axi_aclk(clk), .s_axi_aresetn(resetn),
    .s_axi_awvalid(s_axi_awvalid), .s_axi_awaddr(s_axi_awaddr), .s_axi_awready(s_axi_awready), .s_axi_awprot(3'b0),
    .s_axi_wvalid(s_axi_wvalid), .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(4'hF), .s_axi_wready(s_axi_wready),
    .s_axi_bvalid(s_axi_bvalid), .s_axi_bresp(s_axi_bresp), .s_axi_bready(s_axi_bready),
    .s_axi_arvalid(s_axi_arvalid), .s_axi_araddr(s_axi_araddr), .s_axi_arready(s_axi_arready), .s_axi_arprot(3'b0),
    .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready), .s_axi_rresp(s_axi_rresp), .s_axi_rdata(s_axi_rdata),
    .irq(irq), .sync(1'b0),
    .m_dest_axi_aclk(clk), .m_dest_axi_aresetn(resetn),
    .m_dest_axi_awaddr(m_awaddr), .m_dest_axi_awlen(m_awlen), .m_dest_axi_awsize(awsize), .m_dest_axi_awburst(awburst),
    .m_dest_axi_awprot(awprot), .m_dest_axi_awcache(awcache), .m_dest_axi_awvalid(m_awvalid), .m_dest_axi_awready(m_awready),
    .m_dest_axi_awid(awid), .m_dest_axi_awlock(awlock),
    .m_dest_axi_wdata(m_wdata), .m_dest_axi_wstrb(wstrb), .m_dest_axi_wready(m_wready), .m_dest_axi_wvalid(m_wvalid),
    .m_dest_axi_wlast(m_wlast), .m_dest_axi_wid(wid),
    .m_dest_axi_bvalid(m_bvalid), .m_dest_axi_bresp(2'b00), .m_dest_axi_bready(m_bready), .m_dest_axi_bid(1'b0),
    .m_dest_axi_arvalid(arvalid), .m_dest_axi_araddr(araddr), .m_dest_axi_arlen(arlen), .m_dest_axi_arsize(arsize),
    .m_dest_axi_arburst(arburst), .m_dest_axi_arcache(arcache), .m_dest_axi_arprot(arprot), .m_dest_axi_arready(1'b0),
    .m_dest_axi_rvalid(1'b0), .m_dest_axi_rresp(2'b00), .m_dest_axi_rdata(64'd0), .m_dest_axi_rready(rready),
    .m_dest_axi_arid(arid), .m_dest_axi_arlock(arlock), .m_dest_axi_rid(1'b0), .m_dest_axi_rlast(1'b0),
    // unused source MM / SG masters: tie inputs idle
    .m_src_axi_aclk(clk), .m_src_axi_aresetn(resetn),
    .m_src_axi_arready(1'b0), .m_src_axi_rdata(64'd0), .m_src_axi_rvalid(1'b0), .m_src_axi_rresp(2'b0), .m_src_axi_rid(1'b0), .m_src_axi_rlast(1'b0),
    .m_src_axi_awready(1'b0), .m_src_axi_wready(1'b0), .m_src_axi_bvalid(1'b0), .m_src_axi_bresp(2'b0), .m_src_axi_bid(1'b0),
    .m_sg_axi_aclk(clk), .m_sg_axi_aresetn(resetn),
    .m_sg_axi_arready(1'b0), .m_sg_axi_rdata(64'd0), .m_sg_axi_rvalid(1'b0), .m_sg_axi_rresp(2'b0), .m_sg_axi_rid(1'b0), .m_sg_axi_rlast(1'b0),
    .m_sg_axi_awready(1'b0), .m_sg_axi_wready(1'b0), .m_sg_axi_bvalid(1'b0), .m_sg_axi_bresp(2'b0), .m_sg_axi_bid(1'b0),
    // stream source
    .s_axis_aclk(clk), .s_axis_ready(s_axis_ready), .s_axis_valid(s_axis_valid), .s_axis_data(s_axis_data),
    .s_axis_strb(8'hFF), .s_axis_keep(8'hFF), .s_axis_user({s_axis_user}), .s_axis_id(8'd0), .s_axis_dest(4'd0), .s_axis_last(s_axis_last),
    // unused stream dest / fifo interfaces
    .m_axis_aclk(clk), .m_axis_ready(1'b0),
    .fifo_wr_clk(clk), .fifo_wr_en(1'b0), .fifo_wr_din(64'd0),
    .fifo_rd_clk(clk), .fifo_rd_en(1'b0),
    .src_ext_sync(1'b0), .dest_ext_sync(1'b0)
  );

  assign wit_needs_sync    = u_dmac.i_transfer.i_request_arb.g_src_stream.i_src_dma_stream.i_data_mover.needs_sync;
  assign wit_active        = u_dmac.i_transfer.i_request_arb.g_src_stream.i_src_dma_stream.i_data_mover.active;
  assign wit_pending_burst = u_dmac.i_transfer.i_request_arb.g_src_stream.i_src_dma_stream.i_data_mover.pending_burst;
  assign wit_xfer_req      = u_dmac.i_transfer.i_request_arb.g_src_stream.i_src_dma_stream.i_data_mover.xfer_req;
endmodule
