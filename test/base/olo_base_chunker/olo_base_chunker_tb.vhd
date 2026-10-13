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

library osvvm;
    use osvvm.RandomPkg.all;

library olo;
    use olo.olo_base_pkg_math.all;
    use olo.olo_base_pkg_logic.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
-- vunit: run_all_in_same_sim
entity olo_base_chunker_tb is
    generic (
        runner_cfg      : string;
        Width_g         : positive := 32;
        ChunkBeats_g    : positive := 3;
        RandomStall_g   : boolean  := false
    );
end entity;

architecture sim of olo_base_chunker_tb is

    -----------------------------------------------------------------------------------------------
    -- Constants
    -----------------------------------------------------------------------------------------------
    constant ClkPeriod_c : time    := 10 ns;
    constant BeWidth_c   : natural := Width_g / 8;
    constant StallProb_c : real    := choose(RandomStall_g, 0.5, 0.0);

    -----------------------------------------------------------------------------------------------
    -- TB Defnitions
    -----------------------------------------------------------------------------------------------

    -- *** Verification Compnents ***
    constant AxisMaster_c : axi_stream_master_t := new_axi_stream_master (
        data_length => Width_g,
        stall_config => new_stall_config(StallProb_c, 0, 5)
    );
    constant AxisSlave_c  : axi_stream_slave_t  := new_axi_stream_slave (
        data_length => Width_g,
        user_length => 1,
        stall_config => new_stall_config(StallProb_c, 0, 5)
    );

    -- *** Procedures ***
    -- Push a packet (or a part of an endless stream if last is false) and expect the chunks.
    -- Pos is the beat position inside the current chunk, it is updated for the next call.
    procedure testPacket (
        signal net : inout network_t;
        beats      : positive;
        Pos        : inout natural;
        last       : boolean := true;
        lastBytes  : integer := -1; -- valid bytes of the last beat (-1: all)
        start      : natural := 0;
        msg        : string  := "") is
        -- variables
        variable Data_v      : std_logic_vector(Width_g - 1 downto 0);
        variable Be_v        : std_logic_vector(BeWidth_c - 1 downto 0);
        variable Last_v      : std_logic;
        variable ChunkLast_v : std_logic;
        variable InLast_v    : std_logic_vector(0 downto 0);
    begin

        for i in 0 to beats - 1 loop
            -- Stimuli
            Data_v := std_logic_vector(to_unsigned((start + i) mod 2**minimum(Width_g, 30), Width_g));
            Be_v   := (others => '1');
            Last_v := '0';
            if i = beats - 1 and last then
                Last_v := '1';
                if lastBytes >= 0 then
                    Be_v := (others => '0');

                    for b in 0 to lastBytes - 1 loop
                        Be_v(b) := '1';
                    end loop;

                end if;
            end if;
            push_axi_stream(net, AxisMaster_c, Data_v, tlast => Last_v, tstrb => Be_v);

            -- Expected output
            if Pos = ChunkBeats_g - 1 or Last_v = '1' then
                ChunkLast_v := '1';
            else
                ChunkLast_v := '0';
            end if;
            InLast_v(0) := Last_v;
            check_axi_stream(net, AxisSlave_c, Data_v,
                             tlast    => ChunkLast_v,
                             tstrb    => Be_v,
                             tuser    => InLast_v,
                             msg      => msg & " beat " & integer'image(i),
                             blocking => false);

            -- Position inside the chunk
            if ChunkLast_v = '1' then
                Pos := 0;
            else
                Pos := Pos + 1;
            end if;
        end loop;

    end procedure;

    -----------------------------------------------------------------------------------------------
    -- Interface Signals
    -----------------------------------------------------------------------------------------------
    signal Clk        : std_logic                                := '0';
    signal Rst        : std_logic                                := '1';
    signal In_Valid   : std_logic                                := '0';
    signal In_Ready   : std_logic                                := '0';
    signal In_Data    : std_logic_vector(Width_g - 1 downto 0)   := (others => '0');
    signal In_Be      : std_logic_vector(BeWidth_c - 1 downto 0) := (others => '1');
    signal In_Last    : std_logic                                := '0';
    signal Out_Valid  : std_logic                                := '0';
    signal Out_Ready  : std_logic                                := '0';
    signal Out_Data   : std_logic_vector(Width_g - 1 downto 0)   := (others => '0');
    signal Out_Be     : std_logic_vector(BeWidth_c - 1 downto 0) := (others => '1');
    signal Out_Last   : std_logic                                := '0';
    signal Out_InLast : std_logic                                := '0';

