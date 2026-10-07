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
entity olo_ft_cc_pulse_tb is
    generic (
        runner_cfg     : string;
        ClockRatio_N_g : integer               := 3;
        ClockRatio_D_g : integer               := 2;
        SyncStages_g   : positive range 3 to 4 := 3
    );
end entity;

architecture sim of olo_ft_cc_pulse_tb is

    -----------------------------------------------------------------------------------------------
    -- Constants
    -----------------------------------------------------------------------------------------------
    constant ClockRatio_c : real    := real(ClockRatio_N_g) / real(ClockRatio_D_g);
    constant NumPulses_c  : integer := 4;

    constant ClkIn_Frequency_c  : real := 100.0e6;
    constant ClkIn_Period_c     : time := (1 sec) / ClkIn_Frequency_c;
    constant ClkOut_Frequency_c : real := ClkIn_Frequency_c * ClockRatio_c;
    constant ClkOut_Period_c    : time := (1 sec) / ClkOut_Frequency_c;

    -- Expected output pulse width: SyncStages_g - 1 cycles on Out_Clk
    constant ExpectedOutPulse_c : integer := SyncStages_g - 1;

    -- Slower of the two clocks defines the reaction time of the crossing
    constant SlowerClock_Period_c : time := (1 sec) / minimum(ClkIn_Frequency_c, ClkOut_Frequency_c);
    constant MaxReactionTime_c    : time := (8 + SyncStages_g) * SlowerClock_Period_c;

    -----------------------------------------------------------------------------------------------
    -- Interface Signals
    -----------------------------------------------------------------------------------------------
    signal In_Clk     : std_logic                                  := '0';
    signal In_RstIn   : std_logic                                  := '1';
    signal In_RstOut  : std_logic;
    signal In_Pulse   : std_logic_vector(NumPulses_c - 1 downto 0) := (others => '0');
    signal Out_Clk    : std_logic                                  := '0';
    signal Out_RstIn  : std_logic                                  := '1';
    signal Out_RstOut : std_logic;
    signal Out_Pulse  : std_logic_vector(NumPulses_c - 1 downto 0);

    -----------------------------------------------------------------------------------------------
    -- Helpers
    -----------------------------------------------------------------------------------------------
    -- Send a single-cycle pulse on bit <bit_idx> of In_Pulse
    procedure sendPulse (
        constant bit_idx : in    natural;
        signal   Clk     : in    std_logic;
        signal   Data    : out   std_logic_vector) is
    begin
        wait until rising_edge(Clk);
        Data(bit_idx) <= '1';
        wait until rising_edge(Clk);
        Data(bit_idx) <= '0';
    end procedure;

    -- Wait for a pulse on bit <bit_idx> of Out_Pulse, with timeout in Out_Clk cycles
    procedure waitForPulse (
        constant bit_idx : in    natural;
        constant timeout : in    natural;
        signal   Clk     : in    std_logic;
        signal   Data    : in    std_logic_vector;
        variable success : out   boolean) is
    begin
        success := false;

        for i in 0 to timeout - 1 loop
            wait until rising_edge(Clk);
            if Data(bit_idx) = '1' then
                success := true;
                exit;
            end if;
        end loop;

    end procedure;

    -- Count consecutive cycles the bit stays high (pulse width measurement)
    procedure countHighCycles (
        constant bit_idx : in    natural;
        constant max     : in    natural;
        signal   Clk     : in    std_logic;
        signal   Data    : in    std_logic_vector;
        variable cycles  : out   natural) is
    begin
        cycles := 0;

        for i in 0 to max - 1 loop
            if Data(bit_idx) = '1' then
                cycles := cycles + 1;
                wait until rising_edge(Clk);
            else
                exit;
            end if;
        end loop;

    end procedure;

