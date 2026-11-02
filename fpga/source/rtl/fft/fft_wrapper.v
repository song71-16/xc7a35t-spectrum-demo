`timescale 1ns/1ps
// One fixed-N AXI FFT. Configuration and every stream obey valid/ready.
// Input samples are signed16; unscaled output retains 16+log2(N)+1 bits.
module fft_wrapper #(
    parameter integer N = 512
) (
    input wire clk, input wire rst,
    input wire signed [15:0] in_data,
    input wire in_valid, output wire in_ready,
    output wire signed [31:0] out_real, output wire signed [31:0] out_imag,
    output wire [15:0] out_index,
    output wire out_valid, input wire out_ready, output wire out_last,
    output reg protocol_error,
    output reg [31:0] completed_frames
);
    reg configured;
    reg [15:0] input_index;
    wire config_ready, data_ready;
    wire unexpected_last, missing_last;
    wire [63:0] result;
    localparam integer INDEX_W = (($clog2(N)+7)/8)*8;
    wire [INDEX_W-1:0] result_index;
    assign in_ready = configured && data_ready;
    assign out_real = result[31:0];
    assign out_imag = result[63:32];
    assign out_index = {{(16-INDEX_W){1'b0}},result_index};
    always @(posedge clk) begin
        if (rst) begin
            configured <= 0;
            input_index <= 0;
            protocol_error <= 0;
            completed_frames <= 0;
        end else begin
            if (!configured && config_ready) configured <= 1;
            if (in_valid && in_ready)
                input_index <= input_index == N-1 ? 0 : input_index + 1'b1;
            if (unexpected_last || missing_last) protocol_error <= 1;
            if (out_valid && out_ready) begin
                if (out_last != (out_index == N-1)) protocol_error <= 1;
                if (out_last) completed_frames <= completed_frames + 1'b1;
            end
        end
    end
    spectrum_fft fft (
        .aclk(clk), .aresetn(!rst),
        .s_axis_config_tdata(8'h01), .s_axis_config_tvalid(!configured && !rst),
        .s_axis_config_tready(config_ready),
        .s_axis_data_tdata({16'b0,in_data}),
        .s_axis_data_tvalid(in_valid && configured && !rst), .s_axis_data_tready(data_ready),
        .s_axis_data_tlast(input_index == N-1),
        .m_axis_data_tdata(result), .m_axis_data_tuser(result_index),
        .m_axis_data_tvalid(out_valid), .m_axis_data_tready(out_ready), .m_axis_data_tlast(out_last),
        .event_frame_started(), .event_tlast_unexpected(unexpected_last),
        .event_tlast_missing(missing_last), .event_status_channel_halt(),
        .event_data_in_channel_halt(), .event_data_out_channel_halt()
    );
endmodule
