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
    context vunit_lib.com_context;
    context vunit_lib.vc_context;

library work;
    use work.olo_test_ft_pkg.all;
    use work.olo_test_axis_slave_pkg.all;

library olo;
    use olo.olo_base_pkg_math.all;
    use olo.olo_base_pkg_logic.all;
    use olo.olo_ft_pkg_ecc.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
-- vunit: run_all_in_same_sim
entity olo_ft_private_fifo_stream_tb is
    generic (
        runner_cfg    : string;
        Width_g       : positive range 5 to 128 := 32;
        Depth_g       : positive                := 32;
        EccPipeline_g : natural range 0 to 2    := 0;
        RamBehavior_g : string                  := "RBW"
    );
end entity;

architecture sim of olo_ft_private_fifo_stream_tb is

    -----------------------------------------------------------------------------------------------
    -- Constants
    -----------------------------------------------------------------------------------------------
    constant ClkPeriod_c     : time     := 10 ns;
    constant CodewordWidth_c : positive := eccCodewordWidth(Width_g);
    constant TpBeats_c       : positive := 64;

    -----------------------------------------------------------------------------------------------
    -- Verification components (both stall at 20 %, so every test case sees back-pressure)
    -----------------------------------------------------------------------------------------------
    constant AxisMaster_c : axi_stream_master_t := new_axi_stream_master (
        data_length  => Width_g,
        stall_config => new_stall_config(0.2, 0, 3)
    );
    constant AxisSlave_c  : axi_stream_slave_t  := new_axi_stream_slave (
        data_length  => padded_data_length(Width_g),
        user_length  => 2,
        stall_config => new_stall_config(0.2, 0, 3)
    );

    -----------------------------------------------------------------------------------------------
    -- Interface Signals
    -----------------------------------------------------------------------------------------------
    signal Clk               : std_logic                                      := '0';
    signal Rst               : std_logic                                      := '1';
    signal In_Data           : std_logic_vector(Width_g - 1 downto 0);
    signal In_Valid          : std_logic;
    signal In_Ready          : std_logic;
    signal In_ErrInj_BitFlip : std_logic_vector(CodewordWidth_c - 1 downto 0) := (others => '0');
    signal In_ErrInj_Valid   : std_logic                                      := '0';
    signal Out_Data          : std_logic_vector(Width_g - 1 downto 0);
    signal Out_Valid         : std_logic;
    signal Out_Ready         : std_logic;
    signal Out_EccSec        : std_logic;
    signal Out_EccDed        : std_logic;
    signal Out_TUser         : std_logic_vector(1 downto 0);

    -- Verification components and the throughput stimulus share the input and output
    signal Vc_Data      : std_logic_vector(Width_g - 1 downto 0);
    signal Vc_Valid     : std_logic;
    signal Slave_Ready  : std_logic;
    signal Tp_Mode      : boolean                                := false;
    signal Tp_Data      : std_logic_vector(Width_g - 1 downto 0) := (others => '0');
    signal Tp_Valid     : std_logic                              := '0';
    signal Tp_FirstOut  : natural                                := 0;
    signal Tp_OutCount  : natural                                := 0;
    signal Tp_OutGap    : boolean                                := false;
    signal Tp_OutOrder  : boolean                                := true;
    signal Ref_Valid    : std_logic;
    signal Ref_FirstOut : natural                                := 0;
    signal Cycle        : natural                                := 0;

