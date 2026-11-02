`timescale 1ns/1ps
// Conditional GT14 reset/address selection. power_ready is synchronous to clk
// and attests externally stable AVDD/VDDIO; this module does not sequence rails.
// No retry or independent reset after startup failure. Common full reset only.
module demo_gt9147_startup #(
    parameter integer CLK_HZ=50000000
)(
    input wire clk,rst_n,power_ready,
    output reg touch_reset_n,int_drive,int_value,
    output reg ready,fault
);
    // ceil(clock * interval) + 1 ensures strictly greater, not merely equal.
    localparam integer LOW_TICKS=(CLK_HZ+99)/100+1;
    localparam integer SELECT_TICKS=(CLK_HZ+9999)/10000+1;
    localparam integer HIGH_TICKS=(CLK_HZ+199)/200+1;
    localparam integer SETTLE_TICKS=(CLK_HZ+19)/20+1;
    localparam [2:0] WAIT_POWER=0,RESET_LOW=1,SELECT=2,HIGH=3,SETTLE=4,RUN=5;
    reg [2:0] state;
    reg [31:0] count;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            state<=WAIT_POWER;count<=0;touch_reset_n<=0;
            int_drive<=1;int_value<=0;ready<=0;fault<=0;
        end else if(!fault)begin
            if(state!=WAIT_POWER && !power_ready)begin
                // Freeze physical outputs, invalidate reader, preserve I2C ownership.
                fault<=1;ready<=0;
            end else case(state)
                WAIT_POWER:if(power_ready)begin state<=RESET_LOW;count<=0;end
                RESET_LOW:if(count==LOW_TICKS-1)begin
                    int_value<=1;count<=0;state<=SELECT;
                end else count<=count+1;
                SELECT:if(count==SELECT_TICKS-1)begin
                    touch_reset_n<=1;count<=0;state<=HIGH;
                end else count<=count+1;
                HIGH:if(count==HIGH_TICKS-1)begin
                    int_drive<=0;count<=0;state<=SETTLE;
                end else count<=count+1;
                SETTLE:if(count==SETTLE_TICKS-1)begin ready<=1;state<=RUN;end
                    else count<=count+1;
                RUN:begin end
                default:begin fault<=1;ready<=0;end
            endcase
        end
    end
    initial if(CLK_HZ<10000 || CLK_HZ>200000000)$fatal(1,"STARTUP_CLOCK_RANGE");
endmodule
