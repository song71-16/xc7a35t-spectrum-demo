`timescale 1ns/1ps
// FT-only diagnostic policy, not a claimed controller-specific power specification.
module touch_ft_startup #(parameter integer CLK_HZ=50000000)(
 input wire clk,rst_n,power_ready,output reg touch_rst_n,ready,power_fault);
 localparam integer LOW_TICKS=(CLK_HZ+49)/50+1; // strictly >20ms
 localparam integer SETTLE_TICKS=(CLK_HZ+9)/10+1; // strictly >100ms
 localparam [1:0]WAIT_POWER=0,LOW=1,SETTLE=2,RUN=3;
 reg [1:0]state;reg [31:0]age;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin touch_rst_n<=0;ready<=0;power_fault<=0;state<=WAIT_POWER;age<=0;end
  else if(!power_fault)begin
   if(state!=WAIT_POWER && !power_ready)begin power_fault<=1;ready<=0;end
   else case(state)
    WAIT_POWER:if(power_ready)begin state<=LOW;age<=0;end
    LOW:if(age==LOW_TICKS-1)begin touch_rst_n<=1;state<=SETTLE;age<=0;end else age<=age+1'b1;
    SETTLE:if(age==SETTLE_TICKS-1)begin ready<=1;state<=RUN;end else age<=age+1'b1;
    RUN:;
   endcase
  end
 end
 initial if(CLK_HZ<10000 || CLK_HZ>200000000)$fatal(1,"STARTUP_CLOCK_RANGE");
endmodule
