`timescale 1ns/1ps
// Fixed vendor-reference initialization comparison. Four volatile config writes, once each.
// Semantic FF is retained as evidence; transport errors lock without retry.
module demo_ft_init_compare #(parameter integer TIMEOUT_CYCLES=10000,GAP_CYCLES=5000,SETTLE_CYCLES=20000)(
 input wire clk,rst_n,ready,input wire[7:0]data,input wire byte_done,done,nack,
 output reg exec,rh,output reg[7:0]write_data,output reg[15:0]addr,output reg[7:0]length,
 output reg complete,fault,output reg[2:0]code,output reg[3:0]stage,output reg[103:0]payload);
 localparam WAIT_READY=0,ISSUE=1,WAIT_TX=2,SETTLE=3,COMMIT=4,GAP=5,LOCK=6;
 reg[2:0]state,bytes;reg[39:0]rx;reg[31:0]age;reg[1:0]quiet;reg inflight;
 wire[3:0]final_bytes={1'b0,bytes}+(byte_done?4'd1:4'd0);
 reg[3:0]err;
 always @*begin
  err=0;
  if(!inflight && (byte_done||done))err=4;
  else if(inflight && byte_done && bytes>=length)err=2;
  else if(inflight && done && nack)err=1;
  else if(inflight && done && final_bytes!=length)err=2;
  else if(inflight && !done && age>=TIMEOUT_CYCLES-1)err=3;
  else if(state!=WAIT_READY && state!=LOCK && !ready)err=5;
  else if(state==COMMIT && stage==0 && {rx[7:0],rx[15:8]}!=16'h0001)err=6;
  else if(state==COMMIT && ((stage==7||stage==8) && rx[7:0]!=0 || stage==9 && rx[7:0]!=22 || stage==10 && rx[7:0]!=12))err=7;
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin state<=WAIT_READY;bytes<=0;rx<=0;age<=0;quiet<=0;inflight<=0;exec<=0;rh<=1;write_data<=0;addr<=0;length<=0;complete<=0;fault<=0;code<=0;stage<=0;payload<=0;end
  else begin
   exec<=0;
   if(fault || err!=0)begin state<=LOCK;fault<=1;if(!fault)code<=err[2:0];if(inflight&&done)inflight<=0;end
   else case(state)
    WAIT_READY:if(ready)begin if(quiet==1)begin state<=ISSUE;quiet<=0;end else quiet<=quiet+1'b1;end else quiet<=0;
    ISSUE:begin
     rh<=1;write_data<=0;
     case(stage)
      0:begin addr<=16'ha1;length<=2;end
      1:begin addr<=2;length<=1;end
      2:begin addr<=16'ha4;length<=1;end
      3:begin addr<=0;length<=1;rh<=0;write_data<=0;end
      4:begin addr<=16'ha4;length<=1;rh<=0;write_data<=0;end
      5:begin addr<=16'h80;length<=1;rh<=0;write_data<=22;end
      6:begin addr<=16'h88;length<=1;rh<=0;write_data<=12;end
      7:begin addr<=0;length<=1;end
      8:begin addr<=16'ha4;length<=1;end
      9:begin addr<=16'h80;length<=1;end
      10:begin addr<=16'h88;length<=1;end
      11:begin addr<=2;length<=1;end
      12:begin addr<=3;length<=4;end
     endcase
     exec<=1;inflight<=1;rx<=0;bytes<=0;age<=0;state<=WAIT_TX;
    end
    WAIT_TX:begin
     if(byte_done)begin rx[8*bytes +: 8]<=data;bytes<=bytes+1'b1;end
     if(done)begin inflight<=0;quiet<=0;state<=SETTLE;end else age<=age+1'b1;
    end
    SETTLE:if(quiet==1)begin state<=COMMIT;quiet<=0;end else quiet<=quiet+1'b1;
    COMMIT:begin
     case(stage)
      0:payload[103:88]<={rx[7:0],rx[15:8]};
      1:payload[87:80]<=rx[7:0];
      2:payload[79:72]<=rx[7:0];
      7:payload[47:40]<=rx[7:0];
      8:payload[55:48]<=rx[7:0];
      9:payload[63:56]<=rx[7:0];
      10:payload[71:64]<=rx[7:0];
      11:payload[39:32]<=rx[7:0];
      12:payload[31:0]<=rx[31:0];
     endcase
     if(stage==12)begin complete<=1;state<=LOCK;end
     else begin stage<=stage+1'b1;age<=0;state<=GAP;end
    end
    GAP:if(age==((stage==7)?SETTLE_CYCLES:GAP_CYCLES)-1)begin state<=ISSUE;age<=0;end else age<=age+1'b1;
    LOCK:state<=LOCK;
   endcase
   // Preserve identity bytes even on identity semantic mismatch.
   if(state==COMMIT && stage==0)payload[103:88]<={rx[7:0],rx[15:8]};
   if(state==COMMIT && stage>=7 && stage<=10)payload[40+8*(stage-7) +:8]<=rx[7:0];
  end
 end
 initial if(TIMEOUT_CYCLES<8 || GAP_CYCLES<1 || SETTLE_CYCLES<1)$fatal(1,"READ_SHAPE_PARAMETERS");
endmodule
