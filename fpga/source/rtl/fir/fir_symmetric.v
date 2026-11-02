`timescale 1ns / 1ps
// Odd symmetric FIR, one accepted sample per clock. Gaps in valid do not
// insert zeros: the history advances only for accepted samples.
module fir_symmetric #(
    parameter integer DW = 16,
    parameter integer TAPS = 31,
    parameter COEFF_FILE = "fir_coeff.mem"
)(
    input wire clk, input wire rst,
    input wire in_valid, input wire signed [DW-1:0] sample_in,
    output wire out_valid,
    output reg signed [DW-1:0] sample_out,
    output reg clip
);
    localparam integer HALF = TAPS/2;
    localparam integer PAIRS = HALF+1;
    localparam integer LEVELS = $clog2(PAIRS);
    localparam integer TREE_SIZE = 1 << LEVELS;
    localparam integer PROD_W = DW+19;
    localparam integer ACC_W = DW+19+$clog2(TAPS);
    localparam integer LATENCY = LEVELS+3;
    reg signed [17:0] coeff [0:TAPS-1];
    reg signed [DW-1:0] history [0:TAPS-2];
    reg signed [DW:0] preadd [0:PAIRS-1];
    (* use_dsp = "yes" *) reg signed [PROD_W-1:0] product [0:PAIRS-1];
    wire signed [ACC_W-1:0] tree [0:LEVELS][0:TREE_SIZE-1];
    reg [LATENCY-1:0] valid_pipe;
    assign out_valid = valid_pipe[LATENCY-1];
    genvar node, level;
    generate
        for (node=0; node<TREE_SIZE; node=node+1) begin : leaves
            if (node<PAIRS) assign tree[0][node] = product[node];
            else assign tree[0][node] = 0;
        end
        for (level=1; level<=LEVELS; level=level+1) begin : stages
            for (node=0; node<(TREE_SIZE >> level); node=node+1) begin : adders
                reg signed [ACC_W-1:0] sum;
                always @(posedge clk) begin
                    if (rst) sum <= 0;
                    else sum <= tree[level-1][2*node] + tree[level-1][2*node+1];
                end
                assign tree[level][node] = sum;
            end
        end
    endgenerate
    function signed [ACC_W:0] round_even;
        input signed [ACC_W-1:0] value;
        reg signed [ACC_W:0] quotient, remainder;
        begin
            quotient = $signed(value) >>> 17;
            remainder = $signed(value) - (quotient <<< 17);
            if ((remainder > 65536) || ((remainder == 65536) && quotient[0]))
                quotient = quotient + 1'b1;
            round_even = quotient;
        end
    endfunction
    wire signed [ACC_W:0] rounded = round_even(tree[LEVELS][0]);
    localparam signed [ACC_W:0] MAX_SAMPLE = (1 << (DW-1))-1;
    localparam signed [ACC_W:0] MIN_SAMPLE = -(1 << (DW-1));
    integer i;
    initial begin
        if (TAPS < 3 || TAPS%2 != 1) $error("fir_symmetric needs odd TAPS >= 3");
        $readmemh(COEFF_FILE, coeff);
    end
    always @(posedge clk) begin
        if (rst) begin
            valid_pipe <= 0; sample_out <= 0; clip <= 0;
            for (i=0; i<TAPS-1; i=i+1) history[i] <= 0;
            for (i=0; i<PAIRS; i=i+1) begin preadd[i] <= 0; product[i] <= 0; end
        end else begin
            valid_pipe <= {valid_pipe[LATENCY-2:0], in_valid};
            if (in_valid) begin
                for (i=TAPS-2; i>0; i=i-1) history[i] <= history[i-1];
                history[0] <= sample_in;
                preadd[0] <= $signed({sample_in[DW-1],sample_in}) +
                             $signed({history[TAPS-2][DW-1],history[TAPS-2]});
                for (i=1; i<HALF; i=i+1)
                    preadd[i] <= $signed({history[i-1][DW-1],history[i-1]}) +
                                 $signed({history[TAPS-2-i][DW-1],history[TAPS-2-i]});
                preadd[HALF] <= $signed(history[HALF-1]);
            end
            for (i=0; i<PAIRS; i=i+1) product[i] <= preadd[i] * coeff[i];
            clip <= 0;
            if (valid_pipe[LATENCY-2]) begin
                if (rounded > MAX_SAMPLE) begin
                    sample_out <= MAX_SAMPLE[DW-1:0]; clip <= 1;
                end else if (rounded < MIN_SAMPLE) begin
                    sample_out <= MIN_SAMPLE[DW-1:0]; clip <= 1;
                end else sample_out <= rounded[DW-1:0];
            end
        end
    end
endmodule
