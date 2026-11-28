`default_nettype none
module brains(
    input wire clk,
    input wire rst_n,

    input wire [15:0] d_in,

    input  wire [3:0]  cmd,
    input  wire [3:0]  param_0,
    input  wire [3:0]  param_1,
    input  wire [3:0]  param_2,
    input  wire        cmd_valid,
    output wire        cmd_ready,
    output reg         cmd_done,



    //reduce reuse ecycee
    output  reg [2:0] alu_command,
    output  reg [2:0] tritwise_command,
    output  reg [2:0] tritshift_tritwise_command, //trit shifts up to 3 front and back
    //4 trit
    output reg [7:0] alu_t4_a,
    output reg [7:0] alu_t4_b,
    output reg [7:0] alu_t4_c,
    output reg [1:0] alu_t1_a,
    output reg [1:0] alu_t1_b,
    //results here
    input wire [7:0] alu_t4_o,
    input wire [1:0] alu_t1_o,
    input wire [15:0] alu_multiply_o,

    output wire [23:0] pc_out,
    output wire        pc_overflow,
    output wire        reg_overflow,
    output wire [3:0]  offending_id

);
    reg [7:0] sp0_trib0, sp0_trib1, sp0_trib2;

    // Addr 2: sp1 (4t: 3, 4, 5)
    reg [7:0] sp1_trib0, sp1_trib1, sp1_trib2;

    // Addr 3: spf (4t: 6, 7; 1t: 0..7; upper 4t spf_trib2 preserved on 12t ops)
    reg [1:0] spf_flag0, spf_flag1, spf_flag2, spf_flag3;
    reg [1:0] spf_flag4, spf_flag5, spf_flag6, spf_flag7;
    reg [7:0] spf_trib2;

    wire [7:0] spf_trib0 = {spf_flag3, spf_flag2, spf_flag1, spf_flag0};
    wire [7:0] spf_trib1 = {spf_flag7, spf_flag6, spf_flag5, spf_flag4};

    // Addr 4: MAC ladder ({mac_d, mac_b, mac_a} + internal mac_c, mac_carry)
    reg [7:0] mac_a, mac_b, mac_c, mac_d;
    reg [1:0] mac_carry;
    reg [1:0] carry_reg;

    // Addr 5: 12-Trit Program Counter
    reg         pc_inc_enable;
    reg         pc_w_enable;
    reg  [23:0] pc_w_data;
    wire [23:0] pc_r_data;

    ternary_pc_12t program_counter (
        .clk        (clk),
        .rst_n      (rst_n),
        .inc_enable (pc_inc_enable),
        .w_enable   (pc_w_enable),
        .r_enable   (1'b1),
        .w_data     (pc_w_data),
        .r_data     (pc_r_data),
        .overflow   (pc_overflow)
    );

    assign pc_out = pc_r_data;

    // Addr 6..14: General-Purpose 12-Trit Registers
    reg [23:0] gp_reg_6,  gp_reg_7,  gp_reg_8;
    reg [23:0] gp_reg_9,  gp_reg_10, gp_reg_11;
    reg [23:0] gp_reg_12, gp_reg_13, gp_reg_14;

    // -------------------------------------------------------------------------
    // Alias / Mask Buffers
    // -------------------------------------------------------------------------
    reg [23:0] am_buff_12t;
    reg [7:0]  am_buff_4t;
    reg [1:0]  am_buff_1t;
    reg [3:0]  alias_addr_12t;   // 4'd0 = inactive (buffer acts as mask)
    reg [2:0]  alias_addr_4t;
    reg [2:0]  alias_addr_1t;
    reg        alias_active_4t;
    reg        alias_active_1t;
    reg        mask_12t_singleuse;
    reg        mask_4t_singleuse;
    reg        mask_1t_singleuse;

    // -------------------------------------------------------------------------
    // Execution State & Latched Instruction
    // -------------------------------------------------------------------------
    reg        exec_valid;
    reg [3:0]  exec_cmd, exec_p0, exec_p1, exec_p2;
    reg [1:0]  execute_stage;
    reg        write_allow;
    reg [23:0] tmp_12t_lat;
    reg [7:0]  alu_res_4t_lat;
    reg [1:0]  alu_res_1t_lat;
    reg        reg_ovf_r;
    reg [3:0]  offending_id_r;
    reg        do_housekeeping;

    assign cmd_ready    = !exec_valid && (execute_stage == 2'b00);
    assign reg_overflow = reg_ovf_r;
    assign offending_id = offending_id_r;

    // -------------------------------------------------------------------------
    // Masking & Register Read Functions
    // -------------------------------------------------------------------------
    function [1:0] apply_mask_1t;
        input [1:0] val;
        input [1:0] m;
        reg out_ovr;
        begin
            out_ovr       = val[1] | m[1];
            apply_mask_1t = {out_ovr, (~out_ovr) & (val[0] ~^ m[0])};
        end
    endfunction

    function [7:0] apply_mask_4t;
        input [7:0] val;
        input [7:0] m;
        begin
            apply_mask_4t = {
                apply_mask_1t(val[7:6], m[7:6]),
                apply_mask_1t(val[5:4], m[5:4]),
                apply_mask_1t(val[3:2], m[3:2]),
                apply_mask_1t(val[1:0], m[1:0])
            };
        end
    endfunction

    function [23:0] apply_mask_12t;
        input [23:0] val;
        input [23:0] m;
        begin
            apply_mask_12t = {
                apply_mask_4t(val[23:16], m[23:16]),
                apply_mask_4t(val[15:8],  m[15:8]),
                apply_mask_4t(val[7:0],   m[7:0])
            };
        end
    endfunction

    function [23:0] read_any_reg_12t;
        input [3:0]  addr;
        input [3:0]  al_addr;
        input [23:0] al_buff;
        input [7:0]  sp0_t0, sp0_t1, sp0_t2;
        input [7:0]  sp1_t0, sp1_t1, sp1_t2;
        input [7:0]  spf_t0, spf_t1, spf_t2;
        input [7:0]  m_a, m_b, m_d;
        input [23:0] pc_val;
        input [23:0] r6, r7, r8, r9, r10, r11, r12, r13, r14;
        begin
            if (addr == 4'd0) begin
                read_any_reg_12t = 24'hAAAAAA;
            end else if (al_addr == addr) begin
                read_any_reg_12t = al_buff;
            end else begin
                case (addr)
                    4'd1:    read_any_reg_12t = {sp0_t2, sp0_t1, sp0_t0};
                    4'd2:    read_any_reg_12t = {sp1_t2, sp1_t1, sp1_t0};
                    4'd3:    read_any_reg_12t = {spf_t2, spf_t1, spf_t0};
                    4'd4:    read_any_reg_12t = {m_d, m_b, m_a};
                    4'd5:    read_any_reg_12t = pc_val;
                    4'd6:    read_any_reg_12t = r6;
                    4'd7:    read_any_reg_12t = r7;
                    4'd8:    read_any_reg_12t = r8;
                    4'd9:    read_any_reg_12t = r9;
                    4'd10:   read_any_reg_12t = r10;
                    4'd11:   read_any_reg_12t = r11;
                    4'd12:   read_any_reg_12t = r12;
                    4'd13:   read_any_reg_12t = r13;
                    4'd14:   read_any_reg_12t = r14;
                    default: read_any_reg_12t = 24'hAAAAAA;
                endcase
            end
        end
    endfunction

    function [7:0] read_any_reg_4t;
        input [2:0] addr_4t;
        input       al_act;
        input [2:0] al_addr;
        input [7:0] al_buff;
        input [7:0] sp0_t0, sp0_t1, sp0_t2;
        input [7:0] sp1_t0, sp1_t1, sp1_t2;
        input [7:0] spf_t0, spf_t1;
        begin
            if (al_act && (al_addr == addr_4t)) begin
                read_any_reg_4t = al_buff;
            end else begin
                case (addr_4t)
                    3'd0: read_any_reg_4t = sp0_t0;
                    3'd1: read_any_reg_4t = sp0_t1;
                    3'd2: read_any_reg_4t = sp0_t2;
                    3'd3: read_any_reg_4t = sp1_t0;
                    3'd4: read_any_reg_4t = sp1_t1;
                    3'd5: read_any_reg_4t = sp1_t2;
                    3'd6: read_any_reg_4t = spf_t0;
                    3'd7: read_any_reg_4t = spf_t1;
                endcase
            end
        end
    endfunction

    function [1:0] read_any_reg_1t;
        input [2:0] addr_1t;
        input       al_act;
        input [2:0] al_addr;
        input [1:0] al_buff;
        input [1:0] f0, f1, f2, f3, f4, f5, f6, f7;
        begin
            if (al_act && (al_addr == addr_1t)) begin
                read_any_reg_1t = al_buff;
            end else begin
                case (addr_1t)
                    3'd0: read_any_reg_1t = f0;
                    3'd1: read_any_reg_1t = f1;
                    3'd2: read_any_reg_1t = f2;
                    3'd3: read_any_reg_1t = f3;
                    3'd4: read_any_reg_1t = f4;
                    3'd5: read_any_reg_1t = f5;
                    3'd6: read_any_reg_1t = f6;
                    3'd7: read_any_reg_1t = f7;
                endcase
            end
        end
    endfunction

    // -------------------------------------------------------------------------
    // Shared Read Address Decode & Read Muxes
    // -------------------------------------------------------------------------
    reg [3:0] rd_addr_12t;
    reg [2:0] rd_addr_4t_a, rd_addr_4t_b, rd_addr_4t_c;
    reg [2:0] rd_addr_1t_a, rd_addr_1t_b;

    always @(*) begin
        rd_addr_12t  = 4'd0;
        rd_addr_4t_a = 3'd0;
        rd_addr_4t_b = 3'd0;
        rd_addr_4t_c = 3'd0;
        rd_addr_1t_a = 3'd0;
        rd_addr_1t_b = 3'd0;

        case (exec_cmd)
            4'b0001: begin // 1-Param Ops
                rd_addr_12t  = exec_p1;
                rd_addr_4t_a = exec_p1[3:1];
                rd_addr_1t_a = exec_p1[3:1];
            end

            4'b0010: begin // 2-Param Ops
                rd_addr_12t  = (execute_stage == 2'b00) ? exec_p1 : exec_p2;
                rd_addr_4t_a = (exec_p0 == 4'b1111) ? exec_p1[2:0] : exec_p1[3:1];
                rd_addr_4t_b = (exec_p0 == 4'b1111) ? exec_p2[2:0] : exec_p2[3:1];
                rd_addr_1t_a = exec_p1[3:1];
                rd_addr_1t_b = exec_p2[3:1];
            end

            4'b0011,       // Add / Sub
            4'b0100: begin // MAC + Pump
                rd_addr_4t_a = exec_p0[3:1];
                rd_addr_4t_b = exec_p1[3:1];
            end

            4'b0101: begin // Add3 (Packed: aaab bbcc cddd)
                rd_addr_4t_a = exec_p0[3:1];
                rd_addr_4t_b = {exec_p0[0], exec_p1[3:2]};
                rd_addr_4t_c = {exec_p1[1:0], exec_p2[3]};
            end

            4'b0110: begin // Trit Shift: A (4t), amt (1t)
                rd_addr_4t_a = exec_p0[3:1];
                rd_addr_1t_a = exec_p1[3:1];
            end

            4'b1000, 4'b1001, 4'b1010: begin // Tritwise 1..3
                rd_addr_1t_a = exec_p0[3:1];
                rd_addr_1t_b = exec_p1[3:1];
            end

            4'b1100: begin // 12t<->4t (p1[0]=0) or 4t<->1t (p1[0]=1)
                rd_addr_12t  = exec_p0;
                rd_addr_4t_a = exec_p1[0] ? exec_p0[3:1] : exec_p1[3:1];
                rd_addr_1t_a = exec_p1[3:1];
            end

            default: ;
        endcase
    end

    wire [23:0] shared_rd_12t = read_any_reg_12t(
        rd_addr_12t, alias_addr_12t, am_buff_12t,
        sp0_trib0, sp0_trib1, sp0_trib2, sp1_trib0, sp1_trib1, sp1_trib2,
        spf_trib0, spf_trib1, spf_trib2, mac_a, mac_b, mac_d,
        pc_r_data,
        gp_reg_6,  gp_reg_7,  gp_reg_8,
        gp_reg_9,  gp_reg_10, gp_reg_11,
        gp_reg_12, gp_reg_13, gp_reg_14
    );

    wire [7:0] shared_rd_4t_a = read_any_reg_4t(
        rd_addr_4t_a, alias_active_4t, alias_addr_4t, am_buff_4t,
        sp0_trib0, sp0_trib1, sp0_trib2, sp1_trib0, sp1_trib1, sp1_trib2,
        spf_trib0, spf_trib1
    );

    wire [7:0] shared_rd_4t_b = read_any_reg_4t(
        rd_addr_4t_b, alias_active_4t, alias_addr_4t, am_buff_4t,
        sp0_trib0, sp0_trib1, sp0_trib2, sp1_trib0, sp1_trib1, sp1_trib2,
        spf_trib0, spf_trib1
    );

    wire [7:0] shared_rd_4t_c = read_any_reg_4t(
        rd_addr_4t_c, alias_active_4t, alias_addr_4t, am_buff_4t,
        sp0_trib0, sp0_trib1, sp0_trib2, sp1_trib0, sp1_trib1, sp1_trib2,
        spf_trib0, spf_trib1
    );

    wire [1:0] shared_rd_1t_a = read_any_reg_1t(
        rd_addr_1t_a, alias_active_1t, alias_addr_1t, am_buff_1t,
        spf_flag0, spf_flag1, spf_flag2, spf_flag3,
        spf_flag4, spf_flag5, spf_flag6, spf_flag7
    );

    wire [1:0] shared_rd_1t_b = read_any_reg_1t(
        rd_addr_1t_b, alias_active_1t, alias_addr_1t, am_buff_1t,
        spf_flag0, spf_flag1, spf_flag2, spf_flag3,
        spf_flag4, spf_flag5, spf_flag6, spf_flag7
    );

    // -------------------------------------------------------------------------
    // Cross-Width Sub-Alias Hazard Detection (12t vs 4t vs 1t)
    // -------------------------------------------------------------------------
    reg [3:0] wr_addr_12t;
    always @(*) begin
        wr_addr_12t = 4'd0;
        case (exec_cmd)
            4'b0010: if (exec_p0 == 4'b0000 || exec_p0 == 4'b0010 ||
                         exec_p0 == 4'b0101 || (exec_p0 == 4'b1101 && exec_p1[1:0] == 2'b00))
                         wr_addr_12t = exec_p2;
            4'b1100: if (!exec_p1[0] && exec_p2[0])
                         wr_addr_12t = exec_p0;
            default: ;
        endcase
    end

    wire uses_12t_1 = (rd_addr_12t == 4'd1) || (wr_addr_12t == 4'd1);
    wire uses_12t_2 = (rd_addr_12t == 4'd2) || (wr_addr_12t == 4'd2);
    wire uses_12t_3 = (rd_addr_12t == 4'd3) || (wr_addr_12t == 4'd3);

    reg [2:0] wr_addr_4t;
    reg       wr_en_4t;
    always @(*) begin
        wr_addr_4t = 3'd0;
        wr_en_4t   = 1'b0;
        case (exec_cmd)
            4'b0001: if (exec_p0 == 4'b0001) begin
                wr_addr_4t = {1'b0, exec_p1[3:2]} + 3'd3;
                wr_en_4t   = 1'b1;
            end else if (exec_p0 == 4'b0010 || exec_p0 == 4'b0011) begin
                wr_addr_4t = exec_p1[3:1];
                wr_en_4t   = 1'b1;
            end
            4'b0010: if (exec_p0 == 4'b0100 || exec_p0 == 4'b0110 ||
                        (exec_p0 == 4'b1101 && exec_p1[1:0] == 2'b01)) begin
                wr_addr_4t = exec_p2[3:1];
                wr_en_4t   = 1'b1;
            end
            4'b0011, 4'b0100, 4'b0110, 4'b1011: begin
                wr_addr_4t = exec_p2[3:1];
                wr_en_4t   = 1'b1;
            end
            4'b0101: begin
                wr_addr_4t = exec_p2[2:0];
                wr_en_4t   = 1'b1;
            end
            4'b1100: if (!exec_p1[0] && !exec_p2[0]) begin
                wr_addr_4t = exec_p1[3:1];
                wr_en_4t   = 1'b1;
            end else if (exec_p1[0] && exec_p2[0]) begin
                wr_addr_4t = exec_p0[3:1];
                wr_en_4t   = 1'b1;
            end
            default: ;
        endcase
    end

    wire uses_4t_6 = (rd_addr_4t_a == 3'd6) || (rd_addr_4t_b == 3'd6) ||
                     (rd_addr_4t_c == 3'd6) || (wr_en_4t && wr_addr_4t == 3'd6);
    wire uses_4t_7 = (rd_addr_4t_a == 3'd7) || (rd_addr_4t_b == 3'd7) ||
                     (rd_addr_4t_c == 3'd7) || (wr_en_4t && wr_addr_4t == 3'd7);

    wire hazard_12t_vs_4t = alias_active_4t && (
        (uses_12t_1 && (alias_addr_4t <= 3'd2)) ||
        (uses_12t_2 && (alias_addr_4t >= 3'd3 && alias_addr_4t <= 3'd5)) ||
        (uses_12t_3 && (alias_addr_4t >= 3'd6))
    );
    wire hazard_12t_vs_1t = alias_active_1t && uses_12t_3;
    wire hazard_4t_vs_1t  = alias_active_1t && (
        (uses_4t_6 && !alias_addr_1t[2]) ||
        (uses_4t_7 &&  alias_addr_1t[2])
    );
    wire sub_alias_stall = hazard_12t_vs_4t || hazard_12t_vs_1t || hazard_4t_vs_1t;

    // -------------------------------------------------------------------------
    // Register Write & Alias Commit Tasks
    // -------------------------------------------------------------------------
    task write_any_reg_12t;
        input        use_mask;
        input        w_allow;
        input [3:0]  addr;
        input [23:0] data_12t;
        reg   [23:0] wdata;
        begin
            if (w_allow) begin
                wdata = (alias_addr_12t == 4'd0 && use_mask) ? apply_mask_12t(data_12t, am_buff_12t) : data_12t;
                case (addr)
                    4'd1:  {sp0_trib2, sp0_trib1, sp0_trib0} <= wdata;
                    4'd2:  {sp1_trib2, sp1_trib1, sp1_trib0} <= wdata;
                    4'd3:  {spf_trib2, spf_flag7, spf_flag6, spf_flag5, spf_flag4,
                                       spf_flag3, spf_flag2, spf_flag1, spf_flag0} <= wdata;
                    4'd4:  {mac_d, mac_b, mac_a} <= wdata;
                    4'd5:  begin
                        pc_w_data   <= wdata;
                        pc_w_enable <= 1'b1;
                    end
                    4'd6:  gp_reg_6  <= wdata;
                    4'd7:  gp_reg_7  <= wdata;
                    4'd8:  gp_reg_8  <= wdata;
                    4'd9:  gp_reg_9  <= wdata;
                    4'd10: gp_reg_10 <= wdata;
                    4'd11: gp_reg_11 <= wdata;
                    4'd12: gp_reg_12 <= wdata;
                    4'd13: gp_reg_13 <= wdata;
                    4'd14: gp_reg_14 <= wdata;
                    default: ;
                endcase
                if (alias_addr_12t == addr && addr != 4'd0) begin
                    alias_addr_12t <= 4'd0;
                    am_buff_12t    <= 24'h555555;
                end
            end
        end
    endtask

    task write_any_reg_4t;
        input       use_mask;
        input       w_allow;
        input [2:0] addr_4t;
        input [7:0] data_4t;
        reg   [7:0] wdata;
        begin
            if (w_allow) begin
                wdata = (!alias_active_4t && use_mask) ? apply_mask_4t(data_4t, am_buff_4t) : data_4t;
                case (addr_4t)
                    3'd0: sp0_trib0 <= wdata;
                    3'd1: sp0_trib1 <= wdata;
                    3'd2: sp0_trib2 <= wdata;
                    3'd3: sp1_trib0 <= wdata;
                    3'd4: sp1_trib1 <= wdata;
                    3'd5: sp1_trib2 <= wdata;
                    3'd6: {spf_flag3, spf_flag2, spf_flag1, spf_flag0} <= wdata;
                    3'd7: {spf_flag7, spf_flag6, spf_flag5, spf_flag4} <= wdata;
                endcase
                if (alias_active_4t && (alias_addr_4t == addr_4t)) begin
                    alias_active_4t <= 1'b0;
                    am_buff_4t      <= 8'h55;
                end
            end
        end
    endtask

    task write_any_reg_1t;
        input       use_mask;
        input       w_allow;
        input [2:0] addr_1t;
        input [1:0] data_1t;
        reg   [1:0] wdata;
        begin
            if (w_allow) begin
                wdata = (!alias_active_1t && use_mask) ? apply_mask_1t(data_1t, am_buff_1t) : data_1t;
                case (addr_1t)
                    3'd0: spf_flag0 <= wdata;
                    3'd1: spf_flag1 <= wdata;
                    3'd2: spf_flag2 <= wdata;
                    3'd3: spf_flag3 <= wdata;
                    3'd4: spf_flag4 <= wdata;
                    3'd5: spf_flag5 <= wdata;
                    3'd6: spf_flag6 <= wdata;
                    3'd7: spf_flag7 <= wdata;
                endcase
                if (alias_active_1t && (alias_addr_1t == addr_1t)) begin
                    alias_active_1t <= 1'b0;
                    am_buff_1t      <= 2'b01;
                end
            end
        end
    endtask

    task execute_alias_write;
        input active;
        begin
            if (active) begin
                if (alias_addr_12t != 4'd0) begin
                    if (write_allow)
                        write_any_reg_12t(1'b0, 1'b1, alias_addr_12t, am_buff_12t);
                    else begin
                        alias_addr_12t <= 4'd0;
                        am_buff_12t    <= 24'h555555;
                    end
                end
                if (alias_active_4t) begin
                    if (write_allow)
                        write_any_reg_4t(1'b0, 1'b1, alias_addr_4t, am_buff_4t);
                    else begin
                        alias_active_4t <= 1'b0;
                        am_buff_4t      <= 8'h55;
                    end
                end
                if (alias_active_1t) begin
                    if (write_allow)
                        write_any_reg_1t(1'b0, 1'b1, alias_addr_1t, am_buff_1t);
                    else begin
                        alias_active_1t <= 1'b0;
                        am_buff_1t      <= 2'b01;
                    end
                end
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Main ISA Execution FSM
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            exec_valid                 <= 1'b0;
            exec_cmd                   <= 4'd0;
            exec_p0                    <= 4'd0;
            exec_p1                    <= 4'd0;
            exec_p2                    <= 4'd0;
            execute_stage              <= 2'b00;
            cmd_done                   <= 1'b0;
            write_allow                <= 1'b1;
            pc_inc_enable              <= 1'b0;
            pc_w_enable                <= 1'b0;
            pc_w_data                  <= 24'hAAAAAA;
            reg_ovf_r                  <= 1'b0;
            offending_id_r             <= 4'd0;
            carry_reg                  <= 2'b10;
            mac_carry                  <= 2'b10;
            alias_addr_12t             <= 4'd0;
            alias_addr_4t              <= 3'd0;
            alias_addr_1t              <= 3'd0;
            alias_active_4t            <= 1'b0;
            alias_active_1t            <= 1'b0;
            am_buff_12t                <= 24'h555555;
            am_buff_4t                 <= 8'h55;
            am_buff_1t                 <= 2'b01;
            mask_12t_singleuse         <= 1'b0;
            mask_4t_singleuse          <= 1'b0;
            mask_1t_singleuse          <= 1'b0;
            alu_command                <= 3'd0;
            tritwise_command           <= 3'd0;
            tritshift_tritwise_command <= 3'd0;
            alu_t4_a                   <= 8'hAA;
            alu_t4_b                   <= 8'hAA;
            alu_t4_c                   <= 8'hAA;
            alu_t1_a                   <= 2'b10;
            alu_t1_b                   <= 2'b10;
            tmp_12t_lat                <= 24'hAAAAAA;
            alu_res_4t_lat             <= 8'hAA;
            alu_res_1t_lat             <= 2'b10;
            // Register file (sp0, sp1, spf, mac_a..d, gp_reg_6..14) intentionally
            // left unreset to save GF180MCU DFF area, matching thread_command.v
        end else begin
            cmd_done        <= 1'b0;
            pc_inc_enable   <= 1'b0;
            pc_w_enable     <= 1'b0;
            reg_ovf_r       <= 1'b0;
            do_housekeeping  = 1'b0;

            // -----------------------------------------------------------------
            // Idle / Command Intake (flushes pending aliases in background)
            // -----------------------------------------------------------------
            if (!exec_valid && execute_stage == 2'b00) begin
                do_housekeeping = 1'b1;
                if (cmd_valid) begin
                    exec_cmd   <= cmd;
                    exec_p0    <= param_0;
                    exec_p1    <= param_1;
                    exec_p2    <= param_2;
                    exec_valid <= 1'b1;
                end

            // -----------------------------------------------------------------
            // Stage 0: Decode & Launch
            // -----------------------------------------------------------------
            end else if (exec_valid && execute_stage == 2'b00) begin
                if (sub_alias_stall) begin
                    do_housekeeping = 1'b1; // Flush conflicting alias, retry next clk
                end else begin
                    case (exec_cmd)
                        // --- 0-Parameter Ops (sub-op in param_0) ---
                        4'b0000: begin
                            exec_valid <= 1'b0;
                            cmd_done   <= 1'b1;
                            case (exec_p0)
                                4'b0001: if (write_allow) begin // MAC ladder flush
                                    {mac_a, mac_b, mac_c, mac_d} <= 32'hAAAAAAAA;
                                    mac_carry <= 2'b10;
                                end
                                4'b0010: if (write_allow) begin // Clear carry
                                    carry_reg <= 2'b10;
                                end
                                4'b0011: if (write_allow) begin // Reset masks & aliases
                                    am_buff_12t     <= 24'h555555;
                                    am_buff_4t      <= 8'h55;
                                    am_buff_1t      <= 2'b01;
                                    alias_active_1t <= 1'b0;
                                    alias_active_4t <= 1'b0;
                                    alias_addr_12t  <= 4'd0;
                                end
                                4'b0101: write_allow <= 1'b0;   // Disable write
                                4'b0110: write_allow <= 1'b1;   // Enable write
                                4'b0111: if (write_allow) begin // Clear scratchpads
                                    {sp0_trib2, sp0_trib1, sp0_trib0} <= 24'hAAAAAA;
                                    {sp1_trib2, sp1_trib1, sp1_trib0} <= 24'hAAAAAA;
                                    if (alias_addr_12t == 4'd1 || alias_addr_12t == 4'd2) alias_addr_12t <= 4'd0;
                                    if (alias_active_4t && alias_addr_4t <= 3'd5)         alias_active_4t <= 1'b0;
                                end
                                4'b1000: if (write_allow) begin // Clear GP6..GP8
                                    gp_reg_6 <= 24'hAAAAAA;
                                    gp_reg_7 <= 24'hAAAAAA;
                                    gp_reg_8 <= 24'hAAAAAA;
                                    if (alias_addr_12t >= 4'd6 && alias_addr_12t <= 4'd8) alias_addr_12t <= 4'd0;
                                end
                                4'b1010: do_housekeeping = 1'b1; // Explicit alias flush
                                4'b1011: pc_inc_enable  <= 1'b1; // Increment PC
                                4'b1100: if (write_allow) begin  // MAC pump (no dest)
                                    mac_a <= mac_c;
                                    mac_b <= mac_d;
                                end
                                4'b1101: if (write_allow) begin  // MAC add C -> B, clear C
                                    alu_command   <= 3'd1;
                                    alu_t4_a      <= mac_b;
                                    alu_t4_b      <= mac_c;
                                    alu_t1_a      <= mac_carry;
                                    execute_stage <= 2'b01;
                                    exec_valid    <= 1'b1;
                                    cmd_done      <= 1'b0;
                                end
                                // FREE: 0000, 0100, 1001, 1110, 1111
                                default: ;
                            endcase
                        end

                        // --- 1-Parameter Ops (sub-op in param_0, arg in param_1) ---
                        4'b0001: begin
                            exec_valid <= 1'b0;
                            cmd_done   <= 1'b1;
                            case (exec_p0)
                                4'b0001: begin // MAC read -> 4t regs 3..6
                                    case (exec_p1[1:0])
                                        2'b00: write_any_reg_4t(1'b0, write_allow, {1'b0, exec_p1[3:2]} + 3'd3, mac_a);
                                        2'b01: write_any_reg_4t(1'b0, write_allow, {1'b0, exec_p1[3:2]} + 3'd3, mac_b);
                                        2'b10: write_any_reg_4t(1'b0, write_allow, {1'b0, exec_p1[3:2]} + 3'd3, mac_c);
                                        2'b11: write_any_reg_4t(1'b0, write_allow, {1'b0, exec_p1[3:2]} + 3'd3, mac_d);
                                    endcase
                                end
                                4'b0010: if (write_allow) begin // MAC pump -> overflow dest
                                    write_any_reg_4t(exec_p1[0], 1'b1, exec_p1[3:1], mac_a);
                                    mac_a <= mac_c;
                                    mac_b <= mac_d;
                                end
                                4'b0011: if (write_allow) begin // Clear 4t scratch (0) or MAC (1)
                                    if (exec_p1[0]) begin
                                        case (exec_p1[3:1])
                                            3'b000: mac_a <= 8'hAA;
                                            3'b001: mac_b <= 8'hAA;
                                            3'b010: mac_c <= 8'hAA;
                                            3'b011: mac_d <= 8'hAA;
                                            default: ;
                                        endcase
                                    end else begin
                                        write_any_reg_4t(1'b0, 1'b1, exec_p1[3:1], 8'hAA);
                                    end
                                end
                                4'b0101, 4'b0110: begin // Load 12t mask (0101=single, 0110=persist)
                                    if (alias_addr_12t == 4'd0) begin
                                        if (write_allow) begin
                                            am_buff_12t        <= shared_rd_12t;
                                            mask_12t_singleuse <= (exec_p0 == 4'b0101);
                                        end
                                    end else begin
                                        do_housekeeping = 1'b1;
                                        execute_stage  <= 2'b01;
                                        exec_valid     <= 1'b1;
                                        cmd_done       <= 1'b0;
                                    end
                                end
                                4'b0111: begin // Load 4t mask
                                    if (!alias_active_4t) begin
                                        if (write_allow) begin
                                            am_buff_4t        <= shared_rd_4t_a;
                                            mask_4t_singleuse <= ~exec_p1[0];
                                        end
                                    end else begin
                                        do_housekeeping = 1'b1;
                                        execute_stage  <= 2'b01;
                                        exec_valid     <= 1'b1;
                                        cmd_done       <= 1'b0;
                                    end
                                end
                                4'b1000: begin // Load 1t mask
                                    if (!alias_active_1t) begin
                                        if (write_allow) begin
                                            am_buff_1t        <= shared_rd_1t_a;
                                            mask_1t_singleuse <= ~exec_p1[0];
                                        end
                                    end else begin
                                        do_housekeeping = 1'b1;
                                        execute_stage  <= 2'b01;
                                        exec_valid     <= 1'b1;
                                        cmd_done       <= 1'b0;
                                    end
                                end
                                // FREE: 0000, 0100, 1001, 1010, 1011, 1100, 1101, 1110, 1111
                                default: ;
                            endcase
                        end

                        // --- 2-Parameter Ops (sub-op in param_0, args in param_1/2) ---
                        4'b0010: begin
                            case (exec_p0)
                                4'b0000, 4'b0010: begin // 12t Copy (no mask / masked)
                                    tmp_12t_lat   <= shared_rd_12t;
                                    execute_stage <= 2'b01;
                                end
                                4'b0001, 4'b0011, 4'b0100, 4'b1100, 4'b1101: begin
                                    if (alias_addr_12t != 4'd0) do_housekeeping = 1'b1;
                                    execute_stage <= 2'b01;
                                end
                                4'b0101: begin // 12t Swap
                                    if (alias_addr_12t != 4'd0) do_housekeeping = 1'b1;
                                    tmp_12t_lat   <= shared_rd_12t;
                                    execute_stage <= 2'b01;
                                end
                                4'b0110: begin // 4t Swap
                                    if (alias_active_4t) do_housekeeping = 1'b1;
                                    execute_stage <= 2'b01;
                                end
                                4'b0111: begin // 1t Swap
                                    if (alias_active_1t) do_housekeeping = 1'b1;
                                    execute_stage <= 2'b01;
                                end
                                4'b1111: begin // MAC multiply / seed (no pump)
                                    alu_command   <= 3'd2;
                                    alu_t4_a      <= shared_rd_4t_a;
                                    alu_t4_b      <= shared_rd_4t_b;
                                    execute_stage <= 2'b01;
                                end
                                // FREE: 1000, 1001, 1010, 1011, 1110
                                default: begin
                                    exec_valid <= 1'b0;
                                    cmd_done   <= 1'b1;
                                end
                            endcase
                        end

                        // --- 3-Parameter Direct Ops ---
                        4'b0011: begin // 4t Add / Sub
                            alu_command   <= 3'd1;
                            alu_t4_a      <= shared_rd_4t_a;
                            alu_t4_b      <= exec_p0[0] ? apply_mask_4t(shared_rd_4t_b, 8'h00) : shared_rd_4t_b;
                            alu_t1_a      <= carry_reg;
                            execute_stage <= 2'b01;
                        end

                        4'b0100: begin // Reworked MAC (Multiply-Accumulate & Pump)
                            alu_command   <= 3'd2;
                            alu_t4_a      <= (exec_p0[0] && !alias_active_4t) ? apply_mask_4t(shared_rd_4t_a, am_buff_4t) : shared_rd_4t_a;
                            alu_t4_b      <= (exec_p1[0] && !alias_active_4t) ? apply_mask_4t(shared_rd_4t_b, am_buff_4t) : shared_rd_4t_b;
                            execute_stage <= 2'b01;
                        end

                        4'b0101: begin // 4t Add3 (A + B + C + carry -> D)
                            alu_command   <= 3'd6;
                            alu_t4_a      <= shared_rd_4t_a;
                            alu_t4_b      <= shared_rd_4t_b;
                            alu_t4_c      <= shared_rd_4t_c;
                            alu_t1_a      <= carry_reg;
                            execute_stage <= 2'b01;
                        end

                        4'b0110: begin // 4t Trit Shift
                            alu_command   <= 3'd7;
                            alu_t4_a      <= (exec_p0[0] && !alias_active_4t) ? apply_mask_4t(shared_rd_4t_a, am_buff_4t) : shared_rd_4t_a;
                            alu_t1_a      <= exec_p1[0] ? {1'b0, exec_p2[0]} : 2'b10;
                            tritshift_tritwise_command <= {
                                ~exec_p2[0],
                                shared_rd_1t_a[1] ? 2'd2 : (shared_rd_1t_a[0] ? 2'd3 : 2'd1)
                            };
                            execute_stage <= 2'b01;
                        end

                        4'b1000, 4'b1001, 4'b1010: begin // 1t Tritwise 1..3
                            case (exec_cmd[1:0])
                                2'b00:   alu_command <= 3'd3;
                                2'b01:   alu_command <= 3'd4;
                                2'b10:   alu_command <= 3'd5;
                                default: alu_command <= 3'd3;
                            endcase
                            tritwise_command <= {exec_p0[0], exec_p1[0], exec_p2[0]};
                            alu_t1_a         <= shared_rd_1t_a;
                            alu_t1_b         <= shared_rd_1t_b;
                            execute_stage    <= 2'b01;
                        end

                        4'b1011, 4'b1100: begin // 4t Imm Load / Slice Transfer
                            execute_stage <= 2'b01;
                        end

                        // FREE TOP-LEVEL OPS: 0111, 1101, 1110, 1111
                        default: begin
                            exec_valid <= 1'b0;
                            cmd_done   <= 1'b1;
                        end
                    endcase
                end

            // -----------------------------------------------------------------
            // Stage 1 & Stage 2: Multi-Cycle Commit / Writeback
            // -----------------------------------------------------------------
            end else if (execute_stage != 2'b00) begin
                case (execute_stage)
                    2'b01: begin
                        // 0000:1101 MAC B <= B + C, clear C
                        if (exec_cmd == 4'b0000 && exec_p0 == 4'b1101) begin
                            if (write_allow) begin
                                mac_b     <= alu_t4_o;
                                mac_carry <= alu_t1_o;
                                mac_c     <= 8'hAA;
                            end
                            execute_stage <= 2'b00;
                            exec_valid    <= 1'b0;
                            cmd_done      <= 1'b1;

                        // ALU / MAC Ops
                        end else if ((exec_cmd == 4'b0010 && exec_p0 == 4'b1111) ||
                                      exec_cmd == 4'b0011 || exec_cmd == 4'b0100 ||
                                      exec_cmd == 4'b0101 || exec_cmd == 4'b0110 ||
                                      exec_cmd == 4'b1000 || exec_cmd == 4'b1001 ||
                                      exec_cmd == 4'b1010) begin
                            alu_res_4t_lat <= alu_t4_o;
                            alu_res_1t_lat <= alu_t1_o;
                            if (exec_cmd == 4'b0010 && exec_p0 == 4'b1111) begin
                                if (write_allow) begin
                                    if (exec_p1[3]) begin // MAC seed -> B,A
                                        mac_a     <= alu_multiply_o[7:0];
                                        mac_b     <= alu_multiply_o[15:8];
                                        mac_carry <= 2'b10;
                                    end else begin        // MAC mul -> D,C
                                        mac_c     <= alu_multiply_o[7:0];
                                        mac_d     <= alu_multiply_o[15:8];
                                    end
                                end
                                execute_stage <= 2'b00;
                                exec_valid    <= 1'b0;
                                cmd_done      <= 1'b1;
                            end else if (exec_cmd == 4'b0100) begin
                                if (write_allow) begin
                                    mac_c <= alu_multiply_o[7:0];
                                    mac_d <= alu_multiply_o[15:8];
                                end
                                alu_command   <= 3'd1;
                                alu_t4_a      <= mac_b;
                                alu_t4_b      <= alu_multiply_o[7:0];
                                alu_t1_a      <= mac_carry;
                                execute_stage <= 2'b10;
                            end else begin
                                execute_stage <= 2'b10;
                            end

                        // Deferred 1-Param Mask Loads (after Stage 0 alias flush)
                        end else if (exec_cmd == 4'b0001) begin
                            if (write_allow) begin
                                case (exec_p0)
                                    4'b0101, 4'b0110: begin
                                        am_buff_12t        <= shared_rd_12t;
                                        mask_12t_singleuse <= (exec_p0 == 4'b0101);
                                    end
                                    4'b0111: begin
                                        am_buff_4t        <= shared_rd_4t_a;
                                        mask_4t_singleuse <= ~exec_p1[0];
                                    end
                                    4'b1000: begin
                                        am_buff_1t        <= shared_rd_1t_a;
                                        mask_1t_singleuse <= ~exec_p1[0];
                                    end
                                    default: ;
                                endcase
                            end
                            execute_stage <= 2'b00;
                            exec_valid    <= 1'b0;
                            cmd_done      <= 1'b1;

                        // 2-Param Non-ALU Commits
                        end else if (exec_cmd == 4'b0010) begin
                            if (write_allow) begin
                                case (exec_p0)
                                    4'b0000, 4'b0010: begin // 12t Copy (unmasked / masked)
                                        write_any_reg_12t(exec_p0[1], 1'b1, exec_p2, tmp_12t_lat);
                                        if (exec_p0[1] && mask_12t_singleuse) am_buff_12t <= 24'h555555;
                                    end
                                    4'b0001: begin // 1t Imm Write
                                        if (exec_p1[1:0] == 2'b10)
                                            carry_reg <= (exec_p2[0] && !alias_active_1t) ? apply_mask_1t(exec_p1[3:2], am_buff_1t) : exec_p1[3:2];
                                        else
                                            write_any_reg_1t(exec_p2[0], 1'b1, exec_p2[3:1], exec_p1[3:2]);
                                        if (exec_p2[0] && mask_1t_singleuse) am_buff_1t <= 2'b01;
                                    end
                                    4'b0011: begin // 1t Move
                                        write_any_reg_1t(exec_p1[0], 1'b1, exec_p2[3:1], shared_rd_1t_a);
                                        if (exec_p1[0] && mask_1t_singleuse) am_buff_1t <= 2'b01;
                                    end
                                    4'b0100: begin // 4t Move
                                        write_any_reg_4t(exec_p1[0], 1'b1, exec_p2[3:1], shared_rd_4t_a);
                                        if (exec_p1[0] && mask_4t_singleuse) am_buff_4t <= 8'h55;
                                    end
                                    4'b0101: begin // 12t Swap
                                        am_buff_12t    <= tmp_12t_lat;
                                        alias_addr_12t <= exec_p2;
                                        write_any_reg_12t(1'b0, 1'b1, exec_p1, shared_rd_12t);
                                    end
                                    4'b0110: begin // 4t Swap
                                        am_buff_4t      <= shared_rd_4t_a;
                                        alias_addr_4t   <= exec_p2[3:1];
                                        alias_active_4t <= 1'b1;
                                        write_any_reg_4t(1'b0, 1'b1, exec_p1[3:1], shared_rd_4t_b);
                                    end
                                    4'b0111: begin // 1t Swap
                                        am_buff_1t      <= shared_rd_1t_a;
                                        alias_addr_1t   <= exec_p2[3:1];
                                        alias_active_1t <= 1'b1;
                                        write_any_reg_1t(1'b0, 1'b1, exec_p1[3:1], shared_rd_1t_b);
                                    end
                                    4'b1100: begin // Generate Mask into am_buff_12t
                                        if (exec_p1 == 4'd0) begin
                                            reg_ovf_r      <= 1'b1;
                                            offending_id_r <= exec_cmd;
                                        end else begin
                                            am_buff_12t        <= 24'h555555;
                                            mask_12t_singleuse <= ~exec_p2[1];
                                            case (exec_p1)
                                                4'd1: am_buff_12t[7:0]   <= {4{exec_p2[3:2]}};
                                                4'd2: am_buff_12t[15:8]  <= {4{exec_p2[3:2]}};
                                                4'd3: am_buff_12t[23:16] <= {4{exec_p2[3:2]}};
                                                default: am_buff_12t[(exec_p1 - 4'd4)*2 +: 2] <= exec_p2[3:2];
                                            endcase
                                        end
                                    end
                                    4'b1101: begin // Generate Value (fill 12t / 4t / 1t)
                                        case (exec_p1[1:0])
                                            2'b00: write_any_reg_12t(1'b0, 1'b1, exec_p2,      {12{exec_p1[3:2]}});
                                            2'b01: write_any_reg_4t (1'b0, 1'b1, exec_p2[3:1], {4{exec_p1[3:2]}});
                                            2'b10: write_any_reg_1t (1'b0, 1'b1, exec_p2[3:1], exec_p1[3:2]);
                                            default: ;
                                        endcase
                                    end
                                    default: ;
                                endcase
                            end
                            execute_stage <= 2'b00;
                            exec_valid    <= 1'b0;
                            cmd_done      <= 1'b1;

                        // 4t Imm Load (1011) & Slice Transfer (1100)
                        end else begin
                            if (write_allow && exec_cmd == 4'b1011) begin
                                write_any_reg_4t(exec_p2[0], 1'b1, exec_p2[3:1], {exec_p0, exec_p1});
                                if (exec_p2[0] && mask_4t_singleuse) am_buff_4t <= 8'h55;
                            end else if (write_allow && exec_cmd == 4'b1100) begin
                                if (!exec_p1[0]) begin // 12t <-> 4t
                                    if (!exec_p2[0]) begin // Extract 4t from 12t
                                        write_any_reg_4t(exec_p2[1], 1'b1, exec_p1[3:1],
                                            (exec_p2[3:2] == 2'd0) ? shared_rd_12t[7:0]  :
                                            (exec_p2[3:2] == 2'd1) ? shared_rd_12t[15:8] : shared_rd_12t[23:16]);
                                        if (exec_p2[1] && mask_4t_singleuse) am_buff_4t <= 8'h55;
                                    end else begin         // Insert 4t into 12t
                                        write_any_reg_12t(exec_p2[1], 1'b1, exec_p0,
                                            (exec_p2[3:2] == 2'd0) ? {shared_rd_12t[23:8],  shared_rd_4t_a} :
                                            (exec_p2[3:2] == 2'd1) ? {shared_rd_12t[23:16], shared_rd_4t_a, shared_rd_12t[7:0]} :
                                                                     {shared_rd_4t_a, shared_rd_12t[15:0]});
                                        if (exec_p2[1] && mask_12t_singleuse) am_buff_12t <= 24'h555555;
                                    end
                                end else begin         // 4t <-> 1t
                                    if (!exec_p2[0]) begin // Extract 1t from 4t
                                        write_any_reg_1t(exec_p2[1], 1'b1, exec_p1[3:1],
                                            shared_rd_4t_a[exec_p2[3:2]*2 +: 2]);
                                        if (exec_p2[1] && mask_1t_singleuse) am_buff_1t <= 2'b01;
                                    end else begin         // Insert 1t into 4t
                                        write_any_reg_4t(exec_p2[1], 1'b1, exec_p0[3:1],
                                            (exec_p2[3:2] == 2'd0) ? {shared_rd_4t_a[7:2], shared_rd_1t_a} :
                                            (exec_p2[3:2] == 2'd1) ? {shared_rd_4t_a[7:4], shared_rd_1t_a, shared_rd_4t_a[1:0]} :
                                            (exec_p2[3:2] == 2'd2) ? {shared_rd_4t_a[7:6], shared_rd_1t_a, shared_rd_4t_a[3:0]} :
                                                                     {shared_rd_1t_a, shared_rd_4t_a[5:0]});
                                        if (exec_p2[1] && mask_4t_singleuse) am_buff_4t <= 8'h55;
                                    end
                                end
                            end
                            execute_stage <= 2'b00;
                            exec_valid    <= 1'b0;
                            cmd_done      <= 1'b1;
                        end
                    end

                    2'b10: begin
                        if (exec_cmd == 4'b0100) begin // MAC pump + commit
                            if (write_allow) begin
                                write_any_reg_4t(exec_p2[0], 1'b1, exec_p2[3:1], mac_a);
                                mac_a     <= alu_t4_o;
                                mac_b     <= mac_d;
                                mac_carry <= alu_t1_o;
                                if ((exec_p0[0] || exec_p1[0] || exec_p2[0]) && mask_4t_singleuse)
                                    am_buff_4t <= 8'h55;
                            end
                        end else if (write_allow) begin
                            case (exec_cmd)
                                4'b0011: begin // Add / Sub
                                    carry_reg <= alu_res_1t_lat;
                                    write_any_reg_4t(exec_p2[0], 1'b1, exec_p2[3:1],
                                        exec_p1[0] ? apply_mask_4t(alu_res_4t_lat, 8'h00) : alu_res_4t_lat);
                                    if (exec_p2[0] && mask_4t_singleuse) am_buff_4t <= 8'h55;
                                end
                                4'b0101: begin // Add3
                                    carry_reg <= alu_res_1t_lat;
                                    write_any_reg_4t(1'b0, 1'b1, exec_p2[2:0], alu_res_4t_lat);
                                end
                                4'b0110: begin // Trit Shift
                                    write_any_reg_4t(1'b0, 1'b1, exec_p2[3:1], alu_res_4t_lat);
                                    if (exec_p0[0] && mask_4t_singleuse) am_buff_4t <= 8'h55;
                                end
                                4'b1000, 4'b1001, 4'b1010: begin // Tritwise 1..3
                                    write_any_reg_1t(exec_p2[0], 1'b1, exec_p2[3:1], alu_res_1t_lat);
                                    if (exec_p2[0] && mask_1t_singleuse) am_buff_1t <= 2'b01;
                                end
                                default: ;
                            endcase
                        end
                        execute_stage <= 2'b00;
                        exec_valid    <= 1'b0;
                        cmd_done      <= 1'b1;
                    end

                    default: begin
                        execute_stage <= 2'b00;
                        exec_valid    <= 1'b0;
                        cmd_done      <= 1'b1;
                    end
                endcase
            end

            execute_alias_write(do_housekeeping);
        end
    end

endmodule