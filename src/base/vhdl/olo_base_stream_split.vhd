---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- This entity cuts the packets of a stream into segments of a size given per segment in bytes:
-- every segment starts in lane 0 and ends with Out_Last, the segment in which the input packet
-- ends is marked by Out_InLast.
--
-- Documentation:
-- https://github.com/open-logic/open-logic/blob/main/doc/base/olo_base_stream_split.md
--
-- Note: The link points to the documentation of the latest release. If you
--       use an older version, the documentation might not match the code.

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library work;
    use work.olo_base_pkg_math.all;
    use work.olo_base_pkg_string.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity olo_base_stream_split is
    generic (
        Width_g      : positive range 8 to 1024;
        MaxSegSize_g : positive range 1 to 2**30 - 1
    );
    port (
        -- Control Signals
        Clk          : in    std_logic;
        Rst          : in    std_logic;
        -- Input
        In_Valid     : in    std_logic                                  := '1';
        In_Ready     : out   std_logic;
        In_Data      : in    std_logic_vector(Width_g - 1 downto 0);
        In_Be        : in    std_logic_vector(Width_g / 8 - 1 downto 0) := (others => '1');
        In_Last      : in    std_logic                                  := '0';
        -- Segment Commands
        Seg_Valid    : in    std_logic                                  := '1';
        Seg_Ready    : out   std_logic;
        Seg_Size     : in    std_logic_vector(log2ceil(MaxSegSize_g + 1) - 1 downto 0);
        -- Output
        Out_Valid    : out   std_logic;
        Out_Ready    : in    std_logic                                  := '1';
        Out_Data     : out   std_logic_vector(Width_g - 1 downto 0);
        Out_Be       : out   std_logic_vector(Width_g / 8 - 1 downto 0);
        Out_Last     : out   std_logic;
        Out_InLast   : out   std_logic
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of olo_base_stream_split is

    -- *** Constants ***
    constant EntityName_c : string   := "olo_base_stream_split";
    constant Bytes_c      : positive := Width_g / 8;
    constant SizeBits_c   : positive := log2ceil(MaxSegSize_g + 1);

    -- *** Types ***
    subtype Byte_t is std_logic_vector(7 downto 0);
    type Bytes_t is array (natural range <>) of Byte_t;

    -- *** Functions ***
    -- Bytes of a data vector, lane 0 first
    function toBytes (Data : std_logic_vector) return Bytes_t is
        variable Bytes_v : Bytes_t(0 to Data'length / 8 - 1);
    begin

        for i in Bytes_v'range loop
            Bytes_v(i) := Data(Data'low + 8 * i + 7 downto Data'low + 8 * i);
        end loop;

        return Bytes_v;
    end function;

    -- Data vector of the first Count bytes, the other lanes zero
    function toData (
        Bytes : Bytes_t;
        Count : natural) return std_logic_vector is
        variable Data_v : std_logic_vector(Width_g - 1 downto 0);
    begin

        for i in 0 to Bytes_c - 1 loop
            if i < Count then
                Data_v(8 * i + 7 downto 8 * i) := Bytes(Bytes'low + i);
            else
                Data_v(8 * i + 7 downto 8 * i) := (others => '0');
            end if;
        end loop;

        return Data_v;
    end function;

    -- Byte enables of the lanes 0 to Count - 1
    function lanesBe (Count : natural) return std_logic_vector is
        variable Be_v : std_logic_vector(Bytes_c - 1 downto 0);
    begin

        for i in 0 to Bytes_c - 1 loop
            if i < Count then
                Be_v(i) := '1';
            else
                Be_v(i) := '0';
            end if;
        end loop;

        return Be_v;
    end function;

    -- *** Two Process Method ***
    type TwoProcess_r is record
        Carry      : Bytes_t(0 to Bytes_c - 1);         -- bytes not yet output, from lane 0
        CarryCnt   : natural range 0 to Bytes_c;
        CarryLast  : std_logic;                          -- the carry holds the end of a packet
        SegActive  : std_logic;
        SegRem     : natural range 0 to 2**SizeBits_c - 1; -- bytes of the active segment not yet output
        Out_Valid  : std_logic;
        Out_Data   : std_logic_vector(Width_g - 1 downto 0);
        Out_Be     : std_logic_vector(Bytes_c - 1 downto 0);
        Out_Last   : std_logic;
        Out_InLast : std_logic;
    end record;

    signal r, r_next : TwoProcess_r;

begin

    -- *** Assertions ***
    assert Width_g mod 8 = 0
        report errorMessage(EntityName_c, "Width_g must be a multiple of 8")
        severity failure;

    -----------------------------------------------------------------------------------------------
    -- Combinatorial Process
    -----------------------------------------------------------------------------------------------
    p_comb : process (all) is
        variable v         : TwoProcess_r;
        variable OutFree_v : boolean;
        variable Active_v  : boolean;
        variable Rem_v     : natural range 0 to 2**SizeBits_c - 1;
        variable RemBeat_v : natural range 0 to Bytes_c;
        variable InReady_v : std_logic;
        variable Take_v    : boolean;
        variable InBytes_v : Bytes_t(0 to Bytes_c - 1);
        variable InCnt_v   : natural range 0 to Bytes_c;
        variable Avail_v   : natural range 0 to 2 * Bytes_c;
        variable LastIn_v  : std_logic;
        variable Comb_v    : Bytes_t(0 to 2 * Bytes_c - 1);
    begin
        -- *** hold variables stable ***
        v := r;

        -- *** Output handshake ***
        if Out_Ready = '1' then
            v.Out_Valid := '0';
        end if;
        OutFree_v := (r.Out_Valid = '0') or (Out_Ready = '1');

        -- *** Segment command: taken while no segment is active, applies in the same clock cycle ***
        if r.SegActive = '1' then
            Active_v := true;
            Rem_v    := r.SegRem;
        elsif Seg_Valid = '1' then
            Active_v    := true;
            Rem_v       := to_integer(unsigned(Seg_Size));
            v.SegActive := '1';
            v.SegRem    := Rem_v;
        else
            Active_v := false;
            Rem_v    := 0;
        end if;

        -- Bytes of the next output beat of the segment
        if Rem_v < Bytes_c then
            RemBeat_v := Rem_v;
        else
            RemBeat_v := Bytes_c;
        end if;

        -- *** Valid bytes of the input beat (In_Be contiguous from lane 0) ***
        InCnt_v := 0;

        for i in 0 to Bytes_c - 1 loop
            if In_Be(i) = '1' then
                InCnt_v := i + 1;
            end if;
        end loop;

        -- *** Input accepted while a segment is active, the output is free, the carry holds no packet end and
        --     at most the bytes of the next output beat ***
        if Active_v and OutFree_v and (r.CarryLast = '0') and (r.CarryCnt <= RemBeat_v) then
            InReady_v := '1';
        else
            InReady_v := '0';
        end if;
        Take_v := (InReady_v = '1') and (In_Valid = '1');

        if Take_v then
            Avail_v  := r.CarryCnt + InCnt_v;
            LastIn_v := In_Last;
        else
            Avail_v  := r.CarryCnt;
            LastIn_v := r.CarryLast;
        end if;

        -- *** Carry bytes followed by the input bytes ***
        InBytes_v := toBytes(In_Data);

        for j in 0 to Bytes_c - 1 loop
            if j < r.CarryCnt then
                Comb_v(j) := r.Carry(j);
            else
                Comb_v(j) := InBytes_v(j - r.CarryCnt);
            end if;
        end loop;

        for j in Bytes_c to 2 * Bytes_c - 1 loop
            if j - r.CarryCnt < Bytes_c then
                Comb_v(j) := InBytes_v(j - r.CarryCnt);
            else
                Comb_v(j) := (others => '0');
            end if;
        end loop;

        -- *** Split ***
        if Active_v and OutFree_v then
            if (LastIn_v = '1') and (Avail_v <= RemBeat_v) then
                -- The packet ends in this beat: the last beat of the segment (also a packet without any byte)
                v.Out_Data   := toData(Comb_v(0 to Bytes_c - 1), Avail_v);
                v.Out_Be     := lanesBe(Avail_v);
                v.Out_Last   := '1';
                v.Out_InLast := '1';
                v.Out_Valid  := '1';
                v.CarryCnt   := 0;
                v.CarryLast  := '0';
                v.SegActive  := '0';
            elsif Avail_v > RemBeat_v then
                -- A beat of the segment, the rest stays in the carry
                v.Out_Data   := toData(Comb_v(0 to Bytes_c - 1), RemBeat_v);
                v.Out_Be     := lanesBe(RemBeat_v);
                v.Out_InLast := '0';
                v.Out_Valid  := '1';

                for i in 0 to Bytes_c - 1 loop
                    v.Carry(i) := Comb_v(RemBeat_v + i);
                end loop;

                v.CarryCnt  := Avail_v - RemBeat_v;
                v.CarryLast := LastIn_v;
                v.SegRem    := Rem_v - RemBeat_v;
                if Rem_v <= Bytes_c then
                    v.Out_Last  := '1';
                    v.SegActive := '0';
                else
                    v.Out_Last := '0';
                end if;
            else
                -- At most the bytes of this output beat: held, so that an empty closing beat can still mark them
                v.Carry    := Comb_v(0 to Bytes_c - 1);
                v.CarryCnt := Avail_v;
            end if;
        end if;

        -- *** Outputs ***
        In_Ready  <= InReady_v;
        Seg_Ready <= not r.SegActive;

        -- *** Assign to signal ***
        r_next <= v;
    end process;

    -----------------------------------------------------------------------------------------------
    -- Outputs
    -----------------------------------------------------------------------------------------------
    Out_Valid  <= r.Out_Valid;
    Out_Data   <= r.Out_Data;
    Out_Be     <= r.Out_Be;
    Out_Last   <= r.Out_Last;
    Out_InLast <= r.Out_InLast;

    -----------------------------------------------------------------------------------------------
    -- Sequential Process
    -----------------------------------------------------------------------------------------------
    p_seq : process (Clk) is
    begin
        if rising_edge(Clk) then
            r <= r_next;
            if Rst = '1' then
                r.CarryCnt  <= 0;
                r.CarryLast <= '0';
                r.SegActive <= '0';
                r.Out_Valid <= '0';
            end if;
        end if;
    end process;

    -----------------------------------------------------------------------------------------------
    -- Input Checks (simulation only)
    -----------------------------------------------------------------------------------------------
    -- synthesis translate_off
    p_check : process (Clk) is
    begin
        if rising_edge(Clk) then
            if Rst = '0' then
                if In_Valid = '1' then

                    for i in 0 to Bytes_c - 2 loop
                        assert not ((In_Be(i) = '0') and (In_Be(i + 1) = '1'))
                            report errorMessage(EntityName_c, "In_Be must be contiguous from lane 0")
                            severity error;
                    end loop;

                end if;
                if (Seg_Valid = '1') and (r.SegActive = '0') then
                    assert (unsigned(Seg_Size) >= 1) and (unsigned(Seg_Size) <= MaxSegSize_g)
                        report errorMessage(EntityName_c, "Seg_Size must be 1 to MaxSegSize_g")
                        severity error;
                end if;
            end if;
        end if;
    end process;

    -- synthesis translate_on

end architecture;
