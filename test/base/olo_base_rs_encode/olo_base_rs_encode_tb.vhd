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
entity olo_base_rs_encode_tb is
    generic (
        SymbolWidth_g     : positive := 8;
        FieldPolynomial_g : natural  := 16#87#;
        CodewordSymbols_g : positive := 255;
        DataSymbols_g     : positive := 223;
        FirstRoot_g       : natural  := 212;
        RootStep_g        : positive := 11;
        InterleaveDepth_g : positive := 1;
        DualBasis_g       : natural  := 117;
        RandomStall_g     : boolean  := false;
        output_path       : string;
        runner_cfg        : string
    );
end entity;

architecture sim of olo_base_rs_encode_tb is

    -----------------------------------------------------------------------------------------------
    -- Constants
    -----------------------------------------------------------------------------------------------
    constant ClkPeriod_c    : time                                         := 10 ns;
    constant Poly_c         : std_logic_vector(SymbolWidth_g - 1 downto 0) := toUslv(FieldPolynomial_g, SymbolWidth_g);
    -- Symbols before the reset of test ResetMidBlock: less than the first (full) block
    constant PartialBlock_c : positive := minimum(5, InterleaveDepth_g * DataSymbols_g - 1);

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
    signal Clk        : std_logic := '0';
    signal Rst        : std_logic := '1';
    signal In_Valid   : std_logic;
    signal In_Ready   : std_logic;
    signal In_Data    : std_logic_vector(SymbolWidth_g - 1 downto 0);
    signal In_Last    : std_logic;
    signal Out_Valid  : std_logic;
    signal Out_Ready  : std_logic;
    signal Out_Data   : std_logic_vector(SymbolWidth_g - 1 downto 0);
    signal Out_Parity : std_logic;
    signal Out_Last   : std_logic;
    signal Out_DataVc : std_logic_vector(VcWidth_c - 1 downto 0);

    -----------------------------------------------------------------------------------------------
    -- Procedures
    -----------------------------------------------------------------------------------------------
    -- Push the input symbols of the model (enc_in.csv: symbol, last), at most count symbols (-1: all)
    procedure pushInput (
        signal net : inout network_t;
        count      : in    integer := -1) is
        variable Vec_v  : integer_array_t;
        variable Rows_v : natural;
        variable Data_v : std_logic_vector(SymbolWidth_g - 1 downto 0);
        variable Last_v : std_logic;
    begin
        Vec_v  := load_csv(output_path & "enc_in.csv");
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

    -- Expect the output symbols of the model (enc_out.csv: symbol, check symbol, last), at most count symbols (-1: all)
    procedure expectOutput (
        signal net : inout network_t;
        count      : in    integer := -1;
        file_name  : in    string  := "enc_out.csv") is
        variable Vec_v  : integer_array_t;
        variable Rows_v : natural;
        variable Data_v : std_logic_vector(VcWidth_c - 1 downto 0);
        variable User_v : std_logic_vector(0 downto 0);
        variable Last_v : std_logic;
    begin
        Vec_v  := load_csv(output_path & file_name);
        Rows_v := height(Vec_v);
        if count >= 0 and count < Rows_v then
            Rows_v := count;
        end if;

        for i in 0 to Rows_v - 1 loop
            Data_v := toUslv(get(Vec_v, 0, i), VcWidth_c);
            User_v := toUslv(get(Vec_v, 1, i), 1);
            Last_v := choose(get(Vec_v, 2, i) = 1, '1', '0');
            check_axi_stream(net, AxisSlave_c, Data_v, tlast => Last_v, tuser => User_v, blocking => false, msg => "symbol " & integer'image(i));
        end loop;

    end procedure;

begin

    -----------------------------------------------------------------------------------------------
    -- TB Control
    -----------------------------------------------------------------------------------------------
    test_runner_watchdog(runner, 50 ms);

    p_control : process is
    begin
        test_runner_setup(runner, runner_cfg);

        while test_suite loop

            -- Reset
            wait until rising_edge(Clk);
            Rst <= '1';
            wait for 100 ns;
            wait until rising_edge(Clk);
            Rst <= '0';
            wait until rising_edge(Clk);

            -- Check the block sequence of the model
            if run("ModelVectors") then
                pushInput(net);
                expectOutput(net);

            -- A reset in the middle of a block discards the block
            elsif run("ResetMidBlock") then
                pushInput(net, PartialBlock_c);
                -- The data symbols pass unchanged (the first block is a full block)
                expectOutput(net, PartialBlock_c, "enc_in_as_out.csv");
                wait_until_idle(net, as_sync(AxisMaster_c));
                wait_until_idle(net, as_sync(AxisSlave_c));
                wait until rising_edge(Clk);
                Rst <= '1';
                wait until rising_edge(Clk);
                Rst <= '0';
                pushInput(net);
                expectOutput(net);
            end if;

            -- Wait for idle
            wait_until_idle(net, as_sync(AxisMaster_c));
            wait_until_idle(net, as_sync(AxisSlave_c));
            wait for 1 us;

        end loop;

        -- TB done
        test_runner_cleanup(runner);
    end process;

    -----------------------------------------------------------------------------------------------
    -- Clock
    -----------------------------------------------------------------------------------------------
    Clk <= not Clk after 0.5 * ClkPeriod_c;

    -----------------------------------------------------------------------------------------------
    -- DUT
    -----------------------------------------------------------------------------------------------
    i_dut : entity olo.olo_base_rs_encode
        generic map (
            FieldPolynomial_g => Poly_c,
            CodewordSymbols_g => CodewordSymbols_g,
            DataSymbols_g     => DataSymbols_g,
            FirstRoot_g       => FirstRoot_g,
            RootStep_g        => RootStep_g,
            InterleaveDepth_g => InterleaveDepth_g,
            DualBasis_g       => DualBasis_g
        )
        port map (
            Clk        => Clk,
            Rst        => Rst,
            In_Valid   => In_Valid,
            In_Ready   => In_Ready,
            In_Data    => In_Data,
            In_Last    => In_Last,
            Out_Valid  => Out_Valid,
            Out_Ready  => Out_Ready,
            Out_Data   => Out_Data,
            Out_Parity => Out_Parity,
            Out_Last   => Out_Last
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

    Out_DataVc <= std_logic_vector(resize(unsigned(Out_Data), VcWidth_c));

    vc_response : entity vunit_lib.axi_stream_slave
        generic map (
            Slave => AxisSlave_c
        )
        port map (
            Aclk     => Clk,
            TValid   => Out_Valid,
            TReady   => Out_Ready,
            TData    => Out_DataVc,
            TLast    => Out_Last,
            TUser(0) => Out_Parity
        );

end architecture;
