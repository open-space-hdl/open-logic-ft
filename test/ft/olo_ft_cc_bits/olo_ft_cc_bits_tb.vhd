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
entity olo_ft_cc_bits_tb is
    generic (
        runner_cfg     : string;
        ClockRatio_N_g : integer               := 3;
        ClockRatio_D_g : integer               := 2;
        SyncStages_g   : positive range 2 to 4 := 2
    );
end entity;

architecture sim of olo_ft_cc_bits_tb is

    -----------------------------------------------------------------------------------------------
    -- Constants
    -----------------------------------------------------------------------------------------------
    constant ClockRatio_c : real    := real(ClockRatio_N_g) / real(ClockRatio_D_g);
    constant DataWidth_c  : integer := 8;

    -----------------------------------------------------------------------------------------------
    -- TB Definitions
    -----------------------------------------------------------------------------------------------
    constant ClkIn_Frequency_c    : real := 100.0e6;
    constant ClkIn_Period_c       : time := (1 sec) / ClkIn_Frequency_c;
    constant ClkOut_Frequency_c   : real := ClkIn_Frequency_c * ClockRatio_c;
    constant ClkOut_Period_c      : time := (1 sec) / ClkOut_Frequency_c;
    constant SlowerClock_Period_c : time := (1 sec) / minimum(ClkIn_Frequency_c, ClkOut_Frequency_c);

    constant Time_Rst_Assert_c  : time := 2 * SlowerClock_Period_c;
    constant Time_Rst_Recover_c : time := 10 * SlowerClock_Period_c;
    constant Time_MaxDel_c      : time := (real(SyncStages_g + 1) + 0.01) * SlowerClock_Period_c; -- 1 cycle per stage + 1 for input register
    constant Time_Flush_c       : time := (SyncStages_g + 3) * SlowerClock_Period_c;                -- an upset has left the chain

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
    signal In_Clk   : std_logic                                  := '0';
    signal In_Rst   : std_logic                                  := '1';
    signal In_Data  : std_logic_vector(DataWidth_c - 1 downto 0) := x"00";
    signal Out_Clk  : std_logic                                  := '0';
    signal Out_Rst  : std_logic                                  := '1';
    signal Out_Data : std_logic_vector(DataWidth_c - 1 downto 0);

    -----------------------------------------------------------------------------------------------
    -- TB Signals
    -----------------------------------------------------------------------------------------------
    signal OutChanges : natural := 0;

