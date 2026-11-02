`timescale 1ns/1ps
// Clause 22 MDIO, 100 kHz at 100 MHz. Drive on MDC falling, sample on rising.
module eth_mdio(input wire clk,rst,start,read_op,input wire [4:0] address,
    input wire [15:0] write_data,output reg busy=0,done=0,ack=0,
    output reg [15:0] read_data=0,output reg mdc=0,inout wire mdio);
    reg [63:0] bits;reg [5:0] index=0;reg [8:0] divider=0;reg reading=0;
    wire enable=busy && (!reading || index>=18);
    (* ASYNC_REG="TRUE",SHREG_EXTRACT="NO" *) reg mdio_meta=1,mdio_sync=1;
    always @(posedge clk)begin mdio_meta<=mdio;mdio_sync<=mdio_meta;end
    assign mdio=enable ? bits[index] : 1'bz;
    always @(posedge clk)begin
        done<=0;
        if(rst)begin busy<=0;mdc<=0;divider<=0;index<=0;ack<=0;read_data<=0;end
        else if(!busy)begin
            mdc<=0;divider<=0;
            if(start)begin
                bits<={32'hffffffff,2'b01,(read_op ? 2'b10:2'b01),5'd4,address,2'b10,write_data};
                reading<=read_op;index<=63;busy<=1;read_data<=0;ack<=!read_op;
            end
        end else if(divider==499)begin
            divider<=0;mdc<=!mdc;
            if(!mdc)begin
                if(reading && index==16)ack<=!mdio_sync;
                if(reading && index<16)read_data<={read_data[14:0],mdio_sync};
            end else if(index==0)begin busy<=0;done<=1;end
            else index<=index-1'b1;
        end else divider<=divider+1'b1;
    end
endmodule

module eth_phy #(parameter integer RESET_CYCLES=2000000,POST_RESET_CYCLES=100000000,POLL_CYCLES=10000000)(
    input wire clk,rst,output reg eth_rst_n=0,output wire eth_mdc,inout wire eth_mdio,
    output reg gigabit=0,output reg fault=0,output reg [15:0] status=0);
    reg [26:0] timer=0;reg [3:0] step=0;reg waiting=0,started=0;
    reg start=0,read_op=0;reg [4:0] address=0;reg [15:0] write_data=0,saved=0;
    wire busy,done,ack;wire [15:0] read_data;
    eth_mdio mdio(.clk(clk),.rst(rst),.start(start),.read_op(read_op),.address(address),
        .write_data(write_data),.busy(busy),.done(done),.ack(ack),.read_data(read_data),.mdc(eth_mdc),.mdio(eth_mdio));
    always @(posedge clk)begin
        start<=0;
        if(rst)begin timer<=0;eth_rst_n<=0;step<=0;waiting<=0;started<=0;gigabit<=0;fault<=0;status<=0;end
        else if(!eth_rst_n)begin
            if(timer==RESET_CYCLES-1)begin eth_rst_n<=1;timer<=0;end else timer<=timer+1'b1;
        end else if(!started)begin
            if(timer==POST_RESET_CYCLES-1)begin started<=1;timer<=0;end else timer<=timer+1'b1;
        end else if(!fault)begin
            if(done)begin
                waiting<=0;
                if(!ack)begin fault<=1;gigabit<=0;end
                else case(step)
                    0:if(read_data!=16'h4f51)fault<=1;else step<=1;
                    1:if((read_data&16'hfff0)!=16'he910)fault<=1;else step<=2;
                    3:begin saved<=(read_data & 16'hfcff)|16'h0100;step<=4;end
                    5:if(read_data!=saved)fault<=1;else step<=6;
                    7:begin saved<=(read_data & 16'h83f0)|16'h000d;step<=8;end
                    9:if(read_data!=saved)fault<=1;else begin step<=10;timer<=0;end
                    10:begin status<=read_data;gigabit<=((read_data&16'hec00)==16'hac00);timer<=POLL_CYCLES;end
                    default:step<=step+1'b1;
                endcase
            end else if(!waiting&&!busy)begin
                if(step==10 && timer!=0)timer<=timer-1'b1;
                else begin
                    start<=1;waiting<=1;write_data<=0;read_op<=1;
                    case(step)
                        0:address<=2;
                        1:address<=3;
                        2:begin address<=30;write_data<=16'ha001;read_op<=0;end
                        3,5,7,9:address<=31;
                        4,8:begin address<=31;write_data<=saved;read_op<=0;end
                        6:begin address<=30;write_data<=16'ha003;read_op<=0;end
                        10:address<=17;
                        default:begin fault<=1;start<=0;end
                    endcase
                end
            end
        end
    end

    reg [127:0] phy_observation=0;
    always @(posedge clk) phy_observation <= {16'hD144,
      rst,eth_rst_n,started,waiting,busy,done,ack,fault,
      step,3'd0,gigabit,status,read_data,saved,address,read_op,2'd0,
      timer,5'd0,8'd0};
    touch_identity_vio phy_evidence(.clk(clk),.probe_in0(phy_observation));
endmodule
