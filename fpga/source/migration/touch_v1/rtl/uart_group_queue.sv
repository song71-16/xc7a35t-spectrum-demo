`timescale 1ns/1ps
// Single-clock bounded queue of complete encoded protocol groups/responses.
// Producer formats at core speed; consumer alone sees physical UART stalls.
// One slot is reserved from data admission for a control response. More
// responses than available storage backpressure the producer (never disappear).
module uart_group_queue #(
    parameter integer SLOTS=4, SLOT_BYTES=4096
)(
    input wire clk,rst,
    input wire begin_data,begin_response,end_item,
    input wire [7:0] in_data,input wire in_valid,output wire in_ready,
    output reg [7:0] out_data,output reg out_valid,input wire out_ready,
    output reg [31:0] groups_queued,groups_dropped,groups_sent,
    output reg [31:0] responses_queued,queue_errors,
    output wire [7:0] queued_items
);
    localparam SW=$clog2(SLOTS), BW=$clog2(SLOT_BYTES);
    localparam IDLE=0,WRITE=1,DROP=2,WAIT_RESPONSE=3;
    reg [1:0] state;
    reg [SW-1:0] wr_slot,rd_slot;
    reg [SW:0] count;
    reg [BW:0] write_count;
    reg [BW-1:0] read_index;
    reg writing_response,overflowed;
    reg [BW:0] lengths[0:SLOTS-1];
    reg response_kind[0:SLOTS-1];
    (* ram_style="block" *) reg [7:0] memory[0:SLOTS*SLOT_BYTES-1];
    assign queued_items=count;
    assign in_ready=state==WRITE || state==DROP;
    wire push=end_item && state==WRITE && !overflowed && write_count!=0;
    wire pop=out_valid && out_ready && read_index+1'b1==lengths[rd_slot];
    wire write_byte=state==WRITE && in_valid && in_ready && write_count<SLOT_BYTES;
    wire read_byte=(!out_valid && count!=0) || (out_valid && out_ready && !pop);
    wire [SW+BW-1:0] read_address={rd_slot,read_index}+(out_valid ? 1'b1 : 1'b0);
    // No reset on memory contents; count/valid/ownership invalidate stale bytes.
    always @(posedge clk)
        if(write_byte) memory[{wr_slot,write_count[BW-1:0]}]<=in_data;
    // A single explicit synchronous read port lets Vivado infer simple
    // dual-port BRAM. out_valid masks the uninitialized output after reset.
    always @(posedge clk)
        if(!rst && read_byte) out_data<=memory[read_address];
    always @(posedge clk)
        if(push) begin lengths[wr_slot]<=write_count;response_kind[wr_slot]<=writing_response;end
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;wr_slot<=0;rd_slot<=0;count<=0;write_count<=0;
            read_index<=0;writing_response<=0;overflowed<=0;
            out_valid<=0;
            groups_queued<=0;groups_dropped<=0;groups_sent<=0;
            responses_queued<=0;queue_errors<=0;
        end else begin
            case({push,pop})
                2'b10:count<=count+1'b1;
                2'b01:count<=count-1'b1;
            endcase
            if(begin_data || begin_response) begin
                if(state!=IDLE || (begin_data && begin_response)) queue_errors<=queue_errors+1'b1;
                else begin
                    write_count<=0;overflowed<=0;writing_response<=begin_response;
                    if(begin_response) state<=count<SLOTS ? WRITE : WAIT_RESPONSE;
                    else if(count<SLOTS-1) state<=WRITE;
                    else begin state<=DROP;groups_dropped<=groups_dropped+1'b1;end
                end
            end
            if(state==WAIT_RESPONSE && count<SLOTS) state<=WRITE;
            if(state==WRITE && in_valid && in_ready) begin
                if(write_count<SLOT_BYTES) write_count<=write_count+1'b1;
                else if(!overflowed) begin overflowed<=1;queue_errors<=queue_errors+1'b1;end
            end
            if(end_item) begin
                if(state==WRITE) begin
                    state<=IDLE;
                    if(push) begin
                        wr_slot<=wr_slot+1'b1;
                        if(writing_response) responses_queued<=responses_queued+1'b1;
                        else groups_queued<=groups_queued+1'b1;
                    end else if(!overflowed) queue_errors<=queue_errors+1'b1;
                end else if(state==DROP) state<=IDLE;
                else queue_errors<=queue_errors+1'b1;
            end
            // Registered BRAM read with a stable output register under stalls.
            if(!out_valid) begin
                if(count!=0) begin
                    out_valid<=1;
                end
            end else if(out_ready) begin
                if(pop) begin
                    out_valid<=0;read_index<=0;rd_slot<=rd_slot+1'b1;
                    if(!response_kind[rd_slot]) groups_sent<=groups_sent+1'b1;
                end else begin
                    read_index<=read_index+1'b1;
                end
            end
        end
    end
`ifndef SYNTHESIS
    initial begin
        if(SLOTS<2 || (SLOTS&(SLOTS-1))!=0 || SLOTS>128) $fatal(1,"queue slot geometry");
        if(SLOT_BYTES<2062 || (SLOT_BYTES&(SLOT_BYTES-1))!=0) $fatal(1,"queue byte geometry");
    end
    always @(posedge clk) if(!rst) begin
        if(count>SLOTS) $fatal(1,"queue ownership overflow");
        if(push && count==SLOTS) $fatal(1,"queue overwrites unread slot");
        if(write_byte && out_valid && wr_slot==rd_slot) $fatal(1,"queue read/write ownership overlap");
        if(end_item && in_valid) $fatal(1,"end_item must follow final byte");
    end
`endif
endmodule
