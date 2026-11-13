// 16-bit single-port SRAM: portable reference or official 2025 RAMSP macro.
// Define KWT_SRAM_2025 and supply the official library models for simulation.
// Macro instantiation alone does not establish timing, area or power compliance.
`default_nettype none
module kwt_sram16_sp #(
    parameter DEPTH = 1024,
    parameter AW = $clog2(DEPTH)
)(
    input wire clk, en, we,
    input wire [AW-1:0] addr,
    input wire [15:0] din,
    output wire [15:0] dout
);
`ifdef KWT_SRAM_2025
    // Official models: synchronous read, write holds Q, active-low controls.
    // EMA/EMAW are the defaults stated by the 2025 ARM simulation models.
    generate
        if (DEPTH == 128) begin: official_128
            RAMSP128X16 u_macro (.Q(dout), .CLK(clk), .CEN(~en),
                .WEN(16'b0), .A(addr), .D(din), .EMA(3'd2),
                .EMAW(2'd0), .GWEN(~we), .RET1N(1'b1));
        end else if (DEPTH == 1024) begin: official_1024
            RAMSP1024X16 u_macro (.Q(dout), .CLK(clk), .CEN(~en),
                .WEN(16'b0), .A(addr), .D(din), .EMA(3'd2),
                .EMAW(2'd0), .GWEN(~we), .RET1N(1'b1));
        end else if (DEPTH == 4096) begin: official_4096
            RAMSP4096X16 u_macro (.Q(dout), .CLK(clk), .CEN(~en),
                .WEN(16'b0), .A(addr), .D(din), .EMA(3'd2),
                .EMAW(2'd0), .GWEN(~we), .RET1N(1'b1));
        end
    endgenerate
`else
    reg [15:0] reference_dout;
    assign dout = reference_dout;
    reg [15:0] mem [0:DEPTH-1];
    always @(posedge clk) begin
        if (en) begin
            if (we) mem[addr] <= din;
            else reference_dout <= mem[addr];
        end
    end
`endif
    // No reset/initialization of memory; disabled and write cycles hold dout.
    // synthesis translate_off
    initial begin
        if (!(DEPTH == 128 || DEPTH == 1024 || DEPTH == 4096))
            $fatal(1, "unsupported SRAM reference depth");
        if (AW != $clog2(DEPTH))
            $fatal(1, "SRAM address width must match depth");
    end
    // synthesis translate_on
endmodule

// Cascade equal-depth macros without adding a read cycle. The macro selector
// is registered at the SAME edge as the selected macro's synchronous read.
module kwt_sram16_linear #(
    parameter WORDS = 6336,
    parameter MACRO_DEPTH = 4096,
    parameter AW = (WORDS > 1 ? $clog2(WORDS) : 1)
)(
    input wire clk, en, we,
    input wire [AW-1:0] addr,
    input wire [15:0] din,
    output wire [15:0] dout
);
    localparam COUNT = (WORDS + MACRO_DEPTH - 1) / MACRO_DEPTH;
    localparam MAW = $clog2(MACRO_DEPTH);
    localparam SW = (COUNT > 1 ? $clog2(COUNT) : 1);
    wire [15:0] macro_data [0:COUNT-1];
    wire valid_addr = addr < WORDS;
    wire [MAW-1:0] word_addr = addr % MACRO_DEPTH;
    reg [SW-1:0] read_macro;
    always @(posedge clk)
        if (en && !we && valid_addr) read_macro <= addr / MACRO_DEPTH;
    assign dout = macro_data[read_macro];
    genvar m;
    generate for (m = 0; m < COUNT; m = m+1) begin: macros
        kwt_sram16_sp #(.DEPTH(MACRO_DEPTH)) u_mem (
            .clk(clk), .en(en && valid_addr && addr / MACRO_DEPTH == m),
            .we(we), .addr(word_addr), .din(din), .dout(macro_data[m])
        );
    end endgenerate
