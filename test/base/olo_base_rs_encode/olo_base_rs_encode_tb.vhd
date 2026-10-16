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
    use ieee.math_real.all;

library vunit_lib;
    context vunit_lib.vunit_context;

library olo;
    use olo.olo_base_pkg_math.all;
    use olo.olo_base_pkg_logic.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
-- Stimuli and expected outputs come from the Python model (cosim.py). The streams are driven and checked
-- directly from the model files (no message queues), so the memory of the bench does not grow.
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
    -- Random stalls: before a beat, with probability StallProb_c, for 0 ... StallMax_c clock cycles
    constant StallProb_c    : real    := choose(RandomStall_g, 0.5, 0.0);
    constant StallMax_c     : natural := 10;

    -----------------------------------------------------------------------------------------------
    -- Interface Signals
    -----------------------------------------------------------------------------------------------
    signal Clk        : std_logic                                    := '0';
    signal Rst        : std_logic                                    := '1';
    signal In_Valid   : std_logic                                    := '0';
    signal In_Ready   : std_logic;
    signal In_Data    : std_logic_vector(SymbolWidth_g - 1 downto 0) := (others => '0');
    signal In_Last    : std_logic                                    := '0';
    signal Out_Valid  : std_logic;
    signal Out_Ready  : std_logic                                    := '0';
    signal Out_Data   : std_logic_vector(SymbolWidth_g - 1 downto 0);
    signal Out_Parity : std_logic;
    signal Out_Last   : std_logic;

    -- *** TB Signals ***
    signal InputCount  : natural := 0;
    signal OutputCount : natural := 0;
    -- Stream driver and checker: request (incremented by p_control) and acknowledge (set when done)
    signal StimReq     : natural := 0;
    signal StimAck     : natural := 0;
    signal StimCount   : integer := -1;
    signal CheckReq    : natural := 0;
    signal CheckAck    : natural := 0;
    signal CheckCount  : integer := -1;
    signal CheckAsIn   : boolean := false;

    -----------------------------------------------------------------------------------------------
    -- Procedures
    -----------------------------------------------------------------------------------------------
    -- Random stall length (0 if no stall)
    procedure stallCycles (
        variable seed1  : inout positive;
        variable seed2  : inout positive;
        variable cycles : out natural) is
        variable Rnd_v : real;
    begin
        uniform(seed1, seed2, Rnd_v);
        cycles := 0;
        if Rnd_v < StallProb_c then
            uniform(seed1, seed2, Rnd_v);
            cycles := integer(floor(Rnd_v * real(StallMax_c + 1)));
        end if;
    end procedure;

    -- Start the stream driver (and the checker if checkOut) and wait until both are done
    procedure runStreams (
        signal stimReq  : inout natural;
        signal checkReq : inout natural;
        signal stimAck  : in    natural;
        signal checkAck : in    natural;
        checkOut        : in    boolean := true) is
    begin
        stimReq <= stimReq + 1;
        if checkOut then
            checkReq <= checkReq + 1;
        end if;
        wait until stimAck = stimReq and checkAck = checkReq;
    end procedure;

    -- Number of rows of a model file
    impure function csvRows (file_name : string) return natural is
        variable Vec_v  : integer_array_t;
        variable Rows_v : natural;
    begin
        Vec_v  := load_csv(output_path & file_name);
        Rows_v := height(Vec_v);
        deallocate(Vec_v);
        return Rows_v;
    end function;

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
                StimCount  <= -1;
                CheckCount <= -1;
                CheckAsIn  <= false;
                runStreams(StimReq, CheckReq, StimAck, CheckAck);

            -- A reset in the middle of a block discards the block
            elsif run("ResetMidBlock") then
                -- The data symbols pass unchanged (the first block is a full block)
                StimCount  <= PartialBlock_c;
                CheckCount <= PartialBlock_c;
                CheckAsIn  <= true;
                runStreams(StimReq, CheckReq, StimAck, CheckAck);
                wait until rising_edge(Clk);
                Rst        <= '1';
                wait until rising_edge(Clk);
                Rst        <= '0';
                StimCount  <= -1;
                CheckCount <= -1;
                CheckAsIn  <= false;
                runStreams(StimReq, CheckReq, StimAck, CheckAck);
            end if;

            wait for 1 us;
            -- Every symbol of the model passed the encoder
            check_equal(InputCount, csvRows("enc_in.csv"), "number of input symbols");
            check_equal(OutputCount, csvRows("enc_out.csv"), "number of output symbols");

        end loop;

        -- TB done
        test_runner_cleanup(runner);
    end process;

    -----------------------------------------------------------------------------------------------
    -- Stream driver: input symbols of the model (enc_in.csv: symbol, last)
    -----------------------------------------------------------------------------------------------
    p_stim : process is
        variable Vec_v    : integer_array_t;
        variable Loaded_v : boolean  := false;
        variable Rows_v   : natural;
        variable Stall_v  : natural;
        variable Seed1_v  : positive := 1;
        variable Seed2_v  : positive := 2;
    begin
        wait on StimReq;
        if not Loaded_v then
            Vec_v    := load_csv(output_path & "enc_in.csv");
            Loaded_v := true;
        end if;
        Rows_v := height(Vec_v);
        if StimCount >= 0 and StimCount < Rows_v then
            Rows_v := StimCount;
        end if;

        for i in 0 to Rows_v - 1 loop
            stallCycles(Seed1_v, Seed2_v, Stall_v);
            if Stall_v > 0 then
                In_Valid <= '0';

                for c in 1 to Stall_v loop
                    wait until rising_edge(Clk);
                end loop;

            end if;
            In_Valid <= '1';
            In_Data  <= toUslv(get(Vec_v, 0, i), SymbolWidth_g);
            In_Last  <= choose(get(Vec_v, 1, i) = 1, '1', '0');
            wait until rising_edge(Clk) and In_Ready = '1';
        end loop;

        In_Valid <= '0';
        StimAck  <= StimReq;
    end process;

    -----------------------------------------------------------------------------------------------
    -- Stream checker: output symbols of the model (symbol, check symbol, last)
    -----------------------------------------------------------------------------------------------
    p_check : process is
        variable Out_v    : integer_array_t;
        variable AsIn_v   : integer_array_t;
        variable Loaded_v : boolean  := false;
        variable Rows_v   : natural;
        variable Stall_v  : natural;
        variable Seed1_v  : positive := 3;
        variable Seed2_v  : positive := 4;
        variable Exp_v    : integer_array_t;
    begin
        wait on CheckReq;
        if not Loaded_v then
            Out_v    := load_csv(output_path & "enc_out.csv");
            AsIn_v   := load_csv(output_path & "enc_in_as_out.csv");
            Loaded_v := true;
        end if;
        Exp_v  := Out_v when not CheckAsIn else AsIn_v;
        Rows_v := height(Exp_v);
        if CheckCount >= 0 and CheckCount < Rows_v then
            Rows_v := CheckCount;
        end if;

        for i in 0 to Rows_v - 1 loop
            stallCycles(Seed1_v, Seed2_v, Stall_v);
            if Stall_v > 0 then
                Out_Ready <= '0';

                for c in 1 to Stall_v loop
                    wait until rising_edge(Clk);
                end loop;

            end if;
            Out_Ready <= '1';
            wait until rising_edge(Clk) and Out_Valid = '1';
            check_equal(Out_Data, toUslv(get(Exp_v, 0, i), SymbolWidth_g), "Out_Data, symbol " & integer'image(i));
            check_equal(Out_Parity, choose(get(Exp_v, 1, i) = 1, '1', '0'), "Out_Parity, symbol " & integer'image(i));
            check_equal(Out_Last, choose(get(Exp_v, 2, i) = 1, '1', '0'), "Out_Last, symbol " & integer'image(i));
        end loop;

        -- Further output symbols are accepted and counted (number of output symbols at the end of the test)
        CheckAck <= CheckReq;
    end process;

    -----------------------------------------------------------------------------------------------
    -- Accepted beats
    -----------------------------------------------------------------------------------------------
    p_count : process (Clk) is
    begin
        if rising_edge(Clk) then
            if Rst = '1' then
                InputCount  <= 0;
                OutputCount <= 0;
            else
                if In_Valid = '1' and In_Ready = '1' then
                    InputCount <= InputCount + 1;
                end if;
                if Out_Valid = '1' and Out_Ready = '1' then
                    OutputCount <= OutputCount + 1;
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

end architecture;
