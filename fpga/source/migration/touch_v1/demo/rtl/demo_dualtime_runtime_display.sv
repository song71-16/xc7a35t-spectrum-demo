// DRAFT_UNVERIFIED dual-TIME derivative of migration/touch_v1/demo/rtl/demo_runtime_display.sv.
`timescale 1ns/1ps
// Board-independent real frontend/runtime/DSP/snapshot/render integration.
// No controller profile or frequency preset is enabled by default.
// N/TAPS/DW/Fs fixed to the validated ingress contract; board top supplies clocks.
module demo_dualtime_runtime_display #(
    parameter integer SIM_TRIGGER_CYCLES=0,
    parameter bit PROFILE_CONFIGURED=0,
    parameter bit PROFILE_GT911=0,PROFILE_FT=0,FT_MAP_CONFIRMED=0,FT_SWAP_XY=0,
    parameter integer FT_RAW_WIDTH=4096,FT_RAW_HEIGHT=4096,
    parameter [15:0] FT_VERSION_BE_EXACT=16'h0001,
    parameter [15:0] FW_EXACT=16'h0000,
    parameter integer POLL_CYCLES=500,
    parameter integer OFFER_CYCLES=50000000,RESULT_CYCLES=100000000
)(
    input wire clk,clk_50,pixel_clk,rst_n,power_ready,
    output wire touch_reset_n,touch_scl,inout wire touch_int,touch_sda,
    input wire presets_ready,input wire [31:0] preset_phase_0,preset_phase_1,preset_phase_2,
    input wire [7:0] rx_data,input wire rx_valid,output wire rx_ready,
    output wire [7:0] tx_data,output wire tx_valid,input wire tx_ready,
    output wire storage_reset,rx_ready_storage,tx_valid_storage,
    input wire frame_start,vblank_start,scan_de,scan_hsync,scan_vsync,
    input wire [10:0] scan_x,input wire [9:0] scan_y,
    output wire out_de,out_hsync,out_vsync,
    output wire [10:0] out_x,output wire [9:0] out_y,output wire [23:0] out_rgb,
    output wire front_valid,swapped,render_busy,
    output wire [31:0] front_frame_id,display_drops,invalid_descriptors,
    output wire [31:0] submitted_frames,failed_frames,dropped_frames,rejected_frames,
    output wire [15:0] front_epoch,
    output wire [511:0] front_status,output wire [287:0] front_config,
    output wire [31:0] actual_phase,output wire [15:0] actual_amplitude,actual_epoch,
    output wire [84:0] display_feedback,output wire feedback_valid,feedback_updated,
    output wire control_reset,pixel_reset,touch_available,
    output wire group_enqueued,output wire [31:0] processing_cycles,debug_accepted,
    output wire [15:0] debug_epoch,
    output wire [31:0] uart_groups_queued,uart_groups_dropped,uart_groups_sent,
    output wire [31:0] uart_responses_queued,uart_queue_errors,output wire [7:0] uart_queued_items
);
    (* ASYNC_REG="TRUE" *) reg [1:0] pixel_reset_pipe;
    always @(posedge pixel_clk or negedge rst_n)
        if(!rst_n)pixel_reset_pipe<=0;else pixel_reset_pipe<={pixel_reset_pipe[0],1'b1};
    // Keep RAM CE/address/reset changes clocked; the pipe latches short pulses.
    reg pixel_reset_q=1'b1;
    always @(posedge pixel_clk)pixel_reset_q<=!pixel_reset_pipe[1];
    assign pixel_reset=pixel_reset_q;
    wire local_valid,local_ready,local_done,local_take;
    wire [1:0] local_op;wire [31:0] local_argument,local_result_step;
    wire [63:0] local_id,local_result_id;wire [7:0] local_status;
    wire [15:0] local_result_amplitude,local_result_epoch;
    wire busy,armed,protocol_fault,id_exhausted,press_rejected;
    wire [2:0] action_state;wire [7:0] result_status;wire [3:0] notice;
    generate if(PROFILE_FT)begin:gen_ft
    demo_ft_frontend #(.PROFILE_CONFIGURED(PROFILE_CONFIGURED && !PROFILE_GT911),
        .MAP_CONFIRMED(FT_MAP_CONFIRMED),.SWAP_XY(FT_SWAP_XY),
        .RAW_WIDTH(FT_RAW_WIDTH),.RAW_HEIGHT(FT_RAW_HEIGHT),.VERSION_BE_EXACT(FT_VERSION_BE_EXACT),
        .POLL_CYCLES(5000),.OFFER_CYCLES(OFFER_CYCLES),.RESULT_CYCLES(RESULT_CYCLES)) touch(
        .clk_50(clk_50),.control_clk(clk),.rst_n(rst_n),.power_ready(power_ready),
        .touch_reset_n(touch_reset_n),.touch_scl(touch_scl),.touch_int(touch_int),.touch_sda(touch_sda),
        .presets_ready(presets_ready),.preset_phase_0(preset_phase_0),.preset_phase_1(preset_phase_1),.preset_phase_2(preset_phase_2),
        .local_valid(local_valid),.local_ready(local_ready),.local_op(local_op),.local_argument(local_argument),.local_id(local_id),
        .local_done(local_done),.local_result_id(local_result_id),.local_status(local_status),.local_take(local_take),
        .control_reset(control_reset),.touch_available(touch_available),.busy(busy),.armed(armed),
        .protocol_fault(protocol_fault),.id_exhausted(id_exhausted),.action_state(action_state),
        .result_status(result_status),.notice(notice),.press_rejected(press_rejected));
    end else begin:gen_gt
    demo_touch_frontend #(.PROFILE_CONFIGURED(PROFILE_CONFIGURED),.PROFILE_GT911(PROFILE_GT911),.FW_EXACT(FW_EXACT),
        .POLL_CYCLES(POLL_CYCLES),.OFFER_CYCLES(OFFER_CYCLES),.RESULT_CYCLES(RESULT_CYCLES)) touch(
        .clk_50(clk_50),.control_clk(clk),.rst_n(rst_n),.power_ready(power_ready),
        .touch_reset_n(touch_reset_n),.touch_scl(touch_scl),.touch_int(touch_int),.touch_sda(touch_sda),
        .presets_ready(presets_ready),.preset_phase_0(preset_phase_0),.preset_phase_1(preset_phase_1),.preset_phase_2(preset_phase_2),
        .local_valid(local_valid),.local_ready(local_ready),.local_op(local_op),.local_argument(local_argument),.local_id(local_id),
        .local_done(local_done),.local_result_id(local_result_id),.local_status(local_status),.local_take(local_take),
        .control_reset(control_reset),.touch_available(touch_available),.busy(busy),.armed(armed),
        .protocol_fault(protocol_fault),.id_exhausted(id_exhausted),.action_state(action_state),
        .result_status(result_status),.notice(notice),.press_rejected(press_rejected));
    end endgenerate
    wire display_offer,display_word_valid,display_commit,offer_ready;
    wire display_offer_storage,display_word_valid_storage,display_commit_storage;
    wire [31:0] display_frame_id;wire [15:0] display_epoch,display_config_epoch;wire [31:0] display_word_data;
    wire [9:0] display_time_count,display_word_index;
    wire [511:0] display_status;wire [287:0] display_config;
    demo_dualtime_core #(.SIM_TRIGGER_CYCLES(SIM_TRIGGER_CYCLES)) core(
        .rst(control_reset),.*);
    wire buffer_offer,buffer_word_valid,buffer_commit;
    snapshot_ingress #(.N(512),.TAPS(31),.DW(16)) ingress(
        .clk(clk),.rst(storage_reset),.offer(display_offer_storage),.buffer_ready(offer_ready),
        .epoch(display_epoch),.config_epoch(display_config_epoch),.time_count(display_time_count),
        .status_data(display_status),.config_data(display_config),.word_valid(display_word_valid_storage),.commit(display_commit_storage),
        .buffer_offer(buffer_offer),.buffer_word_valid(buffer_word_valid),.buffer_commit(buffer_commit),.invalid_descriptors(invalid_descriptors));
    wire snapshot_vblank,snapshot_read_en,snapshot_read_valid,snapshot_valid,snapshot_swapped;
    wire [9:0] snapshot_read_index,snapshot_time_count;
    wire [31:0] snapshot_read_data;wire [15:0] snapshot_epoch;
    wire [31:0] snapshot_frame_id;wire [511:0] snapshot_status;wire [287:0] snapshot_config;
    wire [31:0] snapshot_rejected,snapshot_published;
    demo_dualtime_snapshot #(.N(512)) snapshots(
        .wr_clk(clk),.pixel_clk(pixel_clk),.arst(!rst_n),.offer(buffer_offer),.offer_ready(offer_ready),
        .in_frame_id(display_frame_id),.in_epoch(display_epoch),.in_time_count(display_time_count),
        .in_status(display_status),.in_config(display_config),.word_valid(buffer_word_valid),
        .word_index(display_word_index),.word_data(display_word_data),.commit(buffer_commit),.abort_fill(1'b0),
        .dropped_offers(display_drops),.rejected_frames(snapshot_rejected),.published_frames(snapshot_published),
        .vblank_start(snapshot_vblank),.freeze(1'b0),.front_valid(snapshot_valid),.swapped(snapshot_swapped),
        .front_frame_id(snapshot_frame_id),.front_epoch(snapshot_epoch),.front_time_count(snapshot_time_count),
        .front_status(snapshot_status),.front_config(snapshot_config),.read_en(snapshot_read_en),
        .read_index(snapshot_read_index),.read_valid(snapshot_read_valid),.read_data(snapshot_read_data));
    wire [23:0] plot_rgb,status_rgb;
    demo_dualtime_plot #(.N(512)) display(.rst(pixel_reset),.freeze(1'b0),.out_rgb(plot_rgb),.*);
    demo_dualtime_status status_overlay(.pixel_clk(pixel_clk),.rst(pixel_reset),.frame_start(frame_start),
        .front_valid(front_valid),.front_frame_id(front_frame_id),.front_epoch(front_epoch),.front_status(front_status),
        .in_de(out_de),.x(out_x),.y(out_y),.in_rgb(plot_rgb),.out_rgb(status_rgb));
    // [84:53] phase [52:37] Q15 [36:21] current epoch [20:18] last local action
    // [17:10] result [9:6] notice [5:0] available/busy/armed/fault/exhausted/presets.
    wire [84:0] current_feedback={actual_phase,actual_amplitude,actual_epoch,action_state,result_status,
        notice,touch_available,busy,armed,protocol_fault,id_exhausted,presets_ready};
    wire feedback_busy;
    demo_control_display_cdc #(.WIDTH(85)) feedback(.control_clk(clk),.pixel_clk(pixel_clk),.rst_n(rst_n),
        .source_data(current_feedback),.frame_start(frame_start),.display_data(display_feedback),
        .display_valid(feedback_valid),.updated(feedback_updated),.busy(feedback_busy));
    demo_touch_overlay touch_overlay(.pixel_clk(pixel_clk),.rst(pixel_reset),.frame_start(frame_start),
        .feedback_valid(feedback_valid),.feedback(display_feedback),.in_de(out_de),.x(out_x),.y(out_y),.in_rgb(status_rgb),.out_rgb(out_rgb));
endmodule