endmodule

// FFN X/Y storage. Loading X, computing and DMA reading Y are serialized by
// the controller. Y's PAR lanes write one word to each bank at the same edge.
module kwt_ffn_xy_mem #(
    parameter K = 64, N = 256, M_ROWS = 99, PAR = 16,
    parameter XW = $clog2(M_ROWS*K),
    parameter OW = $clog2(M_ROWS*N),
    parameter YAW = (M_ROWS*(N/PAR) > 1 ? $clog2(M_ROWS*(N/PAR)) : 1)
)(
    input wire clk,
    input wire x_we,
    input wire [XW-1:0] x_addr,
    input wire [15:0] x_din,
    input wire x_rd_en,
    input wire [XW-1:0] x_rd_addr,
    output wire signed [15:0] x_dout,
    input wire y_we,
    input wire [YAW-1:0] y_word,
    input wire [PAR*16-1:0] y_din,
    input wire y_rd_en,
    input wire [OW-1:0] y_rd_addr,
    output wire signed [15:0] y_dout,
    output wire signed [15:0] y_dout_hi
);
    kwt_sram16_linear #(.WORDS(M_ROWS*K), .MACRO_DEPTH(4096), .AW(XW)) x_store (
        .clk(clk), .en(x_we || x_rd_en), .we(x_we),
        .addr(x_we ? x_addr : x_rd_addr), .din(x_din), .dout(x_dout)
    );
    localparam BW = (PAR > 1 ? $clog2(PAR) : 1);
    wire [15:0] bank_data [0:PAR-1];
    reg [BW-1:0] read_bank;
    wire [YAW-1:0] read_word = y_rd_addr / PAR;
    wire [BW-1:0] req_bank = y_rd_addr % PAR;
    wire pair_read = !y_rd_addr[0] && (y_rd_addr + 1'b1 < M_ROWS*N);
    always @(posedge clk)
        if (y_rd_en && !y_we && y_rd_addr < M_ROWS*N)
            read_bank <= req_bank;
    assign y_dout = bank_data[read_bank];
    assign y_dout_hi = bank_data[read_bank | {{(BW-1){1'b0}}, 1'b1}];
    genvar b;
    generate for (b = 0; b < PAR; b = b+1) begin: y_banks
        wire bank_rd_hit = (req_bank == b) || (pair_read && ((req_bank | {{(BW-1){1'b0}}, 1'b1}) == b));
        kwt_sram16_linear #(.WORDS(M_ROWS*(N/PAR)), .MACRO_DEPTH(1024), .AW(YAW)) y_store (
            .clk(clk), .en(y_we || (y_rd_en && y_rd_addr < M_ROWS*N && bank_rd_hit)),
            .we(y_we), .addr(y_we ? y_word : read_word),
            .din(y_din[b*16 +: 16]), .dout(bank_data[b])
        );
    end endgenerate
    // synthesis translate_off
    initial begin
        if (N % PAR != 0 || PAR < 1) $fatal(1, "invalid FFN bank geometry");
    end
    // synthesis translate_on
endmodule

// Two signed W8 lanes share one 16-bit single-port bank. A byte write is
// accepted on w_valid && w_ready, reads the old word, and commits the merged
// word at the following edge.
module kwt_ffn_w_mem #(
    parameter K = 64, N = 256, PAR = 16,
    parameter WW = $clog2(K*N),
    parameter TW = (K > 1 ? $clog2(K) : 1),
    parameter GW = (N/PAR > 1 ? $clog2(N/PAR) : 1)
)(
    input wire clk, rst_n,
    input wire w_valid,
    output wire w_ready, idle,
    input wire [WW-1:0] w_addr,
    input wire [7:0] w_din,
    input wire rd_en,
    input wire [TW-1:0] rd_k,
    input wire [GW-1:0] rd_grp,
    output wire [PAR*8-1:0] rd_data
);
    localparam BANKS = PAR/2;
    localparam WORDS = K*(N/PAR);
    localparam AW = (WORDS > 1 ? $clog2(WORDS) : 1);
    localparam BW = (BANKS > 1 ? $clog2(BANKS) : 1);
    reg pending;
    reg [BW-1:0] saved_bank;
    reg [AW-1:0] saved_word;
    reg saved_byte;
    reg [7:0] saved_data;
    wire [15:0] bank_data [0:BANKS-1];
    wire [BW-1:0] write_bank = (w_addr % PAR)/2;
    wire [AW-1:0] write_word = (w_addr / N)*(N/PAR) + (w_addr % N)/PAR;
    wire [AW-1:0] read_word = rd_k*(N/PAR) + rd_grp;
    assign idle = !pending;
    assign w_ready = rst_n && !pending && !rd_en && w_addr < K*N;
    wire accept = w_valid && w_ready;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) pending <= 1'b0;
        else if (pending) pending <= 1'b0;
        else if (accept) begin
            pending <= 1'b1;
            saved_bank <= write_bank;
            saved_word <= write_word;
            saved_byte <= w_addr[0];
            saved_data <= w_din;
        end
    end
    genvar wb;
    generate for (wb = 0; wb < BANKS; wb = wb+1) begin: w_banks
        wire commit = rst_n && pending && saved_bank == wb;
        wire read_old = accept && write_bank == wb;
        wire [15:0] merged = saved_byte ? {saved_data, bank_data[wb][7:0]} :
                                          {bank_data[wb][15:8], saved_data};
        kwt_sram16_linear #(.WORDS(WORDS), .MACRO_DEPTH(1024), .AW(AW)) w_store (
            .clk(clk), .en(commit || read_old || (rst_n && rd_en && !pending && !accept)),
            .we(commit), .addr(commit ? saved_word : (read_old ? write_word : read_word)),
            .din(merged), .dout(bank_data[wb])
        );
        assign rd_data[wb*16 +: 16] = bank_data[wb];
    end endgenerate
    // synthesis translate_off
    initial begin
        if (PAR < 2 || PAR % 2 != 0 || N % PAR != 0)
            $fatal(1, "invalid packed weight geometry");
    end
    // synthesis translate_on
endmodule

// Fast dual-bank 32-bit direct write + legacy single-byte write W SRAM wrapper.
module kwt_ffn_w_mem_fast #(
    parameter K = 64, N = 256, PAR = 16,
    parameter WW = $clog2(K*N),
    parameter TW = (K > 1 ? $clog2(K) : 1),
    parameter GW = (N/PAR > 1 ? $clog2(N/PAR) : 1)
)(
    input wire clk, rst_n,
    input wire w_valid,
    input wire w_fast_32b,
    input wire [31:0] w_fast_din,
    output wire w_ready, idle,
    input wire [WW-1:0] w_addr,
    input wire [7:0] w_din,
    input wire rd_en,
    input wire [TW-1:0] rd_k,
    input wire [GW-1:0] rd_grp,
    output wire [PAR*8-1:0] rd_data
);
    localparam BANKS = PAR/2;
    localparam WORDS = K*(N/PAR);
    localparam AW = (WORDS > 1 ? $clog2(WORDS) : 1);
    localparam BW = (BANKS > 1 ? $clog2(BANKS) : 1);
    reg pending;
    reg [BW-1:0] saved_bank;
    reg [AW-1:0] saved_word;
    reg saved_byte;
    reg [7:0] saved_data;
    wire [15:0] bank_data [0:BANKS-1];
    wire [BW-1:0] write_bank = (w_addr % PAR)/2;
    wire [AW-1:0] write_word = (w_addr / N)*(N/PAR) + (w_addr % N)/PAR;
    wire [AW-1:0] read_word = rd_k*(N/PAR) + rd_grp;
    assign idle = !pending;
    assign w_ready = rst_n && !pending && !rd_en && w_addr < K*N;
    wire accept_byte = w_valid && !w_fast_32b && w_ready;
    wire accept_fast = w_fast_32b && w_ready;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) pending <= 1'b0;
        else if (pending) pending <= 1'b0;
        else if (accept_byte) begin
            pending <= 1'b1;
            saved_bank <= write_bank;
            saved_word <= write_word;
            saved_byte <= w_addr[0];
            saved_data <= w_din;
        end
    end
    genvar wb;
    generate for (wb = 0; wb < BANKS; wb = wb+1) begin: w_banks
        wire fast_lo = (wb % 2 == 0) && accept_fast && (write_bank == wb);
        wire fast_hi = (wb % 2 == 1) && accept_fast && ((write_bank | {{(BW-1){1'b0}}, 1'b1}) == wb);
        wire fast_we = fast_lo || fast_hi;
        wire commit = rst_n && pending && saved_bank == wb;
        wire read_old = accept_byte && write_bank == wb;
        wire [15:0] merged = saved_byte ? {saved_data, bank_data[wb][7:0]} :
                                          {bank_data[wb][15:8], saved_data};
        wire [15:0] din_mux = fast_lo ? w_fast_din[15:0] :
                              (fast_hi ? w_fast_din[31:16] : merged);
        wire [AW-1:0] addr_mux = fast_we ? write_word :
                                 (commit ? saved_word : (read_old ? write_word : read_word));
        kwt_sram16_linear #(.WORDS(WORDS), .MACRO_DEPTH(1024), .AW(AW)) w_store (
            .clk(clk),
            .en(fast_we || commit || read_old || (rst_n && rd_en && !pending && !accept_byte && !accept_fast)),
            .we(fast_we || commit),
            .addr(addr_mux),
            .din(din_mux),
            .dout(bank_data[wb])
        );
        assign rd_data[wb*16 +: 16] = bank_data[wb];
    end endgenerate
endmodule

// Six sequential 16-bit writes per accepted parameter channel. Acceptance
// latches the entire payload; reset aborts control, never clears SRAM. After
// an interrupted load the producer must reload every required channel.
module kwt_ffn_p_mem #(
    parameter N = 256,
    parameter PW = (N > 1 ? $clog2(N) : 1),
    parameter AW = (N*6 > 1 ? $clog2(N*6) : 1)
)(
    input wire clk, rst_n,
    input wire p_valid,
    output wire p_ready, idle,
    input wire [PW-1:0] p_addr,
    input wire [47:0] p_bias,
    input wire [31:0] p_m,
    input wire [6:0] p_shift,
    input wire rd_en,
    input wire [AW-1:0] rd_addr,
    output wire [15:0] rd_data
);
    reg pending;
    reg [2:0] word_index;
    reg [AW-1:0] saved_base;
    reg [95:0] saved_data;
    assign idle = !pending;
    assign p_ready = rst_n && !pending && !rd_en && p_addr < N;
    wire accept = p_valid && p_ready;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin pending <= 0; word_index <= 0; end
        else if (pending) begin
            if (word_index == 5) begin pending <= 0; word_index <= 0; end
            else word_index <= word_index + 1'b1;
        end else if (accept) begin
            pending <= 1;
            word_index <= 0;
            saved_base <= p_addr * 6;
            saved_data <= {9'd0, p_shift, p_m, p_bias};
        end
    end
    wire commit = rst_n && pending;
    wire [15:0] commit_data = saved_data[word_index*16 +: 16];
    wire [AW-1:0] commit_addr = saved_base + word_index;
    kwt_sram16_linear #(.WORDS(N*6), .MACRO_DEPTH(1024), .AW(AW)) p_store (
        .clk(clk), .en(commit || (rst_n && rd_en && !pending)),
        .we(commit), .addr(commit ? commit_addr : rd_addr),
        .din(commit_data), .dout(rd_data)
    );
endmodule
`default_nettype wire
