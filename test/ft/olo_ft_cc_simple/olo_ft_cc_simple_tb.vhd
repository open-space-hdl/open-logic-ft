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
    context vunit_lib.com_context;
    context vunit_lib.vc_context;

library work;
    use work.olo_test_activity_pkg.all;

library olo;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
-- vunit: run_all_in_same_sim
entity olo_ft_cc_simple_tb is
    generic (
        runner_cfg     : string;
        ClockRatio_N_g : integer               := 3;
        ClockRatio_D_g : integer               := 2;
        SyncStages_g   : positive range 2 to 4 := 2
    );
end entity;

architecture sim of olo_ft_cc_simple_tb is

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
    constant MaxRatePeriod_c      : time := ClkOut_Period_c * (3+SyncStages_g);
    constant Settle_c             : time := (10 + 2 * SyncStages_g) * SlowerClock_Period_c;

    -- Single-event upset (SEU) injection. The upsets are injected from the test bench by forcing
    -- the TMR copies inside the DUT through VHDL-2008 external names; the DUT is not modified.
    type SeuTarget_t is (SeuDataLatchIn, SeuToggleIn, SeuOutData, SeuOutValid, SeuToggleOut);

    type SeuAction_t is (SeuFlip, SeuHold, SeuRelease);

    type SeuCmd_r is record
        Target : SeuTarget_t;
        Copies : std_logic_vector(0 to 2);
        Action : SeuAction_t;
    end record;

    -- Copy masks
    constant CopyA_c  : std_logic_vector(0 to 2) := "100";
    constant CopyB_c  : std_logic_vector(0 to 2) := "010";
    constant CopyC_c  : std_logic_vector(0 to 2) := "001";
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
    signal In_Valid   : std_logic                                  := '0';
    signal Out_Clk    : std_logic                                  := '0';
    signal Out_RstIn  : std_logic                                  := '1';
    signal Out_RstOut : std_logic;
    signal Out_Data   : std_logic_vector(DataWidth_c - 1 downto 0);
    signal Out_Valid  : std_logic;

    -----------------------------------------------------------------------------------------------
    -- TB Signals
    -----------------------------------------------------------------------------------------------
    signal ValidCount  : natural := 0;
    signal SeuCmd      : SeuCmd_r;
    signal SeuReqCnt   : natural := 0;
    signal SeuAckCnt   : natural := 0;
    signal InjectEna   : boolean := false;
    signal InjectCount : natural := 0;

    -----------------------------------------------------------------------------------------------
    -- Verification Components
    -----------------------------------------------------------------------------------------------
    constant AxisSlave_c : axi_stream_slave_t := new_axi_stream_slave (
        data_length => DataWidth_c,
        stall_config => new_stall_config(0.0, 0, 0)
    );

