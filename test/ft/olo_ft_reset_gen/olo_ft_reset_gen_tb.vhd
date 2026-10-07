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

library work;
    use work.olo_test_activity_pkg.all;

library olo;
    use olo.olo_base_pkg_math.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
-- vunit: run_all_in_same_sim
entity olo_ft_reset_gen_tb is
    generic (
        runner_cfg          : string;
        RstPulseCycles_g    : positive range 3 to positive'high := 3;
        RstInPolarity_g     : integer range 0 to 1              := 1;
        AsyncResetOutput_g  : boolean                           := true
    );
end entity;

architecture sim of olo_ft_reset_gen_tb is

    -----------------------------------------------------------------------------------------------
    -- TB Defnitions
    -----------------------------------------------------------------------------------------------
    constant Clk_Frequency_c   : real      := 100.0e6;
    constant Clk_Period_c      : time      := (1 sec) / Clk_Frequency_c;
    constant RstPolarityStdl_c : std_logic := choose(RstInPolarity_g = 1, '1', '0');

    -- Single and double upsets of the TMR copies
    type CopyMasks_t is array (0 to 2) of std_logic_vector(0 to 2);

    constant SingleCopy_c : CopyMasks_t              := ("100", "010", "001");
    constant CopyAb_c     : std_logic_vector(0 to 2) := "110";

    -----------------------------------------------------------------------------------------------
    -- Interface Signals
    -----------------------------------------------------------------------------------------------
    signal Clk    : std_logic := '1';
    signal RstOut : std_logic;
    signal RstIn  : std_logic := not RstPolarityStdl_c;