begin

    -----------------------------------------------------------------------------------------------
    -- DUT
    -----------------------------------------------------------------------------------------------
    i_dut : entity olo.olo_ft_cc_bits
        generic map (
            Width_g      => DataWidth_c,
            SyncStages_g => SyncStages_g
        )
        port map (
            In_Clk   => In_Clk,
            In_Rst   => In_Rst,
            In_Data  => In_Data,
            Out_Clk  => Out_Clk,
            Out_Rst  => Out_Rst,
            Out_Data => Out_Data
        );

    -----------------------------------------------------------------------------------------------
    -- Clock
    -----------------------------------------------------------------------------------------------
    In_Clk  <= not In_Clk after 0.5 * ClkIn_Period_c;
    Out_Clk <= not Out_Clk after 0.5 * ClkOut_Period_c;

    -----------------------------------------------------------------------------------------------
    -- TB Control
    -----------------------------------------------------------------------------------------------
    test_runner_watchdog(runner, 1 ms);

    p_control : process is
        -- Sender register and first synchronizer stage of the TMR copies inside the DUT
        alias RegInA is << signal .olo_ft_cc_bits_tb.i_dut.g_copy(0).RegIn : std_logic_vector(DataWidth_c - 1 downto 0) >>;
        alias RegInB is << signal .olo_ft_cc_bits_tb.i_dut.g_copy(1).RegIn : std_logic_vector(DataWidth_c - 1 downto 0) >>;
        alias RegInC is << signal .olo_ft_cc_bits_tb.i_dut.g_copy(2).RegIn : std_logic_vector(DataWidth_c - 1 downto 0) >>;
        alias Reg0A  is << signal .olo_ft_cc_bits_tb.i_dut.g_copy(0).Reg0 : std_logic_vector(DataWidth_c - 1 downto 0) >>;
        alias Reg0B  is << signal .olo_ft_cc_bits_tb.i_dut.g_copy(1).Reg0 : std_logic_vector(DataWidth_c - 1 downto 0) >>;
        alias Reg0C  is << signal .olo_ft_cc_bits_tb.i_dut.g_copy(2).Reg0 : std_logic_vector(DataWidth_c - 1 downto 0) >>;

        -- Force the sender register of the selected copies to a value (until releaseIn)
        procedure forceIn (
            Copies : std_logic_vector(0 to 2);
            Value  : std_logic_vector(DataWidth_c - 1 downto 0)) is
        begin
            if Copies(0) = '1' then
                RegInA <= force Value;
            end if;
            if Copies(1) = '1' then
                RegInB <= force Value;
            end if;
            if Copies(2) = '1' then
                RegInC <= force Value;
            end if;
        end procedure;

        procedure releaseIn is
        begin
            RegInA <= release;
            RegInB <= release;
            RegInC <= release;
        end procedure;

        -- Force the first synchronizer stage of the selected copies to a value (until releaseOut)
        procedure forceOut (
            Copies : std_logic_vector(0 to 2);
            Value  : std_logic_vector(DataWidth_c - 1 downto 0)) is
        begin
            if Copies(0) = '1' then
                Reg0A <= force Value;
            end if;
            if Copies(1) = '1' then
                Reg0B <= force Value;
            end if;
            if Copies(2) = '1' then
                Reg0C <= force Value;
            end if;
        end procedure;

        procedure releaseOut is
        begin
            Reg0A <= release;
            Reg0B <= release;
            Reg0C <= release;
        end procedure;

        -- Upset all bits of the sender register of the selected copies for one In_Clk edge
        procedure flipIn (
            Copies : std_logic_vector(0 to 2)) is
        begin
            wait until rising_edge(In_Clk);
            wait for 0.25 * ClkIn_Period_c;
            forceIn(Copies, not In_Data);
            -- Hold the upset until the receiver has sampled it (an unsampled upset has no effect)
            wait until rising_edge(Out_Clk);
            wait until rising_edge(In_Clk);
            wait for 0.25 * ClkIn_Period_c;
            releaseIn;
        end procedure;

        -- Upset all bits of the first synchronizer stage of the selected copies for one Out_Clk edge
        procedure flipOut (
            Copies : std_logic_vector(0 to 2)) is
        begin
            wait until rising_edge(Out_Clk);
            wait for 0.25 * ClkOut_Period_c;
            forceOut(Copies, not Out_Data);
            wait until rising_edge(Out_Clk);
            wait for 0.25 * ClkOut_Period_c;
            releaseOut;
        end procedure;

        variable Start_v : time;
        variable Count_v : natural;
        variable Old_v   : std_logic_vector(DataWidth_c - 1 downto 0);
        variable New_v   : std_logic_vector(DataWidth_c - 1 downto 0);
        variable Force_v : std_logic_vector(DataWidth_c - 1 downto 0);
    begin
        test_runner_setup(runner, runner_cfg);

        while test_suite loop

            -- *** Reset ***
            In_Rst  <= '1';
            Out_Rst <= '1';
            wait for Time_Rst_Assert_c;
            In_Rst  <= '0';
            Out_Rst <= '0';
            wait for Time_Rst_Recover_c;

            if run("SimpleTransfer") then
                In_Data <= x"AB";
                wait_for_value_stdlv(Out_Data, x"AB", Time_MaxDel_c, "Data not transferred 1");
                In_Data <= x"CD";
                wait_for_value_stdlv(Out_Data, x"CD", Time_MaxDel_c, "Data not transferred 2");

            -- data transfer with A longer in reset
            elsif run("LongResetA") then
                wait until rising_edge(In_Clk);
                In_Rst  <= '1';
                Out_Rst <= '1';
                wait for Time_Rst_Assert_c;
                Out_Rst <= '0';
                wait for 100 * SlowerClock_Period_c;
                In_Rst  <= '0';
                wait for Time_Rst_Recover_c;
                In_Data <= x"12";
                wait_for_value_stdlv(Out_Data, x"12", Time_MaxDel_c, "Data not transferred 3");
                In_Data <= x"34";
                wait_for_value_stdlv(Out_Data, x"34", Time_MaxDel_c, "Data not transferred 4");

            -- data transfer with B longer in reset
            elsif run("LongResetB") then
                wait until rising_edge(In_Clk);
                In_Rst  <= '1';
                Out_Rst <= '1';
                wait for Time_Rst_Assert_c;
                In_Rst  <= '0';
                wait for 100 * SlowerClock_Period_c;
                Out_Rst <= '0';
                wait for Time_Rst_Recover_c;
                In_Data <= x"56";
                wait_for_value_stdlv(Out_Data, x"56", Time_MaxDel_c, "Data not transferred 5");
                In_Data <= x"78";
                wait_for_value_stdlv(Out_Data, x"78", Time_MaxDel_c, "Data not transferred 6");

            -- Upsets of any single copy do not change a stable output (each upset leaves the chain
            -- before the next one is injected)
            elsif run("Seu-Idle") then
                In_Data <= x"5A";
                wait_for_value_stdlv(Out_Data, x"5A", Time_MaxDel_c, "Data not transferred");
                wait for Time_Flush_c;
                Start_v := now;

                for Copy in 0 to 2 loop
                    flipIn(copyMask(Copy));
                    wait for Time_Flush_c;
                    flipOut(copyMask(Copy));
                    wait for Time_Flush_c;
                end loop;

                check(Out_Data'last_event >= now - Start_v, "Output changed by a single upset");
                check_equal(Out_Data, std_logic_vector'(x"5A"), "Output changed by a single upset");

            -- One copy takes a change earlier or later than the other two (sampling uncertainty of
            -- the crossing, or an upset during the change): the output changes exactly once, at the
            -- time of the other two copies
            elsif run("Seu-Crossing") then
                Old_v   := x"5A";
                In_Data <= Old_v;
                wait_for_value_stdlv(Out_Data, Old_v, Time_MaxDel_c, "Data not transferred");
                wait for Time_Flush_c;

                for Copy in 0 to 2 loop

                    for Side in 0 to 1 loop

                        for Early in boolean loop
                            New_v   := not Old_v;
                            Count_v := OutChanges;

                            -- Deviating copy: shows the new value before the others (Early) or keeps
                            -- the old value after the others have taken the new one (not Early)
                            if Early then
                                Force_v := New_v;
                            else
                                Force_v := Old_v;
                            end if;
                            wait until rising_edge(In_Clk);
                            if Side = 0 then
                                forceIn(copyMask(Copy), Force_v);
                            else
                                forceOut(copyMask(Copy), Force_v);
                            end if;
                            wait for Time_Flush_c;
                            check_equal(Out_Data, Old_v, "Single early copy changed the output");

                            -- Change the input: the other two copies take it within the normal latency
                            wait until rising_edge(In_Clk);
                            In_Data <= New_v;
                            wait_for_value_stdlv(Out_Data, New_v, Time_MaxDel_c, "Single late copy delayed the output");
                            wait for Time_Flush_c;

                            -- Release the deviating copy: it catches up without changing the output
                            releaseIn;
                            releaseOut;
                            wait for Time_Flush_c;
                            check_equal(Out_Data, New_v, "Output wrong after release");
                            check_equal(OutChanges, Count_v + 1, "Output did not change exactly once");

                            Old_v := New_v;
                        end loop;

                    end loop;

                end loop;

            -- Sanity check of the injection: upsets of two copies are not masked
            elsif run("DoubleFault-Visible") then
                In_Data <= x"5A";
                wait_for_value_stdlv(Out_Data, x"5A", Time_MaxDel_c, "Data not transferred");
                flipOut(CopyAb_c);
                wait_for_value_stdlv(Out_Data, x"A5", Time_MaxDel_c, "Double upset (receive side) not visible");
                wait_for_value_stdlv(Out_Data, x"5A", Time_Flush_c, "Upset (receive side) not shifted out");
                flipIn(CopyAb_c);
                wait_for_value_stdlv(Out_Data, x"A5", Time_MaxDel_c, "Double upset (send side) not visible");
                wait_for_value_stdlv(Out_Data, x"5A", Time_Flush_c, "Upset (send side) not shifted out");
            end if;
        end loop;

        -- TB done
        test_runner_cleanup(runner);
    end process;

    -----------------------------------------------------------------------------------------------
    -- Output Monitor (counts the output changes seen by the receiver)
    -----------------------------------------------------------------------------------------------
    p_monitor : process (Out_Clk) is
        variable Last_v : std_logic_vector(DataWidth_c - 1 downto 0) := (others => '0');
    begin
        if rising_edge(Out_Clk) then
            if Out_Data /= Last_v then
                OutChanges <= OutChanges + 1;
            end if;
            Last_v := Out_Data;
        end if;
    end process;

end architecture;
