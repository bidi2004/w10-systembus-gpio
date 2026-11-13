// Autonomous aligned word copy, arbitrated BEFORE the original System Bus.
// All source reads and destination writes traverse that decoder and its ports.
// Control space 0x00020000..0x0002000f was unused; no SRAM address is stolen.
`default_nettype none
module kwt_bus_dma(
 input wire clk,rst_n,
 input wire cpu_cmd_valid, output wire cpu_cmd_ready,
 input wire [31:0] cpu_cmd_addr, input wire cpu_cmd_read,
 input wire [31:0] cpu_cmd_wdata, input wire [3:0] cpu_cmd_wmask,
 output wire cpu_rsp_valid, input wire cpu_rsp_ready,
 output wire cpu_rsp_err, output wire [31:0] cpu_rsp_rdata,
 output wire bus_cmd_valid, input wire bus_cmd_ready,
 output wire [31:0] bus_cmd_addr, output wire bus_cmd_read,
 output wire [31:0] bus_cmd_wdata, output wire [3:0] bus_cmd_wmask,
 input wire bus_rsp_valid, output wire bus_rsp_ready,
 input wire bus_rsp_err, input wire [31:0] bus_rsp_rdata
);
 localparam IDLE=3'd0, RD_CMD=3'd1, RD_RSP=3'd2, WR_CMD=3'd3, WR_RSP=3'd4;
 reg [2:0] state;
 reg [31:0] cfg_src,cfg_dst,cfg_words;
 reg [31:0] source,dest,left,data;
 reg done,error;
 wire busy=state!=IDLE;
 wire cfg_sel=cpu_cmd_addr[31:4]==28'h0002000;
 wire cfg_bad=cpu_cmd_addr[1:0]!=0;
 wire dma_req=state==RD_CMD || state==WR_CMD;
 // A single outstanding transaction preserves the original bus capability.
 reg pending,owner_dma,owner_cfg,last_cpu;
 reg grant_held,held_dma;
 reg [31:0] cfg_result;
 reg cfg_error;
 wire choose_dma=grant_held ? held_dma : dma_req && (!cpu_cmd_valid || last_cpu);
 wire choose_cpu=cpu_cmd_valid && !choose_dma;
 wire cfg_accept=cpu_cmd_valid && cpu_cmd_ready && cfg_sel;
 wire dma_accept=bus_cmd_valid && bus_cmd_ready && choose_dma;
 wire dma_response=pending && owner_dma && bus_rsp_valid;
 assign bus_cmd_valid=!pending && (choose_dma || (choose_cpu && !cfg_sel));
 assign bus_cmd_addr=choose_dma ? (state==RD_CMD ? source:dest):cpu_cmd_addr;
 assign bus_cmd_read=choose_dma ? state==RD_CMD:cpu_cmd_read;
 assign bus_cmd_wdata=choose_dma ? data:cpu_cmd_wdata;
 assign bus_cmd_wmask=choose_dma ? 4'hf:cpu_cmd_wmask;
 assign cpu_cmd_ready=!pending && choose_cpu && (cfg_sel || bus_cmd_ready);
 assign cpu_rsp_valid=pending && !owner_dma && (owner_cfg || bus_rsp_valid);
 assign cpu_rsp_rdata=owner_cfg ? cfg_result:bus_rsp_rdata;
 assign cpu_rsp_err=owner_cfg ? cfg_error:bus_rsp_err;
 assign bus_rsp_ready=pending && !owner_cfg && (owner_dma || cpu_rsp_ready);
 wire response_done=pending && (owner_cfg ? cpu_rsp_ready : bus_rsp_valid && bus_rsp_ready);
 function [31:0] merge_bytes;
  input [31:0] old_value,new_value; input [3:0] mask;
  integer b; begin
   for(b=0;b<4;b=b+1)merge_bytes[b*8+:8]=mask[b]?new_value[b*8+:8]:old_value[b*8+:8];
  end
 endfunction
 wire [32:0] src_limit={1'b0,cfg_src}+({1'b0,cfg_words}<<2);
 wire [32:0] dst_limit={1'b0,cfg_dst}+({1'b0,cfg_words}<<2);
 wire config_ok=cfg_src[1:0]==0 && cfg_dst[1:0]==0 && cfg_words!=0 && cfg_words<=131072
  && cfg_src>=32'h20000000 && src_limit<=33'h040000000
  && cfg_dst>=32'ha0000000 && dst_limit<=33'h0a0080000;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   pending<=0;owner_dma<=0;owner_cfg<=0;last_cpu<=0;cfg_result<=0;cfg_error<=0;
   grant_held<=0;held_dma<=0;
   state<=IDLE;cfg_src<=0;cfg_dst<=0;cfg_words<=0;
   source<=0;dest<=0;left<=0;data<=0;done<=0;error<=0;
  end else begin
   if(bus_cmd_valid && !bus_cmd_ready)begin grant_held<=1;held_dma<=choose_dma;end
   if(bus_cmd_valid && bus_cmd_ready)grant_held<=0;
   if(response_done)pending<=0;
   if(!pending && (cfg_accept || bus_cmd_valid && bus_cmd_ready))begin
    pending<=1;owner_dma<=choose_dma;owner_cfg<=choose_cpu && cfg_sel;last_cpu<=choose_cpu;
   end
   if(cfg_accept)begin
    cfg_error<=cfg_bad || (!cpu_cmd_read && busy);
    case(cpu_cmd_addr[3:2])
     0:cfg_result<=cfg_src;
     1:cfg_result<=cfg_dst;
     2:cfg_result<=cfg_words;
     3:cfg_result<={29'd0,error,done,busy};
    endcase
    if(!cpu_cmd_read && !cfg_bad && !busy)case(cpu_cmd_addr[3:2])
     0:cfg_src<=merge_bytes(cfg_src,cpu_cmd_wdata,cpu_cmd_wmask);
     1:cfg_dst<=merge_bytes(cfg_dst,cpu_cmd_wdata,cpu_cmd_wmask);
     2:cfg_words<=merge_bytes(cfg_words,cpu_cmd_wdata,cpu_cmd_wmask);
     3:if(cpu_cmd_wmask[0] && cpu_cmd_wdata[0])begin
      done<=!config_ok;error<=!config_ok;
      if(config_ok)begin source<=cfg_src;dest<=cfg_dst;left<=cfg_words;state<=RD_CMD;end
     end
    endcase
   end
   if(dma_accept)state<=state==RD_CMD ? RD_RSP:WR_RSP;
   if(dma_response)begin
    if(bus_rsp_err)begin state<=IDLE;done<=1;error<=1;end
    else if(state==RD_RSP)begin data<=bus_rsp_rdata;state<=WR_CMD;end
    else if(state==WR_RSP)begin
     left<=left-1;source<=source+4;dest<=dest+4;
     if(left==1)begin state<=IDLE;done<=1;end else state<=RD_CMD;
    end
   end
  end
 end
endmodule
`default_nettype wire
