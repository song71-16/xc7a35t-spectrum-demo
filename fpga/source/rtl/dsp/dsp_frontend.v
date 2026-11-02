`timescale 1ns/1ps
// Continuous DDS/FIR front end. DW is a real quantizer boundary; outputs are
// rescaled to signed Q1.15 for the frame/FFT interfaces.
module dsp_frontend #(
    parameter integer DW = 16,
    parameter integer TAPS = 31,
    parameter SINE_FILE = "dds_sine.mem",
    parameter COEFF_FILE = "fir_coeff.mem"
)(
    input wire clk, input wire rst, input wire enable,
    input wire [31:0] phase_inc_a, input wire [31:0] phase_inc_b,
    input wire [15:0] amplitude_a, input wire [15:0] amplitude_b,
    input wire dual_enable,
    output wire raw_valid, output wire signed [15:0] raw_sample,
    output wire filtered_valid, output wire signed [15:0] filtered_sample,
    output wire dds_clip, output wire fir_clip
);
    wire signed [DW-1:0] dds_sample, fir_sample;
    dds_dual #(.DW(DW),.SINE_FILE(SINE_FILE)) oscillator (
        .clk(clk),.rst(rst),.en(enable),.phase_inc_a(phase_inc_a),.phase_inc_b(phase_inc_b),
        .amplitude_a(amplitude_a),.amplitude_b(amplitude_b),.dual_enable(dual_enable),
        .sample_out(dds_sample),.out_valid(raw_valid),.clip(dds_clip));
    fir_symmetric #(.DW(DW),.TAPS(TAPS),.COEFF_FILE(COEFF_FILE)) filter (
        .clk(clk),.rst(rst),.in_valid(raw_valid),.sample_in(dds_sample),
        .sample_out(fir_sample),.out_valid(filtered_valid),.clip(fir_clip));
    assign raw_sample = $signed(dds_sample) * (16'sd1 <<< (16-DW));
    assign filtered_sample = $signed(fir_sample) * (16'sd1 <<< (16-DW));
endmodule
