`timescale 1ns/1ps
// Same fixed 13-transaction initialization used by D13D hardware capture.
// Only the observed version0001 profile is supported. Defaults remain disabled.
// Startup-only FF wait; no fault retry, address scan or scaling.
module demo_ft_initialized_reader #(
    parameter bit PROFILE_CONFIGURED=0,
    parameter [15:0] VERSION_BE_EXACT=16'h0001,
    parameter integer RAW_WIDTH=4096,RAW_HEIGHT=4096,
    parameter bit SWAP_XY=0,
    parameter integer POLL_CYCLES=5000,TIMEOUT_CYCLES=10000
)(
    input wire clk,rst_n,bringup_ready,
    output wire [6:0] slave_addr,
    output wire i2c_exec,
    output wire i2c_rh_wl,bit_ctrl,
    output wire [15:0] i2c_addr,
    output wire [7:0] i2c_data_w,
    output wire [7:0] reg_num,
    input wire [7:0] i2c_data_r,
    input wire once_byte_done,i2c_done,ack,
    output wire available,
    output wire fault,output wire [3:0] fault_code,
    output wire inflight,report_valid,input wire report_ready,
    output wire [3:0] report_count,
    output wire [15:0] report_x,report_y,version_be,
    output wire [39:0] raw_report
);

 wire [79:0] diagnostic_run;
 wire init_complete,init_fault,init_exec,init_rh;
 wire[2:0]init_code;wire[3:0]init_stage;wire[103:0]init_payload;
 wire[7:0]init_data,init_len;wire[15:0]init_addr;
 wire run_exec,run_rh,run_bit,run_available,run_fault,run_inflight;
 wire[6:0]run_slave;wire[7:0]run_data,run_len;wire[15:0]run_addr,run_version;
 wire[3:0]run_code;reg init_inflight;
 always @(posedge clk or negedge rst_n)
  if(!rst_n)init_inflight<=0;
  else if(init_exec)init_inflight<=1;
  else if(i2c_done)init_inflight<=0;
 demo_ft_init_compare #(.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) initialization(
  .clk(clk),.rst_n(rst_n),.ready(PROFILE_CONFIGURED && bringup_ready),
  .data(i2c_data_r),.byte_done(once_byte_done && !init_complete),
  .done(i2c_done && !init_complete),.nack(ack),
  .exec(init_exec),.rh(init_rh),.write_data(init_data),.addr(init_addr),.length(init_len),
  .complete(init_complete),.fault(init_fault),.code(init_code),.stage(init_stage),.payload(init_payload));
 demo_ft_reader #(.PROFILE_CONFIGURED(PROFILE_CONFIGURED),.VERSION_BE_EXACT(VERSION_BE_EXACT),
  .RAW_WIDTH(RAW_WIDTH),.RAW_HEIGHT(RAW_HEIGHT),.SWAP_XY(SWAP_XY),
  .POLL_CYCLES(POLL_CYCLES),.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) reader(
  .clk(clk),.rst_n(rst_n),.bringup_ready(bringup_ready && init_complete && !init_fault),
  .slave_addr(run_slave),.i2c_exec(run_exec),.i2c_rh_wl(run_rh),.bit_ctrl(run_bit),
  .i2c_addr(run_addr),.i2c_data_w(run_data),.reg_num(run_len),
  .i2c_data_r(i2c_data_r),.once_byte_done(once_byte_done && init_complete),
  .i2c_done(i2c_done && init_complete),.ack(ack),
  .available(run_available),.fault(run_fault),.fault_code(run_code),.inflight(run_inflight),
  .report_valid(report_valid),.report_ready(report_ready),.report_count(report_count),
  .report_x(report_x),.report_y(report_y),.version_be(run_version),.raw_report(raw_report),.diagnostic_state(diagnostic_run));
 assign slave_addr=init_complete?run_slave:7'h38;
 assign bit_ctrl=init_complete?run_bit:1'b0;
 assign i2c_exec=init_complete?run_exec:init_exec;
 assign i2c_rh_wl=init_complete?run_rh:init_rh;
 assign i2c_addr=init_complete?run_addr:init_addr;
 assign i2c_data_w=init_complete?run_data:init_data;
 assign reg_num=init_complete?run_len:init_len;
 assign available=init_complete && !init_fault && run_available;
 assign fault=init_fault||run_fault;
 assign fault_code=init_fault?{1'b0,init_code}:run_code;
 assign inflight=init_complete?run_inflight:init_inflight;
 assign version_be=init_complete?run_version:init_payload[103:88];

 // Read-only diagnostic snapshot. Both payloads belong to this dri_clk domain.
 // Freeze after the first registered init/run fault, preserving its code and rx.
 wire [127:0] init_live={16'hD13E,init_complete,init_fault,init_code,3'b000,init_payload};
 wire [127:0] run_live={16'hD146,init_stage,run_code,
   PROFILE_CONFIGURED,bringup_ready,init_complete,init_fault,run_available,run_fault,run_inflight,report_valid,
   run_version,diagnostic_run};
 reg frozen; reg[127:0] init_saved,run_saved;
 always @(posedge clk or negedge rst_n) begin
   if(!rst_n)begin frozen<=0;init_saved<=0;run_saved<=0;end
   else if(!frozen)begin
     init_saved<=init_live;run_saved<=run_live;
     if(init_fault||run_fault)frozen<=1;
   end
 end
 touch_identity_vio init_evidence(.clk(clk),.probe_in0(init_saved));
 touch_identity_vio run_evidence(.clk(clk),.probe_in0(run_saved));
 initial if(PROFILE_CONFIGURED && VERSION_BE_EXACT!=16'h0001)$fatal(1,"FT_INIT_UNSUPPORTED_VERSION");
endmodule
