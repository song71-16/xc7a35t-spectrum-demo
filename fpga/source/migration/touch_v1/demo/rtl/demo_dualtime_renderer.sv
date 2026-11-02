// DRAFT_UNVERIFIED dual-TIME derivative of migration/touch_v1/rtl/snapshot_render_controller.sv.
`timescale 1ns/1ps
// One snapshot -> TIME/SPEC spans. All logic here is in pixel_clk domain.
// snapshot_vblank is the ONLY blank pulse allowed to reach the snapshot reader.
module demo_dualtime_renderer #(
    parameter integer N=512, MAX_RENDER_CYCLES=500000
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
    input wire frame_ready,span_ready,
    output wire frame_begin,commit_frame,abort_frame,
    output reg [31:0] frame_id,submitted_frames,failed_frames,
    output reg [15:0] frame_epoch,
    output reg [511:0] frame_status,
    output reg [287:0] frame_config,
    output wire span_valid,span_last,
    output wire [1:0] span_layer,
    output wire [9:0] span_index,
    output wire [7:0] span_min,span_max,
    output wire busy
);
    localparam [3:0] IDLE=0,BEGIN_FRAME=1,READ_REQUEST=2,READ_WAIT=3,
        MAP_SEND=4,MAP_WAIT=5,POINT_SEND=6,LAYER_DRAIN=7,COMMIT=8,ABORT=9;
    reg [3:0] state;
    reg [1:0] layer;
    reg [9:0] time_count,sample_index;
    reg [15:0] sample_value;
    reg [9:0] point_x,point_y;
    reg [31:0] elapsed;
    wire pipeline_reset=rst || state==ABORT;
    wire [9:0] sample_count=layer==2 ? N/2+1 : time_count;
    wire mapped_valid;
    wire [9:0] mapped_x,mapped_y;
    wire point_ready,line_error,pixel_valid,pixel_ready,pixel_last;
    wire [9:0] pixel_x,pixel_y;
    wire raw_valid,raw_ready,raw_last;
    wire [9:0] raw_x,raw_min,raw_max;
    wire [9:0] y_base=layer==2 ? 10'd336 : 10'd80;
    wire raw_legal=raw_x>=64 && raw_x<=831 && raw_min>=y_base &&
        raw_max<=y_base+10'd191 && raw_min<=raw_max;
    wire count_legal=snapshot_time_count==N || snapshot_time_count==N/2 || snapshot_time_count==N/4;
    wire snapshot_changed=!snapshot_valid || snapshot_swapped || snapshot_frame_id!=frame_id ||
        snapshot_epoch!=frame_epoch || snapshot_time_count!=time_count;
    assign busy=state!=IDLE;
    assign snapshot_vblank=!rst && state==IDLE && frame_ready && !freeze && !snapshot_swapped && vblank_start;
    assign snapshot_read_en=!rst && state==READ_REQUEST;
    assign snapshot_read_index=(layer==2 ? time_count : 10'd0)+sample_index;
    assign frame_begin=!rst && state==BEGIN_FRAME;
    assign commit_frame=!rst && state==COMMIT;
    assign abort_frame=!rst && state==ABORT;
    assign span_valid=!pipeline_reset && busy && raw_valid && raw_legal;
    assign raw_ready=!pipeline_reset && busy && span_ready && raw_legal;
    assign span_layer=layer;
    assign span_last=raw_last;
    assign span_index=raw_x-10'd64;
    assign span_min=raw_min-y_base;
    assign span_max=raw_max-y_base;
    plot_coordinate_mapper coordinates(
        .clk(pixel_clk),.rst(pipeline_reset),.in_valid(state==MAP_SEND),.is_spectrum(layer==2),
        .sample_index(sample_index),.sample_count(sample_count),.sample_value(sample_value),
        .out_valid(mapped_valid),.x(mapped_x),.y(mapped_y));
    plot_line_rasterizer lines(
        .clk(pixel_clk),.rst(pipeline_reset),.point_valid(state==POINT_SEND),
        .first_point(sample_index==0),.last_point(sample_index==sample_count-1'b1),
        .point_x(point_x),.point_y(point_y),.point_ready(point_ready),
        .pixel_valid(pixel_valid),.pixel_ready(pixel_ready),.pixel_x(pixel_x),.pixel_y(pixel_y),
        .pixel_last(pixel_last),.error_pulse(line_error));
    plot_span_accumulator columns(
        .clk(pixel_clk),.rst(pipeline_reset),.pixel_valid(pixel_valid),.pixel_last(pixel_last),
        .pixel_x(pixel_x),.pixel_y(pixel_y),.pixel_ready(pixel_ready),
        .span_valid(raw_valid),.span_ready(raw_ready),.span_last(raw_last),
        .span_x(raw_x),.span_y_min(raw_min),.span_y_max(raw_max));
    always @(posedge pixel_clk) begin
        if(rst) begin
            state<=IDLE;layer<=0;time_count<=0;sample_index<=0;sample_value<=0;
            point_x<=0;point_y<=0;elapsed<=0;frame_id<=0;frame_epoch<=0;frame_status<=0;frame_config<=0;
            submitted_frames<=0;failed_frames<=0;
        end else begin
            if(state==IDLE) elapsed<=0;else elapsed<=elapsed+1'b1;
            if(state!=IDLE && state!=ABORT &&
                (snapshot_changed || line_error || (raw_valid && !raw_legal) || elapsed>=MAX_RENDER_CYCLES)) begin
                state<=ABORT;failed_frames<=failed_frames+1'b1;
            end else case(state)
                IDLE:if(snapshot_swapped) begin
                    if(snapshot_valid && count_legal && frame_ready) begin
                        frame_id<=snapshot_frame_id;frame_epoch<=snapshot_epoch;
                        frame_status<=snapshot_status;frame_config<=snapshot_config;
                        time_count<=snapshot_time_count;layer<=0;sample_index<=0;state<=BEGIN_FRAME;
                    end else failed_frames<=failed_frames+1'b1;
                end
                BEGIN_FRAME:state<=READ_REQUEST;
                READ_REQUEST:state<=READ_WAIT;
                READ_WAIT:if(snapshot_read_valid) begin sample_value<=layer==0 ? snapshot_read_data[31:16] : snapshot_read_data[15:0];state<=MAP_SEND;end
                MAP_SEND:state<=MAP_WAIT;
                MAP_WAIT:if(mapped_valid) begin point_x<=mapped_x;point_y<=mapped_y;state<=POINT_SEND;end
                POINT_SEND:if(point_ready) begin
                    if(sample_index==sample_count-1'b1) state<=LAYER_DRAIN;
                    else begin sample_index<=sample_index+1'b1;state<=READ_REQUEST;end
                end
                LAYER_DRAIN:if(raw_valid && raw_ready && raw_last) begin
                    if(layer<2) begin layer<=layer+1'b1;sample_index<=0;state<=READ_REQUEST;end
                    else state<=COMMIT;
                end
                COMMIT:begin submitted_frames<=submitted_frames+1'b1;state<=IDLE;end
                ABORT:state<=IDLE;
                default:begin state<=ABORT;failed_frames<=failed_frames+1'b1;end
            endcase
        end
    end
`ifndef SYNTHESIS
    initial if((N!=256 && N!=512) || MAX_RENDER_CYCLES<1) $fatal(1,"Invalid renderer parameters");
`endif
endmodule
