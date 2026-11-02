`timescale 1ns/1ps
// Shared full reset ONLY. Bundled data is held until the ack round trip.
// Coalesce latest source state; accept at frame_start to avoid torn UI frames.
// This is a behavioral CDC contract; physical constraints/signoff remain open.
module demo_control_display_cdc #(parameter integer WIDTH=85)(
    input wire control_clk,pixel_clk,rst_n,
    input wire [WIDTH-1:0] source_data,
    input wire frame_start,
    output reg [WIDTH-1:0] display_data,
    output reg display_valid,updated,
    output wire busy
);
    (* ASYNC_REG="TRUE" *) reg [1:0] control_reset,pixel_reset;
    always @(posedge control_clk or negedge rst_n)
        if(!rst_n)control_reset<=0;else control_reset<={control_reset[0],1'b1};
    always @(posedge pixel_clk or negedge rst_n)
        if(!rst_n)pixel_reset<=0;else pixel_reset<={pixel_reset[0],1'b1};
    reg request_toggle,ack_toggle,sent;
    reg [WIDTH-1:0] held;
    (* ASYNC_REG="TRUE" *) reg [1:0] ack_sync,request_sync;
    always @(posedge control_clk or negedge rst_n)
        if(!rst_n)ack_sync<=0;
        else ack_sync<={ack_sync[0],ack_toggle};
    always @(posedge pixel_clk or negedge rst_n)
        if(!rst_n)request_sync<=0;
        else request_sync<={request_sync[0],request_toggle};
    assign busy=request_toggle!=ack_sync[1];
    always @(posedge control_clk or negedge rst_n) begin
        if(!rst_n)begin request_toggle<=0;sent<=0;held<=0;end
        else if(!control_reset[1])begin request_toggle<=0;sent<=0;held<=0;end
        else if(!busy && (!sent || held!=source_data))begin
            held<=source_data;request_toggle<=!request_toggle;sent<=1;
        end
    end
    always @(posedge pixel_clk or negedge rst_n) begin
        if(!rst_n)begin ack_toggle<=0;display_data<=0;display_valid<=0;updated<=0;end
        else if(!pixel_reset[1])begin ack_toggle<=0;display_data<=0;display_valid<=0;updated<=0;end
        else begin
            updated<=0;
            if(frame_start && request_sync[1]!=ack_toggle)begin
                display_data<=held;display_valid<=1;updated<=1;
                ack_toggle<=request_sync[1];
            end
        end
    end
endmodule
