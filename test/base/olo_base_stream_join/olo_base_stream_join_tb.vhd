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
entity olo_base_stream_join_tb is
    generic (
        runner_cfg      : string;
        Width_g         : positive := 32
    );
end entity;

architecture sim of olo_base_stream_join_tb is

    -----------------------------------------------------------------------------------------------
    -- Constants
    -----------------------------------------------------------------------------------------------
    constant ClkPeriod_c : time     := 10 ns;
    constant Bytes_c     : positive := Width_g / 8;

    -----------------------------------------------------------------------------------------------
    -- TB Definitions
    -----------------------------------------------------------------------------------------------
    -- Input beats (per beat: byte count, last, bytes) and expected output beats (per beat: data, Be, last)
    constant InBeatQ_c  : queue_t := new_queue;
    constant ExpBeatQ_c : queue_t := new_queue;

    -- Probability of an idle cycle before an input beat and of Out_Ready low in a cycle
    signal InGapProb    : real := 0.0;
    signal OutStallProb : real := 0.0;

    -- Monitoring
    signal BeatsChecked : natural := 0;
    signal InStalls     : natural := 0; -- cycles with In_Valid = '1' and In_Ready = '0'

    -----------------------------------------------------------------------------------------------
    -- Interface Signals
    -----------------------------------------------------------------------------------------------
    signal Clk       : std_logic                              := '0';
    signal Rst       : std_logic                              := '1';
    signal In_Valid  : std_logic                              := '0';
    signal In_Ready  : std_logic;
    signal In_Data   : std_logic_vector(Width_g - 1 downto 0) := (others => '0');
    signal In_Be     : std_logic_vector(Bytes_c - 1 downto 0) := (others => '0');
    signal In_Last   : std_logic                              := '0';
    signal Out_Valid : std_logic;
    signal Out_Ready : std_logic                              := '1';
    signal Out_Data  : std_logic_vector(Width_g - 1 downto 0);
    signal Out_Be    : std_logic_vector(Bytes_c - 1 downto 0);
    signal Out_Last  : std_logic;

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

    -- Push a packet whose input beats hold Counts(i) bytes (In_Last on the beat of the last element unless Last is
    -- false) and its expected output beats: the bytes without gaps, every beat full except the last (one empty beat
    -- for a packet without any byte). The bytes are random (non-periodic).
    procedure pushPacket (
        Counts       : integer_vector;
        variable Rnd : inout RandomPType;
        Expect       : boolean := true;
        Last         : boolean := true) is
        variable Total_v : natural := 0;
        variable Pos_v   : natural := 0;
        variable Byte_v  : natural;
        variable Data_v  : std_logic_vector(Width_g - 1 downto 0);
        variable Lane_v  : natural;
        variable Pkt_v   : queue_t := new_queue;
    begin

        -- Input beats
        for b in Counts'range loop
            push_integer(InBeatQ_c, Counts(b));
            push_boolean(InBeatQ_c, Last and (b = Counts'high));

            for i in 0 to Counts(b) - 1 loop
                Byte_v := Rnd.RandInt(0, 255);
                push_integer(InBeatQ_c, Byte_v);
                push_integer(Pkt_v, Byte_v);
            end loop;

            Total_v := Total_v + Counts(b);
        end loop;

        -- Expected output beats
        if Expect then
            if Total_v = 0 then
                push_std_ulogic_vector(ExpBeatQ_c, zerosVector(Width_g));
                push_std_ulogic_vector(ExpBeatQ_c, zerosVector(Bytes_c));
                push_boolean(ExpBeatQ_c, true);
            end if;

            while Pos_v < Total_v loop
                Data_v := (others => '0');
                Lane_v := 0;

                while (Lane_v < Bytes_c) and (Pos_v < Total_v) loop
                    Data_v(8 * Lane_v + 7 downto 8 * Lane_v) := toUslv(pop_integer(Pkt_v), 8);
                    Lane_v                                   := Lane_v + 1;
                    Pos_v                                    := Pos_v + 1;
                end loop;

                push_std_ulogic_vector(ExpBeatQ_c, Data_v);
                push_std_ulogic_vector(ExpBeatQ_c, lanesBe(Lane_v));
                push_boolean(ExpBeatQ_c, Pos_v = Total_v);
            end loop;

        end if;
    end procedure;

    -- Push a packet of Bytes bytes in input beats of random byte counts (0 to Bytes_c, empty beats included);
    -- with CloseEmpty the packet ends with an empty beat
    procedure pushRandomPacket (
        Bytes        : natural;
        variable Rnd : inout RandomPType;
        CloseEmpty   : boolean) is
        variable Counts_v : integer_vector(0 to 4 * Bytes + 8);
        variable Cnt_v    : natural := 0;
        variable Left_v   : natural := Bytes;
        variable Beat_v   : natural;
    begin

        while Left_v > 0 loop
            Beat_v := minimum(Rnd.RandInt(0, Bytes_c), Left_v);
            -- Bound the number of beats
            if Cnt_v >= Counts_v'high - 1 then
                Beat_v := minimum(Bytes_c, Left_v);
            end if;
            Counts_v(Cnt_v) := Beat_v;
            Cnt_v           := Cnt_v + 1;
            Left_v          := Left_v - Beat_v;
        end loop;

        if CloseEmpty or (Cnt_v = 0) then
            Counts_v(Cnt_v) := 0;
            Cnt_v           := Cnt_v + 1;
        end if;
        pushPacket(Counts_v(0 to Cnt_v - 1), Rnd);
    end procedure;

    -- Wait until all input beats are sent and all expected output beats are checked
    procedure waitDone (Timeout : time := 1 ms) is
    begin
        wait until is_empty(InBeatQ_c) and is_empty(ExpBeatQ_c) and rising_edge(Clk) for Timeout;
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
    begin
        test_runner_setup(runner, runner_cfg);
        Rnd_v.InitSeed(Rnd_v'instance_name);

        while test_suite loop

            -- Reset
            InGapProb    <= 0.0;
            OutStallProb <= 0.0;

            wait until rising_edge(Clk);
            Rst <= '1';
            wait for 200 ns;
            wait until rising_edge(Clk);
            Rst <= '0';
            wait until rising_edge(Clk);

            if run("ResetValues") then
                check_equal(Out_Valid, '0', "Out_Valid");
                check_equal(In_Ready, '1', "In_Ready");
            end if;

            -- Full beats only
            if run("FullBeats") then
                pushPacket((0 => Bytes_c), Rnd_v);
                pushPacket((Bytes_c, Bytes_c, Bytes_c), Rnd_v);
                pushPacket((Bytes_c, Bytes_c, maximum(Bytes_c - 1, 1)), Rnd_v);
                waitDone;
            end if;

            -- Partial beats inside a packet are joined without gaps, at every lane offset
            if run("PartialBeats") then

                for Offs in 1 to Bytes_c loop
                    pushPacket((Offs, Bytes_c, Bytes_c, Offs), Rnd_v);
                    pushPacket((Offs, 1, Bytes_c - 1, Bytes_c), Rnd_v);
                end loop;

                waitDone;
            end if;

            -- Empty beats inside a packet are skipped
            if run("EmptyBeatsInside") then
                pushPacket((3 mod (Bytes_c + 1), 0, 0, Bytes_c, 0, 1), Rnd_v);
                pushPacket((0, Bytes_c, 0, Bytes_c), Rnd_v);
                waitDone;
            end if;

            -- An empty closing beat puts Out_Last on the last held byte: carry 1, B - 1 and B (exactly full)
            if run("EmptyClosingBeat") then
                pushPacket((1, 0), Rnd_v);
                pushPacket((maximum(Bytes_c - 1, 1), 0), Rnd_v);
                pushPacket((Bytes_c, 0), Rnd_v);
                pushPacket((Bytes_c, Bytes_c, 0), Rnd_v);
                pushPacket((Bytes_c, 1, Bytes_c - 1, 0), Rnd_v);
                waitDone;
            end if;

            -- A packet without any byte gives one empty beat with Out_Last
            if run("ZeroBytePacket") then
                pushPacket((0 => 0), Rnd_v);
                pushPacket((0, 0, 0), Rnd_v);
                pushPacket((0 => 1), Rnd_v);
                pushPacket((0 => 0), Rnd_v);
                pushPacket((Bytes_c, 2 mod (Bytes_c + 1)), Rnd_v);
                waitDone;
            end if;

            -- Single-byte beats and packets
            if run("SingleBytes") then

                for i in 1 to 3 * Bytes_c loop
                    pushPacket((0 => 1), Rnd_v);
                end loop;

                pushPacket((1, 1, 1, 1, 1, 1, 1, 1, 1, 1), Rnd_v);
                waitDone;
            end if;

            -- Rst clears the carry: the held bytes of a packet cut by the reset are not output
            if run("ResetClearsCarry") then
                pushPacket((Bytes_c - 1, 1), Rnd_v, Expect => false, Last => false);
                wait until is_empty(InBeatQ_c) and rising_edge(Clk);
                wait for 5 * ClkPeriod_c;
                wait until rising_edge(Clk);
                check_equal(Out_Valid, '0', "Out_Valid before the reset");
                Rst <= '1';
                wait until rising_edge(Clk);
                Rst <= '0';
                pushPacket((2 mod (Bytes_c + 1), Bytes_c), Rnd_v);
                waitDone;
            end if;

            -- Random packets, random input gaps and output backpressure
            if run("Random-Backpressure") then
                InGapProb    <= 0.3;
                OutStallProb <= 0.4;

                for p in 0 to 99 loop
                    pushRandomPacket(Rnd_v.RandInt(1, 20 * Bytes_c + Bytes_c - 1), Rnd_v, Rnd_v.RandInt(0, 3) = 0);
                end loop;

                waitDone(5 ms);
            end if;

            if run("Random-NoBackpressure") then

                for p in 0 to 99 loop
                    pushRandomPacket(Rnd_v.RandInt(0, 20 * Bytes_c + Bytes_c - 1), Rnd_v, Rnd_v.RandInt(0, 3) = 0);
                end loop;

                waitDone(5 ms);
            end if;

            -- Throughput: one input beat per clock cycle, at most one inserted cycle per packet
            if run("Throughput") then
                Stalls_v := InStalls;

                for p in 0 to 19 loop
                    pushPacket((Bytes_c, Bytes_c, Bytes_c, Bytes_c, Bytes_c, Bytes_c, Bytes_c, maximum(Bytes_c - 1, 1)),
                               Rnd_v);
                end loop;

                waitDone;
                check(InStalls - Stalls_v <= 20, "Throughput: more than one inserted cycle per packet: " &
                      integer'image(InStalls - Stalls_v));
                info("Throughput: inserted cycles for 20 packets of 8 beats: " & integer'image(InStalls - Stalls_v));
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
    i_dut : entity olo.olo_base_stream_join
        generic map (
            Width_g    => Width_g
        )
        port map (
            Clk        => Clk,
            Rst        => Rst,
            In_Valid   => In_Valid,
            In_Ready   => In_Ready,
            In_Data    => In_Data,
            In_Be      => In_Be,
            In_Last    => In_Last,
            Out_Valid  => Out_Valid,
            Out_Ready  => Out_Ready,
            Out_Data   => Out_Data,
            Out_Be     => Out_Be,
            Out_Last   => Out_Last
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

    -- Input stalls (valid but not ready)
    p_stalls : process (Clk) is
    begin
        if rising_edge(Clk) then
            if (In_Valid = '1') and (In_Ready = '0') then
                InStalls <= InStalls + 1;
            end if;
        end if;
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
        variable Data_v : std_logic_vector(Width_g - 1 downto 0);
        variable Be_v   : std_logic_vector(Bytes_c - 1 downto 0);
        variable Last_v : boolean;
    begin
        if rising_edge(Clk) then
            if (Out_Valid = '1') and (Out_Ready = '1') then
                if is_empty(ExpBeatQ_c) then
                    error("Unexpected output beat");
                else
                    Data_v := pop_std_ulogic_vector(ExpBeatQ_c);
                    Be_v   := pop_std_ulogic_vector(ExpBeatQ_c);
                    Last_v := pop_boolean(ExpBeatQ_c);
                    check_equal(Out_Data, Data_v, "Out_Data of beat " & integer'image(BeatsChecked));
                    check_equal(Out_Be, Be_v, "Out_Be of beat " & integer'image(BeatsChecked));
                    check_equal(Out_Last, toSl(Last_v), "Out_Last of beat " & integer'image(BeatsChecked));

                    BeatsChecked <= BeatsChecked + 1;
                end if;
            end if;
        end if;
    end process;

end architecture;
