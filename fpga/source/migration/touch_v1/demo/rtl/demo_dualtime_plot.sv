// DRAFT_UNVERIFIED dual-TIME derivative of migration/touch_v1/rtl/snapshot_plot_display.sv.
`timescale 1ns/1ps
// Snapshot reader + supplied scan bundle -> RGB. No board clock/IP/pin assumptions.
module demo_dualtime_plot #(
    parameter integer N=512,MAX_RENDER_CYCLES=500000,
    parameter bit HS_IDLE=1'b1,VS_IDLE=1'b1
)(
    input wire pixel_clk,rst,vblank_start,freeze,
    input wire snapshot_valid,snapshot_swapped,
    input wire [31:0] snapshot_frame_id,
    input wire [15:0] snapshot_epoch,
    input wire [9:0] snapshot_time_count,
    input wire [511:0] snapshot_status,
    input wire [287:0] snapshot_config,
    output wire snapshot_vblank,snapshot_read_en,
    output wire [9:0] snapshot_read_index,
    input wire snapshot_read_valid,
    input wire [31:0] snapshot_read_data,
    input wire scan_de,scan_hsync,scan_vsync,
    input wire [10:0] scan_x,
    input wire [9:0] scan_y,
    output wire out_de,out_hsync,out_vsync,
    output wire [10:0] out_x,
    output wire [9:0] out_y,
    output wire [23:0] out_rgb,
    output wire front_valid,swapped,render_busy,
    output wire [31:0] front_frame_id,submitted_frames,failed_frames,dropped_frames,rejected_frames,
    output wire [15:0] front_epoch,
    output wire [511:0] front_status,
    output wire [287:0] front_config
);
    wire frame_ready,frame_begin,commit_frame,abort_frame,span_ready,span_valid,span_last;
    wire [1:0] span_layer;
    wire [9:0] span_index;
    wire [7:0] span_min,span_max;
    wire [31:0] frame_id,read_frame_id;
    wire [15:0] frame_epoch;
    wire [511:0] frame_status;
    wire [287:0] frame_config;
    wire column_read_en,column_valid;
    wire [9:0] column_read_index;
    wire [7:0] time_min,time_max,filtered_min,filtered_max,spec_min,spec_max;
    demo_dualtime_renderer #(.N(N),.MAX_RENDER_CYCLES(MAX_RENDER_CYCLES)) renderer(.busy(render_busy),.*);
    demo_dualtime_columns buffer(
        .in_frame_id(frame_id),.in_epoch(frame_epoch),.in_status(frame_status),.in_config(frame_config),
        .read_en(column_read_en),.read_index(column_read_index),.read_valid(column_valid),.*);
    demo_dualtime_pixels #(.HS_IDLE(HS_IDLE),.VS_IDLE(VS_IDLE)) compositor(.*);
endmodule
