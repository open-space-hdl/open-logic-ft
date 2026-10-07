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

library work;
    use work.olo_test_ft_pkg.all;

library olo;
    use olo.olo_base_pkg_math.all;
    use olo.olo_base_pkg_logic.all;
    use olo.olo_ft_pkg_ecc.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
-- vunit: run_all_in_same_sim
entity olo_ft_delay_tb is
    generic (
        runner_cfg    : string;
        Width_g       : positive range 5 to 128 := 16;
        Delay_g       : natural                 := 5;
        Resource_g    : string                  := "AUTO";
        RstState_g    : boolean                 := true;
        EccPipeline_g : natural range 0 to 1    := 0
    );
end entity;

architecture sim of olo_ft_delay_tb is

    -----------------------------------------------------------------------------------------------
    -- Constants
    -----------------------------------------------------------------------------------------------
    constant ClkPeriod_c     : time     := 10 ns;
    constant CodewordWidth_c : positive := eccCodewordWidth(Width_g);
    constant MaxSamples_c    : positive := 1024;

    -----------------------------------------------------------------------------------------------
    -- Interface Signals
    -----------------------------------------------------------------------------------------------
    signal Clk               : std_logic                                      := '0';
    signal Rst               : std_logic                                      := '1';
    signal In_Data           : std_logic_vector(Width_g - 1 downto 0)         := (others => '0');
    signal In_Valid          : std_logic                                      := '0';
    signal Out_Data          : std_logic_vector(Width_g - 1 downto 0);
    signal Out_EccSec        : std_logic;
    signal Out_EccDed        : std_logic;
    signal In_ErrInj_BitFlip : std_logic_vector(CodewordWidth_c - 1 downto 0) := (others => '0');
    signal In_ErrInj_Valid   : std_logic                                      := '0';

    -----------------------------------------------------------------------------------------------
    -- Types
    -----------------------------------------------------------------------------------------------
    type Data_t is array (0 to MaxSamples_c - 1) of std_logic_vector(Width_g - 1 downto 0);