begin

    -----------------------------------------------------------------------------------------------
    -- TB Control
    -----------------------------------------------------------------------------------------------
    test_runner_watchdog(runner, 5 ms);

    p_control : process is
        variable Flip_v : std_logic_vector(CodewordWidth_c - 1 downto 0);
    begin
        test_runner_setup(runner, runner_cfg);

        while test_suite loop

            -- Reset
            In_ErrInj_BitFlip <= (others => '0');
            In_ErrInj_Valid   <= '0';
            wait until rising_edge(Clk);
            Rst               <= '1';
            wait for 200 ns;
            wait until rising_edge(Clk);
            Rst               <= '0';
            wait until rising_edge(Clk);

            ---------------------------------------------------------------------------------------
            if run("Basic") then
                Flip_v := (others => '0');
                ftPushBeat(net, AxisMaster_c, Clk, In_ErrInj_BitFlip, In_ErrInj_Valid, toUslv(10, Width_g), Flip_v);
                ftPushBeat(net, AxisMaster_c, Clk, In_ErrInj_BitFlip, In_ErrInj_Valid, toUslv(20, Width_g), Flip_v);
                ftPushBeat(net, AxisMaster_c, Clk, In_ErrInj_BitFlip, In_ErrInj_Valid, toUslv(30, Width_g), Flip_v);
                ftExpectBeat(net, AxisSlave_c, toUslv(10, Width_g), Flip_v, "Basic[0]");
                ftExpectBeat(net, AxisSlave_c, toUslv(20, Width_g), Flip_v, "Basic[1]");
                ftExpectBeat(net, AxisSlave_c, toUslv(30, Width_g), Flip_v, "Basic[2]");

            ---------------------------------------------------------------------------------------
            elsif run("EccSec") then
                Flip_v := setBits(0, CodewordWidth_c);
                ftPushBeat(net, AxisMaster_c, Clk, In_ErrInj_BitFlip, In_ErrInj_Valid, toUslv(16#AB#, Width_g), Flip_v);
                ftExpectBeat(net, AxisSlave_c, toUslv(16#AB#, Width_g), Flip_v, "EccSec corrected");

            ---------------------------------------------------------------------------------------
            elsif run("EccDed") then
                Flip_v := setBits((0, 1), CodewordWidth_c);
                ftPushBeat(net, AxisMaster_c, Clk, In_ErrInj_BitFlip, In_ErrInj_Valid, toUslv(16#EF#, Width_g), Flip_v);
                ftExpectBeat(net, AxisSlave_c, toUslv(16#EF#, Width_g), Flip_v, "EccDed detected");

            ---------------------------------------------------------------------------------------
            elsif run("Mixed") then
                -- Clean / SEC / DED / clean: the flags stay with their beat through the decoder pipeline
                Flip_v := (others => '0');
                ftPushBeat(net, AxisMaster_c, Clk, In_ErrInj_BitFlip, In_ErrInj_Valid, toUslv(16#01#, Width_g), Flip_v);
                ftPushBeat(net, AxisMaster_c, Clk, In_ErrInj_BitFlip, In_ErrInj_Valid, toUslv(16#02#, Width_g), setBits(3, CodewordWidth_c));
                ftPushBeat(net, AxisMaster_c, Clk, In_ErrInj_BitFlip, In_ErrInj_Valid, toUslv(16#03#, Width_g), setBits((1, 4), CodewordWidth_c));
                ftPushBeat(net, AxisMaster_c, Clk, In_ErrInj_BitFlip, In_ErrInj_Valid, toUslv(16#04#, Width_g), Flip_v);
                ftExpectBeat(net, AxisSlave_c, toUslv(16#01#, Width_g), (Flip_v'range => '0'),           "Mixed[0] clean");
                ftExpectBeat(net, AxisSlave_c, toUslv(16#02#, Width_g), setBits(3, CodewordWidth_c),      "Mixed[1] Sec");
                ftExpectBeat(net, AxisSlave_c, toUslv(16#03#, Width_g), setBits((1, 4), CodewordWidth_c), "Mixed[2] Ded");
                ftExpectBeat(net, AxisSlave_c, toUslv(16#04#, Width_g), (Flip_v'range => '0'),           "Mixed[3] clean");

            ---------------------------------------------------------------------------------------
            elsif run("SecAllBits") then
                -- Every bit of the codeword, data bits included: the corrected data must leave the FIFO

                for bitIdx in 0 to CodewordWidth_c - 1 loop
                    Flip_v := setBits(bitIdx, CodewordWidth_c);
                    ftPushBeat(net, AxisMaster_c, Clk, In_ErrInj_BitFlip, In_ErrInj_Valid, toUslv(16#A5#, Width_g), Flip_v);
                    ftExpectBeat(net, AxisSlave_c, toUslv(16#A5#, Width_g), Flip_v,
                        "SecAllBits flip " & integer'image(bitIdx));
                    wait_until_idle(net, as_sync(AxisSlave_c));
                end loop;

            ---------------------------------------------------------------------------------------
            elsif run("DedSampledPairs") then

                for pair in 0 to 4 loop

                    case pair is
                        when 0 => Flip_v := setBits((0, 1),                              CodewordWidth_c);
                        when 1 => Flip_v := setBits((0, CodewordWidth_c - 1),            CodewordWidth_c);
                        when 2 => Flip_v := setBits((1, 2),                              CodewordWidth_c);
                        when 3 => Flip_v := setBits((2, 5),                              CodewordWidth_c);
                        when others => Flip_v := setBits((CodewordWidth_c / 2,
                                                          CodewordWidth_c / 2 + 1), CodewordWidth_c);
                    end case;

                    ftPushBeat(net, AxisMaster_c, Clk, In_ErrInj_BitFlip, In_ErrInj_Valid, toUslv(16#5A#, Width_g), Flip_v);
                    ftExpectBeat(net, AxisSlave_c, toUslv(16#5A#, Width_g), Flip_v,
                        "DedPair " & integer'image(pair));
                    wait_until_idle(net, as_sync(AxisSlave_c));
                end loop;

            ---------------------------------------------------------------------------------------
            elsif run("LatchedInjection") then
                -- The latched pattern applies to the next accepted beat only
                In_ErrInj_BitFlip <= setBits(2, CodewordWidth_c);
                In_ErrInj_Valid   <= '1';
                wait until rising_edge(Clk);
                In_ErrInj_Valid   <= '0';

                for i in 0 to 4 loop
                    wait until rising_edge(Clk);
                end loop;

                push_axi_stream(net, AxisMaster_c, toUslv(16#3C#, Width_g));
                push_axi_stream(net, AxisMaster_c, toUslv(16#3D#, Width_g));
                ftExpectBeat(net, AxisSlave_c, toUslv(16#3C#, Width_g), setBits(2, CodewordWidth_c), "Latched flip applied");
                ftExpectBeat(net, AxisSlave_c, toUslv(16#3D#, Width_g), (Flip_v'range => '0'),      "Next beat clean");
                wait_until_idle(net, as_sync(AxisSlave_c));
                In_ErrInj_BitFlip <= (others => '0');

            ---------------------------------------------------------------------------------------
            elsif run("BackToBack") then
                -- Twice the depth under back-pressure on both sides

                for i in 0 to 2 * Depth_g + 7 loop
                    push_axi_stream(net, AxisMaster_c, toUslv(i + 1, Width_g));
                end loop;

                for i in 0 to 2 * Depth_g + 7 loop
                    check_axi_stream_padded(net, AxisSlave_c, toUslv(i + 1, Width_g), tuser => "00",
                        msg                                                                 => "BackToBack " & integer'image(i), blocking => false);
                end loop;

            ---------------------------------------------------------------------------------------
            elsif run("FillAndDrain") then
                -- Fill the FIFO without reading, then drain: nothing is lost

                for i in 0 to Depth_g - 1 loop
                    push_axi_stream(net, AxisMaster_c, toUslv(i + 16#20#, Width_g));
                end loop;

                wait_until_idle(net, as_sync(AxisMaster_c));
                wait for 20 * ClkPeriod_c;

                for i in 0 to Depth_g - 1 loop
                    check_axi_stream_padded(net, AxisSlave_c, toUslv(i + 16#20#, Width_g), tuser => "00",
                        msg                                                                      => "FillAndDrain " & integer'image(i), blocking => false);
                end loop;

            ---------------------------------------------------------------------------------------
            elsif run("ResetInFlight") then
                -- Beats in the FIFO and in the decoder pipeline are dropped by the reset (at most Depth_g beats:
                -- nothing takes them)

                for i in 0 to minimum(8, Depth_g) - 1 loop
                    push_axi_stream(net, AxisMaster_c, toUslv(i + 16#40#, Width_g));
                end loop;

                wait_until_idle(net, as_sync(AxisMaster_c));

                for i in 0 to 4 + EccPipeline_g loop
                    wait until rising_edge(Clk);
                end loop;

                check_equal(Out_Valid, '1', "Out_Valid must be high before the reset");
                wait until rising_edge(Clk);
                Rst <= '1';
                wait until rising_edge(Clk);
                wait until rising_edge(Clk);
                Rst <= '0';

                for i in 0 to 4 + EccPipeline_g loop
                    wait until rising_edge(Clk);
                    check_equal(Out_Valid, '0', "Out_Valid must be squashed by the reset");
                end loop;

                Flip_v := (others => '0');
                ftPushBeat(net, AxisMaster_c, Clk, In_ErrInj_BitFlip, In_ErrInj_Valid, toUslv(16#77#, Width_g), Flip_v);
                ftExpectBeat(net, AxisSlave_c, toUslv(16#77#, Width_g), Flip_v, "Recovery beat");

            ---------------------------------------------------------------------------------------
            elsif run("Throughput") then
                -- Without back-pressure the FIFO passes one beat per clock cycle without a gap (from Depth_g = 3 on,
                -- as olo_base_fifo_sync), and the decoder pipeline adds exactly EccPipeline_g clock cycles to the
                -- latency of olo_base_fifo_sync
                Tp_Mode <= true;
                wait until rising_edge(Clk);

                for i in 0 to TpBeats_c - 1 loop
                    Tp_Data  <= toUslv(i mod 2**minimum(Width_g, 30), Width_g);
                    Tp_Valid <= '1';
                    wait until rising_edge(Clk) and In_Ready = '1';
                end loop;

                Tp_Valid <= '0';
                wait until Tp_OutCount = TpBeats_c;
                -- olo_base_fifo_sync sees a read on its write side one clock cycle late: 2 entries take at most 2
                -- beats in 3 clock cycles
                if Depth_g >= 3 then
                    check(not Tp_OutGap, "Gap in the output stream");
                end if;
                check(Tp_OutOrder, "Output data out of order");
                check_equal(Tp_FirstOut, Ref_FirstOut + EccPipeline_g, "Latency: olo_base_fifo_sync plus EccPipeline_g");
                Tp_Mode <= false;
                wait until rising_edge(Clk);
            end if;

            -- Wait for idle
            wait_until_idle(net, as_sync(AxisMaster_c));
            wait_until_idle(net, as_sync(AxisSlave_c));
            wait for 1 us;

        end loop;

        -- TB done
        test_runner_cleanup(runner);
    end process;

    -----------------------------------------------------------------------------------------------
    -- Throughput monitor: first input and output beat, gaps and order of the output stream
    -----------------------------------------------------------------------------------------------
    p_tp_monitor : process (Clk) is
        variable OutSeen_v, RefSeen_v : boolean := false;
        variable Expected_v           : natural := 0;
    begin
        if rising_edge(Clk) then
            Cycle <= Cycle + 1;
            if not Tp_Mode then
                OutSeen_v   := false;
                RefSeen_v   := false;
                Expected_v  := 0;
                Tp_OutCount <= 0;
                Tp_OutGap   <= false;
                Tp_OutOrder <= true;
            else
                if Ref_Valid = '1' and not RefSeen_v then
                    RefSeen_v    := true;
                    Ref_FirstOut <= Cycle;
                end if;
                if Out_Valid = '1' then
                    if not OutSeen_v then
                        OutSeen_v   := true;
                        Tp_FirstOut <= Cycle;
                    end if;
                    if Out_Data /= toUslv(Expected_v mod 2**minimum(Width_g, 30), Width_g) then
                        Tp_OutOrder <= false;
                    end if;
                    Expected_v  := Expected_v + 1;
                    Tp_OutCount <= Expected_v;
                elsif OutSeen_v and Expected_v < TpBeats_c then
                    Tp_OutGap <= true;
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
    In_Valid  <= Tp_Valid when Tp_Mode else Vc_Valid;
    In_Data   <= Tp_Data when Tp_Mode else Vc_Data;
    Out_Ready <= '1' when Tp_Mode else Slave_Ready;
    Out_TUser <= Out_EccSec & Out_EccDed;

    i_dut : entity olo.olo_ft_private_fifo_stream
        generic map (
            Width_g       => Width_g,
            Depth_g       => Depth_g,
            EccPipeline_g => EccPipeline_g,
            RamBehavior_g => RamBehavior_g
        )
        port map (
            Clk               => Clk,
            Rst               => Rst,
            In_Data           => In_Data,
            In_Valid          => In_Valid,
            In_Ready          => In_Ready,
            Out_Data          => Out_Data,
            Out_Valid         => Out_Valid,
            Out_Ready         => Out_Ready,
            Out_EccSec        => Out_EccSec,
            Out_EccDed        => Out_EccDed,
            In_ErrInj_BitFlip => In_ErrInj_BitFlip,
            In_ErrInj_Valid   => In_ErrInj_Valid
        );

    -- Latency reference
    i_ref : entity olo.olo_base_fifo_sync
        generic map (
            Width_g       => Width_g,
            Depth_g       => Depth_g,
            RamBehavior_g => RamBehavior_g
        )
        port map (
            Clk       => Clk,
            Rst       => Rst,
            In_Data   => In_Data,
            In_Valid  => In_Valid,
            Out_Valid => Ref_Valid,
            Out_Ready => Out_Ready
        );

    -----------------------------------------------------------------------------------------------
    -- Verification Components
    -----------------------------------------------------------------------------------------------
    vc_master : entity vunit_lib.axi_stream_master
        generic map (
            Master => AxisMaster_c
        )
        port map (
            AClk   => Clk,
            TValid => Vc_Valid,
            TReady => In_Ready,
            TData  => Vc_Data
        );

    vc_slave : entity work.olo_test_axis_slave_vc
        generic map (
            Slave      => AxisSlave_c,
            Data_Width => Width_g
        )
        port map (
            AClk   => Clk,
            TValid => Out_Valid,
            TReady => Slave_Ready,
            TData  => Out_Data,
            TUser  => Out_TUser
        );

end architecture;
