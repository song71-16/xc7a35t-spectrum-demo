`timescale 1ns/1ps
// IDDR/ODDR topology follows the supplied 51_eth_udp_loop example.
// RX_ER is decoded as rising XOR falling control, not silently discarded.
// PHY supplies RX/TX clock skew. Eleven calibrated RX data taps compensate
// the FPGA BUFIO insertion relative to the direct data path (STA checked).
module eth_rgmii(input wire ref_clk,ref_rst,net_clk,net_rst,
    input wire eth_rxc,eth_rx_ctl,input wire [3:0] eth_rxd,
    output wire eth_txc,eth_tx_ctl,output wire [3:0] eth_txd,
    output wire rx_clk,output wire [7:0] rx_data,output wire rx_dv,rx_error,
    input wire [7:0] tx_data,input wire tx_en,output wire delay_ready);
    wire io_clk;wire [4:0] delayed;wire [1:0] control;
    BUFIO rxio(.I(eth_rxc),.O(io_clk));BUFG rxbuf(.I(eth_rxc),.O(rx_clk));
    (* IODELAY_GROUP="ethernet_rx" *) IDELAYCTRL delays(.REFCLK(ref_clk),.RST(ref_rst),.RDY(delay_ready));
    wire [4:0] pins={eth_rx_ctl,eth_rxd};
    genvar i;
    generate for(i=0;i<5;i=i+1)begin:rx
        (* IODELAY_GROUP="ethernet_rx" *) IDELAYE2 #(.IDELAY_TYPE("FIXED"),.IDELAY_VALUE(11),
            .REFCLK_FREQUENCY(200.0),.DELAY_SRC("IDATAIN"),.HIGH_PERFORMANCE_MODE("TRUE")) delay(
            .DATAOUT(delayed[i]),.IDATAIN(pins[i]),.DATAIN(1'b0),.C(1'b0),.CE(1'b0),
            .CINVCTRL(1'b0),.CNTVALUEIN(5'b0),.INC(1'b0),.LD(1'b0),.LDPIPEEN(1'b0),.REGRST(1'b0),.CNTVALUEOUT());
        if(i<4)begin
            IDDR #(.DDR_CLK_EDGE("SAME_EDGE_PIPELINED"),.SRTYPE("SYNC")) iddr(
                .Q1(rx_data[i]),.Q2(rx_data[i+4]),.C(io_clk),.CE(1'b1),.D(delayed[i]),.R(1'b0),.S(1'b0));
        end else begin
            IDDR #(.DDR_CLK_EDGE("SAME_EDGE_PIPELINED"),.SRTYPE("SYNC")) iddr(
                .Q1(control[0]),.Q2(control[1]),.C(io_clk),.CE(1'b1),.D(delayed[i]),.R(1'b0),.S(1'b0));
        end
    end endgenerate
    assign rx_dv=control[0];assign rx_error=control[0]^control[1];
    ODDR #(.DDR_CLK_EDGE("SAME_EDGE")) txclock(.Q(eth_txc),.C(net_clk),.CE(1'b1),.D1(1'b1),.D2(1'b0),.R(1'b0),.S(1'b0));
    ODDR #(.DDR_CLK_EDGE("SAME_EDGE")) txcontrol(.Q(eth_tx_ctl),.C(net_clk),.CE(1'b1),
        .D1(tx_en&&!net_rst),.D2(tx_en&&!net_rst),.R(1'b0),.S(1'b0));
    generate for(i=0;i<4;i=i+1)begin:tx
        ODDR #(.DDR_CLK_EDGE("SAME_EDGE")) oddr(.Q(eth_txd[i]),.C(net_clk),.CE(1'b1),
            .D1(tx_data[i]),.D2(tx_data[i+4]),.R(1'b0),.S(1'b0));
    end endgenerate
endmodule