begin

    -----------------------------------------------------------------------------------------------
    -- TB Control
    -----------------------------------------------------------------------------------------------
    test_runner_watchdog(runner, 10 ms);

    p_control : process is
        -- Expected decoder outcome per applied sample (computed at apply time, including flips)
        variable ExpData_v : Data_t;
        variable ExpSec_v  : std_logic_vector(0 to MaxSamples_c - 1);
        variable ExpDed_v  : std_logic_vector(0 to MaxSamples_c - 1);
        -- Number of samples applied since the last reset
        variable J_v       : natural;

        -- Check the DUT output against the sample-indexed model. Convention: after the clock
        -- edge of sample j, the (registered) output shows sample j-(Delay_g-1); before that it
        -- shows the RstState_g zeros. Checks are skipped in the warm-up window for
        -- RstState_g=false (storage content is undefined there).
        procedure checkOutput (
            constant Msg_c : in string) is
            constant J_c : natural := J_v - 1; -- index of the sample just applied
        begin

            if Delay_g > 0 and J_c >= Delay_g - 1 then
                check_equal(Out_Data, ExpData_v(J_c - (Delay_g - 1)), Msg_c & " data");
                check_equal(Out_EccSec, ExpSec_v(J_c - (Delay_g - 1)), Msg_c & " sec");
                check_equal(Out_EccDed, ExpDed_v(J_c - (Delay_g - 1)), Msg_c & " ded");
            elsif Delay_g > 0 and RstState_g then
                check_equal(Out_Data, toUslv(0, Width_g), Msg_c & " warm-up data");
                check_equal(Out_EccSec, '0', Msg_c & " warm-up sec");
                check_equal(Out_EccDed, '0', Msg_c & " warm-up ded");
            end if;

        end procedure;

        -- Apply one In_Valid beat (optionally with an error injection) and check the output.
        -- For Delay_g=0 the DUT is combinational and checked within the beat.
        procedure applyBeat (
            constant Data_c : in std_logic_vector;
            constant Flip_c : in std_logic_vector;
            constant Msg_c  : in string;
            constant Gap_c  : in natural := 0) is
            variable ExpD_v     : std_logic_vector(Width_g - 1 downto 0);
            variable ExpS_v     : std_logic;
            variable ExpDd_v    : std_logic;
            variable AnyFlip_v  : boolean := false;
            variable HoldData_v : std_logic_vector(Width_g - 1 downto 0);
            variable HoldSec_v  : std_logic;
            variable HoldDed_v  : std_logic;
        begin

            for i in Flip_c'range loop
                if Flip_c(i) = '1' then
                    AnyFlip_v := true;
                end if;
            end loop;

            -- Expected decoder outcome for this sample
            ftExpectedBeat(Data_c, Flip_c, ExpD_v, ExpS_v, ExpDd_v);
            ExpData_v(J_v) := ExpD_v;
            ExpSec_v(J_v)  := ExpS_v;
            ExpDed_v(J_v)  := ExpDd_v;
            J_v            := J_v + 1;

            -- Drive the beat (direct injection: pattern applied in the same cycle)
            if AnyFlip_v then
                In_ErrInj_BitFlip <= Flip_c;
                In_ErrInj_Valid   <= '1';
            end if;
            In_Data  <= Data_c;
            In_Valid <= '1';

            -- Combinational DUT: check within the beat
            if Delay_g = 0 then
                wait for 1 ns;
                check_equal(Out_Data, ExpD_v, Msg_c & " comb data");
                check_equal(Out_EccSec, ExpS_v, Msg_c & " comb sec");
                check_equal(Out_EccDed, ExpDd_v, Msg_c & " comb ded");
            end if;

            wait until rising_edge(Clk);
            In_Valid          <= '0';
            In_ErrInj_BitFlip <= (others => '0');
            In_ErrInj_Valid   <= '0';

            -- Registered DUT: check after the edge
            wait for 1 ns;
            checkOutput(Msg_c);

            -- Idle cycles: the sample-gated output must hold its value
            HoldData_v := Out_Data;
            HoldSec_v  := Out_EccSec;
            HoldDed_v  := Out_EccDed;

            for i in 1 to Gap_c loop
                wait until rising_edge(Clk);
                wait for 1 ns;
                check_equal(Out_Data, HoldData_v, Msg_c & " hold data");
                check_equal(Out_EccSec, HoldSec_v, Msg_c & " hold sec");
                check_equal(Out_EccDed, HoldDed_v, Msg_c & " hold ded");
            end loop;

        end procedure;

        -- Apply a reset and restart the sample-indexed model
        procedure applyReset is
        begin
            wait until rising_edge(Clk);
            Rst <= '1';
            wait until rising_edge(Clk);
            wait until rising_edge(Clk);
            Rst <= '0';
            wait until rising_edge(Clk);
            J_v := 0;
        end procedure;

        variable NoFlip_v : std_logic_vector(CodewordWidth_c - 1 downto 0);
        variable Flip_v   : std_logic_vector(CodewordWidth_c - 1 downto 0);
        variable NumSmp_v : natural;
    begin
        test_runner_setup(runner, runner_cfg);

        while test_suite loop

            NoFlip_v := (others => '0');
            applyReset;

            ---------------------------------------------------------------------------------------
            if run("Basic") then
                -- Continuous stream: warm-up zeros (RstState_g), then every sample delayed by
                -- exactly Delay_g, flags idle on clean data.
                NumSmp_v := 3 * maximum(Delay_g, 1) + 20;

                for j in 0 to NumSmp_v - 1 loop
                    applyBeat(toUslv((j * 3 + 1) mod 2**minimum(Width_g, 30), Width_g), NoFlip_v,
                              "Basic[" & integer'image(j) & "]");
                end loop;

            ---------------------------------------------------------------------------------------
            elsif run("GappedValid") then
                -- Same stream with 0..3 idle cycles between beats: the delay counts samples,
                -- not clock cycles, and the output holds during gaps.
                NumSmp_v := 2 * maximum(Delay_g, 1) + 10;

                for j in 0 to NumSmp_v - 1 loop
                    applyBeat(toUslv((j * 5 + 2) mod 2**minimum(Width_g, 30), Width_g), NoFlip_v,
                              "Gapped[" & integer'image(j) & "]", Gap_c => j mod 4);
                end loop;

            ---------------------------------------------------------------------------------------
            elsif run("SecAllBits") then
                -- One beat per codeword bit position, each with a single-bit flip: every flip
                -- must be corrected and reported with EccSec exactly on its own output sample.

                for bitIdx in 0 to CodewordWidth_c - 1 loop
                    Flip_v := setBits(bitIdx, CodewordWidth_c);
                    applyBeat(toUslv(16#A5# mod 2**minimum(Width_g, 30), Width_g), Flip_v,
                              "SecAllBits flip " & integer'image(bitIdx));
                end loop;

                -- Flush the delay line with clean beats so all flipped samples are checked
                for j in 0 to Delay_g loop
                    applyBeat(toUslv(0, Width_g), NoFlip_v, "SecAllBits flush " & integer'image(j));
                end loop;

            ---------------------------------------------------------------------------------------
            elsif run("DedSampledPairs") then

                for pair in 0 to 4 loop

                    case pair is
                        when 0 => Flip_v := setBits((0, 1),                   CodewordWidth_c);
                        when 1 => Flip_v := setBits((0, CodewordWidth_c - 1), CodewordWidth_c);
                        when 2 => Flip_v := setBits((1, 2),                   CodewordWidth_c);
                        when 3 => Flip_v := setBits((2, 4),                   CodewordWidth_c);
                        when others => Flip_v := setBits((CodewordWidth_c / 2,
                                                          CodewordWidth_c / 2 + 1), CodewordWidth_c);
                    end case;

                    applyBeat(toUslv(16#5A# mod 2**minimum(Width_g, 30), Width_g), Flip_v,
                              "DedPair " & integer'image(pair));
                end loop;

                -- Flush the delay line with clean beats so all flipped samples are checked
                for j in 0 to Delay_g loop
                    applyBeat(toUslv(0, Width_g), NoFlip_v, "DedPairs flush " & integer'image(j));
                end loop;

            ---------------------------------------------------------------------------------------
            elsif run("LatchedInjection") then
                -- Arm the injection latch during an idle phase: the pattern must be applied to
                -- exactly the next sample, the following samples are clean again.
                Flip_v := setBits(2, CodewordWidth_c);

                In_ErrInj_BitFlip <= Flip_v;
                In_ErrInj_Valid   <= '1';
                wait until rising_edge(Clk);
                In_ErrInj_BitFlip <= (others => '0');
                In_ErrInj_Valid   <= '0';
                wait until rising_edge(Clk);
                wait until rising_edge(Clk);

                -- The armed pattern hits this sample: record it in the model by hand
                ftExpectedBeat(toUslv(16#33# mod 2**minimum(Width_g, 30), Width_g), Flip_v,
                                 ExpData_v(J_v), ExpSec_v(J_v), ExpDed_v(J_v));
                J_v      := J_v + 1;
                In_Data  <= toUslv(16#33# mod 2**minimum(Width_g, 30), Width_g);
                In_Valid <= '1';

                if Delay_g = 0 then
                    wait for 1 ns;
                    check_equal(Out_EccSec, '1', "Latched comb sec");
                end if;

                wait until rising_edge(Clk);
                In_Valid <= '0';
                wait for 1 ns;
                checkOutput("Latched");

                -- Following samples are clean; flush until the flipped sample was observed
                for j in 0 to Delay_g + 2 loop
                    applyBeat(toUslv(j + 1, Width_g), NoFlip_v, "Latched flush " & integer'image(j));
                end loop;

            ---------------------------------------------------------------------------------------
            elsif run("ResetMidStream") then
                -- Reset with the delay line full: the warm-up behavior must restart cleanly and
                -- no stale sample may appear.
                NumSmp_v := maximum(Delay_g, 1) + 5;

                for j in 0 to NumSmp_v - 1 loop
                    applyBeat(toUslv(j + 16#40#, Width_g), NoFlip_v, "PreReset[" & integer'image(j) & "]");
                end loop;

                applyReset;

                for j in 0 to NumSmp_v - 1 loop
                    applyBeat(toUslv(j + 16#60#, Width_g), NoFlip_v, "PostReset[" & integer'image(j) & "]");
                end loop;

            end if;

            In_Valid <= '0';
            wait for 100 ns;

        end loop;

        test_runner_cleanup(runner);
    end process;

    -----------------------------------------------------------------------------------------------
    -- Clock
    -----------------------------------------------------------------------------------------------
    Clk <= not Clk after 0.5 * ClkPeriod_c;

    -----------------------------------------------------------------------------------------------
    -- DUT
    -----------------------------------------------------------------------------------------------
    i_dut : entity olo.olo_ft_delay
        generic map (
            Width_g       => Width_g,
            Delay_g       => Delay_g,
            Resource_g    => Resource_g,
            RstState_g    => RstState_g,
            EccPipeline_g => EccPipeline_g
        )
        port map (
            Clk               => Clk,
            Rst               => Rst,
            In_Data           => In_Data,
            In_Valid          => In_Valid,
            Out_Data          => Out_Data,
            Out_EccSec        => Out_EccSec,
            Out_EccDed        => Out_EccDed,
            In_ErrInj_BitFlip => In_ErrInj_BitFlip,
            In_ErrInj_Valid   => In_ErrInj_Valid
        );

end architecture;
