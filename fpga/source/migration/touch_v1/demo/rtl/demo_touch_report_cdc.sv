`timescale 1ns/1ps
// One owned report, mirrored in mailbox storage. Source holds valid/data until
// ready, then must lower valid for at least one source edge (GT reader contract).
// Common full-system reset only; never reset this seam to cancel a command.
module demo_touch_report_cdc (
    input wire source_clk,control_clk,rst_n,
    input wire source_available,source_fault,source_valid,
    input wire [3:0] source_count,
    input wire [15:0] source_x,source_y,
    output wire source_ready,source_busy,
    output reg source_online,
    output wire available,report_fault,report_valid,
    output reg [3:0] report_count,
    output reg [15:0] report_x,report_y
);
    (* ASYNC_REG="TRUE" *) reg [1:0] source_reset,control_reset;
    always @(posedge source_clk or negedge rst_n)
        if(!rst_n)source_reset<=0;else source_reset<={source_reset[0],1'b1};
    always @(posedge control_clk or negedge rst_n)
        if(!rst_n)control_reset<=0;else control_reset<={control_reset[0],1'b1};
    wire srst_n=source_reset[1],drst_n=control_reset[1];
    reg request_toggle,ack_toggle;
    reg [35:0] payload;
    (* ASYNC_REG="TRUE" *) reg [1:0] ack_sync,request_sync,online_return;
    // ONLY the registered source health may asynchronously invalidate the
    // destination. Reader combinational available is never an async reset.
    (* ASYNC_REG="TRUE" *) reg [1:0] online_sync;
    wire online_reset_n=drst_n && source_online;
    always @(posedge control_clk or negedge online_reset_n)
        if(!online_reset_n)online_sync<=0;else online_sync<={online_sync[0],1'b1};
    assign available=online_sync[1];
    assign report_fault=!available;
    reg pending,pending_request;
    assign report_valid=pending && available;
    always @(posedge control_clk or negedge drst_n) begin
        if(!drst_n)begin
            request_sync<=0;ack_toggle<=0;pending<=0;pending_request<=0;
            report_count<=0;report_x<=0;report_y<=0;
        end else begin
            request_sync<={request_sync[0],request_toggle};
            if(pending)begin
                // Actions consumes report_valid on THIS edge, or discards it
                // while unavailable. This ack never means a command succeeded.
                pending<=0;ack_toggle<=pending_request;
            end else if(request_sync[1]!=ack_toggle)begin
                {report_count,report_x,report_y}<=payload;
                pending_request<=request_sync[1];pending<=1;
            end
        end
    end
    localparam [1:0] IDLE=0,WAIT_ACK=1,RELEASE=2,WAIT_DROP=3;
    reg [1:0] state;
    wire healthy=source_available && !source_fault;
    assign source_busy=state!=IDLE;
    assign source_ready=srst_n && state==RELEASE;
    always @(posedge source_clk or negedge srst_n) begin
        if(!srst_n)begin
            ack_sync<=0;online_return<=0;request_toggle<=0;payload<=0;
            source_online<=0;state<=IDLE;
        end else begin
            ack_sync<={ack_sync[0],ack_toggle};
            online_return<={online_return[0],available};
            if(!healthy)source_online<=0;
            else if(!source_online && !online_return[1] && state==IDLE)
                source_online<=1;
            case(state)
                IDLE:if(source_valid)begin
                    if(!healthy)state<=RELEASE; // Explicitly discard invalid held report.
                    else if(source_online && online_return[1])begin
                        payload<={source_count,source_x,source_y};
                        request_toggle<=!request_toggle;state<=WAIT_ACK;
                    end
                end
                WAIT_ACK:if(ack_sync[1]==request_toggle)state<=RELEASE;
                RELEASE:state<=WAIT_DROP;
                WAIT_DROP:if(!source_valid)state<=IDLE;
            endcase
        end
    end
endmodule
