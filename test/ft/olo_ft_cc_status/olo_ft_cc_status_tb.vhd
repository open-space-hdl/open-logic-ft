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
entity olo_ft_cc_status_tb is
    generic (
        runner_cfg     : string;
        ClockRatio_N_g : integer               := 3;
        ClockRatio_D_g : integer               := 2;
        SyncStages_g   : positive range 2 to 4 := 2
    );
end entity;

architecture sim of olo_ft_cc_status_tb is

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
    constant Time_Rst_Assert_c    : time := 2 * SlowerClock_Period_c;
    constant Time_Rst_Recover_c   : time := 10 * SlowerClock_Period_c;
    constant Time_MaxDel_c        : time := 15 * SlowerClock_Period_c;

    -- Upper bound of the time one token needs for a round trip
    constant TokenPeriod_c : time := (6 + 2 * SyncStages_g) * SlowerClock_Period_c;
    constant Window_c      : time := 20 * TokenPeriod_c;

    -- Single-event upset (SEU) injection. The upsets are injected from the test bench by forcing
    -- the TMR copies inside the DUT through VHDL-2008 external names; the DUT is not modified.
    -- The first five targets are clocked by In_Clk, the others by Out_Clk.
    type SeuTarget_t is (
        SeuStarted, SeuVldIn, SeuFbToggleOut, SeuDataLatchIn, SeuToggleIn,
        SeuOutData, SeuOutValid, SeuToggleOut, SeuFbToggleIn
    );

    type SeuAction_t is (SeuFlip, SeuHold, SeuRelease);

    type SeuCmd_r is record
        Target : SeuTarget_t;
        Copies : std_logic_vector(0 to 2);
        Action : SeuAction_t;
    end record;

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
    signal In_Clk     : std_logic                                  := '0';
    signal In_RstIn   : std_logic                                  := '1';
    signal In_RstOut  : std_logic;
    signal In_Data    : std_logic_vector(DataWidth_c - 1 downto 0) := x"00";
    signal Out_Clk    : std_logic                                  := '0';
    signal Out_RstIn  : std_logic                                  := '1';
    signal Out_RstOut : std_logic;
    signal Out_Data   : std_logic_vector(DataWidth_c - 1 downto 0);

    -----------------------------------------------------------------------------------------------
    -- TB Signals
    -----------------------------------------------------------------------------------------------
    signal TokenCount  : natural := 0;
    signal MonitorEna  : boolean := false;
    signal SeuCmd      : SeuCmd_r;
    signal SeuReqCnt   : natural := 0;
    signal SeuAckCnt   : natural := 0;
    signal InjectEna   : boolean := false;
    signal InjectCount : natural := 0;

