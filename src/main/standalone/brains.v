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
    input wire [15:0] alu_multiply_o

);

    // reduce reuse recycle
    // registers
                reg [7:0] sp0_trib0;
        reg [7:0] sp0_trib1;
        reg [7:0] sp0_trib2;
        
        reg [7:0] sp1_trib0;
        reg [7:0] sp1_trib1;
        reg [7:0] sp1_trib2;
        
        reg [1:0] spf_flag0;
        reg [1:0] spf_flag1;
        reg [1:0] spf_flag2;
        reg [1:0] spf_flag3;
        reg [1:0] spf_flag4;
        reg [1:0] spf_flag5;
        reg [1:0] spf_flag6;
        reg [1:0] spf_flag7;

        wire [7:0] spf_trib0;
        assign spf_trib0 = {spf_flag3, spf_flag2, spf_flag1, spf_flag0};
        wire [7:0] spf_trib1;
        assign spf_trib1 = {spf_flag7, spf_flag6, spf_flag5, spf_flag4};

        reg  [7:0] spf_trib2; // cannot be accessed normally. basically just to keep the data there to prevent losing it

        reg [7:0] mac_a;
        reg [7:0] mac_b;
        reg [7:0] mac_c;
        reg [7:0] mac_d;
        reg [1:0] mac_carry;

        reg [1:0] carry_reg;


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
//aliased buffers / masks
    //stands for alias mask buffer
        reg  [23:0] am_buff_12t;
        reg  [7:0] am_buff_4t;
        reg  [1:0] am_buff_1t;
        reg [3:0] alias_addr_12t; // the 0000 state is to mark it to be used as a mask
        reg [2:0] alias_addr_4t;
        reg [2:0] alias_addr_1t;
        reg alias_active_1t; //since 1 t has a valid 0 address, one more is needed
        reg alias_active_4t; //since 4 t has a valid 0 address, one more is needed

        reg mask_12t_singleuse;
        reg mask_4t_singleuse;
        reg mask_1t_singleuse;



    //state management
    reg        exec_valid;
    reg [1:0]  execute_stage;
    reg        write_allow;
    reg [23:0] tmp_12t_lat;
    reg [7:0]  alu_res_4t_lat;
    reg [1:0]  alu_res_1t_lat;
    reg [3:0]  offending_id_r;
    reg        do_housekeeping;

    assign cmd_ready    = !exec_valid && (execute_stage == 2'b00);
    
    //moved below
//shared read ports
    reg [3:0] rd_addr_12t;
    reg [2:0] rd_addr_4t_a, rd_addr_4t_b, rd_addr_4t_c;
    reg [2:0] rd_addr_1t_a, rd_addr_1t_b;
    reg hold_stall;

    wire addr4t_a_hits_hold = (hold_reg_addr == 4'd1 && rd_addr_4t_a <= 3'd2) ||
                          (hold_reg_addr == 4'd2 && rd_addr_4t_a >= 3'd3 && rd_addr_4t_a <= 3'd5) ||
                          (hold_reg_addr == 4'd3 && rd_addr_4t_a >= 3'd6);
    wire addr4t_b_hits_hold = (hold_reg_addr == 4'd1 && rd_addr_4t_b <= 3'd2) ||
                            (hold_reg_addr == 4'd2 && rd_addr_4t_b >= 3'd3 && rd_addr_4t_b <= 3'd5) ||
                            (hold_reg_addr == 4'd3 && rd_addr_4t_b >= 3'd6);
    wire addr4t_c_hits_hold = (hold_reg_addr == 4'd1 && rd_addr_4t_c <= 3'd2) ||
                            (hold_reg_addr == 4'd2 && rd_addr_4t_c >= 3'd3 && rd_addr_4t_c <= 3'd5) ||
                            (hold_reg_addr == 4'd3 && rd_addr_4t_c >= 3'd6);


    
    //shared read ports
    wire [23:0] shared_rd_12t = read_any_reg_12t(
        rd_addr_12t, using_macroop_1, alias_addr_12t, am_buff_12t,
        sp0_trib0, sp0_trib1, sp0_trib2, sp1_trib0, sp1_trib1, sp1_trib2,
        spf_trib0, spf_trib1, spf_trib2, mac_a, mac_b, mac_d,
        pc_r_data, gp_reg_6, gp_reg_7, gp_reg_8,
        cmd0_reg_0, cmd0_reg_1, cmd0_reg_2, cmd0_reg_3, cmd0_reg_4, cmd0_reg_5,
        cmd1_reg_0, cmd1_reg_1, cmd1_reg_2, cmd1_reg_3, cmd1_reg_4, cmd1_reg_5
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

//main
always @(posedge clk) begin
    if (!rst_n) begin

        //control & state        
        // prev_reg_addr  <= 5'd0;
        // prev_reg_stage <= 2'b00;
        // prev_is_read   <= 1'b0;
        // spi_tx_data    <= 12'd0;
        // spi_tx_start   <= 1'b0;
        // spi_clk_div    <= 4'd4;
        // spi_div_we     <= 1'b0;
        write_allow        <= 1'b1;
        // threadstate        <= THREAD_EMPTY;
        // macroop_register   <= 16'b0;
        // using_macroop_1    <= 1'b0;
        // cmd_param_id       <= 3'd1;      // 1-indexed to match commandpipe_address (1..6)
        // //cmd_param_reg      <= 24'hAAAAAA;
        // ret_micro          <= 1'b0;
        // cmd_done       <= 1'b0;
        execute_stage      <= 2'b00;
        // pulses and handshakes
        // cmd_buf_clr_ack    <= 1'b0;
        // single_execute_ack <= 1'b0;
        pc_inc_enable       <= 1'b0;
        pc_w_enable        <= 1'b0;
        //pc_w_data          <= 24'hAAAAAA;
        // cmd_we             <= 1'b0;
        //macroop_pipe_full      <= 1'b0;
        //debug_reg_cache    <= 24'hAAAAAA;
        //dbg_dout           <= 8'hAA;

        //aliases
        // action_ctr         <= 7'd0;
        // param_ctr          <= 7'd0;
        alias_addr_12t     <= 4'b0;
        alias_addr_4t      <= 3'b0;
        alias_addr_1t      <= 3'b0;
        alias_active_4t    <= 1'b0;
        alias_active_1t    <= 1'b0;
        am_buff_12t        <= 24'h555555;
        am_buff_4t         <= 8'h55;
        am_buff_1t         <= 2'b01;

        //uhhhh
        // loading_second_slot <= 1'b0;

        //top reggies
        // {sp0_trib2, sp0_trib1, sp0_trib0} <= 24'hAAAAAA;
        // {sp1_trib2, sp1_trib1, sp1_trib0} <= 24'hAAAAAA;
        // {spf_flag7, spf_flag6, spf_flag5, spf_flag4,
        //  spf_flag3, spf_flag2, spf_flag1, spf_flag0} <= 16'hAAAA;
        // {mac_a,mac_b,mac_c,mac_d} <= 32'hAAAAAAAA;
        mac_carry <= 2'b10;
        reg_ovf_r <= 1'b0;
        // gp_reg_6    <= 24'hAAAAAA; gp_reg_7     <= 24'hAAAAAA; gp_reg_8     <= 24'hAAAAAA;
        // cmd0_reg_0  <= 24'hAAAAAA; cmd0_reg_1   <= 24'hAAAAAA; cmd0_reg_2   <= 24'hAAAAAA;
        // cmd0_reg_3  <= 24'hAAAAAA; cmd0_reg_4   <= 24'hAAAAAA; cmd0_reg_5   <= 24'hAAAAAA;
        // cmd1_reg_0  <= 24'hAAAAAA; cmd1_reg_1   <= 24'hAAAAAA; cmd1_reg_2   <= 24'hAAAAAA;
        // cmd1_reg_3  <= 24'hAAAAAA; cmd1_reg_4   <= 24'hAAAAAA; cmd1_reg_5   <= 24'hAAAAAA;


        // //execution state resets
        // alu_res_4t_lat <= 8'hAA;
        // alu_res_1t_lat <= 2'b10;
        // alu_res_mul_lat <= 16'hAAAA;
        // hold_reg_addr <= 4'b0;
        // hold_reg_active <= 1'b0;
        carry_reg <= 2'b10;
        // request_show_reg      <= 1'b0;
        // request_set_pc        <= 1'b0;
        // request_memory_access <= 1'b0;
        // is_write_memory       <= 1'b0;
        // ext_addr_out          <= 16'hAAAA; // 8 trits of canonical zero
        // cmd_target_bank <= 1'b0;
        // pc_tx_pending <= 1'b0;
        // ucode_state           <= ST_IDLE; 
        // ucode_address         <= 12'd0;
        // wait_cnt              <= 4'd0;
        // ucode_req             <= 1'b0;
        // ucode_data_ready      <= 1'b0;
        // has_cached_odd        <= 1'b0;
        mask_12t_singleuse    <= 1'b0;
        mask_4t_singleuse     <= 1'b0;
        mask_1t_singleuse     <= 1'b0;
        
        exec_valid                 <= 1'b0;
        exec_cmd                   <= 4'd0;
        exec_p0                    <= 4'd0;
        exec_p1                    <= 4'd0;
        exec_p2                    <= 4'd0;
        cmd_done                   <= 1'b0;
        pc_w_data                  <= 24'd0;
        reg_ovf_r                  <= 1'b0;
        offending_id_r             <= 4'd0;
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
    end else begin
        cmd_done        <= 1'b0;
        pc_inc_enable   <= 1'b0;
        pc_w_enable     <= 1'b0;
        reg_ovf_r       <= 1'b0;
        do_housekeeping  = 1'b0;

        //command fetch and housekeep
        if (!exec_valid && execute_stage == 2'b00) begin
            do_housekeeping = 1'b1;
            if (cmd_valid) begin
                exec_cmd   <= cmd;
                exec_p0    <= param_0;
                exec_p1    <= param_1;
                exec_p2    <= param_2;
                exec_valid <= 1'b1;
            end

        //decode
        end else if (exec_valid && execute_stage == 2'b00) begin
            if (sub_alias_stall) begin
                do_housekeeping = 1'b1; //if alias conflict, flush here
            end else begin
                case (exec_cmd)
                    
                    4'b0000: begin
                        exec_valid <= 1'b0;
                        cmd_done   <= 1'b1;
                        case(exec_p0)
                            4'b0001: begin
                                //mac ladder flush
                                if(write_allow) begin
                                    {mac_a,mac_b,mac_c,mac_d} <= 32'hAAAAAAAA;
                                    mac_carry <= 2'b10;
                                end
                            end
                            4'b0010: begin
                                //clear carry
                                if(write_allow) begin
                                    carry_reg <= 2'b10;
                                end
                            end
                            4'b0011: begin
                                //reset mask/alias
                                if(write_allow) begin
                                    am_buff_12t <= 24'h555555;
                                    am_buff_4t <= 8'h55;
                                    am_buff_1t <= 2'b01;
                                    alias_active_1t <= 1'b0;
                                    alias_active_4t <= 1'b0;
                                    alias_addr_12t <= 4'd0;
                                end
                            end
                            // 4'b0100: begin
                            //     //return
                            //     ret_micro <= 1'b1;
                            //     action_ctr <= 7'd0;
                            //     param_ctr  <= 7'd0;
                            //     has_cached_odd   <= 1'b0;
                            //     cmd_done     <= 1'b0;
                            //     //maybe unfinished
                            //     //purge all cached microcode on the handler side

                            // end
                            4'b0101: begin
                                //disable write
                                write_allow <= 1'b0;
                            end
                            4'b0110: begin
                                //enable write
                                write_allow <= 1'b1; //do not clear on a clockly basis 
                            end
                            4'b0111: begin
                                //clear scratchpads
                                if(write_allow) begin
                                    {sp0_trib2, sp0_trib1, sp0_trib0} <= 24'hAAAAAA;
                                    {sp1_trib2, sp1_trib1, sp1_trib0} <= 24'hAAAAAA;
                                    if (alias_addr_12t == 4'd1 || alias_addr_12t == 4'd2) alias_addr_12t <= 4'd0;
                                    if (alias_active_4t && alias_addr_4t <= 3'd5)         alias_active_4t <= 1'b0;
                                end
                            end
                            4'b1000: begin
                                //clear general purpose registers
                                if(write_allow) begin
                                    gp_reg_6 <= 24'hAAAAAA;
                                    gp_reg_7 <= 24'hAAAAAA;
                                    gp_reg_8 <= 24'hAAAAAA;
                                    if (alias_addr_12t >= 4'd6 && alias_addr_12t <= 4'd8) alias_addr_12t <= 4'd0;
                                end
                            end
                            // 4'b1001: begin
                            //     //we need request next command here
                            //     //when pulled high, this should prompt to cycle threads 
                            //     //stall until next macro command is in
                            //     //to prevent a permanent stall, do nothing if direct instr is up
                            //     if (!direct_instr && (threadstate != THREAD_FULL)) begin
                            //         execute_stage   <= 2'b01; // Wait in Stage 1
                            //         cmd_done    <= 1'b0;
                            //     end else begin
                            //         cmd_done    <= 1'b1;  // Already full or direct_instr active -> continue
                            //     end
                            // end
                            4'b1010: begin
                                //only housekeep
                                //no moar threads
                                do_housekeeping  = 1'b1;
                                //this needs to be implemented on all sides
                            end
                            4'b1011: begin
                                //program counter increment
                                pc_inc_enable <= 1'b1;
                                // start_bus_tx(TX_SET_PC, 24'hAAAAAA, pc_r_data);
                                //blocking or non blocking here?
                                //remember to always request a pc update when we change it inside here to prevent desync after each macro op and also for situations like these
                            end
                            4'b1100: begin
                                //mac pump (destinationless)
                                if (write_allow) begin
                                    mac_a <= mac_c;
                                    mac_b <= mac_d;
                                end
                            end
                            4'b1101: begin
                                //mac add but just takes whatever is in spot c and throws it onto b, clearing c in the process
                                if (write_allow) begin
                                    alu_command   <= 3'd1;
                                    alu_t4_a      <= mac_b;
                                    alu_t4_b      <= mac_c;
                                    alu_t1_a      <= mac_carry;
                                    execute_stage <= 2'b01;
                                    cmd_done      <= 1'b0;
                                    exec_valid <= 1'b1;
                                end
                            end

                            default: ;
                        endcase
                    end

                    4'b0001: begin
                        exec_valid <= 1'b0;
                        cmd_done   <= 1'b1;
                        case(exec_p0)
                            4'b0001: begin
                                //mac read with imm
                                //due to space limitations, this is constrained to 4 4t scratchpads, which are the 3 in sp1 and flag
                                /*
                                task write_any_reg_4t;
                                input use_mask;
                                input write_allow;
                                input [2:0] addr_4t;
                                inout       alias_active_4t;
                                input [2:0] alias_addr_4t;
                                input [7:0] data_4t;

                                inout [7:0] am_4t;
                                output [7:0] sp0_t0, sp0_t1, sp0_t2;
                                output [7:0] sp1_t0, sp1_t1, sp1_t2;
                                output [7:0] spf_t0, spf_t1;

                                reg [7:0] wdata;
                                begin                             


                                input       use_mask;
                                    input       w_allow;
                                    input [2:0] addr_4t;
                                    input [7:0] data_4t;
                                    reg   [7:0] wdata;
                                    begin
                                */

                                case(exec_p1[1:0])
                                    2'b00:write_any_reg_4t(1'b0,write_allow,{1'b0, exec_p1[3:2]} + 2'd3,mac_a);
                                    2'b01:write_any_reg_4t(1'b0,write_allow,{1'b0, exec_p1[3:2]} + 2'd3,mac_b);
                                    2'b10:write_any_reg_4t(1'b0,write_allow,{1'b0, exec_p1[3:2]} + 2'd3,mac_c);
                                    2'b11:write_any_reg_4t(1'b0,write_allow,{1'b0, exec_p1[3:2]} + 2'd3,mac_d);
                                endcase
                            end
                            4'b0010: begin
                                //mac pump. param is overflow destination
                                if(write_allow) begin
                                    write_any_reg_4t(exec_p1[0],1'b1,exec_p1[3:1],mac_a);
                                    mac_a <= mac_c;
                                    mac_b <= mac_d;
                                end
                            end
                            4'b0011: begin
                                //clear 4 trits of scratch/mac
                                //4 trit chunk address
                                // Xxx0: clear scratchpads
                                // Xxx1: clear mac ladder section
                                if(write_allow) begin
                                    if(exec_p1[0]) begin
                                        case(exec_p1[3:1])
                                        3'b000: mac_a <= 8'hAA;
                                        3'b001: mac_b <= 8'hAA;
                                        3'b010: mac_c <= 8'hAA;
                                        3'b011: mac_d <= 8'hAA;
                                        endcase
                                    end
                                    else begin
                                        write_any_reg_4t(1'b0,1'b1,exec_p1[3:1],8'hAA);
                                        if(alias_active_4t && alias_addr_4t == exec_p1[3:1]) begin
                                            //clear alias
                                            alias_active_4t <= 1'b0;
                                            am_buff_4t <= 8'h55;
                                        end
                                    end
                                end
                            end
                            
                            4'b0101,4'b0110: begin
                                if(alias_addr_12t == 4'd0) begin
                                    if(write_allow) begin
                                        am_buff_12t <= shared_rd_12t;
                                        mask_12t_singleuse <= (exec_p0 == 4'b0101);//singleuse
                                    end
                                end
                                else begin
                                    do_housekeeping = 1'b1;
                                    execute_stage <= 2'b01;
                                    exec_valid <= 1'b1;
                                    cmd_done <= 1'b0;
                                    //housekeep to clear aliases first
                                end
                                    //remember for masks if aliasing is active remember they share the same registers so clear the aliases first
                                    //set single use mask for 12 trits
                                    //the value at that 12t address will be copied into the mask buffer
                                    //param 1 is the addresss of the 12 trits that will be copied into the mask
                            end
                            4'b0111: begin
                                //4t mask
                                if(!alias_active_4t) begin
                                        if(write_allow) begin
                                        am_buff_4t <= shared_rd_4t_a;
                                        //xxx0 : single use
                                        //xxx1 : will not clear
                                        mask_4t_singleuse <= ~exec_p1[0];
                                    end
                                end else begin
                                    //housekeep
                                    do_housekeeping = 1'b1;
                                    execute_stage <= 2'b01;
                                    exec_valid <= 1'b1;
                                    cmd_done <= 1'b0;
                                end
                            end
                            4'b1000: begin
                                //1t mask
                                if(!alias_active_1t) begin
                                    if(write_allow) begin
                                        am_buff_1t <= shared_rd_1t_a;
                                        //xxx0 : single use
                                        //xxx1 : will not clear
                                        mask_1t_singleuse <= ~exec_p1[0];
                                    end
                                end else begin
                                    //housekeep
                                    exec_valid <= 1'b1;
                                    do_housekeeping = 1'b1;
                                    execute_stage <= 2'b01;
                                    cmd_done <= 1'b0;
                                end
                            end
                            
                            /*
                                4'b0100: begin
                                    //hold until register change
                                    //when a micro op with that register being used is reached, it must make sure the register is updated BEFORE it can proceed
                                    //12t register address
                                    hold_reg_addr   <= exec_p1;
                                    hold_reg_active <= 1'b1;
                                end
                                4'b1001: begin
                                    //hop micro op 4 trit address
                                    //xxx0 : action
                                    //xxx1 : param
                                    //xxx is the address of the 4 trit chunk
                                    if(write_allow) begin
                                        if(exec_p1[0] == 1'b0) begin
                                            //xxx0 : action
                                            action_ctr <= hop_bin_val;
                                        end else begin
                                            //xxx1 : param
                                            param_ctr <= hop_bin_val;
                                        end
                                        trigger_ucode_flush;
                                        cmd_done <= 1'b1;
                                    end
                                end
                                4'b1010: begin
                                    //read 12 trits of memory to that address (the memory address is overwritten from there)
                                    //this works to provide memory read writes
                                    //this needs to work in conjunction with the memory bus
                                    //need 2 finish
                                    start_bus_tx(TX_MEM_READ, shared_rd_12t, 24'hAAAAAA);
                                end
                                4'b1011: begin
                                    //alu hogging
                                    //for big operations that need alu max priority on all processes
                                    //param 1 is a binary number up to 16
                                    //free space
                                end
                                4'b1100: begin
                                    //save to the extended memory address (so you can get up to 9.7GiB of addressable ram)
                                    //this gets sent to the thread manager and saved there
                                    //each thread has their own little memory address
                                    if (write_allow) ext_addr_out <= shared_rd_12t[15:0];
                                end
                                4'b1101: begin
                                    //show register data on bus
                                    //param 1 is reg addr
                                    start_bus_tx(TX_SHOW_REG, 24'hAAAAAA, shared_rd_12t);
                                    // d_out <= shared_rd_12t; request_show_reg <= 1'b1; execute_stage <= 2'b01; cmd_done <= 1'b0;
                                end
                                
                                4'b1110: begin
                                    //use the singular spi to do stuff i guess
                                    //param 1 is reg addr for spi, read as 24 bits
                                    //remember to add ownership stuff. send data to the thread control
                                    //placeholder
                                    cmd_done <= 1'b1;
                                    execute_stage <= 2'b00;
                                    // // Latch 12 trits (1 for +1, 0 otherwise) and request SPI shift
                                    // cmd_done <= 1'b0;
                                    // if (!spi_busy) begin
                                    //     spi_tx_data   <= trits12_to_spi12(shared_rd_12t);
                                    //     spi_tx_start  <= 1'b1;
                                    //     execute_stage <= 2'b01;
                                    // end
                                end
                                4'b1111: begin
                                    //disabled due to lack of pins
                                    // // Set SPI clock division (1..15 of input clock)
                                    // if (write_allow) begin
                                    //     spi_clk_div <= (exec_p1 == 4'd0) ? 4'd1 : exec_p1;
                                    //     spi_div_we  <= 1'b1;
                                    // end
                                end
                            */
                            default: ;
                        endcase
                    end

                    4'b0010: begin
                        // 2 parameters
                        case(exec_p0)
                            4'b0000,4'b0010: begin
                                //register A copy to register B (12 trits) without mask
                                //param1 regA addr
                                //param2 regB addr
                                //we are strapped for addresses so this will have to do
                                tmp_12t_lat   <= shared_rd_12t; //latch source before Stage 1
                                execute_stage <= 2'b01;
                                //register A copy to register B (12 trits) with mask
                                //param1 regA addr
                                //param2 regB addr
                            end
                            //by collapsing all of the commands to deal with them later, we need not deal with them now
                            4'b0001, 4'b0011, 4'b0100, 4'b1101,4'b1100: begin
                                if (alias_addr_12t != 4'd0) do_housekeeping = 1'b1;
                                execute_stage <= 2'b01;
                            end
                            4'b0101: begin
                                //due to the shoddy construction of things, you cant swap and mask
                                //reg swap 12t
                                //param 1 and 2 : addresses of A and B
                                if (alias_addr_12t != 4'd0) do_housekeeping = 1'b1;
                                tmp_12t_lat   <= shared_rd_12t;
                                execute_stage <= 2'b01;
                            end
                            4'b0110: begin
                                //reg swap 4t
                                //param 1 and 2 : addresses of A and B
                                if (alias_active_4t) do_housekeeping = 1'b1;
                                execute_stage <= 2'b01;
                            end
                            4'b0111: begin
                                //reg swap 1t
                                //param 1 and 2 : addresses of A and B
                                if (alias_active_1t) do_housekeeping = 1'b1;
                                execute_stage <= 2'b01;
                            end
                            
                            /*
                                4'b1000: begin
                                    //read extended register (the extended register is basically just ram stored on another fpga)
                                    //param 1 Local reg addr 12T
                                    //param 2 Extended reg addr 12t
                                    start_bus_tx(TX_MEM_READ, {16'h0000, exec_p2, 4'hA}, 24'hAAAAAA);
                                end
                                4'b1001: begin
                                    //write extended register
                                    //param 1 Local reg addr 12T
                                    //param 2 Extended reg addr 12t
                                    if (write_allow) start_bus_tx(TX_MEM_WRITE, {16'h0000, exec_p2, 4'hA}, shared_rd_12t);
                                    else             cmd_done <= 1'b1;
                                    //if (write_allow)
                                    //     start_bus_tx(TX_MEM_WRITE, mem_addr_24b, mem_data_24b);
                                    // else
                                    //     cmd_done <= 1'b1;
                                end
                                4'b1010: begin
                                    //hop parameter counter using immediate
                                    if (write_allow) begin
                                        param_ctr <= hop_bin_val;
                                        trigger_ucode_flush;
                                    end
                                    cmd_done <= 1'b1;
                                    //param 1 t3 t2
                                    //param 2 t1 t0
                                    //trits are encoded into 2 bits, using override encoding
                                end
                                4'b1011: begin
                                    //hop action counter using immediate
                                    //param 1 t3 t2
                                    //param 2 t1 t0
                                    //trits are encoded into 2 bits, using override encoding
                                    if (write_allow) begin
                                        action_ctr <= hop_bin_val;
                                        trigger_ucode_flush;
                                    end
                                    cmd_done <= 1'b1;
                                end
                                4'b1100: begin
                                    //Generate mask
                                    //param 1
                                    // 0 << error
                                    // 1-3 4 trit mask at positions
                                    // 4-15 1 trit mask

                                    //param 2
                                    //1 trit immediate value and 1 bit is how long it stays, 1 bit is unused
                                end
                                4'b1101: begin
                                    //generate value
                                    //param1 : 1 trit fill value, 2 bits to distinguish 00 = 12 trits 01 = 4 trits 10 = 1 trit
                                    //param2 target addresses
                                    //for only 3 bit addresses, the last bit can be anythhing: xxx0 / xxx1 are both ok 
                                end
                                4'b1110: begin
                                    //write 12 trits to the next command space
                                    //param 1: ADDR from
                                    //param 2: ADDR to 
                                end
                            */
                            4'b1111: begin
                                //mac mul without pumping
                                //OR mac move
                                alu_command       <= 3'd2;
                                alu_t4_a      <= shared_rd_4t_a;
                                alu_t4_b      <= shared_rd_4t_b;
                                execute_stage <= 2'b01;
                            end
                            default: begin
                                exec_valid <= 1'b0;
                                cmd_done <= 1'b1;
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