`timescale 1ns/1ps
// Validates a descriptor before admitting a complete payload to the display.
// Word ordering and exact payload length are checked by the downstream buffer.
module snapshot_ingress #(parameter integer N=512,TAPS=31,DW=16)(
    input wire clk,rst,
    input wire offer,buffer_ready,
    input wire [15:0] epoch,config_epoch,
    input wire [9:0] time_count,
    input wire [511:0] status_data,
    input wire [287:0] config_data,
    input wire word_valid,commit,
    output wire buffer_offer,buffer_word_valid,buffer_commit,
    output reg [31:0] invalid_descriptors
);
    reg admitted;
    wire [15:0] stride=status_data[63:48];
    wire descriptor_ok = epoch==config_epoch && status_data[31:0]==100000000 &&
        status_data[47:32]==1 && status_data[79:64]==N && status_data[87:80]==TAPS &&
        status_data[95:88]==DW && status_data[103:96]==1 &&
        config_data[287:256]==stride && config_data[255:224]==status_data[111:104] &&
        status_data[111:104]<=1 &&
        ((stride==1 && time_count==N)||(stride==2 && time_count==N/2)||(stride==4 && time_count==N/4));
    assign buffer_offer=offer && descriptor_ok && !admitted && !rst;
    assign buffer_word_valid=word_valid && admitted && !rst;
    assign buffer_commit=commit && admitted && !rst;
    always @(posedge clk) begin
        if(rst) begin admitted<=0;invalid_descriptors<=0;end
        else begin
            if(offer) begin
                if(!descriptor_ok || admitted) invalid_descriptors<=invalid_descriptors+1'b1;
                else admitted<=buffer_ready;
            end
            if(commit) admitted<=0;
        end
    end
endmodule
