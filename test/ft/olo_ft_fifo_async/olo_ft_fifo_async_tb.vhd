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

library olo;
    use olo.olo_base_pkg_math.all;
    use olo.olo_base_pkg_logic.all;
    use olo.olo_ft_pkg_ecc.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
-- vunit: run_all_in_same_sim
entity olo_ft_fifo_async_tb is
    generic (
        runner_cfg     : string;
        Width_g        : positive range 5 to 128 := 32;
        Optimization_g : string                  := "SPEED"
    );
end entity;

architecture sim of olo_ft_fifo_async_tb is

    -----------------------------------------------------------------------------------------------
    -- Constants
    -----------------------------------------------------------------------------------------------
    constant InClkPeriod_c   : time     := 10 ns;
    constant OutClkPeriod_c  : time     := 33.3 ns;
    constant Depth_c         : natural  := 32;
    constant CodewordWidth_c : positive := eccCodewordWidth(Width_g);

    -----------------------------------------------------------------------------------------------
    -- Verification components
    --   Master operates on In_Clk; slave on Out_Clk. Both carry a non-zero stall probability so
    --   the codec's AXI-S handshake is exercised under stalls in every test case.
    -----------------------------------------------------------------------------------------------
    constant AxisMaster_c : axi_stream_master_t := new_axi_stream_master (
        data_length  => Width_g,
        stall_config => new_stall_config(0.2, 0, 3)
    );
    constant AxisSlave_c  : axi_stream_slave_t  := new_axi_stream_slave (
        data_length  => Width_g,
        user_length  => 2,
        stall_config => new_stall_config(0.2, 0, 3)
    );

    -----------------------------------------------------------------------------------------------
    -- Interface Signals
    -----------------------------------------------------------------------------------------------
    signal In_Clk            : std_logic                                      := '0';
    signal In_Rst            : std_logic                                      := '1';
    signal In_RstOut         : std_logic;
    signal In_Data           : std_logic_vector(Width_g - 1 downto 0);
    signal In_Valid          : std_logic;
    signal In_Ready          : std_logic;
    signal In_ErrInj_BitFlip : std_logic_vector(CodewordWidth_c - 1 downto 0) := (others => '0');
    signal In_ErrInj_Valid   : std_logic                                      := '0';
    signal In_Level          : std_logic_vector(log2ceil(Depth_c + 1) - 1 downto 0);
    signal Out_Clk           : std_logic                                      := '0';
    signal Out_Rst           : std_logic                                      := '0';
    signal Out_RstOut        : std_logic;
    signal Out_Data          : std_logic_vector(Width_g - 1 downto 0);
    signal Out_Valid         : std_logic;
    signal Out_Ready         : std_logic;
    signal Out_EccSec        : std_logic;
    signal Out_EccDed        : std_logic;
    signal Out_TUser         : std_logic_vector(1 downto 0);
    signal Out_Level         : std_logic_vector(log2ceil(Depth_c + 1) - 1 downto 0);

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

            In_ErrInj_BitFlip <= (others => '0');
            In_ErrInj_Valid   <= '0';
            wait until rising_edge(In_Clk);
            In_Rst            <= '1';
            Out_Rst           <= '1';
            wait for 1 us;
            wait until rising_edge(In_Clk);
            In_Rst            <= '0';
            wait until rising_edge(Out_Clk);
            Out_Rst           <= '0';
            wait for 1 us;
            wait until rising_edge(In_Clk);

            ---------------------------------------------------------------------------------------
            if run("Basic") then
                Flip_v := (others => '0');
                ftPushBeat(net, AxisMaster_c, In_Clk, In_ErrInj_BitFlip, In_ErrInj_Valid, toUslv(10, Width_g), Flip_v);
                ftPushBeat(net, AxisMaster_c, In_Clk, In_ErrInj_BitFlip, In_ErrInj_Valid, toUslv(20, Width_g), Flip_v);
                ftPushBeat(net, AxisMaster_c, In_Clk, In_ErrInj_BitFlip, In_ErrInj_Valid, toUslv(30, Width_g), Flip_v);
                ftExpectBeat(net, AxisSlave_c, toUslv(10, Width_g), Flip_v, "Basic[0]");
                ftExpectBeat(net, AxisSlave_c, toUslv(20, Width_g), Flip_v, "Basic[1]");
                ftExpectBeat(net, AxisSlave_c, toUslv(30, Width_g), Flip_v, "Basic[2]");

            ---------------------------------------------------------------------------------------
            elsif run("EccSec") then
                Flip_v := setBits(0, CodewordWidth_c);
                ftPushBeat(net, AxisMaster_c, In_Clk, In_ErrInj_BitFlip, In_ErrInj_Valid, toUslv(16#AB#, Width_g), Flip_v);
                ftExpectBeat(net, AxisSlave_c, toUslv(16#AB#, Width_g), Flip_v, "EccSec corrected");

            ---------------------------------------------------------------------------------------
            elsif run("EccDed") then
                Flip_v := setBits((0, 1), CodewordWidth_c);
                ftPushBeat(net, AxisMaster_c, In_Clk, In_ErrInj_BitFlip, In_ErrInj_Valid, toUslv(16#EF#, Width_g), Flip_v);
                ftExpectBeat(net, AxisSlave_c, toUslv(16#EF#, Width_g), Flip_v, "EccDed detected");

            ---------------------------------------------------------------------------------------
            elsif run("BackToBack") then
                -- 64 beats (2x depth) across the clock-domain crossing under stalls
                Flip_v := (others => '0');

                for i in 0 to 63 loop
                    push_axi_stream(net, AxisMaster_c, toUslv(i + 1, Width_g));
                end loop;

                for i in 0 to 63 loop
                    check_axi_stream(net, AxisSlave_c, toUslv(i + 1, Width_g), tuser => "00",
                        msg                                                          => "BackToBack " & integer'image(i), blocking => false);
                end loop;

            ---------------------------------------------------------------------------------------
            elsif run("SecAllBits") then

                for bitIdx in 0 to CodewordWidth_c - 1 loop
                    Flip_v := setBits(bitIdx, CodewordWidth_c);
                    ftPushBeat(net, AxisMaster_c, In_Clk, In_ErrInj_BitFlip, In_ErrInj_Valid,
                        toUslv(16#A5#, Width_g), Flip_v);
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

                    ftPushBeat(net, AxisMaster_c, In_Clk, In_ErrInj_BitFlip, In_ErrInj_Valid,
                        toUslv(16#5A#, Width_g), Flip_v);
                    ftExpectBeat(net, AxisSlave_c, toUslv(16#5A#, Width_g), Flip_v,
                        "DedPair " & integer'image(pair));
                    wait_until_idle(net, as_sync(AxisSlave_c));
                end loop;

            ---------------------------------------------------------------------------------------
            elsif run("Mixed") then
                -- Clean / SEC / clean: adjacent beats keep their flags independent through the
                -- FIFO, the clock crossing and the decode pipeline.
                Flip_v := (others => '0');
                ftPushBeat(net, AxisMaster_c, In_Clk, In_ErrInj_BitFlip, In_ErrInj_Valid, toUslv(16#01#, Width_g), Flip_v);
                ftPushBeat(net, AxisMaster_c, In_Clk, In_ErrInj_BitFlip, In_ErrInj_Valid, toUslv(16#02#, Width_g), setBits(0, CodewordWidth_c));
                ftPushBeat(net, AxisMaster_c, In_Clk, In_ErrInj_BitFlip, In_ErrInj_Valid, toUslv(16#03#, Width_g), Flip_v);
                ftExpectBeat(net, AxisSlave_c, toUslv(16#01#, Width_g), (Flip_v'range => '0'),        "Mixed[0] clean");
                ftExpectBeat(net, AxisSlave_c, toUslv(16#02#, Width_g), setBits(0, CodewordWidth_c), "Mixed[1] Sec");
                ftExpectBeat(net, AxisSlave_c, toUslv(16#03#, Width_g), (Flip_v'range => '0'),        "Mixed[2] clean");

            ---------------------------------------------------------------------------------------
            elsif run("FullEmpty") then
                -- Push Depth_c clean beats; the FIFO must accept all of them (master's In_Ready
                -- handshake handles back-pressure when the FIFO fills). Drain afterwards.
                Flip_v := (others => '0');

                for i in 0 to Depth_c - 1 loop
                    push_axi_stream(net, AxisMaster_c, toUslv(i, Width_g));
                end loop;

                for i in 0 to Depth_c - 1 loop
                    check_axi_stream(net, AxisSlave_c, toUslv(i, Width_g), tuser => "00",
                        msg                                                      => "FullEmpty drain " & integer'image(i), blocking => false);
                end loop;

            ---------------------------------------------------------------------------------------
            elsif run("LatchedInjection") then
                -- Preload the injection pattern without pushing data, idle a few cycles, then
                -- push a beat. The codec latch must apply the pattern to that single beat.
                In_ErrInj_BitFlip <= setBits(2, CodewordWidth_c);
                In_ErrInj_Valid   <= '1';
                wait until rising_edge(In_Clk);
                In_ErrInj_Valid   <= '0';

                for i in 0 to 4 loop
                    wait until rising_edge(In_Clk);
                end loop;

                push_axi_stream(net, AxisMaster_c, toUslv(16#3C#, Width_g));
                ftExpectBeat(net, AxisSlave_c, toUslv(16#3C#, Width_g), setBits(2, CodewordWidth_c),
                    "Latched flip applied");

                wait_until_idle(net, as_sync(AxisSlave_c));

                In_ErrInj_BitFlip <= (others => '0');
                push_axi_stream(net, AxisMaster_c, toUslv(16#3C#, Width_g));
                ftExpectBeat(net, AxisSlave_c, toUslv(16#3C#, Width_g), (Flip_v'range => '0'), "Latch cleared");

            ---------------------------------------------------------------------------------------
            elsif run("ResetInFlight") then
                -- Fill the FIFO with beats that are never drained (no read expectation queued,
                -- so the slave VC keeps Out_Ready low), then reset from the input side only:
                -- the internal reset crossing must reset the output side too. The FIFO must
                -- come back empty, with no stale beat, and accept new data cleanly afterwards.

                for i in 0 to 7 loop
                    push_axi_stream(net, AxisMaster_c, toUslv(i + 16#40#, Width_g));
                end loop;

                wait_until_idle(net, as_sync(AxisMaster_c));

                -- Let the beats settle through the crossing into the decode pipeline
                for i in 0 to 6 loop
                    wait until rising_edge(Out_Clk);
                end loop;

                check_equal(Out_Valid, '1', "Out_Valid must be high before the reset");

                -- Reset from the input side; hold until the crossing asserts it on both sides
                wait until rising_edge(In_Clk);
                In_Rst <= '1';
                wait until Out_RstOut = '1' and rising_edge(Out_Clk);
                wait until rising_edge(In_Clk);
                In_Rst <= '0';
                wait until In_RstOut = '0' and rising_edge(In_Clk);
                wait until Out_RstOut = '0' and rising_edge(Out_Clk);

                -- Flush longer than the deepest pipeline: no stale valid may re-appear
                for i in 0 to 6 loop
                    wait until rising_edge(Out_Clk);
                end loop;

                check_equal(Out_Valid, '0', "Out_Valid must be squashed by the reset");
                check_equal(In_Level, toUslv(0, In_Level'length), "In_Level must be 0 after the reset");
                check_equal(Out_Level, toUslv(0, Out_Level'length), "Out_Level must be 0 after the reset");

                -- Clean recovery: a fresh beat passes through untouched
                Flip_v := (others => '0');
                ftPushBeat(net, AxisMaster_c, In_Clk, In_ErrInj_BitFlip, In_ErrInj_Valid, toUslv(16#77#, Width_g), Flip_v);
                ftExpectBeat(net, AxisSlave_c, toUslv(16#77#, Width_g), Flip_v, "Recovery beat");

            end if;

            wait_until_idle(net, as_sync(AxisMaster_c));
            wait_until_idle(net, as_sync(AxisSlave_c));
            wait for 2 us;

        end loop;

        test_runner_cleanup(runner);
    end process;

    -----------------------------------------------------------------------------------------------
    -- Clocks
    -----------------------------------------------------------------------------------------------
    In_Clk  <= not In_Clk  after 0.5 * InClkPeriod_c;
    Out_Clk <= not Out_Clk after 0.5 * OutClkPeriod_c;

    Out_TUser <= Out_EccSec & Out_EccDed;

    -----------------------------------------------------------------------------------------------
    -- DUT
    -----------------------------------------------------------------------------------------------
    i_dut : entity olo.olo_ft_fifo_async
        generic map (
            Width_g        => Width_g,
            Depth_g        => Depth_c,
            Optimization_g => Optimization_g
        )
        port map (
            In_Clk            => In_Clk,
            In_Rst            => In_Rst,
            In_RstOut         => In_RstOut,
            In_Data           => In_Data,
            In_Valid          => In_Valid,
            In_Ready          => In_Ready,
            In_Level          => In_Level,
            Out_Clk           => Out_Clk,
            Out_Rst           => Out_Rst,
            Out_RstOut        => Out_RstOut,
            Out_Data          => Out_Data,
            Out_Valid         => Out_Valid,
            Out_Ready         => Out_Ready,
            Out_EccSec        => Out_EccSec,
            Out_EccDed        => Out_EccDed,
            Out_Level         => Out_Level,
            In_ErrInj_BitFlip => In_ErrInj_BitFlip,
            In_ErrInj_Valid   => In_ErrInj_Valid
        );

    -----------------------------------------------------------------------------------------------
    -- Verification Components
    -----------------------------------------------------------------------------------------------
    vc_master : entity vunit_lib.axi_stream_master
        generic map (
            Master => AxisMaster_c
        )
        port map (
            AClk   => In_Clk,
            TValid => In_Valid,
            TReady => In_Ready,
            TData  => In_Data
        );

    vc_slave : entity vunit_lib.axi_stream_slave
        generic map (
            Slave => AxisSlave_c
        )
        port map (
            AClk   => Out_Clk,
            TValid => Out_Valid,
            TReady => Out_Ready,
            TData  => Out_Data,
            TUser  => Out_TUser
        );

end architecture;
