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

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
-- vunit: run_all_in_same_sim
entity olo_ft_private_cc_toggle_tb is
    generic (
        runner_cfg     : string;
        ClockRatio_N_g : integer               := 3;
        ClockRatio_D_g : integer               := 2;
        SyncStages_g   : positive range 2 to 4 := 2
    );
end entity;

architecture sim of olo_ft_private_cc_toggle_tb is

    -----------------------------------------------------------------------------------------------
    -- Constants
    -----------------------------------------------------------------------------------------------
    constant ClockRatio_c : real := real(ClockRatio_N_g) / real(ClockRatio_D_g);

    -----------------------------------------------------------------------------------------------
    -- TB Definitions
    -----------------------------------------------------------------------------------------------
    constant ClkIn_Frequency_c    : real := 100.0e6;
    constant ClkIn_Period_c       : time := (1 sec) / ClkIn_Frequency_c;
    constant ClkOut_Frequency_c   : real := ClkIn_Frequency_c * ClockRatio_c;
    constant ClkOut_Period_c      : time := (1 sec) / ClkOut_Frequency_c;
    constant SlowerClock_Period_c : time := (1 sec) / minimum(ClkIn_Frequency_c, ClkOut_Frequency_c);
    constant MaxRatePeriod_c      : time := (3 + SyncStages_g) * SlowerClock_Period_c;
    constant Settle_c             : time := (10 + 2 * SyncStages_g) * SlowerClock_Period_c;

    -- Copy masks for the SEU injection
    constant CopyAb_c : std_logic_vector(0 to 2) := "110";

    function copyMask (Copy : natural) return std_logic_vector is
        variable Mask_v : std_logic_vector(0 to 2) := (others => '0');
    begin
        Mask_v(Copy) := '1';
        return Mask_v;
    end function;

    -----------------------------------------------------------------------------------------------
    -- Interface Signals
    -----------------------------------------------------------------------------------------------
    signal In_Clk    : std_logic := '0';
    signal In_Rst    : std_logic := '1';
    signal In_Pulse  : std_logic := '0';
    signal Out_Clk   : std_logic := '0';
    signal Out_Rst   : std_logic := '1';
    signal Out_Pulse : std_logic;

    -----------------------------------------------------------------------------------------------
    -- TB Signals
    -----------------------------------------------------------------------------------------------
    signal PulseCount : natural := 0;
    signal PulseLong  : boolean := false;

