`timescale 1ns / 1ps
// Symmetric Hann coefficients are unsigned UQ1.17, generated separately per N.
module window_hann #(
    parameter integer DW = 16,
    parameter integer N = 512,
    parameter COEFF_FILE = "hann.mem"
)(
    input wire clk, input wire rst,
    input wire in_valid, input wire signed [DW-1:0] sample_in,
    input wire [$clog2(N)-1:0] sample_index,
    output reg out_valid,
    output reg signed [DW-1:0] sample_out
);
    localparam integer PROD_W = DW+19;
    reg [17:0] coeff [0:N-1];
    reg signed [DW-1:0] sample_1;
    reg [17:0] coeff_1;
    reg signed [PROD_W-1:0] product;
    reg valid_1, valid_2;
    function signed [PROD_W:0] round_even;
        input signed [PROD_W-1:0] value;
        reg signed [PROD_W:0] quotient, remainder;
        begin
            quotient = $signed(value) >>> 17;
            remainder = $signed(value) - (quotient <<< 17);
            if ((remainder > 65536) || ((remainder == 65536) && quotient[0]))
                quotient = quotient + 1'b1;
            round_even = quotient;
        end
    endfunction
    wire signed [PROD_W:0] rounded = round_even(product);
    initial $readmemh(COEFF_FILE, coeff);
    always @(posedge clk) begin
        if (rst) begin
            sample_1 <= 0; coeff_1 <= 0; product <= 0;
            valid_1 <= 0; valid_2 <= 0; out_valid <= 0; sample_out <= 0;
        end else begin
            valid_1 <= in_valid; valid_2 <= valid_1; out_valid <= valid_2;
            if (in_valid) begin sample_1 <= sample_in; coeff_1 <= coeff[sample_index]; end
            if (valid_1) product <= sample_1 * $signed({1'b0,coeff_1});
            if (valid_2) sample_out <= rounded[DW-1:0];
        end
    end
endmodule
