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

library osvvm;
    use osvvm.RandomPkg.all;

library olo;
    use olo.olo_base_pkg_math.all;
    use olo.olo_base_pkg_logic.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity olo_base_stream_split_tb is
    generic (
        runner_cfg      : string;
        Width_g         : positive := 32;
        MaxSegSize_g    : positive := 1000
    );
end entity;

architecture sim of olo_base_stream_split_tb is

    -----------------------------------------------------------------------------------------------
    -- Constants
    -----------------------------------------------------------------------------------------------
    constant ClkPeriod_c  : time     := 10 ns;
    constant Bytes_c      : positive := Width_g / 8;
    constant SizeBits_c   : positive := log2ceil(MaxSegSize_g + 1);
    -- Largest random segment
    constant RandSegMax_c : positive := minimum(3 * Bytes_c, MaxSegSize_g);

    -----------------------------------------------------------------------------------------------
    -- TB Definitions
    -----------------------------------------------------------------------------------------------
    -- Input beats (per beat: byte count, last, bytes), segment commands (sizes) and expected output beats (per
    -- beat: data, Be, last, in-last)
    constant InBeatQ_c  : queue_t := new_queue;
    constant SegQ_c     : queue_t := new_queue;
    constant ExpBeatQ_c : queue_t := new_queue;

    -- Probabilities of an idle cycle before an input beat or a segment command and of Out_Ready low in a cycle
    signal InGapProb    : real := 0.0;
    signal SegGapProb   : real := 0.0;
    signal OutStallProb : real := 0.0;

    -- Monitoring
    signal BeatsChecked : natural := 0;
    signal InStalls     : natural := 0; -- cycles with In_Valid = '1' and In_Ready = '0'
    signal SegsTaken    : natural := 0; -- segment commands taken

    -----------------------------------------------------------------------------------------------
    -- Interface Signals
    -----------------------------------------------------------------------------------------------
    signal Clk        : std_logic                                 := '0';
    signal Rst        : std_logic                                 := '1';
    signal In_Valid   : std_logic                                 := '0';
    signal In_Ready   : std_logic;
    signal In_Data    : std_logic_vector(Width_g - 1 downto 0)    := (others => '0');
    signal In_Be      : std_logic_vector(Bytes_c - 1 downto 0)    := (others => '0');
    signal In_Last    : std_logic                                 := '0';
    signal Seg_Valid  : std_logic                                 := '0';
    signal Seg_Ready  : std_logic;
    signal Seg_Size   : std_logic_vector(SizeBits_c - 1 downto 0) := (others => '0');
    signal Out_Valid  : std_logic;
    signal Out_Ready  : std_logic                                 := '1';
    signal Out_Data   : std_logic_vector(Width_g - 1 downto 0);
    signal Out_Be     : std_logic_vector(Bytes_c - 1 downto 0);
    signal Out_Last   : std_logic;
    signal Out_InLast : std_logic;

    -----------------------------------------------------------------------------------------------
    -- Functions and Procedures
    -----------------------------------------------------------------------------------------------
    function toSl (Value : boolean) return std_logic is
    begin
        if Value then
            return '1';
        end if;
        return '0';
    end function;

    -- Byte enables of the lanes 0 to Count - 1
    function lanesBe (Count : natural) return std_logic_vector is
        variable Be_v : std_logic_vector(Bytes_c - 1 downto 0) := (others => '0');
    begin

        for i in 0 to Bytes_c - 1 loop
            if i < Count then
                Be_v(i) := '1';
            end if;
        end loop;

        return Be_v;
    end function;

    -- Push a packet of Bytes random bytes (full beats, the last beat partial; with RandBeats every beat holds a random
    -- number of bytes, empty beats included; with CloseEmpty an empty beat with In_Last follows the bytes; a packet
    -- without bytes is one empty beat), the segment commands that consume it and the expected segment beats. The
    -- segment sizes are taken from Segs in order (the last one repeated); with RandSegs they are random from 1 to
    -- RandSegMax_c.
    -- The expected beats depend only on the bytes of the packet and the segment sizes, not on the input beats.
    procedure pushPacket (
        Bytes        : natural;
        Segs         : integer_vector;
        variable Rnd : inout RandomPType;
        CloseEmpty   : boolean := false;
        RandSegs     : boolean := false;
        RandBeats    : boolean := false;
        Expect       : boolean := true;
        Last         : boolean := true) is
        variable Pkt_v    : queue_t := new_queue;
        variable Byte_v   : natural;
        variable Pos_v    : natural := 0;
        variable Beat_v   : natural;
        variable Left_v   : natural := Bytes;
        variable SegIdx_v : natural := Segs'low;
        variable Size_v   : natural;
        variable Take_v   : natural;
        variable Lane_v   : natural;
        variable Data_v   : std_logic_vector(Width_g - 1 downto 0);
        variable First_v  : boolean := true;
        variable Beats_v  : natural := 0;
    begin

        -- Input beats
        while Pos_v < Bytes loop
            Beat_v := minimum(Bytes_c, Bytes - Pos_v);
            -- Random beat sizes, at most 4 x Bytes + 8 beats per packet
            if RandBeats and (Beats_v < 4 * Bytes + 8) then
                Beat_v := minimum(Rnd.RandInt(0, Bytes_c), Bytes - Pos_v);
            end if;
            Beats_v := Beats_v + 1;
            push_integer(InBeatQ_c, Beat_v);
            push_boolean(InBeatQ_c, Last and (Pos_v + Beat_v = Bytes) and not CloseEmpty);

            for i in 0 to Beat_v - 1 loop
                Byte_v := Rnd.RandInt(0, 255);
                push_integer(InBeatQ_c, Byte_v);
                push_integer(Pkt_v, Byte_v);
            end loop;

            Pos_v := Pos_v + Beat_v;
        end loop;

        if Last and (CloseEmpty or (Bytes = 0)) then
            push_integer(InBeatQ_c, 0);
            push_boolean(InBeatQ_c, true);
        end if;

        -- Segments and their expected beats
        if Expect then

            while (Left_v > 0) or First_v loop
                if RandSegs then
                    Size_v := Rnd.RandInt(1, RandSegMax_c);
                else
                    Size_v   := Segs(SegIdx_v);
                    SegIdx_v := minimum(SegIdx_v + 1, Segs'high);
                end if;
                push_integer(SegQ_c, Size_v);
                Take_v := minimum(Size_v, Left_v);

                -- Beats of the segment (one empty beat for a packet without any byte)
                loop
                    Data_v := (others => '0');
                    Lane_v := 0;

                    while (Lane_v < Bytes_c) and (Take_v > 0) loop
                        Data_v(8 * Lane_v + 7 downto 8 * Lane_v) := toUslv(pop_integer(Pkt_v), 8);
                        Lane_v                                   := Lane_v + 1;
                        Take_v                                   := Take_v - 1;
                        Left_v                                   := Left_v - 1;
                    end loop;

                    push_std_ulogic_vector(ExpBeatQ_c, Data_v);
                    push_std_ulogic_vector(ExpBeatQ_c, lanesBe(Lane_v));
                    push_boolean(ExpBeatQ_c, Take_v = 0);
                    push_boolean(ExpBeatQ_c, (Take_v = 0) and (Left_v = 0));
                    exit when Take_v = 0;
                end loop;

                First_v := false;
            end loop;

        end if;
    end procedure;

    -- Wait until all input beats and segment commands are sent and all expected output beats are checked
    procedure waitDone (Timeout : time := 1 ms) is
    begin
        wait until is_empty(InBeatQ_c) and is_empty(SegQ_c) and is_empty(ExpBeatQ_c) and rising_edge(Clk) for Timeout;
        check(is_empty(ExpBeatQ_c), "waitDone: expected output beats missing");
        -- No further output beat
        wait for 20 * ClkPeriod_c;
        check_equal(Out_Valid, '0', "waitDone: unexpected output beat");
    end procedure;

begin

    -----------------------------------------------------------------------------------------------
    -- TB Control
    -----------------------------------------------------------------------------------------------
    test_runner_watchdog(runner, 20 ms);

    p_control : process is
        variable Rnd_v    : RandomPType;
        variable Stalls_v : natural;
        variable Segs_v   : natural;
    begin
        test_runner_setup(runner, runner_cfg);
        Rnd_v.InitSeed(Rnd_v'instance_name);

        while test_suite loop

            -- Reset
            InGapProb    <= 0.0;
            SegGapProb   <= 0.0;
            OutStallProb <= 0.0;

            wait until rising_edge(Clk);
            Rst <= '1';
            wait for 200 ns;
            wait until rising_edge(Clk);
            Rst <= '0';
            wait until rising_edge(Clk);

            if run("ResetValues") then
                check_equal(Out_Valid, '0', "Out_Valid");
                check_equal(Seg_Ready, '1', "Seg_Ready");
                check_equal(In_Ready, '0', "In_Ready without a segment");
            end if;

            -- The packet ends before the end of the segment
            if run("PacketShorterThanSegment") then
                pushPacket(2 * Bytes_c + 1, (0 => minimum(5 * Bytes_c, MaxSegSize_g)), Rnd_v);
                pushPacket(1, (0 => minimum(3, MaxSegSize_g)), Rnd_v);
                waitDone;
            end if;

            -- The packet ends exactly at the end of the segment: Out_Last and Out_InLast, no extra beat
            if run("PacketEndsAtSegmentEnd") then
                pushPacket(minimum(2 * Bytes_c, MaxSegSize_g), (0 => minimum(2 * Bytes_c, MaxSegSize_g)), Rnd_v);
                pushPacket(minimum(2 * Bytes_c + 1, MaxSegSize_g), (0 => minimum(2 * Bytes_c + 1, MaxSegSize_g)), Rnd_v);
                pushPacket(1, (0 => 1), Rnd_v);
                waitDone;
            end if;

            -- An empty closing beat after a segment that ends at a beat boundary marks that segment
            if run("EmptyCloseAtSegmentEnd") then
                pushPacket(minimum(2 * Bytes_c, MaxSegSize_g), (0 => minimum(2 * Bytes_c, MaxSegSize_g)), Rnd_v,
                           CloseEmpty => true);
                pushPacket(Bytes_c, (0 => minimum(Bytes_c, MaxSegSize_g)), Rnd_v, CloseEmpty => true);
                pushPacket(3, (0 => 1), Rnd_v, CloseEmpty => true);
                waitDone;
            end if;

            -- An empty closing beat inside a segment ends it at the last byte of the packet
            if run("EmptyCloseInsideSegment") then
                pushPacket(3 * Bytes_c, (0 => minimum(5 * Bytes_c, MaxSegSize_g)), Rnd_v, CloseEmpty => true);
                pushPacket(Bytes_c, (0 => MaxSegSize_g), Rnd_v, CloseEmpty => true);
                waitDone;
            end if;

            -- The packet continues after the segment: several segments
            if run("PacketLongerThanSegment") then
                pushPacket(5 * Bytes_c + 2, (0 => minimum(2 * Bytes_c, MaxSegSize_g)), Rnd_v);
                pushPacket(4 * Bytes_c, (0 => minimum(Bytes_c + 1, MaxSegSize_g)), Rnd_v);
                waitDone;
            end if;

            -- Segment ends at every lane offset; the next segment starts inside the input beat
            if run("EveryLaneOffset") then

                for Offs in 1 to Bytes_c loop
                    pushPacket(3 * Bytes_c, (minimum(Offs, MaxSegSize_g), MaxSegSize_g), Rnd_v);
                    pushPacket(3 * Bytes_c + Offs, (minimum(Bytes_c + Offs, MaxSegSize_g), minimum(Offs, MaxSegSize_g)), Rnd_v);
                end loop;

                waitDone;
            end if;

            -- Segments of exactly one byte and of exactly one beat
            if run("SegmentsOfOneByte") then
                pushPacket(2 * Bytes_c + 1, (0 => 1), Rnd_v);
                waitDone;
            end if;

            if run("SegmentsOfOneBeat") then
                pushPacket(3 * Bytes_c + 2, (0 => minimum(Bytes_c, MaxSegSize_g)), Rnd_v);
                waitDone;
            end if;

            -- A packet without any byte gives one empty segment beat with Out_Last and Out_InLast
            if run("ZeroBytePacket") then
                pushPacket(0, (0 => 1), Rnd_v);
                pushPacket(Bytes_c + 1, (0 => MaxSegSize_g), Rnd_v);
                pushPacket(0, (0 => MaxSegSize_g), Rnd_v);
                pushPacket(0, (0 => 1), Rnd_v);
                waitDone;
            end if;

            -- No input beat is taken while no segment is active
            if run("PacketWaitsForSegment") then
                -- Hold the segment commands back
                SegGapProb <= 1.0;
                wait until rising_edge(Clk);
                pushPacket(2 * Bytes_c + 1, (0 => minimum(Bytes_c, MaxSegSize_g)), Rnd_v);
                wait for 30 * ClkPeriod_c;
                wait until rising_edge(Clk);
                check_equal(In_Ready, '0', "In_Ready without a segment");
                check_equal(In_Valid, '1', "In_Valid of the waiting packet");
                check_equal(Out_Valid, '0', "Out_Valid without a segment");
                SegGapProb <= 0.0;
                -- The command applies in the cycle it is taken: the waiting beat is taken in the same cycle
                wait until rising_edge(Clk) and (Seg_Valid = '1') and (Seg_Ready = '1') for 1 us;
                check_equal(Seg_Valid, '1', "segment command taken");
                check_equal(In_Valid, '1', "In_Valid with the segment command");
                check_equal(In_Ready, '1', "waiting beat taken with the segment command");
                waitDone;
            end if;

            -- The segment command and the first data beat arrive in the same cycle: both are taken in it
            if run("SegmentWithFirstBeat") then
                InGapProb  <= 1.0;
                SegGapProb <= 1.0;
                wait until rising_edge(Clk);
                pushPacket(2 * Bytes_c + 1, (0 => MaxSegSize_g), Rnd_v);
                wait for 5 * ClkPeriod_c;
                wait until rising_edge(Clk);
                check_equal(In_Valid, '0', "no data beat before the release");
                check_equal(Seg_Valid, '0', "no segment command before the release");
                Stalls_v   := InStalls;

                -- Release both drivers in the same delta cycle
                InGapProb  <= 0.0;
                SegGapProb <= 0.0;
                wait until rising_edge(Clk) and (Seg_Valid = '1') and (Seg_Ready = '1') for 1 us;
                check_equal(Seg_Valid, '1', "segment command taken");
                check_equal(In_Valid, '1', "first data beat with the segment command");
                check_equal(In_Ready, '1', "first data beat taken with the segment command");
                -- The first data beat did not wait for the command
                check_equal(InStalls, Stalls_v, "input stalls before the segment command");
                waitDone;
            end if;

            -- Packets back to back
            if run("BackToBackPackets") then

                for p in 0 to 9 loop
                    pushPacket(p * Bytes_c / 3 + 1, (0 => MaxSegSize_g), Rnd_v);
                end loop;

                waitDone;
            end if;

            -- The largest segment
            if run("MaxSegSize") then
                pushPacket(3 * Bytes_c + 1, (0 => MaxSegSize_g), Rnd_v);
                if MaxSegSize_g <= 4096 then
                    pushPacket(MaxSegSize_g + Bytes_c + 1, (0 => MaxSegSize_g), Rnd_v);
                    pushPacket(MaxSegSize_g, (0 => MaxSegSize_g), Rnd_v, CloseEmpty => true);
                end if;
                waitDone(5 ms);
            end if;

            -- Rst clears the carry and the active segment
            if run("ResetClearsState") then
                -- A cut packet that stays in the carry (no output before the reset) inside an active segment
                pushPacket(maximum(minimum(Bytes_c - 1, MaxSegSize_g), 1), (0 => 1), Rnd_v, Expect => false, Last => false);
                push_integer(SegQ_c, minimum(2 * Bytes_c, MaxSegSize_g));
                wait until is_empty(InBeatQ_c) and is_empty(SegQ_c) and rising_edge(Clk);
                wait for 10 * ClkPeriod_c;
                wait until rising_edge(Clk);
                check_equal(Out_Valid, '0', "Out_Valid before the reset");
                Rst <= '1';
                wait until rising_edge(Clk);
                Rst <= '0';
                -- Neither the held bytes nor the segment survive the reset
                pushPacket(2 * Bytes_c + 1, (0 => MaxSegSize_g), Rnd_v);
                waitDone;
            end if;

            -- Random packets and segments, random gaps and output backpressure
            if run("Random-Backpressure") then
                InGapProb    <= 0.3;
                SegGapProb   <= 0.3;
                OutStallProb <= 0.4;

                for p in 0 to 99 loop
                    pushPacket(Rnd_v.RandInt(0, 20 * Bytes_c + Bytes_c - 1), (0 => 1), Rnd_v,
                               CloseEmpty => Rnd_v.RandInt(0, 3) = 0, RandSegs => true, RandBeats => (p mod 2) = 1);
                end loop;

                waitDone(5 ms);
            end if;

            if run("Random-NoBackpressure") then

                for p in 0 to 99 loop
                    pushPacket(Rnd_v.RandInt(0, 20 * Bytes_c + Bytes_c - 1), (0 => 1), Rnd_v,
                               CloseEmpty => Rnd_v.RandInt(0, 3) = 0, RandSegs => true, RandBeats => (p mod 2) = 1);
                end loop;

                waitDone(5 ms);
            end if;

            -- Throughput: one output beat per clock cycle, at most one inserted input cycle per segment
            if run("Throughput") then
                Stalls_v := InStalls;
                Segs_v   := SegsTaken;

                -- Segments of whole beats and segments that end inside a beat
                for p in 0 to 9 loop
                    pushPacket(8 * Bytes_c, (0 => minimum(2 * Bytes_c, MaxSegSize_g)), Rnd_v);
                    pushPacket(8 * Bytes_c, (0 => minimum(2 * Bytes_c + maximum(Bytes_c / 2, 1), MaxSegSize_g)), Rnd_v);
                end loop;

                waitDone;
                Segs_v := SegsTaken - Segs_v;
                check(InStalls - Stalls_v <= Segs_v, "Throughput: more than one inserted cycle per segment: " &
                      integer'image(InStalls - Stalls_v) & " for " & integer'image(Segs_v) & " segments");
                info("Throughput: inserted input cycles " & integer'image(InStalls - Stalls_v) & " for " &
                     integer'image(Segs_v) & " segments");
            end if;

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
    i_dut : entity olo.olo_base_stream_split
        generic map (
            Width_g      => Width_g,
            MaxSegSize_g => MaxSegSize_g
        )
        port map (
            Clk          => Clk,
            Rst          => Rst,
            In_Valid     => In_Valid,
            In_Ready     => In_Ready,
            In_Data      => In_Data,
            In_Be        => In_Be,
            In_Last      => In_Last,
            Seg_Valid    => Seg_Valid,
            Seg_Ready    => Seg_Ready,
            Seg_Size     => Seg_Size,
            Out_Valid    => Out_Valid,
            Out_Ready    => Out_Ready,
            Out_Data     => Out_Data,
            Out_Be       => Out_Be,
            Out_Last     => Out_Last,
            Out_InLast   => Out_InLast
        );

    -----------------------------------------------------------------------------------------------
    -- Input Driver (beats back to back unless a random gap is inserted)
    -----------------------------------------------------------------------------------------------
    p_input : process is
        variable Rnd_v   : RandomPType;
        variable Count_v : natural;
        variable Last_v  : boolean;
        variable Data_v  : std_logic_vector(Width_g - 1 downto 0);
    begin
        Rnd_v.InitSeed(Rnd_v'instance_name);

        loop
            if (not is_empty(InBeatQ_c)) and (Rst = '0') and (Rnd_v.RandReal(0.0, 1.0) >= InGapProb) then
                Count_v := pop_integer(InBeatQ_c);
                Last_v  := pop_boolean(InBeatQ_c);
                -- Random values in the lanes without a valid byte
                Data_v := Rnd_v.RandSlv(Width_g);

                for i in 0 to Count_v - 1 loop
                    Data_v(8 * i + 7 downto 8 * i) := toUslv(pop_integer(InBeatQ_c), 8);
                end loop;

                In_Valid <= '1';
                In_Data  <= Data_v;
                In_Be    <= lanesBe(Count_v);
                In_Last  <= toSl(Last_v);
                wait until rising_edge(Clk) and (In_Ready = '1');
            else
                -- Idle: random values on the data signals
                In_Valid <= '0';
                In_Data  <= Rnd_v.RandSlv(Width_g);
                In_Be    <= Rnd_v.RandSlv(Bytes_c);
                In_Last  <= toSl(Rnd_v.RandInt(0, 1) = 1);
                wait until rising_edge(Clk);
            end if;
        end loop;

    end process;

    -- Input stalls (valid but not ready) and segment commands taken
    p_stalls : process (Clk) is
    begin
        if rising_edge(Clk) then
            if (In_Valid = '1') and (In_Ready = '0') then
                InStalls <= InStalls + 1;
            end if;
            if (Seg_Valid = '1') and (Seg_Ready = '1') then
                SegsTaken <= SegsTaken + 1;
            end if;
        end if;
    end process;

    -----------------------------------------------------------------------------------------------
    -- Segment Command Driver
    -----------------------------------------------------------------------------------------------
    p_seg : process is
        variable Rnd_v : RandomPType;
    begin
        Rnd_v.InitSeed(Rnd_v'instance_name);

        loop
            if (not is_empty(SegQ_c)) and (Rst = '0') and (Rnd_v.RandReal(0.0, 1.0) >= SegGapProb) then
                Seg_Valid <= '1';
                Seg_Size  <= toUslv(pop_integer(SegQ_c), SizeBits_c);
                wait until rising_edge(Clk) and (Seg_Ready = '1');
            else
                Seg_Valid <= '0';
                Seg_Size  <= Rnd_v.RandSlv(SizeBits_c);
                wait until rising_edge(Clk);
            end if;
        end loop;

    end process;

    -----------------------------------------------------------------------------------------------
    -- Output Checker
    -----------------------------------------------------------------------------------------------
    p_ready : process is
        variable Rnd_v : RandomPType;
    begin
        Rnd_v.InitSeed(Rnd_v'instance_name);

        loop
            wait until rising_edge(Clk);
            Out_Ready <= toSl(Rnd_v.RandReal(0.0, 1.0) >= OutStallProb);
        end loop;

    end process;

    p_check : process (Clk) is
        variable Data_v   : std_logic_vector(Width_g - 1 downto 0);
        variable Be_v     : std_logic_vector(Bytes_c - 1 downto 0);
        variable Last_v   : boolean;
        variable InLast_v : boolean;
    begin
        if rising_edge(Clk) then
            if (Out_Valid = '1') and (Out_Ready = '1') then
                if is_empty(ExpBeatQ_c) then
                    error("Unexpected output beat");
                else
                    Data_v   := pop_std_ulogic_vector(ExpBeatQ_c);
                    Be_v     := pop_std_ulogic_vector(ExpBeatQ_c);
                    Last_v   := pop_boolean(ExpBeatQ_c);
                    InLast_v := pop_boolean(ExpBeatQ_c);
                    check_equal(Out_Data, Data_v, "Out_Data of beat " & integer'image(BeatsChecked));
                    check_equal(Out_Be, Be_v, "Out_Be of beat " & integer'image(BeatsChecked));
                    check_equal(Out_Last, toSl(Last_v), "Out_Last of beat " & integer'image(BeatsChecked));
                    check_equal(Out_InLast, toSl(InLast_v), "Out_InLast of beat " & integer'image(BeatsChecked));

                    BeatsChecked <= BeatsChecked + 1;
                end if;
            end if;
        end if;
    end process;

end architecture;
