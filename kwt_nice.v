// KWT FFN1 verify5d: E203 CUSTOM3 NICE accelerator, ABI v5d.
//   LOAD_X  funct7=1 funct3=7 rs1=X address, rs2=3168  -> registers the X buffer, returns at once
//   RUN     funct7=3 funct3=7 rs1=parameter stream, rs2=Y address
//           streams X (99x64 int16) and [M, shift, 4 x (64 bias + 64x64 int16 weight tile)]
//           from shared SRAM concurrently; the 64-lane MAC array starts a row as soon as
//           that X row and the current weight tile are on chip; requantized int16 results
//           are written straight back to shared SRAM through a 32-entry Y FIFO.
// Progress protocol: the word at (base - 4) of the X and the parameter buffer holds the
// number of words the producer has already written; the engine polls it and only reads
// published words, so the whole task overlaps with the host transfer.
`ifndef KWT_WB
`define KWT_WB 10
`endif
`default_nettype none
module kwt_nice #(
    parameter MAXOUT = 2,
    parameter WB = `KWT_WB
)(
    input wire nice_clk, input wire nice_rst_n,
    output wire nice_active, output wire nice_mem_holdup,
    input wire nice_req_valid, output wire nice_req_ready,
    input wire [31:0] nice_req_inst, nice_req_rs1, nice_req_rs2,
    output wire nice_rsp_valid, input wire nice_rsp_ready,
    output reg [31:0] nice_rsp_rdat, output reg nice_rsp_err,
    output wire nice_icb_cmd_valid, input wire nice_icb_cmd_ready,
    output wire [31:0] nice_icb_cmd_addr, output wire nice_icb_cmd_read,
    output wire [31:0] nice_icb_cmd_wdata, output wire [1:0] nice_icb_cmd_size,
    input wire nice_icb_rsp_valid, output wire nice_icb_rsp_ready,
    input wire [31:0] nice_icb_rsp_rdata, input wire nice_icb_rsp_err
);
    localparam K=64, ROWS=99, PAR=64, NG=4;
    localparam XWORDS=3168, YWORDS=12672;
    localparam RWORDS=2*WB, TILEW=128+64*RWORDS, PWORDS=2+NG*TILEW;
    localparam NB=PAR*WB/16, ACCW=WB+22, SUMW=(ACCW>32?ACCW:32)+1;
    localparam PLW=SUMW+17, PHW=SUMW+16, QPW=SUMW+32, RNW=QPW+1;
    localparam C_IDLE=2'd0, C_RUN=2'd2, C_RESP=2'd3;
    integer j;

    // ---------------- instruction decode ----------------
    wire custom3 = nice_req_inst[6:0] == 7'h7b;
    wire [6:0] f7 = nice_req_inst[31:25];
    wire [2:0] f3 = nice_req_inst[14:12];
    wire dec_ldx = custom3 && f3 == 3'b111 && f7 == 7'd1;
    wire dec_run = custom3 && f3 == 3'b111 && f7 == 7'd3;
    wire [32:0] x_end = {1'b0, nice_req_rs1} + XWORDS*4 - 1;
    wire [32:0] p_end = {1'b0, nice_req_rs1} + PWORDS*4 - 1;
    wire [32:0] y_end = {1'b0, nice_req_rs2} + YWORDS*4 - 1;
    wire bad_ldx = nice_req_rs1[1:0] != 0 || nice_req_rs1 < 4 || nice_req_rs2 != XWORDS || x_end[32];
    wire bad_run = nice_req_rs1[1:0] != 0 || nice_req_rs1 < 4 || nice_req_rs2[1:0] != 0 || p_end[32] || y_end[32];

    reg [1:0] cst;
    reg [31:0] xbase, pbase, ybase;
    reg x_armed, err_flag;
    reg [3:0] err_code;
    assign nice_req_ready = cst == C_IDLE;
    assign nice_rsp_valid = cst == C_RESP;
    assign nice_active = cst != C_IDLE || nice_req_valid;
    assign nice_mem_holdup = cst != C_IDLE;
    wire running = cst == C_RUN;

    // ---------------- ICB master ----------------
    reg cmd_pend, cmd_read_r;
    reg [31:0] cmd_addr_r, cmd_wdata_r;
    reg [1:0] inflight;
    reg [2:0] tag_mem [0:1];            // {x, poll, read}
    reg [13:0] availx, availp;
    reg poll_busy, poll_rr;
    reg [5:0] poll_wait;
    reg tag_wp, tag_rp;
    assign nice_icb_cmd_valid = cmd_pend;
    assign nice_icb_cmd_addr = cmd_addr_r;
    assign nice_icb_cmd_read = cmd_read_r;
    assign nice_icb_cmd_wdata = cmd_wdata_r;
    assign nice_icb_cmd_size = 2'b10;
    wire head_read = tag_mem[tag_rp][0];
    wire head_poll = tag_mem[tag_rp][1];
    wire head_x = tag_mem[tag_rp][2];
    wire rd_accept;
    assign nice_icb_rsp_ready = (inflight != 0) && (!head_read || rd_accept);
    wire rsp_fire = nice_icb_rsp_valid && nice_icb_rsp_ready;
    wire cmd_fire = cmd_pend && nice_icb_cmd_ready;
    wire rsp_rd = rsp_fire && head_read && !head_poll;
    wire rsp_poll = rsp_fire && head_poll;
    wire x_rx = rsp_rd && head_x;
    wire p_rx = rsp_rd && !head_x;
    wire [31:0] rdata = nice_icb_rsp_rdata;

    // X stream
    reg [11:0] xi_iss, xi_rx;
    reg [6:0] mr; reg [5:0] mt; reg [1:0] mg;
    // parameter stream issue/receive counters
    reg [13:0] pi_iss;
    reg [1:0] iss_tile; reg [11:0] iss_pos;
    reg [1:0] rx_hdr; reg [2:0] rx_tile; reg [11:0] rx_pos;
    reg [2:0] retired, tiles_written;
    // Y FIFO with serializer credits
    reg [31:0] yfifo [0:31];
    reg [4:0] yf_wp, yf_rp;
    reg [5:0] yf_cnt, ycred;
    reg [1:0] yg; reg [6:0] yr; reg [4:0] yi;
    wire [31:0] y_addr = ybase + {yr, 9'd0} + {yg, 7'd0} + {yi, 2'd0};

    wire p_credit = (pi_iss < 2) || ({1'b0, iss_tile} <= retired + 3'd1);
    wire x_more = xi_iss != XWORDS;
    wire p_more = pi_iss != PWORDS && p_credit;
    wire x_have = {2'd0, xi_iss} < availx;
    wire p_have = pi_iss < availp;
    wire req_y = running && !err_flag && yf_cnt != 0;
    wire req_x = running && !err_flag && x_more && x_have;
    wire req_p = running && !err_flag && p_more && p_have;
    wire want_px = x_more && !x_have;
    wire want_pp = p_more && !p_have;
    wire req_poll = running && !err_flag && !poll_busy && poll_wait == 0 && (want_px || want_pp);
    wire poll_x = want_px && (!want_pp || !poll_rr);
    wire req_any = req_x || req_y || req_p || req_poll;
    wire slot_free = !cmd_pend || cmd_fire;
    wire [1:0] inflight_after_rsp = inflight - {1'b0, rsp_fire};
    wire do_load = req_any && slot_free && inflight_after_rsp < MAXOUT;
    wire load_y = do_load && req_y;
    // the parameter stream goes first while the tile of the current MAC group is incomplete
    reg [13:0] p_need;
    always @(*) case (mg) 2'd0: p_need = 2+TILEW; 2'd1: p_need = 2+2*TILEW; 2'd2: p_need = 2+3*TILEW; default: p_need = PWORDS; endcase
    wire p_urgent = pi_iss < p_need;
    wire pick_p = req_p && (p_urgent || !req_x);
    wire load_poll = do_load && !req_y && req_poll;
    wire load_x = do_load && !req_y && !req_poll && req_x && !pick_p;
    wire load_p = do_load && !req_y && !req_poll && pick_p;

    // ---------------- X store: even / odd k halves, 2 x 4096x16, 2-deep write queues ----------------
    reg mac_issue;
    wire [11:0] x_rd_addr = {mr, 5'd0} + {7'd0, mt[5:1]};
    reg [15:0] xlo_d [0:1]; reg [15:0] xhi_d [0:1];
    reg xlo_wp, xlo_rp, xhi_wp, xhi_rp;
    reg [1:0] xlo_n, xhi_n;
    reg [11:0] xlo_wc, xhi_wc;
    wire x0_rd = mac_issue && !mt[0];
    wire x1_rd = mac_issue && mt[0];
    wire x0_wr = xlo_n != 0 && !x0_rd;
    wire x1_wr = xhi_n != 0 && !x1_rd;
    wire x_room = !xlo_n[1] && !xhi_n[1];
    wire [15:0] xq0, xq1;
    kwt_sram16_sp #(.DEPTH(4096)) u_x0 (.clk(nice_clk), .en(x0_wr || x0_rd),
        .we(x0_wr), .addr(x0_wr ? xlo_wc : x_rd_addr), .din(xlo_d[xlo_rp]), .dout(xq0));
    kwt_sram16_sp #(.DEPTH(4096)) u_x1 (.clk(nice_clk), .en(x1_wr || x1_rd),
        .we(x1_wr), .addr(x1_wr ? xhi_wc : x_rd_addr), .din(xhi_d[xhi_rp]), .dout(xq1));
    wire x_row_ok = (xlo_wc[11:5] > mr) && (xhi_wc[11:5] > mr);

    // ---------------- parameter stream consumer ----------------
    reg [30:0] mq;
    reg [4:0] rw_i; reg [5:0] rw_k;
    reg [5:0] shamt;
    reg stg_full, stg_buf;
    reg [5:0] stg_k;
    reg [PAR*WB-1:0] stg;
    reg ser_q0;
    reg [5:0] sidx; reg [1:0] sg, sg_rd; reg [6:0] sr_rd;
    wire rx_is_hdr = rx_hdr != 2'd2;
    wire rx_is_bias = !rx_is_hdr && rx_pos < 12'd64;
    wire rx_is_m = !rx_is_hdr && rx_pos >= 12'd64 && rx_pos < 12'd128;
    assign rd_accept = head_poll ? 1'b1 : head_x ? x_room :
                       (rx_is_hdr || rx_is_bias || rx_is_m) ? 1'b1 : !stg_full;
    wire bias_we = p_rx && rx_is_bias;
    wire m_we = p_rx && rx_is_m;
    wire pm_we = bias_we || m_we;
    wire ser_adv = ser_q0 && !pm_we && (!sidx[0] || ycred != 0);
    wire [6:0] bias_addr = pm_we ? {rx_tile[0], rx_pos[5:0]} : {sg_rd[0], sidx};
    wire [15:0] bias_lo_q, bias_hi_q;
    kwt_sram16_sp #(.DEPTH(128)) u_b0 (.clk(nice_clk), .en(bias_we || ser_q0), .we(bias_we),
        .addr(bias_addr), .din(rdata[15:0]), .dout(bias_lo_q));
    kwt_sram16_sp #(.DEPTH(128)) u_b1 (.clk(nice_clk), .en(bias_we || ser_q0), .we(bias_we),
        .addr(bias_addr), .din(rdata[31:16]), .dout(bias_hi_q));
    wire [15:0] m_lo_q, m_hi_q;
    kwt_sram16_sp #(.DEPTH(128)) u_m0 (.clk(nice_clk), .en(m_we || ser_q0), .we(m_we),
        .addr(bias_addr), .din(rdata[15:0]), .dout(m_lo_q));
    kwt_sram16_sp #(.DEPTH(128)) u_m1 (.clk(nice_clk), .en(m_we || ser_q0), .we(m_we),
        .addr(bias_addr), .din(rdata[31:16]), .dout(m_hi_q));

    // ---------------- W tile banks: 64 x 128x16 (two 64-deep tiles) ----------------
    wire bank_we = stg_full;
    wire [6:0] w_addr = bank_we ? {stg_buf, stg_k} : {mg[0], mt};
    wire [PAR*WB-1:0] wq;
    genvar b;
    generate for (b = 0; b < NB; b = b + 1) begin: wbank
        kwt_sram16_sp #(.DEPTH(128)) u_w (.clk(nice_clk), .en(bank_we || mac_issue), .we(bank_we),
            .addr(w_addr), .din(stg[b*16 +: 16]), .dout(wq[b*16 +: 16]));
    end endgenerate

    // ---------------- MAC array ----------------
    reg eng_on, issue_done, res_full;
    reg s1_v, s1_first, s1_last, s1_xsel;
    reg s2_v, s2_first, s2_last;
    reg signed [15+WB:0] prod [0:PAR-1];
    reg signed [ACCW-1:0] acc [0:PAR-1];
    reg signed [ACCW-1:0] res [0:PAR-1];
    wire signed [15:0] xmac = s1_xsel ? xq1 : xq0;
    wire tile_ok = tiles_written > {1'b0, mg};
    always @(*) begin
        mac_issue = eng_on && !issue_done && !stg_full && tile_ok && x_row_ok && !(mt == 6'd63 && res_full);
    end

    // ---------------- serializer / requant ----------------
    reg ser_on;
    reg [6:0] sr;
    reg q1_v, q1_odd, q1_end; reg signed [ACCW-1:0] a0;
    reg q2_v, q2_odd, q2_end; reg signed [SUMW-1:0] sum;
    reg q3_v, q3_odd, q3_end; reg signed [PLW-1:0] plo; reg signed [PHW-1:0] phi;
    reg q4_v, q4_odd, q4_end; reg signed [QPW-1:0] qprod;
    reg q5_v, q5_odd, q5_end; reg signed [RNW-1:0] rnd_add;
    reg q6_v, q6_odd, q6_end; reg signed [15:0] yv;
    reg [15:0] lo_hold;
    reg [62:0] rnd_c;
    wire signed [RNW-1:0] rnd_sh = rnd_add >>> shamt;
    wire signed [15:0] ysat = (rnd_sh > 32767) ? 16'sd32767 :
                              (rnd_sh < -32767) ? -16'sd32767 : rnd_sh[15:0];
    wire ser_start = res_full && !ser_q0;
    wire y_push = q6_v && q6_odd;
    wire ycred_take = ser_adv && sidx[0];
    always @(*) ser_on = ser_q0 || q1_v || q2_v || q3_v || q4_v || q5_v || q6_v;

    wire run_done = issue_done && retired == NG && yf_cnt == 0 && !ser_on &&
                    inflight == 0 && !cmd_pend && pi_iss == PWORDS && rx_tile == NG && xi_rx == XWORDS;

    always @(posedge nice_clk or negedge nice_rst_n) begin
        if (!nice_rst_n) begin
            cst <= C_IDLE; xbase <= 0; pbase <= 0; ybase <= 0;
            x_armed <= 0; err_flag <= 0; err_code <= 0;
            nice_rsp_rdat <= 0; nice_rsp_err <= 0;
            cmd_pend <= 0; cmd_read_r <= 0; cmd_addr_r <= 0; cmd_wdata_r <= 0;
            inflight <= 0; tag_wp <= 0; tag_rp <= 0; tag_mem[0] <= 0; tag_mem[1] <= 0;
            availx <= 0; availp <= 0; poll_busy <= 0; poll_rr <= 0; poll_wait <= 0;
            xi_iss <= 0; xi_rx <= 0;
            xlo_wp <= 0; xlo_rp <= 0; xhi_wp <= 0; xhi_rp <= 0; xlo_n <= 0; xhi_n <= 0;
            xlo_wc <= 0; xhi_wc <= 0;
            pi_iss <= 0; iss_tile <= 0; iss_pos <= 0;
            rx_hdr <= 0; rx_tile <= 0; rx_pos <= 0; retired <= 0; tiles_written <= 0;
            yf_wp <= 0; yf_rp <= 0; yf_cnt <= 0; ycred <= 6'd32; yg <= 0; yr <= 0; yi <= 0;
            mq <= 0; rw_i <= 0; rw_k <= 0; shamt <= 0; stg_full <= 0; stg_buf <= 0; stg_k <= 0;
            eng_on <= 0; issue_done <= 0; res_full <= 0; mr <= 0; mt <= 0; mg <= 0;
            s1_v <= 0; s1_first <= 0; s1_last <= 0; s1_xsel <= 0;
            s2_v <= 0; s2_first <= 0; s2_last <= 0;
            ser_q0 <= 0; sidx <= 0; sg <= 0; sr <= 0; sg_rd <= 0; sr_rd <= 0;
            q1_v <= 0; q2_v <= 0; q3_v <= 0; q4_v <= 0; q5_v <= 0; q6_v <= 0; rnd_c <= 0;
        end else begin
            // ---------- ICB command/response bookkeeping ----------
            if (cmd_fire && !do_load) cmd_pend <= 1'b0;
            if (do_load) begin
                cmd_pend <= 1'b1;
                tag_mem[tag_wp] <= {load_x || (load_poll && poll_x), load_poll, !load_y};
                tag_wp <= ~tag_wp;
                cmd_read_r <= !load_y;
                cmd_wdata_r <= yfifo[yf_rp];
                cmd_addr_r <= load_y ? y_addr
                            : load_poll ? ((poll_x ? xbase : pbase) - 32'd4)
                            : load_x ? (xbase + {18'd0, xi_iss, 2'd0})
                            : (pbase + {16'd0, pi_iss, 2'd0});
            end
            inflight <= inflight + {1'b0, do_load} - {1'b0, rsp_fire};
            if (rsp_fire) begin
                tag_rp <= ~tag_rp;
                if (nice_icb_rsp_err && !err_flag) begin err_flag <= 1'b1; err_code <= 4'd4; end
            end
            if (poll_wait != 0) poll_wait <= poll_wait - 1'b1;
            if (load_poll) begin poll_busy <= 1'b1; poll_rr <= ~poll_rr; end
            if (rsp_poll) begin
                poll_busy <= 1'b0; poll_wait <= 6'd63;
                if (head_x) availx <= rdata[13:0]; else availp <= rdata[13:0];
            end
            if (load_x) xi_iss <= xi_iss + 1'b1;
            if (load_p) begin
                pi_iss <= pi_iss + 1'b1;
                if (pi_iss >= 2) begin
                    if (iss_pos == TILEW - 1) begin iss_pos <= 0; iss_tile <= iss_tile + 1'b1; end
                    else iss_pos <= iss_pos + 1'b1;
                end
            end
            if (load_y) begin
                yf_rp <= yf_rp + 1'b1;
                if (yi == 5'd31) begin
                    yi <= 0;
                    if (yr == ROWS - 1) begin yr <= 0; yg <= yg + 1'b1; end
                    else yr <= yr + 1'b1;
                end else yi <= yi + 1'b1;
            end
            yf_cnt <= yf_cnt + {5'd0, y_push} - {5'd0, load_y};
            ycred <= ycred + {5'd0, load_y} - {5'd0, ycred_take};
            if (y_push) begin yfifo[yf_wp] <= {yv, lo_hold}; yf_wp <= yf_wp + 1'b1; end

            // ---------- X receive into the bank write queues ----------
            if (x_rx) begin
                xi_rx <= xi_rx + 1'b1;
                xlo_d[xlo_wp] <= rdata[15:0]; xlo_wp <= ~xlo_wp;
                xhi_d[xhi_wp] <= rdata[31:16]; xhi_wp <= ~xhi_wp;
            end
            xlo_n <= xlo_n + {1'b0, x_rx} - {1'b0, x0_wr};
            xhi_n <= xhi_n + {1'b0, x_rx} - {1'b0, x1_wr};
            if (x0_wr) begin xlo_rp <= ~xlo_rp; xlo_wc <= xlo_wc + 1'b1; end
            if (x1_wr) begin xhi_rp <= ~xhi_rp; xhi_wc <= xhi_wc + 1'b1; end

            // ---------- parameter stream receive ----------
            if (p_rx) begin
                if (rx_is_hdr) begin
                    rx_hdr <= rx_hdr + 1'b1;
                    if (rx_hdr == 0) begin
                        if (rdata == 0 || rdata[31]) begin err_flag <= 1'b1; err_code <= 4'd5; end
                    end else begin
                        shamt <= rdata[5:0];
                        rnd_c <= 63'd1 << (rdata[5:0] - 6'd1);
                        if (rdata == 0 || rdata > 63) begin err_flag <= 1'b1; err_code <= 4'd5; end
                    end
                end else begin
                    if (!rx_is_bias && !rx_is_m) begin
                        stg[rw_i*32 +: 32] <= rdata;
                        if (rw_i == RWORDS - 1) begin
                            rw_i <= 0; rw_k <= rw_k + 1'b1;
                            stg_full <= 1'b1; stg_k <= rw_k; stg_buf <= rx_tile[0];
                        end else rw_i <= rw_i + 1'b1;
                    end
                    if (rx_pos == TILEW - 1) begin rx_pos <= 0; rx_tile <= rx_tile + 1'b1; end
                    else rx_pos <= rx_pos + 1'b1;
                end
            end
            if (bank_we) begin
                stg_full <= 1'b0;
                if (stg_k == 6'd63) tiles_written <= tiles_written + 1'b1;
            end

            // ---------- MAC issue ----------
            s1_v <= mac_issue; s1_first <= mt == 0; s1_last <= mt == 6'd63; s1_xsel <= mt[0];
            if (mac_issue) begin
                mt <= mt + 1'b1;
                if (mt == 6'd63) begin
                    if (mr == ROWS - 1) begin
                        mr <= 0; mg <= mg + 1'b1;
                        if (mg == NG - 1) issue_done <= 1'b1;
                    end else mr <= mr + 1'b1;
                end
            end
            // S1: multiply, S2: accumulate / latch row result
            s2_v <= s1_v; s2_first <= s1_first; s2_last <= s1_last;
            if (s1_v) for (j = 0; j < PAR; j = j + 1) prod[j] <= xmac * $signed(wq[j*WB +: WB]);
            if (s2_v) begin
                for (j = 0; j < PAR; j = j + 1) begin
                    acc[j] <= (s2_first ? $signed({ACCW{1'b0}}) : acc[j]) + prod[j];
                    if (s2_last) res[j] <= acc[j] + prod[j];
                end
                if (s2_last) res_full <= 1'b1;
            end

            // ---------- serializer: bias add, x M, round-shift, saturate, pack ----------
            if (ser_start) begin ser_q0 <= 1'b1; sidx <= 0; end
            q1_v <= ser_adv; q1_odd <= sidx[0]; q1_end <= sidx == 6'd63;
            if (ser_adv) begin
                a0 <= res[sidx];
                sidx <= sidx + 1'b1;
                if (sidx == 6'd63) begin
                    ser_q0 <= 1'b0; res_full <= 1'b0;
                    if (sr_rd == ROWS - 1) begin sr_rd <= 0; sg_rd <= sg_rd + 1'b1; end
                    else sr_rd <= sr_rd + 1'b1;
                end
            end
            q2_v <= q1_v; q2_odd <= q1_odd; q2_end <= q1_end;
            if (q1_v) begin sum <= a0 + $signed({bias_hi_q, bias_lo_q}); mq <= {m_hi_q[14:0], m_lo_q}; end
            q3_v <= q2_v; q3_odd <= q2_odd; q3_end <= q2_end;
            if (q2_v) begin
                plo <= sum * $signed({1'b0, mq[15:0]});
                phi <= sum * $signed({1'b0, mq[30:16]});
            end
            q4_v <= q3_v; q4_odd <= q3_odd; q4_end <= q3_end;
            if (q3_v) qprod <= $signed({phi, 16'd0}) + $signed({{(QPW-PLW){plo[PLW-1]}}, plo});
            q5_v <= q4_v; q5_odd <= q4_odd; q5_end <= q4_end;
            if (q4_v) rnd_add <= $signed({qprod[QPW-1], qprod}) + $signed({{(RNW-63){1'b0}}, rnd_c});
            q6_v <= q5_v; q6_odd <= q5_odd; q6_end <= q5_end;
            if (q5_v) yv <= ysat;
            if (q6_v && !q6_odd) lo_hold <= yv;
            if (q6_v && q6_end) begin
                if (sr == ROWS - 1) begin sr <= 0; sg <= sg + 1'b1; retired <= retired + 1'b1; end
                else sr <= sr + 1'b1;
            end

            // ---------- controller ----------
            case (cst)
                C_IDLE: if (nice_req_valid) begin
                    err_flag <= 0; err_code <= 0;
                    if (dec_ldx) begin
                        if (bad_ldx) begin nice_rsp_err <= 1; nice_rsp_rdat <= 2; end
                        else begin nice_rsp_err <= 0; nice_rsp_rdat <= 0; xbase <= nice_req_rs1; x_armed <= 1; end
                        cst <= C_RESP;
                    end else if (dec_run) begin
                        if (bad_run) begin nice_rsp_err <= 1; nice_rsp_rdat <= 2; cst <= C_RESP; end
                        else if (!x_armed) begin nice_rsp_err <= 1; nice_rsp_rdat <= 3; cst <= C_RESP; end
                        else begin
                            pbase <= nice_req_rs1; ybase <= nice_req_rs2;
                            xi_iss <= 0; xi_rx <= 0; xlo_wc <= 0; xhi_wc <= 0;
                            pi_iss <= 0; iss_tile <= 0; iss_pos <= 0;
                            availx <= 0; availp <= 0; poll_wait <= 0; poll_rr <= 0;
                            rx_hdr <= 0; rx_tile <= 0; rx_pos <= 0; retired <= 0; tiles_written <= 0; rw_i <= 0; rw_k <= 0;
                            yf_wp <= 0; yf_rp <= 0; yf_cnt <= 0; ycred <= 6'd32; yg <= 0; yr <= 0; yi <= 0;
                            stg_full <= 0; eng_on <= 1; issue_done <= 0; res_full <= 0;
                            mr <= 0; mt <= 0; mg <= 0; ser_q0 <= 0; sg <= 0; sr <= 0; sg_rd <= 0; sr_rd <= 0;
                            sidx <= 0; s1_v <= 0; s2_v <= 0;
                            q1_v <= 0; q2_v <= 0; q3_v <= 0; q4_v <= 0; q5_v <= 0; q6_v <= 0;
                            cst <= C_RUN;
                        end
                    end else begin nice_rsp_err <= 1; nice_rsp_rdat <= 1; cst <= C_RESP; end
                end
                C_RUN: if (err_flag ? (inflight == 0 && !cmd_pend && xlo_n == 0 && xhi_n == 0) : run_done) begin
                    nice_rsp_err <= err_flag; nice_rsp_rdat <= err_flag ? {28'd0, err_code} : 32'd0;
                    eng_on <= 0; x_armed <= 0; cst <= C_RESP;
                end
                C_RESP: if (nice_rsp_ready) cst <= C_IDLE;
                default: cst <= C_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
