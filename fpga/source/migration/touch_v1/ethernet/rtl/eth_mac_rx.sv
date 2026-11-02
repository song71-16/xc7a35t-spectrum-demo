`timescale 1ns/1ps
// Store and verify a whole Ethernet frame before exposing it to the endpoint.
module eth_mac_rx(input wire rst,rx_clk,rx_rst,net_clk,net_rst,
    input wire [7:0] rx_data,input wire rx_dv,rx_error,
    input wire release_packet,input wire [10:0] read_addr,output wire [7:0] read_data,
    output reg valid=0,output reg [10:0] length=0,output reg [31:0] drops=0);
    import ethernet_pkg::*;
    reg active=0,bad=0;reg [3:0] preamble=0;
    wire [9:0] fifo_out;wire full,empty,wb,rb;
    reg [9:0] fifo_in;reg write_en;
    always @* begin
        write_en=0;fifo_in=0;
        if(active && rx_dv)begin write_en=1;fifo_in={2'b00,rx_data};end
        if(active && !rx_dv)begin write_en=1;fifo_in={2'b10,7'b0,bad};end
        if(!active && rx_dv && rx_data==8'hd5 && preamble>=7)begin write_en=1;fifo_in={2'b01,8'b0};end
    end
    always @(posedge rx_clk)begin
        if(rx_rst)begin active<=0;bad<=0;preamble<=0;end
        else if(!rx_dv)begin active<=0;preamble<=0;end
        else if(active)begin if(rx_error||full||wb)bad<=1;end
        else if(rx_data==8'h55)begin if(preamble<8)preamble<=preamble+1'b1;end
        else if(rx_data==8'hd5 && preamble>=7)begin active<=1;bad<=rx_error||full||wb;end
        else preamble<=0;
    end
    eth_async_fifo #(.WIDTH(10),.DEPTH(4096)) crossing(.rst(rx_rst),.wr_clk(rx_clk),.rd_clk(net_clk),
        .din(fifo_in),.wr_en(write_en),.rd_en(!empty&&!rb),.dout(fifo_out),.full(full),.empty(empty),.wr_busy(wb),.rd_busy(rb));
    (* ram_style="distributed" *) reg [7:0] memory[0:2047];
    assign read_data=memory[read_addr];
    reg taking=0,overflowed=0;reg [11:0] count=0;reg [31:0] crc=32'hffffffff;
    always @(posedge net_clk)begin
        if(net_rst)begin valid<=0;taking<=0;count<=0;crc<=32'hffffffff;drops<=0;overflowed<=0;length<=0;end
        else begin
            if(release_packet)valid<=0;
            if(!empty&&!rb)case(fifo_out[9:8])
                1:begin taking<=!valid;count<=0;crc<=32'hffffffff;overflowed<=0;if(valid)drops<=drops+1'b1;end
                0:if(taking)begin
                    if(count<2048)memory[count[10:0]]<=fifo_out[7:0];else overflowed<=1;
                    if(count<4095)count<=count+1'b1;
                    crc<=crc32_byte(crc,fifo_out[7:0]);
                end
                2:begin
                    taking<=0;
                    if(taking)begin
                        if(!fifo_out[0]&&!overflowed&&count>=64&&count<=1518&&crc==32'hdebb20e3)begin
                            valid<=1;length<=count-4;
                        end else drops<=drops+1'b1;
                    end
                end
                default:taking<=0;
            endcase
        end
    end
endmodule