begin

    -----------------------------------------------------------------------------------------------
    -- DUT
    -----------------------------------------------------------------------------------------------
    i_dut : entity olo.olo_ft_cc_simple
        generic map (
            Width_g      => DataWidth_c,
            SyncStages_g => SyncStages_g
        )
        port map (
            -- Clock Domain A
            In_Clk      => In_Clk,
            In_RstIn    => In_RstIn,
            In_RstOut   => In_RstOut,
            In_Data     => In_Data,
            In_Valid    => In_Valid,
            -- Clock Domain B
            Out_Clk     => Out_Clk,
            Out_RstIn   => Out_RstIn,
            Out_RstOut  => Out_RstOut,
            Out_Data    => Out_Data,
            Out_Valid   => Out_Valid
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
        variable Stdlv_v : std_logic_vector(In_Data'range);
        variable Count_v : natural;

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

        -- Transfer one sample (single-cycle In_Valid pulse)
        procedure send (
            Data : std_logic_vector) is
        begin
            wait until rising_edge(In_Clk);
            In_Data  <= Data;
            In_Valid <= '1';
            wait until rising_edge(In_Clk);
            In_Data  <= x"00";
            In_Valid <= '0';
        end procedure;

        variable InjCount_v : natural;
        variable Stamp_v    : time;
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
                pulse_sig(In_RstIn, In_Clk);
                wait for 1 us;
                check(In_RstOut = '0', "In_RstOut not de-asserted after In_RstIn");
                check(Out_RstOut = '0', "Out_RstOut not de-asserted after In_RstIn");
                check(In_RstOut'last_event < 1 us, "In_RstOut not asserted after In_RstIn");
                check(Out_RstOut'last_event < 1 us, "Out_RstOut not asserted afterIn_RstIn");

                -- Check if RstB is propagated to both sides
                pulse_sig(Out_RstIn, Out_Clk);
                wait for 1 us;
                check(In_RstOut = '0', "In_RstOut not de-asserted after Out_RstIn");
                check(Out_RstOut = '0', "Out_RstOut not de-asserted after Out_RstIn");
                check(In_RstOut'last_event < 1 us, "In_RstOut not asserted after Out_RstIn");
                check(Out_RstOut'last_event < 1 us, "Out_RstOut not asserted after Out_RstIn");

            -- *** Data Tests ***
            elsif run("Transfer") then

                wait until rising_edge(In_Clk);
                In_Data  <= x"AB";
                In_Valid <= '1';
                wait until rising_edge(In_Clk);
                In_Data  <= x"00";
                In_Valid <= '0';
                wait until rising_edge(Out_Clk) and Out_Valid = '1';
                check_equal(Out_Data, 16#AB#, "Received wrong value 1");
                check_no_activity_stdlv(Out_Data, 10*ClkOut_Period_c, "Value was not kept after Vld going low 1");

                wait until rising_edge(In_Clk);
                In_Data  <= x"CD";
                In_Valid <= '1';
                wait until rising_edge(In_Clk);
                In_Data  <= x"00";
                In_Valid <= '0';
                wait until rising_edge(Out_Clk) and Out_Valid = '1';
                check_equal(Out_Data, 16#CD#, "Received wrong value 2");
                check_no_activity_stdlv(Out_Data, 10*ClkOut_Period_c, "Value was not kept after Vld going low 2");

            elsif run("MaxRate") then

                for i in 1 to 10 loop
                    wait until rising_edge(In_Clk);
                    Stdlv_v  := std_logic_vector(to_unsigned(i, In_Data'length));
                    In_Data  <= Stdlv_v;
                    In_Valid <= '1';
                    check_axi_stream(net, AxisSlave_c, Stdlv_v, blocking => false);
                    wait until rising_edge(In_Clk);
                    In_Valid <= '0';
                    wait for MaxRatePeriod_c-ClkOut_Period_c;
                end loop;

                wait_until_idle(net, as_sync(AxisSlave_c));

            -- *** Fault Tolerance Tests ***
            elsif run("Seu-DataLatchIn") then

                -- An upset copy of the transmit-side data latch is sampled by the receive side while
                -- the valid crosses. The voters mask it and the repair does not glitch the output.
                for Copy in 0 to 2 loop
                    Count_v := ValidCount;
                    Stdlv_v := std_logic_vector(to_unsigned(16#A1# + Copy, DataWidth_c));
                    send(Stdlv_v);
                    seu(SeuDataLatchIn, copyMask(Copy), SeuHold);
                    wait until rising_edge(Out_Clk) and Out_Valid = '1';
                    check_equal(Out_Data, Stdlv_v, "Upset of transmit copy " & integer'image(Copy) & " not masked");
                    seu(SeuDataLatchIn, copyMask(Copy), SeuRelease);
                    check_no_activity_stdlv(Out_Data, 10*ClkOut_Period_c, "Out_Data glitched during repair");
                    check_equal(ValidCount, Count_v + 1, "Wrong number of Out_Valid pulses");
                end loop;

            elsif run("Seu-DataOut") then
                -- Upsets of the held output data are masked. Upsetting the three copies one after
                -- the other (one clock cycle each) only stays masked if every upset copy is repaired
                -- before the next one is hit (voted feedback, no error accumulation).
                send(x"5A");
                wait until rising_edge(Out_Clk) and Out_Valid = '1';
                check_equal(Out_Data, 16#5A#, "Received wrong value");
                Stamp_v := now;

                for Copy in 0 to 2 loop
                    seu(SeuOutData, copyMask(Copy), SeuFlip);
                end loop;

                wait for Settle_c;
                check_equal(Out_Data, 16#5A#, "Upsets of the output copies not masked");
                check(Out_Data'last_event >= now - Stamp_v, "Out_Data glitched");

            elsif run("Seu-Valid") then
                -- Upsets of the valid path do neither produce spurious nor lose real Out_Valid pulses
                Count_v := ValidCount;

                for Copy in 0 to 2 loop
                    seu(SeuToggleIn, copyMask(Copy), SeuFlip);
                    seu(SeuToggleOut, copyMask(Copy), SeuFlip);
                    seu(SeuOutValid, copyMask(Copy), SeuFlip);
                end loop;

                wait for Settle_c;
                check_equal(ValidCount, Count_v, "Spurious Out_Valid pulse in idle state");

                -- Upset the toggle state while a valid pulse crosses: the transmit-side copy right
                -- after it toggled, the receive-side copy for the whole crossing
                for Copy in 0 to 2 loop
                    Count_v := ValidCount;
                    Stdlv_v := std_logic_vector(to_unsigned(16#C1# + Copy, DataWidth_c));
                    send(Stdlv_v);
                    seu(SeuToggleIn, copyMask(Copy), SeuHold);
                    wait until rising_edge(In_Clk);
                    seu(SeuToggleIn, copyMask(Copy), SeuRelease);
                    wait for Settle_c;
                    check_equal(ValidCount, Count_v + 1, "Wrong number of Out_Valid pulses (transmit side)");
                    check_equal(Out_Data, Stdlv_v, "Received wrong value (transmit side)");

                    Count_v := ValidCount;
                    Stdlv_v := std_logic_vector(to_unsigned(16#D1# + Copy, DataWidth_c));
                    send(Stdlv_v);
                    seu(SeuToggleOut, copyMask(Copy), SeuHold);
                    wait for Settle_c;
                    seu(SeuToggleOut, copyMask(Copy), SeuRelease);
                    wait for Settle_c;
                    check_equal(ValidCount, Count_v + 1, "Wrong number of Out_Valid pulses (receive side)");
                    check_equal(Out_Data, Stdlv_v, "Received wrong value (receive side)");
                end loop;

            elsif run("DoubleFault-Visible") then
                -- Sanity check of the injection mechanism: TMR does not mask two upset copies, so
                -- the same injections that are masked in the single-fault tests must become visible.
                send(x"3C");
                wait until rising_edge(Out_Clk) and Out_Valid = '1';
                check_equal(Out_Data, 16#3C#, "Received wrong value");

                -- Data path
                seu(SeuOutData, CopyAb_c, SeuHold);
                wait for ClkOut_Period_c;
                check_equal(Out_Data, 16#C3#, "Double fault on the output data not visible");
                seu(SeuOutData, CopyAb_c, SeuRelease);

                -- Valid path
                Count_v := ValidCount;
                seu(SeuToggleOut, CopyAb_c, SeuFlip);
                wait for Settle_c;
                check_equal(ValidCount, Count_v + 1, "Double fault on the toggle state not visible");

                -- A regular transfer recovers the crossing
                send(x"96");
                wait until rising_edge(Out_Clk) and Out_Valid = '1';
                check_equal(Out_Data, 16#96#, "No recovery after double fault");

            elsif run("Seu-RandomDuringTraffic") then
                -- Random single-copy upsets of all TMR registers while samples are transferred at
                -- the maximum rate
                Count_v    := ValidCount;
                InjCount_v := InjectCount;
                InjectEna  <= true;

                for i in 0 to 99 loop
                    wait until rising_edge(In_Clk);
                    Stdlv_v  := std_logic_vector(to_unsigned((i * 37) mod 256, In_Data'length));
                    In_Data  <= Stdlv_v;
                    In_Valid <= '1';
                    check_axi_stream(net, AxisSlave_c, Stdlv_v, blocking => false, msg => "sample " & integer'image(i));
                    wait until rising_edge(In_Clk);
                    In_Valid <= '0';
                    wait for MaxRatePeriod_c-ClkOut_Period_c;
                end loop;

                wait_until_idle(net, as_sync(AxisSlave_c));
                InjectEna <= false;
                wait for Settle_c + 40 * SlowerClock_Period_c;
                check_equal(ValidCount, Count_v + 100, "Wrong number of Out_Valid pulses");
                check(InjectCount - InjCount_v >= 5, "Too few upsets injected");
            end if;
        end loop;

        -- TB done
        test_runner_cleanup(runner);
    end process;

    -----------------------------------------------------------------------------------------------
    -- Out_Valid Counter
    -----------------------------------------------------------------------------------------------
    p_vld_count : process (Out_Clk) is
    begin
        if rising_edge(Out_Clk) then
            if Out_Valid = '1' then
                ValidCount <= ValidCount + 1;
            end if;
        end if;
    end process;

    -----------------------------------------------------------------------------------------------
    -- SEU Injection
    -----------------------------------------------------------------------------------------------
    p_seu : process is
        -- TMR copies inside the DUT
        alias DataLatchInA  is << signal .olo_ft_cc_simple_tb.i_dut.DataLatchInA : std_logic_vector(DataWidth_c - 1 downto 0) >>;
        alias DataLatchInB  is << signal .olo_ft_cc_simple_tb.i_dut.DataLatchInB : std_logic_vector(DataWidth_c - 1 downto 0) >>;
        alias DataLatchInC  is << signal .olo_ft_cc_simple_tb.i_dut.DataLatchInC : std_logic_vector(DataWidth_c - 1 downto 0) >>;
        alias Out_Data_SigA is << signal .olo_ft_cc_simple_tb.i_dut.Out_Data_SigA : std_logic_vector(DataWidth_c - 1 downto 0) >>;
        alias Out_Data_SigB is << signal .olo_ft_cc_simple_tb.i_dut.Out_Data_SigB : std_logic_vector(DataWidth_c - 1 downto 0) >>;
        alias Out_Data_SigC is << signal .olo_ft_cc_simple_tb.i_dut.Out_Data_SigC : std_logic_vector(DataWidth_c - 1 downto 0) >>;
        alias OutValid      is << signal .olo_ft_cc_simple_tb.i_dut.OutValid : std_logic_vector(0 to 2) >>;
        alias ToggleLast    is << signal .olo_ft_cc_simple_tb.i_dut.i_vld.ToggleLast : std_logic_vector(0 to 2) >>;
        alias ToggleOutLast is << signal .olo_ft_cc_simple_tb.i_dut.i_vld.ToggleOutLast : std_logic_vector(0 to 2) >>;

        -- Force the selected copies to their inverted value (DoForce = true) or release them
        procedure apply (
            Target  : SeuTarget_t;
            Copies  : std_logic_vector(0 to 2);
            DoForce : boolean) is
        begin

            case Target is
                when SeuDataLatchIn =>
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

                when SeuOutData =>
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

                when SeuOutValid =>

                    for i in 0 to 2 loop
                        if Copies(i) = '1' then
                            if DoForce then
                                OutValid(i) <= force not OutValid(i);
                            else
                                OutValid(i) <= release;
                            end if;
                        end if;
                    end loop;

                when SeuToggleIn =>

                    for i in 0 to 2 loop
                        if Copies(i) = '1' then
                            if DoForce then
                                ToggleLast(i) <= force not ToggleLast(i);
                            else
                                ToggleLast(i) <= release;
                            end if;
                        end if;
                    end loop;

                when SeuToggleOut =>

                    for i in 0 to 2 loop
                        if Copies(i) = '1' then
                            if DoForce then
                                ToggleOutLast(i) <= force not ToggleOutLast(i);
                            else
                                ToggleOutLast(i) <= release;
                            end if;
                        end if;
                    end loop;

                -- coverage off
                when others => null;
                -- coverage on
            end case;

        end procedure;

        -- Wait for a rising edge of the clock the target register is clocked with
        procedure waitEdge (
            Target : SeuTarget_t) is
        begin
            if Target = SeuDataLatchIn or Target = SeuToggleIn then
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

        variable Seed1_v  : positive := 1;
        variable Seed2_v  : positive := 2;
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

    -----------------------------------------------------------------------------------------------
    -- Verification Components
    -----------------------------------------------------------------------------------------------
    vc_response : entity vunit_lib.axi_stream_slave
        generic map (
            Slave => AxisSlave_c
        )
        port map (
            AClk   => Out_Clk,
            TValid => Out_Valid,
            TData  => Out_Data
        );

end architecture;
