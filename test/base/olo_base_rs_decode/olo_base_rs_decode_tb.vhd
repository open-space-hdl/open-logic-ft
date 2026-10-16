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
    -- Random stalls: before a beat, with probability StallProb_c, for 0 ... StallMax_c clock cycles
    constant StallProb_c  : real    := choose(RandomStall_g, 0.5, 0.0);
    constant StallMax_c   : natural := 10;

    -----------------------------------------------------------------------------------------------
    -- Interface Signals
    -----------------------------------------------------------------------------------------------
    signal Clk                  : std_logic                                    := '0';
    signal Rst                  : std_logic                                    := '1';
    signal In_Valid             : std_logic                                    := '0';
    signal In_Ready             : std_logic;
    signal In_Data              : std_logic_vector(SymbolWidth_g - 1 downto 0) := (others => '0');
    signal In_Last              : std_logic                                    := '0';
    signal Out_Valid            : std_logic;
    signal Out_Ready            : std_logic;
    signal Out_Data             : std_logic_vector(SymbolWidth_g - 1 downto 0);
    signal Out_Parity           : std_logic;
    signal Out_Last             : std_logic;
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
    signal OutputCount  : natural   := 0;
    signal InStallCount : natural   := 0;
    -- Stream driver and checker: request (incremented by p_control) and acknowledge (set when done)
    signal StimReq      : natural   := 0;
    signal StimAck      : natural   := 0;
    signal StimCount    : integer   := -1;
    signal CheckReq     : natural   := 0;
    signal CheckAck     : natural   := 0;
    signal CheckReady   : std_logic := '0';

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
    test_runner_watchdog(runner, 100 ms);

    p_control : process is
        variable Entries_v : natural;
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
                StimCount <= -1;
                runStreams(StimReq, CheckReq, StimAck, CheckAck);

            -- A reset in the middle of a block discards the block
            elsif run("ResetMidBlock") then
                StimCount <= 5;
                runStreams(StimReq, CheckReq, StimAck, CheckAck, false);
                wait for 200 ns;
                wait until rising_edge(Clk);
                Rst       <= '1';
                wait until rising_edge(Clk);
                Rst       <= '0';
                StimCount <= -1;
                runStreams(StimReq, CheckReq, StimAck, CheckAck);

            -- Long output stalls at the start and near the end of the blocks
            elsif run("OutputStall") then
                HoldEna   <= true;
                StimCount <= -1;
                runStreams(StimReq, CheckReq, StimAck, CheckAck);

            -- Equal full blocks are accepted without a gap if the documented condition holds (without random stalls)
            elsif run("Continuous") then
                StimCount <= -1;
                runStreams(StimReq, CheckReq, StimAck, CheckAck);
                if not RandomStall_g and ContOk_c then
                    check_equal(InStallCount, 0, "In_Ready low during equal full blocks");
                end if;
            end if;

            -- Wait for all status pulses
            -- Status entries of the model (dec_status.csv: corrected, uncorrectable, last, blocks with output)
            Entries_v := csvRows("dec_status.csv");
            if StatusCount /= Entries_v then
                wait until StatusCount = Entries_v for 1 ms;
            end if;
            check_equal(StatusCount, Entries_v, "number of status pulses");
            wait for 1 us;
            check_equal(StatusCount, Entries_v, "no further status pulses");
            -- Every symbol of the model passed the decoder
            check_equal(InputCount, csvRows("dec_in.csv"), "number of input symbols");
            check_equal(OutputCount, csvRows("dec_out.csv"), "number of output symbols");

        end loop;

        -- TB done
        test_runner_cleanup(runner);
    end process;

    -----------------------------------------------------------------------------------------------
    -- Stream driver: received symbols of the model (dec_in.csv: symbol, last)
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
            Vec_v    := load_csv(output_path & "dec_in.csv");
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
    -- Stream checker: output symbols of the model (dec_out.csv: symbol, check symbol, last)
    -----------------------------------------------------------------------------------------------
    p_check : process is
        variable Vec_v    : integer_array_t;
        variable Loaded_v : boolean  := false;
        variable Stall_v  : natural;
        variable Seed1_v  : positive := 3;
        variable Seed2_v  : positive := 4;
    begin
        wait on CheckReq;
        if not Loaded_v then
            Vec_v    := load_csv(output_path & "dec_out.csv");
            Loaded_v := true;
        end if;

        for i in 0 to height(Vec_v) - 1 loop
            stallCycles(Seed1_v, Seed2_v, Stall_v);
            if Stall_v > 0 then
                CheckReady <= '0';

                for c in 1 to Stall_v loop
                    wait until rising_edge(Clk);
                end loop;

            end if;
            CheckReady <= '1';
            wait until rising_edge(Clk) and Out_Valid = '1' and Out_Ready = '1';
            check_equal(Out_Data, toUslv(get(Vec_v, 0, i), SymbolWidth_g), "Out_Data, symbol " & integer'image(i));
            check_equal(Out_Parity, choose(get(Vec_v, 1, i) = 1, '1', '0'), "Out_Parity, symbol " & integer'image(i));
            check_equal(Out_Last, choose(get(Vec_v, 2, i) = 1, '1', '0'), "Out_Last, symbol " & integer'image(i));
        end loop;

        -- Further output symbols are accepted and counted (number of output symbols at the end of the test)
        CheckAck <= CheckReq;
    end process;

    Out_Ready <= CheckReady and not OutHold;

    -----------------------------------------------------------------------------------------------
    -- Status checker
    -----------------------------------------------------------------------------------------------
    -- Values, pulses of a block on consecutive cycles, no status before the Out_Last of its block was accepted
    p_status : process (Clk) is
        variable Vec_v     : integer_array_t;
        variable Loaded_v  : boolean := false;
        variable Idx_v     : natural := 0;
        variable InBlock_v : boolean := false;
    begin
        if rising_edge(Clk) then
            if Rst = '1' then
                Idx_v       := 0;
                InBlock_v   := false;
                StatusCount <= 0;
            elsif Status_Valid = '1' then
                if not Loaded_v then
                    Vec_v    := load_csv(output_path & "dec_status.csv");
                    Loaded_v := true;
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

    -- Accepted output symbols and Out_Last symbols
    p_outlast : process (Clk) is
    begin
        if rising_edge(Clk) then
            if Rst = '1' then
                OutputCount  <= 0;
                OutLastCount <= 0;
            elsif Out_Valid = '1' and Out_Ready = '1' then
                OutputCount <= OutputCount + 1;
                if Out_Last = '1' then
                    OutLastCount <= OutLastCount + 1;
                end if;
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

end architecture;
