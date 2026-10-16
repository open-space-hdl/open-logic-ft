---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library vunit_lib;
    context vunit_lib.vunit_context;
    context vunit_lib.com_context;
    context vunit_lib.vc_context;

library olo;
    use olo.olo_base_pkg_math.all;
    use olo.olo_base_pkg_logic.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
-- Stimuli and expected outputs come from the Python model (cosim.py).
-- vunit: run_all_in_same_sim
entity olo_base_rs_decode_tb is
    generic (
        SymbolWidth_g     : positive := 8;
        FieldPolynomial_g : natural  := 16#87#;
        CodewordSymbols_g : positive := 255;
        DataSymbols_g     : positive := 223;
        FirstRoot_g       : natural  := 212;
        RootStep_g        : positive := 11;
        InterleaveDepth_g : positive := 1;
        DualBasis_g       : natural  := 117;
        OutputParity_g    : boolean  := false;
        RandomStall_g     : boolean  := false;
        output_path       : string;
        runner_cfg        : string
    );
end entity;

architecture sim of olo_base_rs_decode_tb is

    -----------------------------------------------------------------------------------------------
    -- Constants
    -----------------------------------------------------------------------------------------------
    constant ClkPeriod_c  : time                                         := 10 ns;
    constant Poly_c       : std_logic_vector(SymbolWidth_g - 1 downto 0) := toUslv(FieldPolynomial_g, SymbolWidth_g);
    constant T_c          : natural                                      := (CodewordSymbols_g - DataSymbols_g) / 2;
    constant CntBits_c    : positive                                     := log2ceil(T_c + 1);
    -- Output stall of the OutputStall test: long enough for the key equation solver to process a block
    constant Hold_c       : positive := 2 * InterleaveDepth_g * (CodewordSymbols_g - DataSymbols_g + 2) + 50;
    -- Symbols of the equal full blocks at the start of the sequence (cosim.py)
    constant Continuous_c : positive := 4 * InterleaveDepth_g * CodewordSymbols_g;
    -- Condition for continuous operation (documentation): I*n >= I*(2t+3) + 2t + 3
    constant ContOk_c     : boolean := InterleaveDepth_g * CodewordSymbols_g >= InterleaveDepth_g * (2 * T_c + 3) + 2 * T_c + 3;

    -- *** Verification Components ***
    constant AxisMaster_c : axi_stream_master_t := new_axi_stream_master (
        data_length  => SymbolWidth_g,
        stall_config => new_stall_config(choose(RandomStall_g, 0.5, 0.0), 0, 10)
    );
    -- The TDATA check of the VUnit slave compares whole bytes only (VUnit issue #1238): pad the symbols to bytes
    constant VcWidth_c    : positive           := 8 * ((SymbolWidth_g + 7) / 8);
    constant AxisSlave_c  : axi_stream_slave_t := new_axi_stream_slave (
        data_length  => VcWidth_c,
        user_length  => 1,
        stall_config => new_stall_config(choose(RandomStall_g, 0.5, 0.0), 0, 10)
    );

    -----------------------------------------------------------------------------------------------
    -- Interface Signals
    -----------------------------------------------------------------------------------------------
    signal Clk                  : std_logic := '0';
    signal Rst                  : std_logic := '1';
    signal In_Valid             : std_logic;
    signal In_Ready             : std_logic;
    signal In_Data              : std_logic_vector(SymbolWidth_g - 1 downto 0);
    signal In_Last              : std_logic;
    signal Out_Valid            : std_logic;
    signal Out_Ready            : std_logic;
    signal Out_Data             : std_logic_vector(SymbolWidth_g - 1 downto 0);
    signal Out_Parity           : std_logic;
    signal Out_Last             : std_logic;
    signal Out_DataVc           : std_logic_vector(VcWidth_c - 1 downto 0);
    signal Out_ValidVc          : std_logic;
    signal Out_ReadyVc          : std_logic;
    signal Status_Valid         : std_logic;
    signal Status_Last          : std_logic;
    signal Status_Corrected     : std_logic_vector(CntBits_c - 1 downto 0);
    signal Status_Uncorrectable : std_logic;

    -- *** TB Signals ***
    signal StatusCount  : natural   := 0;
    signal OutLastCount : natural   := 0;
    signal OutHold      : std_logic := '0';
    signal HoldEna      : boolean   := false;
    signal InputCount   : natural   := 0;
    signal InStallCount : natural   := 0;

    -----------------------------------------------------------------------------------------------
    -- Procedures
    -----------------------------------------------------------------------------------------------
    -- Push the received symbols of the model (dec_in.csv: symbol, last), at most count symbols (-1: all)
    procedure pushInput (
        signal net : inout network_t;
        count      : in    integer := -1) is
        variable Vec_v  : integer_array_t;
        variable Rows_v : natural;
        variable Data_v : std_logic_vector(SymbolWidth_g - 1 downto 0);
        variable Last_v : std_logic;
    begin
        Vec_v  := load_csv(output_path & "dec_in.csv");
        Rows_v := height(Vec_v);
        if count >= 0 and count < Rows_v then
            Rows_v := count;
        end if;

        for i in 0 to Rows_v - 1 loop
            Data_v := toUslv(get(Vec_v, 0, i), SymbolWidth_g);
            Last_v := choose(get(Vec_v, 1, i) = 1, '1', '0');
            push_axi_stream(net, AxisMaster_c, Data_v, tlast => Last_v);
        end loop;

    end procedure;

    -- Expect the output symbols of the model (dec_out.csv: symbol, check symbol, last)
    procedure expectOutput (
        signal net : inout network_t) is
        variable Vec_v  : integer_array_t;
        variable Data_v : std_logic_vector(VcWidth_c - 1 downto 0);
        variable User_v : std_logic_vector(0 downto 0);
        variable Last_v : std_logic;
    begin
        Vec_v := load_csv(output_path & "dec_out.csv");

        for i in 0 to height(Vec_v) - 1 loop
            Data_v := toUslv(get(Vec_v, 0, i), VcWidth_c);
            User_v := toUslv(get(Vec_v, 1, i), 1);
            Last_v := choose(get(Vec_v, 2, i) = 1, '1', '0');
            check_axi_stream(net, AxisSlave_c, Data_v, tlast => Last_v, tuser => User_v, blocking => false, msg => "symbol " & integer'image(i));
        end loop;

    end procedure;

    -- Number of status entries of the model (dec_status.csv: corrected, uncorrectable, last, blocks with output)
    impure function statusEntries return natural is
    begin
        return height(load_csv(output_path & "dec_status.csv"));
    end function;

begin

    -----------------------------------------------------------------------------------------------
    -- TB Control
    -----------------------------------------------------------------------------------------------
    test_runner_watchdog(runner, 100 ms);

    p_control : process is
    begin
        test_runner_setup(runner, runner_cfg);

        while test_suite loop

            -- Reset
            wait until rising_edge(Clk);
            HoldEna <= false;
            Rst     <= '1';
            wait for 100 ns;
            wait until rising_edge(Clk);
            Rst     <= '0';
            wait until rising_edge(Clk);

            -- Check the block sequence of the model: data, check symbols and status
            if run("ModelVectors") then
                pushInput(net);
                expectOutput(net);

            -- A reset in the middle of a block discards the block
            elsif run("ResetMidBlock") then
                pushInput(net, 5);
                wait_until_idle(net, as_sync(AxisMaster_c));
                wait for 200 ns;
                wait until rising_edge(Clk);
                Rst <= '1';
                wait until rising_edge(Clk);
                Rst <= '0';
                pushInput(net);
                expectOutput(net);

            -- Long output stalls at the start and near the end of the blocks
            elsif run("OutputStall") then
                HoldEna <= true;
                pushInput(net);
                expectOutput(net);

            -- Equal full blocks are accepted without a gap if the documented condition holds (without random stalls)
            elsif run("Continuous") then
                pushInput(net);
                expectOutput(net);
                wait until InputCount >= Continuous_c;
                if not RandomStall_g and ContOk_c then
                    check_equal(InStallCount, 0, "In_Ready low during equal full blocks");
                end if;
            end if;

            -- Wait for idle and all status pulses
            wait_until_idle(net, as_sync(AxisMaster_c));
            wait_until_idle(net, as_sync(AxisSlave_c));
            wait until StatusCount = statusEntries for 1 ms;
            check_equal(StatusCount, statusEntries, "number of status pulses");
            wait for 1 us;
            check_equal(StatusCount, statusEntries, "no further status pulses");

        end loop;

        -- TB done
        test_runner_cleanup(runner);
    end process;

    -----------------------------------------------------------------------------------------------
    -- Status checker
    -----------------------------------------------------------------------------------------------
    -- Values, pulses of a block on consecutive cycles, no status before the Out_Last of its block was accepted
    p_status : process (Clk) is
        variable Vec_v     : integer_array_t;
        variable Idx_v     : natural := 0;
        variable InBlock_v : boolean := false;
    begin
        if rising_edge(Clk) then
            if Rst = '1' then
                Idx_v       := 0;
                InBlock_v   := false;
                StatusCount <= 0;
            elsif Status_Valid = '1' then
                if Idx_v = 0 then
                    Vec_v := load_csv(output_path & "dec_status.csv");
                end if;
                if Idx_v < height(Vec_v) then
                    check_equal(to_integer(unsigned(Status_Corrected)), get(Vec_v, 0, Idx_v), "Status_Corrected " & integer'image(Idx_v));
                    check_equal(Status_Uncorrectable, choose(get(Vec_v, 1, Idx_v) = 1, '1', '0'), "Status_Uncorrectable " & integer'image(Idx_v));
                    check_equal(Status_Last, choose(get(Vec_v, 2, Idx_v) = 1, '1', '0'), "Status_Last " & integer'image(Idx_v));
                    check(OutLastCount >= get(Vec_v, 3, Idx_v), "status " & integer'image(Idx_v) & " before Out_Last");
                else
                    error("unexpected status pulse");
                end if;
                InBlock_v   := Status_Last = '0';
                Idx_v       := Idx_v + 1;
                StatusCount <= Idx_v;
            else
                check(not InBlock_v, "gap in the status pulses of a block");
                InBlock_v := false;
            end if;
        end if;
    end process;

    -- Output stalls before the symbols listed in dec_hold.csv (OutputStall test)
    p_hold : process (Clk) is
        variable Vec_v    : integer_array_t;
        variable Loaded_v : boolean := false;
        variable Beats_v  : natural := 0;
        variable Next_v   : natural := 0;
        variable Cnt_v    : natural := 0;
    begin
        if rising_edge(Clk) then
            if Rst = '1' or not HoldEna then
                Beats_v := 0;
                Next_v  := 0;
                Cnt_v   := 0;
                OutHold <= '0';
            else
                if not Loaded_v then
                    Vec_v    := load_csv(output_path & "dec_hold.csv");
                    Loaded_v := true;
                end if;
                if Out_Valid = '1' and Out_Ready = '1' then
                    Beats_v := Beats_v + 1;
                end if;
                if Cnt_v > 0 then
                    Cnt_v := Cnt_v - 1;
                    if Cnt_v = 0 then
                        OutHold <= '0';
                    end if;
                elsif Next_v < height(Vec_v) and Beats_v = get(Vec_v, 0, Next_v) then
                    OutHold <= '1';
                    Cnt_v   := Hold_c;
                    Next_v  := Next_v + 1;
                end if;
            end if;
        end if;
    end process;

    -- Accepted Out_Last symbols
    p_outlast : process (Clk) is
    begin
        if rising_edge(Clk) then
            if Rst = '1' then
                OutLastCount <= 0;
            elsif Out_Valid = '1' and Out_Ready = '1' and Out_Last = '1' then
                OutLastCount <= OutLastCount + 1;
            end if;
        end if;
    end process;

    -- Input stall monitor for the equal full blocks at the start
    p_stall : process (Clk) is
    begin
        if rising_edge(Clk) then
            if Rst = '1' then
                InputCount   <= 0;
                InStallCount <= 0;
            else
                if In_Valid = '1' and In_Ready = '1' then
                    InputCount <= InputCount + 1;
                end if;
                if In_Valid = '1' and In_Ready = '0' and InputCount > 0 and InputCount < Continuous_c then
                    InStallCount <= InStallCount + 1;
                end if;
            end if;
        end if;
    end process;

    -----------------------------------------------------------------------------------------------
    -- Clock
    -----------------------------------------------------------------------------------------------
    Clk <= not Clk after 0.5 * ClkPeriod_c;

    -----------------------------------------------------------------------------------------------
    -- DUT
    -----------------------------------------------------------------------------------------------
    i_dut : entity olo.olo_base_rs_decode
        generic map (
            FieldPolynomial_g => Poly_c,
            CodewordSymbols_g => CodewordSymbols_g,
            DataSymbols_g     => DataSymbols_g,
            FirstRoot_g       => FirstRoot_g,
            RootStep_g        => RootStep_g,
            InterleaveDepth_g => InterleaveDepth_g,
            DualBasis_g       => DualBasis_g,
            OutputParity_g    => OutputParity_g
        )
        port map (
            Clk                  => Clk,
            Rst                  => Rst,
            In_Valid             => In_Valid,
            In_Ready             => In_Ready,
            In_Data              => In_Data,
            In_Last              => In_Last,
            Out_Valid            => Out_Valid,
            Out_Ready            => Out_Ready,
            Out_Data             => Out_Data,
            Out_Parity           => Out_Parity,
            Out_Last             => Out_Last,
            Status_Valid         => Status_Valid,
            Status_Last          => Status_Last,
            Status_Corrected     => Status_Corrected,
            Status_Uncorrectable => Status_Uncorrectable
        );

    -----------------------------------------------------------------------------------------------
    -- Verification Components
    -----------------------------------------------------------------------------------------------
    vc_stimuli : entity vunit_lib.axi_stream_master
        generic map (
            Master => AxisMaster_c
        )
        port map (
            Aclk   => Clk,
            TValid => In_Valid,
            TReady => In_Ready,
            TData  => In_Data,
            TLast  => In_Last
        );

    Out_DataVc  <= std_logic_vector(resize(unsigned(Out_Data), VcWidth_c));
    Out_ValidVc <= Out_Valid and not OutHold;
    Out_Ready   <= Out_ReadyVc and not OutHold;

    vc_response : entity vunit_lib.axi_stream_slave
        generic map (
            Slave => AxisSlave_c
        )
        port map (
            Aclk     => Clk,
            TValid   => Out_ValidVc,
            TReady   => Out_ReadyVc,
            TData    => Out_DataVc,
            TLast    => Out_Last,
            TUser(0) => Out_Parity
        );

end architecture;
