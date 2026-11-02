`timescale 1ns/1ps
// Conditional FT-compatible frontend. Final parent must share control_reset with
// runtime_control. No hardware profile is enabled by default. Fault recovery
// here is common full-system reset; no independent reader/I2C reset or retry.
module demo_ft_frontend #(
    parameter bit PROFILE_CONFIGURED=0,
    parameter bit MAP_CONFIRMED=0,SWAP_XY=0,
    parameter integer RAW_WIDTH=4096,RAW_HEIGHT=4096,
    parameter [15:0] VERSION_BE_EXACT=16'h0001,
    parameter integer POLL_CYCLES=5000,
    parameter integer OFFER_CYCLES=50000000,RESULT_CYCLES=100000000
)(
    input wire clk_50,control_clk,rst_n,power_ready,
    output wire touch_reset_n,touch_scl,
    inout wire touch_int,touch_sda,
    input wire presets_ready,
    input wire [31:0] preset_phase_0,preset_phase_1,preset_phase_2,
    output wire local_valid,input wire local_ready,
    output wire [1:0] local_op,output wire [31:0] local_argument,
    output wire [63:0] local_id,
    input wire local_done,input wire [63:0] local_result_id,
    input wire [7:0] local_status,output wire local_take,
    output wire control_reset,touch_available,busy,armed,protocol_fault,id_exhausted,
    output wire [2:0] action_state,output wire [7:0] result_status,
    output wire [3:0] notice,output wire press_rejected
);
    (* ASYNC_REG="TRUE" *) reg [1:0] reset_50,reset_control,reset_dri;
    wire dri_clk;
    always @(posedge clk_50 or negedge rst_n)
        if(!rst_n)reset_50<=0;else reset_50<={reset_50[0],1'b1};
    always @(posedge control_clk or negedge rst_n)
        if(!rst_n)reset_control<=0;else reset_control<={reset_control[0],1'b1};
    always @(posedge dri_clk or negedge rst_n)
        if(!rst_n)reset_dri<=0;else reset_dri<={reset_dri[0],1'b1};
    assign control_reset=!reset_control[1];
    wire startup_ready,startup_fault;
    // FT startup never drives INT; mapping must be explicitly attested.
    assign touch_int=1'bz;
    touch_ft_startup startup(.clk(clk_50),.rst_n(reset_50[1]),.power_ready(power_ready),
        .touch_rst_n(touch_reset_n),.ready(startup_ready),.power_fault(startup_fault));
    (* ASYNC_REG="TRUE" *) reg [1:0] startup_sync;
    always @(posedge dri_clk or negedge rst_n)
        if(!rst_n)startup_sync<=0;else startup_sync<={startup_sync[0],startup_ready};
    wire [6:0] slave_addr;
    wire i2c_exec,i2c_rh_wl,bit_ctrl,once_byte_done,i2c_done,ack;
    wire [15:0] i2c_addr;
    wire [7:0] i2c_data_w,i2c_data_r,reg_num;
    demo_touch_i2c bus(.clk(clk_50),.rst_n(reset_50[1]),.slave_addr(slave_addr),
        .i2c_exec(i2c_exec),.bit_ctrl(bit_ctrl),.i2c_rh_wl(i2c_rh_wl),.i2c_addr(i2c_addr),
        .i2c_data_w(i2c_data_w),.reg_num(reg_num),.i2c_data_r(i2c_data_r),
        .i2c_done(i2c_done),.once_byte_done(once_byte_done),.ack(ack),
        .scl(touch_scl),.sda(touch_sda),.dri_clk(dri_clk));
    wire reader_available,reader_fault,reader_inflight,reader_valid,reader_ready;
    wire [3:0] reader_count,reader_fault_code;
    wire [15:0] reader_x,reader_y,reader_fw;
    wire [31:0] reader_id;
    wire [7:0] reader_mode,reader_status,reader_track;
    localparam bit MAP_SHAPE_OK=SWAP_XY ? (RAW_WIDTH==600 && RAW_HEIGHT==1024) :
                                                   (RAW_WIDTH==1024 && RAW_HEIGHT==600);
    wire [39:0] raw_report;
    demo_ft_initialized_reader #(.PROFILE_CONFIGURED(PROFILE_CONFIGURED && MAP_CONFIRMED && MAP_SHAPE_OK),
        .VERSION_BE_EXACT(VERSION_BE_EXACT),.RAW_WIDTH(RAW_WIDTH),.RAW_HEIGHT(RAW_HEIGHT),
        .SWAP_XY(SWAP_XY),.POLL_CYCLES(POLL_CYCLES)) reader(
        .clk(dri_clk),.rst_n(reset_dri[1]),.bringup_ready(startup_sync[1]),
        .slave_addr(slave_addr),.i2c_exec(i2c_exec),.i2c_rh_wl(i2c_rh_wl),
        .bit_ctrl(bit_ctrl),.i2c_addr(i2c_addr),.i2c_data_w(i2c_data_w),.reg_num(reg_num),
        .i2c_data_r(i2c_data_r),.once_byte_done(once_byte_done),.i2c_done(i2c_done),.ack(ack),
        .available(reader_available),.fault(reader_fault),.fault_code(reader_fault_code),
        .inflight(reader_inflight),.report_valid(reader_valid),.report_ready(reader_ready),
        .report_count(reader_count),.report_x(reader_x),.report_y(reader_y),
        .version_be(reader_fw),.raw_report(raw_report));
    wire bridge_busy,bridge_online,report_fault,report_valid;
    wire [3:0] report_count;wire [15:0] report_x,report_y;
    demo_touch_report_cdc bridge(.source_clk(dri_clk),.control_clk(control_clk),.rst_n(rst_n),
        .source_available(reader_available),.source_fault(reader_fault),.source_valid(reader_valid),
        .source_count(reader_count),.source_x(reader_x),.source_y(reader_y),
        .source_ready(reader_ready),.source_busy(bridge_busy),.source_online(bridge_online),
        .available(touch_available),.report_fault(report_fault),.report_valid(report_valid),
        .report_count(report_count),.report_x(report_x),.report_y(report_y));
    demo_touch_actions #(.OFFER_CYCLES(OFFER_CYCLES),.RESULT_CYCLES(RESULT_CYCLES)) actions(
        .clk(control_clk),.rst(control_reset),.available(touch_available),
        .report_fault(report_fault),.report_valid(report_valid),.report_count(report_count),
        .report_x(report_x),.report_y(report_y),.presets_ready(presets_ready),
        .preset_phase_0(preset_phase_0),.preset_phase_1(preset_phase_1),.preset_phase_2(preset_phase_2),
        .local_valid(local_valid),.local_ready(local_ready),.local_op(local_op),
        .local_argument(local_argument),.local_id(local_id),.local_done(local_done),
        .local_result_id(local_result_id),.local_status(local_status),.local_take(local_take),
        .busy(busy),.armed(armed),.protocol_fault(protocol_fault),.id_exhausted(id_exhausted),
        .action_state(action_state),.result_status(result_status),.notice(notice),.press_rejected(press_rejected));

    // Independent control-clock evidence; no cross-domain combinational taps.
    reg [31:0] diagnostic_reports;
    reg [127:0] diagnostic_control;
    reg diagnostic_frozen,diagnostic_seen_available;
    wire [127:0] diagnostic_control_live={16'hD147,
        control_reset,touch_available,report_fault,report_valid,busy,armed,protocol_fault,id_exhausted,
        action_state,notice,press_rejected,
        12'b0,report_count,report_x,report_y,8'b0,result_status,diagnostic_reports};
    always @(posedge control_clk)begin
        if(control_reset)begin diagnostic_reports<=0;diagnostic_control<=0;diagnostic_frozen<=0;diagnostic_seen_available<=0;end
        else begin
            if(touch_available)diagnostic_seen_available<=1;
            if(report_valid)diagnostic_reports<=diagnostic_reports+1'b1;
            if(!diagnostic_frozen)begin
                diagnostic_control<=diagnostic_control_live;
                if((report_fault && diagnostic_seen_available)||protocol_fault)diagnostic_frozen<=1;
            end
        end
    end
    touch_identity_vio control_evidence(.clk(control_clk),.probe_in0(diagnostic_control));
endmodule