begin

    -----------------------------------------------------------------------------------------------
    -- DUT
    -----------------------------------------------------------------------------------------------
    i_dut : entity olo.olo_ft_reset_gen
        generic map (
            RstPulseCycles_g    => RstPulseCycles_g,
            RstInPolarity_g     => RstPolarityStdl_c,
            AsyncResetOutput_g  => AsyncResetOutput_g
        )
        port map (
            Clk     => Clk,
            RstOut  => RstOut,
            RstIn   => RstIn
        );

    -----------------------------------------------------------------------------------------------
    -- Clock
    -----------------------------------------------------------------------------------------------
    Clk <= not Clk after 0.5 * Clk_Period_c;

    -----------------------------------------------------------------------------------------------
    -- TB Control
    -----------------------------------------------------------------------------------------------
    -- TB is not very vunit-ish because Resets are not data-flow oriented
    test_runner_watchdog(runner, 1 ms);

    p_control : process is
        -- TMR copies inside the DUT
        alias ChainA   is << signal .olo_ft_reset_gen_tb.i_dut.g_copy(0).RstSyncChain : std_logic_vector(2 downto 0) >>;
        alias ChainB   is << signal .olo_ft_reset_gen_tb.i_dut.g_copy(1).RstSyncChain : std_logic_vector(2 downto 0) >>;
        alias ChainC   is << signal .olo_ft_reset_gen_tb.i_dut.g_copy(2).RstSyncChain : std_logic_vector(2 downto 0) >>;
        alias RstPulse is << signal .olo_ft_reset_gen_tb.i_dut.RstPulse : std_logic_vector(0 to 2) >>;

        -- Upset the reset synchronizer chains of the selected copies (all stages set) for one edge
        procedure flipChain (
            Copies : std_logic_vector(0 to 2)) is
        begin
            wait until rising_edge(Clk);
            wait for 0.25 * Clk_Period_c;
            if Copies(0) = '1' then
                ChainA <= force "111";
            end if;
            if Copies(1) = '1' then
                ChainB <= force "111";
            end if;
            if Copies(2) = '1' then
                ChainC <= force "111";
            end if;
            wait until rising_edge(Clk);
            wait for 0.25 * Clk_Period_c;
            ChainA <= release;
            ChainB <= release;
            ChainC <= release;
        end procedure;

        -- Upset the pulse prolongation state of the selected copies for one edge
        procedure flipPulse (
            Copies : std_logic_vector(0 to 2)) is
        begin
            wait until rising_edge(Clk);
            wait for 0.25 * Clk_Period_c;

            for i in 0 to 2 loop
                if Copies(i) = '1' then
                    RstPulse(i) <= force not RstPulse(i);
                end if;
            end loop;

            wait until rising_edge(Clk);
            wait for 0.25 * Clk_Period_c;

            for i in 0 to 2 loop
                RstPulse(i) <= release;
            end loop;

        end procedure;

        variable Start_v : time;
    begin
        test_runner_setup(runner, runner_cfg);

        -- Check reset after power-up
        wait for 1 ns;

        for i in 0 to RstPulseCycles_g-1 loop
            check_equal(RstOut, '1', "reset after power-up");
            wait until rising_edge(Clk);
        end loop;

        -- On synchronous assertion removal takes longer due to the synchronizer
        if not AsyncResetOutput_g then
            wait for 2*Clk_Period_c;
        end if;

        -- Check removal
        wait for 0.1*Clk_Period_c;
        check_equal(RstOut, '0', "reset removal after power-up");
        wait for 1 us;

        while test_suite loop
            -- Always edge align before test case
            wait until rising_edge(Clk);

            -- Asynchronous detection
            if run("AsyncDetect") then
                -- Assert reset
                wait until rising_edge(Clk);
                wait for 0.1*Clk_Period_c;
                RstIn <= RstPolarityStdl_c;
                wait for 0.1*Clk_Period_c;
                RstIn <= not RstPolarityStdl_c;

                -- Wait for reset output
                wait_for_value_stdl(RstOut, '1', 1 us, "AsyncDetect - RstOut assertion");
                wait_for_value_stdl(RstOut, '0', Clk_Period_c*(RstPulseCycles_g*2), "AsyncDetect - RstOut de-assertion");
            end if;

            -- Pulse Duration
            if run("PulseDuration") then
                -- Reset Assertion
                RstIn <= RstPolarityStdl_c;
                wait until rising_edge(Clk);
                RstIn <= not RstPolarityStdl_c;

                -- Check Duration
                wait_for_value_stdl(RstOut, '1', 1 us, "RstOut assertion");

                for i in 0 to RstPulseCycles_g-1 loop
                    check_equal(RstOut, '1', "reset removed early");
                    wait until rising_edge(Clk);
                end loop;

                -- On synchronous assertion removal takes longer due to the synchronizer
                if not AsyncResetOutput_g then
                    wait for Clk_Period_c;
                end if;

                wait for 0.1*Clk_Period_c;
                check_equal(RstOut, '0', "reset removed late");
            end if;

            -- Asynchronous Forwarding
            if run("AsyncForward") then
                -- Assert reset
                wait until rising_edge(Clk);
                wait for 0.1*Clk_Period_c;
                RstIn <= RstPolarityStdl_c;
                wait for 0.1*Clk_Period_c;
                RstIn <= not RstPolarityStdl_c;

                -- Wait for reset output (only check when enabled)
                if AsyncResetOutput_g then
                    check_equal(RstOut, '1', "AsyncForward - RstOut assertion");
                    wait_for_value_stdl(RstOut, '0', Clk_Period_c*(RstPulseCycles_g*2), "AsyncForward - RstOut de-assertion");
                end if;
            end if;

            -- Upsets of a single copy of the synchronizers do not assert the reset (one copy at a time,
            -- each upset flushed out of the chains before the next one)
            if run("Seu-Chain") then
                Start_v := now;

                for Copy in 0 to 2 loop
                    flipChain(SingleCopy_c(Copy));
                    wait for Clk_Period_c*10;
                end loop;

                check(RstOut'last_event >= now - Start_v, "Reset asserted by a single upset");
                check_equal(RstOut, '0', "Reset asserted by a single upset");
            end if;

            -- Upsets of a single copy of the pulse prolongation neither assert nor shorten the reset
            if run("Seu-Pulse") then

                -- Idle: no reset
                Start_v := now;

                for Copy in 0 to 2 loop
                    flipPulse(SingleCopy_c(Copy));
                end loop;

                wait for Clk_Period_c*4;
                check(RstOut'last_event >= now - Start_v, "Reset asserted by a single upset");
                check_equal(RstOut, '0', "Reset asserted by a single upset");

                -- During a reset pulse: the duration is kept
                RstIn <= RstPolarityStdl_c;
                wait until rising_edge(Clk);
                RstIn <= not RstPolarityStdl_c;
                wait_for_value_stdl(RstOut, '1', 1 us, "RstOut assertion");
                flipPulse(SingleCopy_c(1));

                -- Two cycles of the duration passed in flipPulse
                for i in 2 to RstPulseCycles_g-1 loop
                    check_equal(RstOut, '1', "reset shortened by a single upset");
                    wait until rising_edge(Clk);
                end loop;

                wait_for_value_stdl(RstOut, '0', Clk_Period_c*(RstPulseCycles_g*2), "RstOut de-assertion");
            end if;

            -- Sanity check of the injection: upsets of two copies are not masked
            if run("DoubleFault-Visible") then
                flipChain(CopyAb_c);
                wait_for_value_stdl(RstOut, '1', Clk_Period_c*8, "Double upset not visible");
                wait_for_value_stdl(RstOut, '0', Clk_Period_c*(RstPulseCycles_g*2+8), "RstOut de-assertion");
            end if;

            -- Delay between tests
            wait for 1 us;

        end loop;

        -- TB done
        test_runner_cleanup(runner);
    end process;

end architecture;