begin

    -----------------------------------------------------------------------------------------------
    -- DUT
    -----------------------------------------------------------------------------------------------
    i_dut : entity olo.olo_ft_cc_status
        generic map (
            Width_g      => DataWidth_c,
            SyncStages_g => SyncStages_g
        )
        port map (
            -- Clock Domain A
            In_Clk     => In_Clk,
            In_RstIn   => In_RstIn,
            In_RstOut  => In_RstOut,
            In_Data    => In_Data,
            -- Clock Domain B
            Out_Clk    => Out_Clk,
            Out_RstIn  => Out_RstIn,
            Out_RstOut => Out_RstOut,
            Out_Data   => Out_Data
        );

    -----------------------------------------------------------------------------------------------
    -- Clock
    -----------------------------------------------------------------------------------------------
    In_Clk  <= not In_Clk after 0.5 * ClkIn_Period_c;
    Out_Clk <= not Out_Clk after 0.5 * ClkOut_Period_c;

    -----------------------------------------------------------------------------------------------
    -- TB Control
    -----------------------------------------------------------------------------------------------
    test_runner_watchdog(runner, 20 ms);

    p_control : process is
        variable Tokens0_v : natural;
        variable Tokens1_v : natural;

        -- Issue an SEU command to p_seu and wait until it is executed
        procedure seu (
            Target : SeuTarget_t;
            Copies : std_logic_vector(0 to 2);
            Action : SeuAction_t) is
        begin
            SeuCmd    <= (Target => Target, Copies => Copies, Action => Action);
            SeuReqCnt <= SeuReqCnt + 1;
            wait until SeuAckCnt = SeuReqCnt;
        end procedure;

        -- Count the tokens (valid pulses) circulating within one window
        procedure countTokens (
            Tokens : out natural) is
            variable Start_v : natural;
        begin
            Start_v := TokenCount;
            wait for Window_c;
            Tokens  := TokenCount - Start_v;
        end procedure;

        variable InjCount_v : natural;
    begin
        test_runner_setup(runner, runner_cfg);

        while test_suite loop

            -- Reset
            In_RstIn  <= '1';
            Out_RstIn <= '1';
            wait for 1 us;

            -- Check if both sides are in reset
            check(In_RstOut = '1', "In_RstOut not asserted");
            check(Out_RstOut = '1', "Out_RstOut not asserted");

            -- Remove reset
            wait until rising_edge(In_Clk);
            In_RstIn  <= '0';
            wait until rising_edge(Out_Clk);
            Out_RstIn <= '0';
            wait for 1 us;

            -- Check if both sides exited reset
            check(In_RstOut = '0', "In_RstOut not de-asserted");
            check(Out_RstOut = '0', "Out_RstOut not de-asserted");

            -- *** Reset Tests ***
            if run("Reset") then

                -- Check if RstA is propagated to both sides
                wait until rising_edge(In_Clk);
                In_RstIn <= '1';
                wait until rising_edge(In_Clk);
                In_RstIn <= '0';
                wait for 1 us;
                check(In_RstOut = '0', "In_RstOut not de-asserted after In_RstIn");
                check(Out_RstOut = '0', "Out_RstOut not de-asserted after In_RstIn");
                check(In_RstOut'last_event < 1 us, "In_RstOut not asserted after In_RstIn");
                check(Out_RstOut'last_event < 1 us, "Out_RstOut not asserted after In_RstIn");

                -- Check if RstB is propagated to both sides
                wait until rising_edge(Out_Clk);
                Out_RstIn <= '1';
                wait until rising_edge(Out_Clk);
                Out_RstIn <= '0';
                wait for 1 us;
                check(In_RstOut = '0', "In_RstOut not de-asserted after Out_RstIn");
                check(Out_RstOut = '0', "Out_RstOut not de-asserted after Out_RstIn");
                check(In_RstOut'last_event < 1 us, "In_RstOut not asserted after Out_RstIn");
                check(Out_RstOut'last_event < 1 us, "Out_RstOut not asserted after Out_RstIn");

            -- *** Data Tests ***
            elsif run("Data") then
                -- data transfer after resetting both
                In_RstIn  <= '1';
                Out_RstIn <= '1';
                wait for Time_Rst_Assert_c;
                In_RstIn  <= '0';
                Out_RstIn <= '0';
                wait for Time_Rst_Recover_c;
                In_Data   <= x"AB";
                wait_for_value_stdlv(Out_Data, x"AB", Time_MaxDel_c, "Data not transferred 1");
                In_Data   <= x"CD";
                wait_for_value_stdlv(Out_Data, x"CD", Time_MaxDel_c, "Data not transferred 2");

                -- data transfer with A longer in reset
                In_RstIn  <= '1';
                Out_RstIn <= '1';
                wait for Time_Rst_Assert_c;
                Out_RstIn <= '0';
                wait for 100 * SlowerClock_Period_c;
                In_RstIn  <= '0';
                wait for Time_Rst_Recover_c;
                In_Data   <= x"12";
                wait_for_value_stdlv(Out_Data, x"12", Time_MaxDel_c, "Data not transferred 3");
                In_Data   <= x"34";
                wait_for_value_stdlv(Out_Data, x"34", Time_MaxDel_c, "Data not transferred 4");

                -- data transfer with B longer in reset
                In_RstIn  <= '1';
                Out_RstIn <= '1';
                wait for Time_Rst_Assert_c;
                In_RstIn  <= '0';
                wait for 100 * SlowerClock_Period_c;
                Out_RstIn <= '0';
                wait for Time_Rst_Recover_c;
                In_Data   <= x"56";
                wait_for_value_stdlv(Out_Data, x"56", Time_MaxDel_c, "Data not transferred 5");
                In_Data   <= x"78";
                wait_for_value_stdlv(Out_Data, x"78", Time_MaxDel_c, "Data not transferred 6");

            -- *** Fault Tolerance Tests ***
            elsif run("Seu-Token") then
                -- Upsetting any single copy of the token state for several token round trips does
                -- neither lose the token (data keeps updating) nor duplicate it (token rate unchanged)
                countTokens(Tokens0_v);
                check(Tokens0_v > 0, "No token circulating");

                for Target in SeuTarget_t'(SeuStarted) to SeuTarget_t'(SeuFbToggleIn) loop
                    -- Data and valid of the inner olo_ft_cc_simple are covered by its own test bench
                    if Target = SeuStarted or Target = SeuVldIn or Target = SeuFbToggleOut or Target = SeuFbToggleIn then

                        for Copy in 0 to 2 loop
                            seu(Target, copyMask(Copy), SeuHold);
                            wait for 3 * TokenPeriod_c;
                            seu(Target, copyMask(Copy), SeuRelease);
                            seu(Target, copyMask(Copy), SeuFlip);
                        end loop;

                    end if;
                end loop;

                countTokens(Tokens1_v);
                check(Tokens1_v <= Tokens0_v + 2 and Tokens1_v + 2 >= Tokens0_v,
                      "Token rate changed after upsets: " & integer'image(Tokens0_v) & " -> " & integer'image(Tokens1_v));
                In_Data <= x"E7";
                wait_for_value_stdlv(Out_Data, x"E7", Time_MaxDel_c, "Data not transferred after upsets");

            elsif run("DoubleFault-Visible") then
                -- Sanity check of the injection mechanism: TMR does not mask two upset copies of the
                -- output data. The status crossing re-transfers the data continuously, so even this
                -- double fault disappears with the next token.
                In_Data <= x"3C";
                wait_for_value_stdlv(Out_Data, x"3C", Time_MaxDel_c, "Data not transferred");
                seu(SeuOutData, CopyAb_c, SeuHold);
                wait for 1 ns;
                check_equal(Out_Data, 16#C3#, "Double fault on the output data not visible");
                seu(SeuOutData, CopyAb_c, SeuRelease);
                wait_for_value_stdlv(Out_Data, x"3C", Time_MaxDel_c, "No recovery after double fault");

            elsif run("Seu-RandomDuringTraffic") then
                -- Random single-copy upsets of all TMR registers while the input changes
                In_Data    <= x"00";
                wait_for_value_stdlv(Out_Data, x"00", Time_MaxDel_c, "Data not transferred");
                countTokens(Tokens0_v);
                MonitorEna <= true;
                InjCount_v := InjectCount;
                InjectEna  <= true;

                for i in 1 to 200 loop
                    wait for TokenPeriod_c / 2;
                    wait until rising_edge(In_Clk);
                    In_Data <= std_logic_vector(to_unsigned(i, DataWidth_c));
                end loop;

                InjectEna  <= false;
                wait for 40 * SlowerClock_Period_c;
                wait_for_value_stdlv(Out_Data, x"C8", Time_MaxDel_c, "Final value not transferred");
                MonitorEna <= false;
                countTokens(Tokens1_v);
                check(Tokens1_v <= Tokens0_v + 2 and Tokens1_v + 2 >= Tokens0_v,
                      "Token rate changed after upsets: " & integer'image(Tokens0_v) & " -> " & integer'image(Tokens1_v));
                check(InjectCount - InjCount_v >= 5, "Too few upsets injected");
            end if;

        end loop;

        -- TB done
        test_runner_cleanup(runner);
    end process;

    -----------------------------------------------------------------------------------------------
    -- Token Counter (white-box observation, no forcing)
    -----------------------------------------------------------------------------------------------
    p_token : process is
        alias VldInVote is << signal .olo_ft_cc_status_tb.i_dut.VldInVote : std_logic >>;
    begin
        wait until rising_edge(In_Clk);
        if VldInVote = '1' then
            TokenCount <= TokenCount + 1;
        end if;
    end process;

    -----------------------------------------------------------------------------------------------
    -- Output Monitor: the output only shows values that were applied to the input, in order
    -----------------------------------------------------------------------------------------------
    p_monitor : process (Out_Clk) is
        variable Last_v : natural := 0;
    begin
        if rising_edge(Out_Clk) then
            if MonitorEna then
                check(to_integer(unsigned(Out_Data)) >= Last_v, "Out_Data went backwards");
                check(to_integer(unsigned(Out_Data)) <= to_integer(unsigned(In_Data)), "Out_Data shows a value never applied");
                Last_v := to_integer(unsigned(Out_Data));
            else
                Last_v := 0;
            end if;
        end if;
    end process;

    -----------------------------------------------------------------------------------------------
    -- SEU Injection
    -----------------------------------------------------------------------------------------------
    p_seu : process is
        -- TMR copies inside the DUT
        alias Started       is << signal .olo_ft_cc_status_tb.i_dut.Started : std_logic_vector(0 to 2) >>;
        alias VldIn         is << signal .olo_ft_cc_status_tb.i_dut.VldIn : std_logic_vector(0 to 2) >>;
        alias FbToggleLast  is << signal .olo_ft_cc_status_tb.i_dut.i_bcc.ToggleLast : std_logic_vector(0 to 2) >>;
        alias FbToggleOut   is << signal .olo_ft_cc_status_tb.i_dut.i_bcc.ToggleOutLast : std_logic_vector(0 to 2) >>;
        alias DataLatchInA  is << signal .olo_ft_cc_status_tb.i_dut.i_scc.DataLatchInA : std_logic_vector(DataWidth_c - 1 downto 0) >>;
        alias DataLatchInB  is << signal .olo_ft_cc_status_tb.i_dut.i_scc.DataLatchInB : std_logic_vector(DataWidth_c - 1 downto 0) >>;
        alias DataLatchInC  is << signal .olo_ft_cc_status_tb.i_dut.i_scc.DataLatchInC : std_logic_vector(DataWidth_c - 1 downto 0) >>;
        alias Out_Data_SigA is << signal .olo_ft_cc_status_tb.i_dut.i_scc.Out_Data_SigA : std_logic_vector(DataWidth_c - 1 downto 0) >>;
        alias Out_Data_SigB is << signal .olo_ft_cc_status_tb.i_dut.i_scc.Out_Data_SigB : std_logic_vector(DataWidth_c - 1 downto 0) >>;
        alias Out_Data_SigC is << signal .olo_ft_cc_status_tb.i_dut.i_scc.Out_Data_SigC : std_logic_vector(DataWidth_c - 1 downto 0) >>;
        alias OutValid      is << signal .olo_ft_cc_status_tb.i_dut.i_scc.OutValid : std_logic_vector(0 to 2) >>;
        alias ToggleLast    is << signal .olo_ft_cc_status_tb.i_dut.i_scc.i_vld.ToggleLast : std_logic_vector(0 to 2) >>;
        alias ToggleOutLast is << signal .olo_ft_cc_status_tb.i_dut.i_scc.i_vld.ToggleOutLast : std_logic_vector(0 to 2) >>;

        -- Force the selected copies of a TMR register to their inverted value or release them
        procedure applyData (
            DoForce : boolean;
            Copies  : std_logic_vector(0 to 2);
            Target  : SeuTarget_t) is
        begin
            if Target = SeuDataLatchIn then
                if Copies(0) = '1' then
                    if DoForce then
                        DataLatchInA <= force not DataLatchInA;
                    else
                        DataLatchInA <= release;
                    end if;
                end if;
                if Copies(1) = '1' then
                    if DoForce then
                        DataLatchInB <= force not DataLatchInB;
                    else
                        DataLatchInB <= release;
                    end if;
                end if;
                if Copies(2) = '1' then
                    if DoForce then
                        DataLatchInC <= force not DataLatchInC;
                    else
                        DataLatchInC <= release;
                    end if;
                end if;
            else
                if Copies(0) = '1' then
                    if DoForce then
                        Out_Data_SigA <= force not Out_Data_SigA;
                    else
                        Out_Data_SigA <= release;
                    end if;
                end if;
                if Copies(1) = '1' then
                    if DoForce then
                        Out_Data_SigB <= force not Out_Data_SigB;
                    else
                        Out_Data_SigB <= release;
                    end if;
                end if;
                if Copies(2) = '1' then
                    if DoForce then
                        Out_Data_SigC <= force not Out_Data_SigC;
                    else
                        Out_Data_SigC <= release;
                    end if;
                end if;
            end if;
        end procedure;

        procedure apply (
            Target  : SeuTarget_t;
            Copies  : std_logic_vector(0 to 2);
            DoForce : boolean) is
        begin

            for i in 0 to 2 loop
                if Copies(i) = '1' then

                    case Target is
                        when SeuStarted =>
                            if DoForce then
                                Started(i) <= force not Started(i);
                            else
                                Started(i) <= release;
                            end if;
                        when SeuVldIn =>
                            if DoForce then
                                VldIn(i) <= force not VldIn(i);
                            else
                                VldIn(i) <= release;
                            end if;
                        when SeuFbToggleOut =>
                            if DoForce then
                                FbToggleOut(i) <= force not FbToggleOut(i);
                            else
                                FbToggleOut(i) <= release;
                            end if;
                        when SeuFbToggleIn =>
                            if DoForce then
                                FbToggleLast(i) <= force not FbToggleLast(i);
                            else
                                FbToggleLast(i) <= release;
                            end if;
                        when SeuToggleIn =>
                            if DoForce then
                                ToggleLast(i) <= force not ToggleLast(i);
                            else
                                ToggleLast(i) <= release;
                            end if;
                        when SeuToggleOut =>
                            if DoForce then
                                ToggleOutLast(i) <= force not ToggleOutLast(i);
                            else
                                ToggleOutLast(i) <= release;
                            end if;
                        when SeuOutValid =>
                            if DoForce then
                                OutValid(i) <= force not OutValid(i);
                            else
                                OutValid(i) <= release;
                            end if;
                        -- W-bit data registers are handled below
                        when others => null;
                    end case;

                end if;
            end loop;

            if Target = SeuDataLatchIn or Target = SeuOutData then
                applyData(DoForce, Copies, Target);
            end if;

        end procedure;

        -- Wait for a rising edge of the clock the target register is clocked with
        procedure waitEdge (
            Target : SeuTarget_t) is
        begin
            if Target <= SeuToggleIn then
                wait until rising_edge(In_Clk);
            else
                wait until rising_edge(Out_Clk);
            end if;
        end procedure;

        -- Upset the selected copies for exactly one clock edge
        procedure flip (
            Target : SeuTarget_t;
            Copies : std_logic_vector(0 to 2)) is
        begin
            waitEdge(Target);
            wait for 0.25 * minimum(ClkIn_Period_c, ClkOut_Period_c);
            apply(Target, Copies, true);
            waitEdge(Target);
            apply(Target, Copies, false);
        end procedure;

        variable Seed1_v  : positive := 3;
        variable Seed2_v  : positive := 4;
        variable Rand_v   : real;
        variable Target_v : SeuTarget_t;
        variable Copy_v   : natural range 0 to 2;
    begin
        if SeuReqCnt = SeuAckCnt and not InjectEna then
            wait until SeuReqCnt /= SeuAckCnt or InjectEna;
        end if;

        if SeuReqCnt /= SeuAckCnt then

            -- Command from p_control
            case SeuCmd.Action is
                when SeuFlip => flip(SeuCmd.Target, SeuCmd.Copies);
                when SeuHold => apply(SeuCmd.Target, SeuCmd.Copies, true);
                when SeuRelease => apply(SeuCmd.Target, SeuCmd.Copies, false);
                -- coverage off
                when others => null;
                -- coverage on
            end case;

            -- Let forced values settle before acknowledging
            wait for 0 ns;
            SeuAckCnt <= SeuReqCnt;
            wait until SeuAckCnt = SeuReqCnt;
        else
            -- Random single-copy upset after a random gap
            uniform(Seed1_v, Seed2_v, Rand_v);
            wait for (3.0 + 12.0 * Rand_v) * SlowerClock_Period_c;
            uniform(Seed1_v, Seed2_v, Rand_v);
            Target_v := SeuTarget_t'val(integer(floor(Rand_v * real(SeuTarget_t'pos(SeuTarget_t'high) + 1))));
            uniform(Seed1_v, Seed2_v, Rand_v);
            Copy_v   := integer(floor(Rand_v * 3.0));
            if InjectEna then
                flip(Target_v, copyMask(Copy_v));
                InjectCount <= InjectCount + 1;
            end if;
        end if;
    end process;

end architecture;
