`timescale 1ns/1ps
module eth_async_fifo #(parameter WIDTH=9,DEPTH=2048)(
    input wire rst,wr_clk,rd_clk,input wire [WIDTH-1:0] din,input wire wr_en,rd_en,
    output wire [WIDTH-1:0] dout,output wire full,empty,wr_busy,rd_busy);
    xpm_fifo_async #(.FIFO_MEMORY_TYPE("block"),.FIFO_WRITE_DEPTH(DEPTH),
        .WRITE_DATA_WIDTH(WIDTH),.READ_DATA_WIDTH(WIDTH),.READ_MODE("fwft"),.FIFO_READ_LATENCY(0),
        .CDC_SYNC_STAGES(3),.DOUT_RESET_VALUE("0"),.ECC_MODE("no_ecc"),.USE_ADV_FEATURES("0000"),
        .WR_DATA_COUNT_WIDTH($clog2(DEPTH)+1),.RD_DATA_COUNT_WIDTH($clog2(DEPTH)+1),
        .PROG_EMPTY_THRESH(10),.PROG_FULL_THRESH(10),.SIM_ASSERT_CHK(1)) fifo(
        .rst(rst),.wr_clk(wr_clk),.rd_clk(rd_clk),.din(din),.wr_en(wr_en&&!full&&!wr_busy),
        .rd_en(rd_en&&!empty&&!rd_busy),.dout(dout),.full(full),.empty(empty),
        .wr_rst_busy(wr_busy),.rd_rst_busy(rd_busy),.sleep(1'b0),.injectsbiterr(1'b0),.injectdbiterr(1'b0),
        .almost_empty(),.almost_full(),.data_valid(),.dbiterr(),.overflow(),.prog_empty(),.prog_full(),
        .rd_data_count(),.sbiterr(),.underflow(),.wr_ack(),.wr_data_count());
endmodule