begin

    -----------------------------------------------------------------------------------------------
    -- DUT
    -----------------------------------------------------------------------------------------------
    i_dut : entity olo.olo_ft_cc_pulse
        generic map (
            NumPulses_g  => NumPulses_c,
            SyncStages_g => SyncStages_g
        )
        port map (
            In_Clk     => In_Clk,
            In_RstIn   => In_RstIn,
            In_RstOut  => In_RstOut,
            In_Pulse   => In_Pulse,
            Out_Clk    => Out_Clk,
            Out_RstIn  => Out_RstIn,
            Out_RstOut => Out_RstOut,
            Out_Pulse  => Out_Pulse
        );

    -----------------------------------------------------------------------------------------------
    -- Clocks
    -----------------------------------------------------------------------------------------------
    In_Clk  <= not In_Clk after 0.5 * ClkIn_Period_c;
    Out_Clk <= not Out_Clk after 0.5 * ClkOut_Period_c;

    -----------------------------------------------------------------------------------------------
    -- TB Control
    -----------------------------------------------------------------------------------------------
    test_runner_watchdog(runner, 1 ms);

    p_control : process is
        variable Success_v : boolean;
        variable Cycles_v  : natural;
    begin
        test_runner_setup(runner, runner_cfg);

        while test_suite loop

            -- Reset
            In_RstIn  <= '1';
            Out_RstIn <= '1';
            In_Pulse  <= (others => '0');
            wait for 200 ns;
            wait until rising_edge(In_Clk);
            In_RstIn  <= '0';
            wait until rising_edge(Out_Clk);
            Out_RstIn <= '0';
            -- Wait for resets to de-assert
            wait until In_RstOut = '0' and rising_edge(In_Clk);
            wait until Out_RstOut = '0' and rising_edge(Out_Clk);

            for i in 1 to 10 loop
                wait until rising_edge(Out_Clk);
            end loop;

            -- Check no spurious output after reset
            check_equal(Out_Pulse, std_logic_vector'(NumPulses_c - 1 downto 0 => '0'),
                        "Out_Pulse should be 0 after reset");

            if run("SinglePulse") then
                -- Send a single pulse on bit 0 and verify it arrives
                sendPulse(0, In_Clk, In_Pulse);
                waitForPulse(0, 30, Out_Clk, Out_Pulse, Success_v);
                check(Success_v, "Output pulse did not arrive within 30 cycles");
                countHighCycles(0, 10, Out_Clk, Out_Pulse, Cycles_v);
                check_equal(Cycles_v, ExpectedOutPulse_c, "Output pulse width");

            elsif run("MultipleBitsIndependent") then
                -- Pulse on bit 1, verify other bits stay low
                sendPulse(1, In_Clk, In_Pulse);
                waitForPulse(1, 30, Out_Clk, Out_Pulse, Success_v);
                check(Success_v, "Output pulse on bit 1 did not arrive");
                check_equal(Out_Pulse(0), '0', "Bit 0 should not be pulsed");
                check_equal(Out_Pulse(2), '0', "Bit 2 should not be pulsed");
                check_equal(Out_Pulse(3), '0', "Bit 3 should not be pulsed");

                for i in 1 to 20 loop
                    wait until rising_edge(Out_Clk);
                    exit when Out_Pulse(1) = '0';
                end loop;

            elsif run("BackToBackPulses") then
                -- Send two pulses with enough spacing
                sendPulse(0, In_Clk, In_Pulse);
                waitForPulse(0, 30, Out_Clk, Out_Pulse, Success_v);
                check(Success_v, "First pulse did not arrive");

                for i in 1 to 30 loop
                    wait until rising_edge(Out_Clk);
                    exit when Out_Pulse(0) = '0';
                end loop;

                -- Additional settling time in both domains
                for i in 1 to 10 loop
                    wait until rising_edge(Out_Clk);
                end loop;

                for i in 1 to 10 loop
                    wait until rising_edge(In_Clk);
                end loop;

                -- Send the second pulse
                sendPulse(0, In_Clk, In_Pulse);
                waitForPulse(0, 30, Out_Clk, Out_Pulse, Success_v);
                check(Success_v, "Second pulse did not arrive");

            elsif run("AllBitsSimultaneous") then
                -- Pulse all bits at the same cycle
                wait until rising_edge(In_Clk);
                In_Pulse <= (others => '1');
                wait until rising_edge(In_Clk);
                In_Pulse <= (others => '0');

                -- Wait for the combined pulse to arrive
                for i in 0 to 29 loop
                    wait until rising_edge(Out_Clk);
                    exit when Out_Pulse /= std_logic_vector'(NumPulses_c - 1 downto 0 => '0');
                end loop;

                check_equal(Out_Pulse, std_logic_vector'(NumPulses_c - 1 downto 0 => '1'),
                            "All bits should pulse simultaneously");

                -- Wait for output to go back to 0
                for i in 1 to 30 loop
                    wait until rising_edge(Out_Clk);
                    exit when Out_Pulse = std_logic_vector'(NumPulses_c - 1 downto 0 => '0');
                end loop;

            elsif run("Reset") then
                -- Check if a reset on either side is propagated to both RstOut ports
                wait until rising_edge(In_Clk);
                In_RstIn <= '1';
                wait until rising_edge(In_Clk);
                In_RstIn <= '0';
                wait for MaxReactionTime_c*2;
                check_equal(In_RstOut, '0', "In_RstOut not de-asserted after In_RstIn");
                check_equal(Out_RstOut, '0', "Out_RstOut not de-asserted after In_RstIn");
                check(In_RstOut'last_event < MaxReactionTime_c*2, "In_RstOut not asserted after In_RstIn");
                check(Out_RstOut'last_event < MaxReactionTime_c*2, "Out_RstOut not asserted after In_RstIn");

                wait until rising_edge(Out_Clk);
                Out_RstIn <= '1';
                wait until rising_edge(Out_Clk);
                Out_RstIn <= '0';
                wait for MaxReactionTime_c*2;
                check_equal(In_RstOut, '0', "In_RstOut not de-asserted after Out_RstIn");
                check_equal(Out_RstOut, '0', "Out_RstOut not de-asserted after Out_RstIn");
                check(In_RstOut'last_event < MaxReactionTime_c*2, "In_RstOut not asserted after Out_RstIn");
                check(Out_RstOut'last_event < MaxReactionTime_c*2, "Out_RstOut not asserted after Out_RstIn");

            elsif run("NoPulse-RstIn") then
                -- Check that a sender-side reset does not produce a spurious output pulse
                sendPulse(0, In_Clk, In_Pulse);
                wait_for_value_stdlv(Out_Pulse, "0001", 100 us, "Pulse not transferred before In_RstIn");
                wait for MaxReactionTime_c;
                pulse_sig(In_RstIn, In_Clk);
                wait for MaxReactionTime_c;
                check_no_activity_stdlv(Out_Pulse, MaxReactionTime_c*2, "Unexpected pulse after In_RstIn");

            elsif run("NoPulse-RstOut") then
                -- Check that a receiver-side reset does not produce a spurious output pulse
                sendPulse(0, In_Clk, In_Pulse);
                wait_for_value_stdlv(Out_Pulse, "0001", 100 us, "Pulse not transferred before Out_RstIn");
                wait for MaxReactionTime_c;
                pulse_sig(Out_RstIn, Out_Clk);
                wait for MaxReactionTime_c;
                check_no_activity_stdlv(Out_Pulse, MaxReactionTime_c*2, "Unexpected pulse after Out_RstIn");

            elsif run("PulseDuringReset") then
                -- A pulse arriving while the sender side is in reset must be discarded: the SR
                -- latch is held clear as long as the synchronized reset is asserted
                wait until rising_edge(In_Clk);
                In_RstIn <= '1';
                wait for MaxReactionTime_c;
                sendPulse(0, In_Clk, In_Pulse);
                wait until rising_edge(In_Clk);
                In_RstIn <= '0';
                check_no_activity_stdlv(Out_Pulse, MaxReactionTime_c*2, "Pulse leaked through reset");

            end if;

        end loop;

        test_runner_cleanup(runner);
    end process;

end architecture;
