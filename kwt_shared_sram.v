// 512 KiB shared SRAM, one 32-bit System Bus ICB slave, one outstanding.
// 32 banks x (4096 x 32 bits). No direct accelerator or testbench write port.
module kwt_shared_sram(
 input clk, rst_n,
 input cmd_valid, output cmd_ready,
 input [31:0] cmd_addr, input cmd_read,
 input [31:0] cmd_wdata, input [3:0] cmd_wmask,
 output reg rsp_valid, input rsp_ready,
 output rsp_err, output [31:0] rsp_rdata
);
 wire hit = cmd_addr[31:19] == (32'ha0000000 >> 19);
 wire fire = cmd_valid && cmd_ready;
 reg [4:0] read_bank;
 reg error;
 wire [31:0] q[0:31];
 assign cmd_ready = !rsp_valid;
 assign rsp_err = error;
 assign rsp_rdata = error ? 32'b0 : q[read_bank];
 always @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin rsp_valid<=0; read_bank<=0; error<=0; end
  else begin
   if (rsp_valid && rsp_ready) rsp_valid<=0;
   if (fire) begin
    rsp_valid<=1; read_bank<=cmd_addr[18:14];
    error<=!hit;
   end
  end
 end
 genvar b,h;
 generate for(b=0;b<32;b=b+1) begin:banks
  for(h=0;h<2;h=h+1) begin:halves
   wire en = fire && hit && cmd_addr[18:14]==b;
   wire [15:0] mask = {{8{cmd_wmask[h*2+1]}},{8{cmd_wmask[h*2]}}};
`ifdef KWT_SRAM_2025
   RAMSP4096X16 u_macro(.Q(q[b][h*16+:16]),.CLK(clk),.CEN(~en),
    .WEN(~mask),.A(cmd_addr[13:2]),.D(cmd_wdata[h*16+:16]),
    .EMA(3'd2),.EMAW(2'd0),.GWEN(cmd_read),.RET1N(1'b1));
`else
   reg [15:0] mem[0:4095];
   reg [15:0] dout;
   assign q[b][h*16+:16]=dout;
   always @(posedge clk) if(en) begin
    if(cmd_read) dout<=mem[cmd_addr[13:2]];
    else begin
     if(cmd_wmask[h*2]) mem[cmd_addr[13:2]][7:0]<=cmd_wdata[h*16+:8];
     if(cmd_wmask[h*2+1]) mem[cmd_addr[13:2]][15:8]<=cmd_wdata[h*16+8+:8];
    end
   end
`endif
  end
 end endgenerate
endmodule
