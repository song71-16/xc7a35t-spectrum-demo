`timescale 1ns/1ps
// Demo derivative: each FIFO reset is clocked in its own write clock domain.
// Both resets belong to the same external reset/PLL-lock epoch.
// Keep the original core byte protocol. Discard telemetry while forwarding RESPONSE.
// One accepted command at a time is enforced by eth_endpoint.
module demo_command_bridge(input wire rst,command_reset,clk,net_clk,
    input wire [7:0] command_data,input wire command_valid,output wire command_ready,
    output wire [8:0] response_data,output wire response_valid,input wire response_ready,
    output wire [7:0] rx_data,output wire rx_valid,input wire rx_ready,
    input wire [7:0] tx_data,input wire tx_valid,output wire tx_ready);
    wire command_full,command_empty,cwb,crb;
    eth_async_fifo #(.WIDTH(8),.DEPTH(1024)) commands(.rst(command_reset),.wr_clk(net_clk),.rd_clk(clk),
        .din(command_data),.wr_en(command_valid),.rd_en(rx_valid&&rx_ready),.dout(rx_data),
        .full(command_full),.empty(command_empty),.wr_busy(cwb),.rd_busy(crb));
    assign command_ready=!command_full&&!cwb;assign rx_valid=!command_empty&&!crb;
    reg [11:0] index=0,total=0;reg [15:0] payload_length=0;reg [7:0] kind=0;
    reg flushing=0;reg [9:0] flush_index=0,flush_length=0;
    (* ram_style="distributed" *) reg [7:0] memory[0:511];
    wire response_full,response_empty,rwb,rrb;
    wire write_response=flushing&&!response_full&&!rwb;
    eth_async_fifo #(.WIDTH(9),.DEPTH(1024)) responses(.rst(rst),.wr_clk(clk),.rd_clk(net_clk),
        .din({flush_index==flush_length-1,memory[flush_index[8:0]]}),.wr_en(write_response),
        .rd_en(response_valid&&response_ready),.dout(response_data),.full(response_full),
        .empty(response_empty),.wr_busy(rwb),.rd_busy(rrb));
    assign response_valid=!response_empty&&!rrb;assign tx_ready=!flushing;
    always @(posedge clk)begin
        if(rst)begin index<=0;flushing<=0;flush_index<=0;flush_length<=0;total<=0;payload_length<=0;kind<=0;end
        else begin
            if(write_response)begin
                if(flush_index==flush_length-1)begin flushing<=0;flush_index<=0;end
                else flush_index<=flush_index+1'b1;
            end
            if(tx_valid&&tx_ready)begin
                if(index<512)memory[index[8:0]]<=tx_data;
                if(index==3)kind<=tx_data;
                if(index==4)payload_length[7:0]<=tx_data;
                if(index==5)begin payload_length[15:8]<=tx_data;total<={tx_data,payload_length[7:0]}+14;end
                if(index>=13 && index==total-1)begin
                    index<=0;
                    if(kind==17 && total<=512)begin flushing<=1;flush_length<=total;flush_index<=0;end
                end else index<=index+1'b1;
            end
        end
    end
endmodule
