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

library olo;
    use olo.olo_base_pkg_math.all;
    use olo.olo_base_pkg_logic.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
-- vunit: run_all_in_same_sim
entity olo_ft_cc_handshake_tb is
    generic (
        runner_cfg      : string;
        RandomStall_g   : boolean               := false;
        ReadyRstState_g : integer               := 1;
        ClockRatio_N_g  : integer               := 1;
        ClockRatio_D_g  : integer               := 1;
        SyncStages_g    : positive range 2 to 4 := 2
    );
end entity;

architecture sim of olo_ft_cc_handshake_tb is

    -----------------------------------------------------------------------------------------------
    -- Constants
    -----------------------------------------------------------------------------------------------
    constant ClockRatio_c    : real      := real(ClockRatio_N_g) / real(ClockRatio_D_g);
    constant DataWidth_c     : integer   := 16;
    constant ReadyRstState_c : std_logic := choose(ReadyRstState_g = 0, '0', '1');

    -----------------------------------------------------------------------------------------------
    -- TB Definitions
    -----------------------------------------------------------------------------------------------
    constant ClkIn_Frequency_c    : real := 100.0e6;
    constant ClkIn_Period_c       : time := (1 sec) / ClkIn_Frequency_c;
    constant ClkOut_Frequency_c   : real := ClkIn_Frequency_c * ClockRatio_c;
    constant ClkOut_Period_c      : time := (1 sec) / ClkOut_Frequency_c;
    constant SlowerClock_Period_c : time := (1 sec) / minimum(ClkIn_Frequency_c, ClkOut_Frequency_c);
    constant Settle_c             : time := (10 + 2 * SyncStages_g) * SlowerClock_Period_c;

    -- Single-event upset (SEU) injection. The upsets are injected from the test bench by forcing
    -- the TMR copies inside the DUT through VHDL-2008 external names; the DUT is not modified.
    -- The first four targets are clocked by In_Clk, the others by Out_Clk.
    type SeuTarget_t is (
        SeuInLatched, SeuAckToggleOut, SeuDataLatchIn, SeuToggleIn,
        SeuOutLatched, SeuOutData, SeuOutValid, SeuToggleOut, SeuAckToggleIn
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
    -- TB Defnitions
    -----------------------------------------------------------------------------------------------
    shared variable InDelay_v  : time := 0 ns;
    shared variable OutDelay_v : time := 0 ns;

    -- *** Verification Compnents ***
    constant AxisMaster_c : axi_stream_master_t := new_axi_stream_master (
        data_length => DataWidth_c,
        stall_config => new_stall_config(choose(RandomStall_g, 0.5, 0.0), 0, 20)
    );
    constant AxisSlave_c  : axi_stream_slave_t  := new_axi_stream_slave (
        data_length => DataWidth_c,
        stall_config => new_stall_config(choose(RandomStall_g, 0.5, 0.0), 0, 20)
    );

    -- *** Procedures ***
    procedure pushValues (
        signal net : inout network_t;
        values     : integer := 100;
        first      : integer := 0) is
    begin

        -- Loop over values
        for i in first to first + values - 1 loop
            if InDelay_v > 0 ns then
                wait for InDelay_v;
            end if;
            push_axi_stream(net, AxisMaster_c, toUslv(i, DataWidth_c));
        end loop;

    end procedure;

    procedure checkValues (
        signal net : inout network_t;
        values     : integer := 100;
        first      : integer := 0) is
    begin

        -- Loop over values
        for i in first to first + values - 1 loop
            if OutDelay_v > 0 ns then
                wait for OutDelay_v;
            end if;
            check_axi_stream(net, AxisSlave_c, toUslv(i, DataWidth_c), blocking => false, msg => "data " & integer'image(i));
        end loop;

    end procedure;

    -----------------------------------------------------------------------------------------------
    -- Interface Signals
    -----------------------------------------------------------------------------------------------
    signal In_Clk     : std_logic                                  := '0';
    signal In_RstIn   : std_logic                                  := '0';
    signal In_RstOut  : std_logic                                  := '0';
    signal In_Valid   : std_logic                                  := '0';
    signal In_Ready   : std_logic                                  := '0';
    signal In_Data    : std_logic_vector(DataWidth_c - 1 downto 0) := (others => '0');
    signal Out_Clk    : std_logic                                  := '0';
    signal Out_RstIn  : std_logic                                  := '0';
    signal Out_RstOut : std_logic                                  := '0';
    signal Out_Valid  : std_logic                                  := '0';
    signal Out_Ready  : std_logic                                  := '0';
    signal Out_Data   : std_logic_vector(DataWidth_c - 1 downto 0) := (others => '0');

    -----------------------------------------------------------------------------------------------
    -- TB Signals
    -----------------------------------------------------------------------------------------------
    signal InBeatCount  : natural := 0;
    signal OutBeatCount : natural := 0;
    signal SeuCmd       : SeuCmd_r;
    signal SeuReqCnt    : natural := 0;
    signal SeuAckCnt    : natural := 0;
    signal InjectEna    : boolean := false;
    signal InjectCount  : natural := 0;

begin

    -----------------------------------------------------------------------------------------------
    -- TB Control
    -----------------------------------------------------------------------------------------------
    test_runner_watchdog(runner, 20 ms);

    p_control : process is
        variable InBeats_v  : natural;
        variable OutBeats_v : natural;

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

        variable InjCount_v : natural;
    begin
        test_runner_setup(runner, runner_cfg);

        while test_suite loop

            InDelay_v  := 0 ns;
            OutDelay_v := 0 ns;

            -- Reset
            wait until rising_edge(In_Clk);
            In_RstIn <= '1';
            wait for 1 us;
            wait until rising_edge(In_Clk);
            In_RstIn <= '0';
            wait until rising_edge(In_Clk) and In_RstOut = '0' and Out_RstOut = '0';

            InBeats_v  := InBeatCount;
            OutBeats_v := OutBeatCount;

            -- Check values after reset
            if run("ResetValues") then
                check_equal(In_Ready, '1', "In_Ready after reset");
                check_equal(Out_Valid, '0', "Out_Valid after ");
                -- assert reset
                In_RstIn <= '1';
                wait until rising_edge(In_Clk) and In_RstOut = '1' and Out_RstOut = '1';
                wait until rising_edge(Out_Clk) and In_RstOut = '1' and Out_RstOut = '1';
                check_equal(In_Ready, ReadyRstState_c, "In_Ready in reset");
                In_RstIn <= '0';

            -- Single Word
            elsif run("Basic") then
                -- One value
                push_axi_stream(net, AxisMaster_c, toUslv(5, DataWidth_c));
                check_axi_stream(net, AxisSlave_c, toUslv(5, DataWidth_c), blocking => false, msg => "data a");
                -- Second value
                wait for 20*SlowerClock_Period_c;
                push_axi_stream(net, AxisMaster_c, toUslv(10, DataWidth_c));
                check_axi_stream(net, AxisSlave_c, toUslv(10, DataWidth_c), blocking => false, msg => "data b");

            elsif run("FullThrottle") then
                if not RandomStall_g then
                    pushValues(net, 20);
                    checkValues(net, 20);
                else
                    pushValues(net, 1000);
                    checkValues(net, 1000);
                end if;

            elsif run("OutLimited") then
                pushValues(net, 20);
                OutDelay_v := SlowerClock_Period_c*20;
                checkValues(net, 20);

            elsif run("InLimited") then
                checkValues(net, 20);
                InDelay_v := SlowerClock_Period_c*20;
                pushValues(net, 20);

            -- *** Fault Tolerance Tests ***
            elsif run("Seu-HandshakeState") then

                -- Upsetting any single copy of the handshake state for the duration of a slow
                -- transfer sequence (output stalls, so the output-side latch is used) does neither
                -- lose nor duplicate data
                for Target in SeuInLatched to SeuAckToggleIn loop
                    if Target = SeuInLatched or Target = SeuAckToggleOut or Target = SeuOutLatched or Target = SeuAckToggleIn then

                        for Copy in 0 to 2 loop
                            seu(Target, copyMask(Copy), SeuHold);
                            pushValues(net, 4, 100);
                            OutDelay_v := SlowerClock_Period_c*(5 + 2 * SyncStages_g);
                            checkValues(net, 4, 100);
                            OutDelay_v := 0 ns;
                            wait_until_idle(net, as_sync(AxisSlave_c));
                            seu(Target, copyMask(Copy), SeuRelease);
                            seu(Target, copyMask(Copy), SeuFlip);
                        end loop;

                    end if;
                end loop;

                wait for Settle_c;
                check_equal(InBeatCount - InBeats_v, 4 * 12, "Wrong number of input beats");
                check_equal(OutBeatCount - OutBeats_v, 4 * 12, "Wrong number of output beats");

            elsif run("DoubleFault-Visible") then
                -- Sanity check of the injection mechanism: TMR does not mask two upset copies. With
                -- two input-side handshake copies upset, the input side waits for an acknowledge
                -- that never comes, until the next reset.
                check_equal(In_Ready, '1', "In_Ready not set in idle state");
                seu(SeuInLatched, CopyAb_c, SeuHold);
                wait for 1 ns;
                check_equal(In_Ready, '0', "Double fault on the input handshake state not visible");
                -- Hold the upset over a clock edge, so the voted feedback latches the wrong majority
                wait until rising_edge(In_Clk);
                wait for 1 ns;
                seu(SeuInLatched, CopyAb_c, SeuRelease);
                wait for Settle_c;
                check_equal(In_Ready, '0', "Double fault on the input handshake state was masked");

                -- A reset recovers the crossing
                wait until rising_edge(In_Clk);
                In_RstIn   <= '1';
                wait until rising_edge(In_Clk);
                In_RstIn   <= '0';
                wait until rising_edge(In_Clk) and In_RstOut = '0' and Out_RstOut = '0';
                check_equal(In_Ready, '1', "No recovery after reset");
                InBeats_v  := InBeatCount;
                OutBeats_v := OutBeatCount;
                pushValues(net, 4);
                checkValues(net, 4);
                wait_until_idle(net, as_sync(AxisSlave_c));
                check_equal(OutBeatCount - OutBeats_v, 4, "Wrong number of output beats");

            elsif run("Seu-RandomDuringTraffic") then
                -- Random single-copy upsets of all TMR registers during a long transfer sequence
                InjCount_v := InjectCount;
                InjectEna  <= true;
                pushValues(net, 300);
                checkValues(net, 300);
                wait_until_idle(net, as_sync(AxisSlave_c));
                InjectEna  <= false;
                wait for Settle_c + 40 * SlowerClock_Period_c;
                check_equal(InBeatCount - InBeats_v, 300, "Wrong number of input beats");
                check_equal(OutBeatCount - OutBeats_v, 300, "Wrong number of output beats");
                check(InjectCount - InjCount_v >= 5, "Too few upsets injected");
            end if;

            wait for 1 us;
            wait_until_idle(net, as_sync(AxisMaster_c));
            wait_until_idle(net, as_sync(AxisSlave_c));

        end loop;

        -- TB done
        test_runner_cleanup(runner);
    end process;

    -----------------------------------------------------------------------------------------------
    -- Clock
    -----------------------------------------------------------------------------------------------
    In_Clk  <= not In_Clk after 0.5 * ClkIn_Period_c;
    Out_Clk <= not Out_Clk after 0.5 * ClkOut_Period_c;

    -----------------------------------------------------------------------------------------------
    -- DUT
    -----------------------------------------------------------------------------------------------
    i_dut : entity olo.olo_ft_cc_handshake
        generic map (
            Width_g         => DataWidth_c,
            ReadyRstState_g => ReadyRstState_c,
            SyncStages_g    => SyncStages_g
        )
        port map (
            In_Clk      => In_Clk,
            In_RstIn    => In_RstIn,
            In_RstOut   => In_RstOut,
            In_Valid    => In_Valid,
            In_Ready    => In_Ready,
            In_Data     => In_Data,
            Out_Clk     => Out_Clk,
            Out_RstIn   => Out_RstIn,
            Out_RstOut  => Out_RstOut,
            Out_Valid   => Out_Valid,
            Out_Ready   => Out_Ready,
            Out_Data    => Out_Data
        );

    -----------------------------------------------------------------------------------------------
    -- Beat Counters
    -----------------------------------------------------------------------------------------------
    p_in_beats : process (In_Clk) is
    begin
        if rising_edge(In_Clk) then
            if In_Valid = '1' and In_Ready = '1' then
                InBeatCount <= InBeatCount + 1;
            end if;
        end if;
    end process;

    p_out_beats : process (Out_Clk) is
    begin
        if rising_edge(Out_Clk) then
            if Out_Valid = '1' and Out_Ready = '1' then
                OutBeatCount <= OutBeatCount + 1;
            end if;
        end if;
    end process;

    -----------------------------------------------------------------------------------------------
    -- SEU Injection
    -----------------------------------------------------------------------------------------------
    p_seu : process is
        -- TMR copies inside the DUT
        alias InLatched     is << signal .olo_ft_cc_handshake_tb.i_dut.InLatched : std_logic_vector(0 to 2) >>;
        alias OutLatched    is << signal .olo_ft_cc_handshake_tb.i_dut.OutLatched : std_logic_vector(0 to 2) >>;
        alias AckToggleLast is << signal .olo_ft_cc_handshake_tb.i_dut.i_bcc.ToggleLast : std_logic_vector(0 to 2) >>;
        alias AckToggleOut  is << signal .olo_ft_cc_handshake_tb.i_dut.i_bcc.ToggleOutLast : std_logic_vector(0 to 2) >>;
        alias DataLatchInA  is << signal .olo_ft_cc_handshake_tb.i_dut.i_scc.DataLatchInA : std_logic_vector(DataWidth_c - 1 downto 0) >>;
        alias DataLatchInB  is << signal .olo_ft_cc_handshake_tb.i_dut.i_scc.DataLatchInB : std_logic_vector(DataWidth_c - 1 downto 0) >>;
        alias DataLatchInC  is << signal .olo_ft_cc_handshake_tb.i_dut.i_scc.DataLatchInC : std_logic_vector(DataWidth_c - 1 downto 0) >>;
        alias Out_Data_SigA is << signal .olo_ft_cc_handshake_tb.i_dut.i_scc.Out_Data_SigA : std_logic_vector(DataWidth_c - 1 downto 0) >>;
        alias Out_Data_SigB is << signal .olo_ft_cc_handshake_tb.i_dut.i_scc.Out_Data_SigB : std_logic_vector(DataWidth_c - 1 downto 0) >>;
        alias Out_Data_SigC is << signal .olo_ft_cc_handshake_tb.i_dut.i_scc.Out_Data_SigC : std_logic_vector(DataWidth_c - 1 downto 0) >>;
        alias OutValid      is << signal .olo_ft_cc_handshake_tb.i_dut.i_scc.OutValid : std_logic_vector(0 to 2) >>;
        alias ToggleLast    is << signal .olo_ft_cc_handshake_tb.i_dut.i_scc.i_vld.ToggleLast : std_logic_vector(0 to 2) >>;
        alias ToggleOutLast is << signal .olo_ft_cc_handshake_tb.i_dut.i_scc.i_vld.ToggleOutLast : std_logic_vector(0 to 2) >>;

        -- Force the selected copies of a W-bit TMR register to their inverted value or release them
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

        -- Force the selected copies of a TMR register to their inverted value or release them
        procedure apply (
            Target  : SeuTarget_t;
            Copies  : std_logic_vector(0 to 2);
            DoForce : boolean) is
        begin

            for i in 0 to 2 loop
                if Copies(i) = '1' then

                    case Target is
                        when SeuInLatched =>
                            if DoForce then
                                InLatched(i) <= force not InLatched(i);
                            else
                                InLatched(i) <= release;
                            end if;
                        when SeuOutLatched =>
                            if DoForce then
                                OutLatched(i) <= force not OutLatched(i);
                            else
                                OutLatched(i) <= release;
                            end if;
                        when SeuAckToggleIn =>
                            if DoForce then
                                AckToggleLast(i) <= force not AckToggleLast(i);
                            else
                                AckToggleLast(i) <= release;
                            end if;
                        when SeuAckToggleOut =>
                            if DoForce then
                                AckToggleOut(i) <= force not AckToggleOut(i);
                            else
                                AckToggleOut(i) <= release;
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

        variable Seed1_v  : positive := 5;
        variable Seed2_v  : positive := 6;
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
    vc_stimuli : entity vunit_lib.axi_stream_master
        generic map (
            Master => AxisMaster_c
        )
        port map (
            AClk   => In_Clk,
            TValid => In_Valid,
            TReady => In_Ready,
            TData  => In_Data
        );

    vc_response : entity vunit_lib.axi_stream_slave
        generic map (
            Slave => AxisSlave_c
        )
        port map (
            AClk   => Out_Clk,
            TValid => Out_Valid,
            TReady => Out_Ready,
            TData  => Out_Data
        );

end architecture;
