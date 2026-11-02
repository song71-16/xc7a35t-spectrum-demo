// DRAFT_UNVERIFIED dual-TIME derivative of rtl/capture/pingpong_capture.v.
`timescale 1ns/1ps
// One fill engine, two banks and two independent readers. A ready/take
// handshake transfers the descriptor to both readers. Each reader must release
// once; the bank is reusable only after both releases. Read latency is 1 cycle.
// First capture sample is the first valid edge AFTER trigger_accept.
module demo_dualtime_capture #(
    parameter integer DW=16, parameter integer N=512,
    parameter integer AW=$clog2(N)
)(
    input wire clk, input wire rst,
    input wire trigger, input wire [15:0] config_epoch,
    input wire [63:0] timestamp_cycles,
    input wire sample_valid, input wire signed [DW-1:0] sample_in,
    input wire [2*DW-1:0] upload_sample_in,
    output reg trigger_accept, output reg trigger_reject,
    output reg [31:0] trigger_count, output reg [31:0] accepted_count,
    output reg [31:0] trigger_reject_count,
    output wire ready_valid, input wire ready_take,
    output wire ready_bank, output wire [31:0] ready_frame_id,
    output wire [15:0] ready_epoch,
    output wire [63:0] ready_timestamp,
    input wire process_release, input wire process_release_bank,
    input wire upload_release, input wire upload_release_bank,
    input wire process_read_en, input wire process_read_bank,
    input wire [AW-1:0] process_read_addr,
    output reg process_read_valid, output reg signed [DW-1:0] process_read_data,
    input wire upload_read_en, input wire upload_read_bank,
    input wire [AW-1:0] upload_read_addr,
    output reg upload_read_valid, output reg [2*DW-1:0] upload_read_data
);
    localparam [1:0] FREE=0,FILL=1,READY=2,HELD=3;
    reg [1:0] state[0:1];
    reg [1:0] readers[0:1];
    reg [31:0] frame_id[0:1]; reg [15:0] epoch[0:1];
    reg [63:0] timestamp[0:1];
    reg filling, fill_bank, trigger_d;
    reg [AW-1:0] write_addr;
    // Duplicate storage is intentional: each copy has one write and one read
    // port, allowing both clients to read the same bank simultaneously.
    (* ram_style="block" *) reg signed [DW-1:0] process_mem[0:2*N-1];
    (* ram_style="block" *) reg [2*DW-1:0] upload_mem[0:2*N-1];
    wire signed [31:0] id_difference=frame_id[0]-frame_id[1];
    assign ready_valid=(state[0]==READY)||(state[1]==READY);
    assign ready_bank=(state[0]==READY) ? ((state[1]==READY) ? !id_difference[31] : 1'b0) : 1'b1;
    assign ready_frame_id=frame_id[ready_bank];
    assign ready_epoch=epoch[ready_bank];
    assign ready_timestamp=timestamp[ready_bank];
    integer bank;
    always @(posedge clk) begin
        if(rst) begin
            for(bank=0;bank<2;bank=bank+1) begin
                state[bank]<=FREE;readers[bank]<=0;frame_id[bank]<=0;epoch[bank]<=0;timestamp[bank]<=0;
            end
            filling<=0;fill_bank<=0;write_addr<=0;trigger_d<=0;
            trigger_accept<=0;trigger_reject<=0;trigger_count<=0;accepted_count<=0;trigger_reject_count<=0;
        end else begin
            trigger_d<=trigger;trigger_accept<=0;trigger_reject<=0;
            if(ready_valid && ready_take) begin state[ready_bank]<=HELD;readers[ready_bank]<=2'b11;end
            for(bank=0;bank<2;bank=bank+1) begin
                if(state[bank]==HELD) begin
                    if(process_release && process_release_bank==bank) readers[bank][0]<=0;
                    if(upload_release && upload_release_bank==bank) readers[bank][1]<=0;
                    if((!readers[bank][0]||(process_release && process_release_bank==bank)) &&
                       (!readers[bank][1]||(upload_release && upload_release_bank==bank))) begin
                        state[bank]<=FREE;readers[bank]<=0;
                    end
                end
            end
            if(trigger && !trigger_d) begin
                trigger_count<=trigger_count+1'b1;
                if(!filling && ((state[0]==FREE)||(state[1]==FREE))) begin
                    fill_bank<=(state[0]!=FREE);filling<=1;write_addr<=0;trigger_accept<=1;
                    accepted_count<=accepted_count+1'b1;
                    if(state[0]==FREE) begin
                        state[0]<=FILL;frame_id[0]<=accepted_count;epoch[0]<=config_epoch;
                    end else begin state[1]<=FILL;frame_id[1]<=accepted_count;epoch[1]<=config_epoch;end
                end else begin trigger_reject<=1;trigger_reject_count<=trigger_reject_count+1'b1;end
            end
            if(filling && sample_valid) begin
                if(write_addr==N-1) begin filling<=0;state[fill_bank]<=READY;timestamp[fill_bank]<=timestamp_cycles;end
                else write_addr<=write_addr+1'b1;
            end
        end
    end
    // No reset on the BRAM arrays; uninitialized bytes cannot be read until
    // every location in the accepted frame has been written.
    always @(posedge clk) begin
        if(!rst && filling && sample_valid) begin
            process_mem[fill_bank*N+write_addr]<=sample_in;
            upload_mem[fill_bank*N+write_addr]<=upload_sample_in;
        end
        if(rst) begin process_read_valid<=0;upload_read_valid<=0;process_read_data<=0;upload_read_data<=0;end
        else begin
            process_read_valid<=0;upload_read_valid<=0;
            if(process_read_en && state[process_read_bank]==HELD && readers[process_read_bank][0] && process_read_addr<N) begin
                process_read_data<=process_mem[process_read_bank*N+process_read_addr];process_read_valid<=1;
            end
            if(upload_read_en && state[upload_read_bank]==HELD && readers[upload_read_bank][1] && upload_read_addr<N) begin
                upload_read_data<=upload_mem[upload_read_bank*N+upload_read_addr];upload_read_valid<=1;
            end
        end
    end
endmodule