begin

    -----------------------------------------------------------------------------------------------
    -- TB Control
    -----------------------------------------------------------------------------------------------
    test_runner_watchdog(runner, 10 ms);

    p_control : process is
        variable Pos_v   : natural;
        variable Rand_v  : RandomPType;
        variable Beats_v : positive;
        variable Bytes_v : integer;
    begin
        test_runner_setup(runner, runner_cfg);
        Rand_v.InitSeed(Rand_v'instance_name);

        while test_suite loop

            -- Reset
            wait until rising_edge(Clk);
            Rst <= '1';
            wait for 200 ns;
            wait until rising_edge(Clk);
            Rst <= '0';
            wait until rising_edge(Clk);

            -- The first beat starts a chunk
            Pos_v := 0;

            -- Packet of several full chunks
            if run("Packet-ExactChunks") then
                testPacket(net, 3 * ChunkBeats_g, Pos_v, msg => "3 chunks");
                testPacket(net, 2 * ChunkBeats_g, Pos_v, start => 100, msg => "2 chunks");
            end if;

            -- Packet of exactly one chunk
            if run("Packet-OneChunk") then
                testPacket(net, ChunkBeats_g, Pos_v, msg => "one chunk");
                testPacket(net, ChunkBeats_g, Pos_v, start => 50, msg => "second packet");
            end if;

            -- Packet one byte longer than a chunk: second chunk of one beat with one byte
            if run("Packet-OneByteLonger") then
                testPacket(net, ChunkBeats_g + 1, Pos_v, lastBytes => 1, msg => "one byte longer");
                testPacket(net, ChunkBeats_g, Pos_v, start => 20, msg => "next packet");
            end if;

            -- Packet shorter than a chunk with a partial last beat
            if run("Packet-Short") then
                testPacket(net, maximum(ChunkBeats_g - 1, 1), Pos_v, lastBytes => maximum(BeWidth_c - 1, 1), msg => "short");
                testPacket(net, ChunkBeats_g + 2, Pos_v, start => 10, msg => "next packet");
            end if;

            -- Single byte packets
            if run("Packet-SingleByte") then

                for i in 0 to 2 * ChunkBeats_g loop
                    testPacket(net, 1, Pos_v, lastBytes => 1, start => i, msg => "single byte " & integer'image(i));
                end loop;

            end if;

            -- A beat without valid bytes is passed through unchanged
            if run("Packet-ZeroLength") then
                testPacket(net, 1, Pos_v, lastBytes => 0, msg => "zero length");
                testPacket(net, ChunkBeats_g + 1, Pos_v, start => 7, msg => "next packet");
                testPacket(net, 1, Pos_v, lastBytes => 0, msg => "zero length after packet");
            end if;

            -- Packets of all lengths up to two chunks plus one beat, back to back
            if run("Packets-BackToBack") then

                for len in 1 to 2 * ChunkBeats_g + 1 loop
                    testPacket(net, len, Pos_v,
                               lastBytes => (len mod BeWidth_c) + 1,
                               start     => len,
                               msg       => "length " & integer'image(len));
                end loop;

            end if;

            -- Endless stream without Last, cut into chunks, then ended by a packet end
            if run("Stream-NoLast") then
                testPacket(net, 2 * ChunkBeats_g + 1, Pos_v, last => false, msg => "stream part 1");
                testPacket(net, ChunkBeats_g + 2, Pos_v, last => false, start => 30, msg => "stream part 2");
                testPacket(net, 2, Pos_v, start => 60, msg => "stream end");
                testPacket(net, ChunkBeats_g, Pos_v, start => 70, msg => "next packet");
            end if;

            -- Reset in the middle of a chunk: the next beat starts a new chunk
            if run("Reset-MidChunk") then
                testPacket(net, ChunkBeats_g + 1, Pos_v, last => false, msg => "before reset");
                wait_until_idle(net, as_sync(AxisMaster_c));
                wait_until_idle(net, as_sync(AxisSlave_c));
                wait until rising_edge(Clk);
                Rst <= '1';
                wait until rising_edge(Clk);
                Rst <= '0';
                wait until rising_edge(Clk);

                -- The first beat after the reset starts a chunk
                Pos_v := 0;
                testPacket(net, ChunkBeats_g + 1, Pos_v, start => 40, msg => "after reset");
            end if;

            -- Random packet lengths and byte enables
            if run("Packets-Random") then

                for i in 0 to 49 loop
                    Beats_v := Rand_v.RandInt(1, 3 * ChunkBeats_g + 1);
                    Bytes_v := Rand_v.RandInt(1, maximum(BeWidth_c, 1));
                    testPacket(net, Beats_v, Pos_v,
                               lastBytes => Bytes_v,
                               start     => i,
                               msg       => "random " & integer'image(i));
                end loop;

            end if;

            wait_until_idle(net, as_sync(AxisMaster_c));
            wait_until_idle(net, as_sync(AxisSlave_c));
            wait for 1 us;

        end loop;

        -- TB done
        test_runner_cleanup(runner);
    end process;

    -----------------------------------------------------------------------------------------------
    -- Clock
    -----------------------------------------------------------------------------------------------
    Clk <= not Clk after 0.5 * ClkPeriod_c;

    -----------------------------------------------------------------------------------------------
    -- DUT
    -----------------------------------------------------------------------------------------------
    i_dut : entity olo.olo_base_chunker
        generic map (
            Width_g      => Width_g,
            ChunkBeats_g => ChunkBeats_g
        )
        port map (
            Clk         => Clk,
            Rst         => Rst,
            In_Valid    => In_Valid,
            In_Ready    => In_Ready,
            In_Data     => In_Data,
            In_Be       => In_Be,
            In_Last     => In_Last,
            Out_Valid   => Out_Valid,
            Out_Ready   => Out_Ready,
            Out_Data    => Out_Data,
            Out_Be      => Out_Be,
            Out_Last    => Out_Last,
            Out_InLast  => Out_InLast
        );

    -----------------------------------------------------------------------------------------------
    -- Verification Components
    -----------------------------------------------------------------------------------------------
    vc_stimuli : entity vunit_lib.axi_stream_master
        generic map (
            Master => AxisMaster_c
        )
        port map (
            AClk   => Clk,
            TValid => In_Valid,
            TReady => In_Ready,
            TData  => In_Data,
            TStrb  => In_Be,
            TLast  => In_Last
        );

    vc_response : entity vunit_lib.axi_stream_slave
        generic map (
            Slave => AxisSlave_c
        )
        port map (
            AClk     => Clk,
            TValid   => Out_Valid,
            TReady   => Out_Ready,
            TData    => Out_Data,
            TStrb    => Out_Be,
            TLast    => Out_Last,
            TUser(0) => Out_InLast
        );

end architecture;