begin

    -----------------------------------------------------------------------------------------------
    -- DUT
    -----------------------------------------------------------------------------------------------
    i_dut : entity olo.olo_ft_private_cc_toggle
        generic map (
            SyncStages_g => SyncStages_g
        )
        port map (
            In_Clk    => In_Clk,
            In_Rst    => In_Rst,
            In_Pulse  => In_Pulse,
            Out_Clk   => Out_Clk,
            Out_Rst   => Out_Rst,
            Out_Pulse => Out_Pulse
        );

    -----------------------------------------------------------------------------------------------
    -- Clock
    -----------------------------------------------------------------------------------------------
    In_Clk  <= not In_Clk after 0.5 * ClkIn_Period_c;
    Out_Clk <= not Out_Clk after 0.5 * ClkOut_Period_c;

    -----------------------------------------------------------------------------------------------
    -- TB Control
    -----------------------------------------------------------------------------------------------
    test_runner_watchdog(runner, 10 ms);

    p_control : process is
        -- TMR copies inside the DUT
        alias ToggleLast    is << signal .olo_ft_private_cc_toggle_tb.i_dut.ToggleLast : std_logic_vector(0 to 2) >>;
        alias ToggleOutLast is << signal .olo_ft_private_cc_toggle_tb.i_dut.ToggleOutLast : std_logic_vector(0 to 2) >>;

        -- Single-cycle input pulse
        procedure sendPulse is
        begin
            wait until rising_edge(In_Clk);
            In_Pulse <= '1';
            wait until rising_edge(In_Clk);
            In_Pulse <= '0';
        end procedure;

        -- Upset the selected copies of the transmit-side toggle state for one In_Clk edge
        procedure flipIn (
            Copies : std_logic_vector(0 to 2)) is
        begin
            wait until rising_edge(In_Clk);
            wait for 0.25 * ClkIn_Period_c;

            for i in 0 to 2 loop
                if Copies(i) = '1' then
                    ToggleLast(i) <= force not ToggleLast(i);
                end if;
            end loop;

            wait until rising_edge(In_Clk);

            for i in 0 to 2 loop
                if Copies(i) = '1' then
                    ToggleLast(i) <= release;
                end if;
            end loop;

        end procedure;

        -- Upset the selected copies of the receive-side toggle state for one Out_Clk edge
        procedure flipOut (
            Copies : std_logic_vector(0 to 2)) is
        begin
            wait until rising_edge(Out_Clk);
            wait for 0.25 * ClkOut_Period_c;

            for i in 0 to 2 loop
                if Copies(i) = '1' then
                    ToggleOutLast(i) <= force not ToggleOutLast(i);
                end if;
            end loop;

            wait until rising_edge(Out_Clk);

            for i in 0 to 2 loop
                if Copies(i) = '1' then
                    ToggleOutLast(i) <= release;
                end if;
            end loop;

        end procedure;

        variable Count_v : natural;
    begin
        test_runner_setup(runner, runner_cfg);

        while test_suite loop

            -- Reset (both sides together, as done by the reset crossing of the instantiating entity)
            In_Pulse <= '0';
            In_Rst   <= '1';
            Out_Rst  <= '1';
            wait for Settle_c;
            wait until rising_edge(In_Clk);
            In_Rst   <= '0';
            wait until rising_edge(Out_Clk);
            Out_Rst  <= '0';
            wait for Settle_c;
            check_equal(Out_Pulse, '0', "Out_Pulse active after reset");

            if run("SinglePulse") then
                Count_v := PulseCount;
                sendPulse;
                wait for Settle_c;
                check_equal(PulseCount, Count_v + 1, "Wrong number of output pulses");

            elsif run("MaxRate") then
                Count_v := PulseCount;

                for i in 0 to 19 loop
                    sendPulse;
                    wait for MaxRatePeriod_c - ClkIn_Period_c;
                end loop;

                wait for Settle_c;
                check_equal(PulseCount, Count_v + 20, "Wrong number of output pulses");

            elsif run("PulseDuringReset") then
                -- Pulses arriving while both sides are in reset are discarded
                Count_v := PulseCount;
                wait until rising_edge(In_Clk);
                In_Rst  <= '1';
                Out_Rst <= '1';
                sendPulse;
                wait until rising_edge(In_Clk);
                In_Rst  <= '0';
                wait until rising_edge(Out_Clk);
                Out_Rst <= '0';
                wait for Settle_c;
                check_equal(PulseCount, Count_v, "Pulse leaked through reset");

                -- Reset in the middle of a crossing does not produce a spurious pulse either
                sendPulse;
                wait until rising_edge(In_Clk);
                In_Rst  <= '1';
                Out_Rst <= '1';
                wait for Settle_c;
                wait until rising_edge(In_Clk);
                In_Rst  <= '0';
                wait until rising_edge(Out_Clk);
                Out_Rst <= '0';
                wait for Settle_c;
                check(PulseCount <= Count_v + 1, "Spurious pulse after reset");

            elsif run("Seu-Idle") then
                -- Upsets of any single copy do not produce an output pulse
                Count_v := PulseCount;

                for Copy in 0 to 2 loop
                    flipIn(copyMask(Copy));
                    flipOut(copyMask(Copy));
                end loop;

                wait for Settle_c;
                check_equal(PulseCount, Count_v, "Spurious output pulse");

            elsif run("Seu-Crossing") then

                -- Upsets of any single copy while a pulse crosses neither duplicate nor lose it
                for Copy in 0 to 2 loop
                    Count_v := PulseCount;
                    sendPulse;
                    flipIn(copyMask(Copy));
                    wait for Settle_c;
                    check_equal(PulseCount, Count_v + 1, "Wrong number of output pulses (transmit side)");

                    Count_v := PulseCount;
                    sendPulse;

                    for i in 0 to 2 * SyncStages_g + 4 loop
                        flipOut(copyMask(Copy));
                    end loop;

                    wait for Settle_c;
                    check_equal(PulseCount, Count_v + 1, "Wrong number of output pulses (receive side)");
                end loop;

            elsif run("DoubleFault-Visible") then
                -- Sanity check of the injection mechanism: two upset copies are not masked
                Count_v := PulseCount;
                flipOut(CopyAb_c);
                wait for Settle_c;
                check_equal(PulseCount, Count_v + 1, "Double fault on the receive side not visible");

                Count_v := PulseCount;
                flipIn(CopyAb_c);
                wait for Settle_c;
                check_equal(PulseCount, Count_v + 1, "Double fault on the transmit side not visible");

            end if;

            check(not PulseLong, "Output pulse longer than one clock cycle");
        end loop;

        -- TB done
        test_runner_cleanup(runner);
    end process;

    -----------------------------------------------------------------------------------------------
    -- Output Pulse Monitor
    -----------------------------------------------------------------------------------------------
    p_monitor : process (Out_Clk) is
        variable Last_v : std_logic := '0';
    begin
        if rising_edge(Out_Clk) then
            if Out_Pulse = '1' then
                PulseCount <= PulseCount + 1;
                if Last_v = '1' then
                    PulseLong <= true;
                end if;
            end if;
            Last_v := Out_Pulse;
        end if;
    end process;

end architecture;
