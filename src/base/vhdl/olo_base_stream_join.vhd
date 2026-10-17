---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- This entity packs the valid bytes of a stream: an input beat may hold fewer bytes than the
-- width (In_Be contiguous from lane 0), the output carries the bytes of each packet without
-- gaps, every output beat full except the last beat of the packet.
--
-- Documentation:
-- https://github.com/open-logic/open-logic/blob/main/doc/base/olo_base_stream_join.md
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
    use work.olo_base_pkg_string.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity olo_base_stream_join is
    generic (
        Width_g      : positive range 8 to 1024
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
        -- Output
        Out_Valid    : out   std_logic;
        Out_Ready    : in    std_logic                                  := '1';
        Out_Data     : out   std_logic_vector(Width_g - 1 downto 0);
        Out_Be       : out   std_logic_vector(Width_g / 8 - 1 downto 0);
        Out_Last     : out   std_logic
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of olo_base_stream_join is

    -- *** Constants ***
    constant EntityName_c : string   := "olo_base_stream_join";
    constant Bytes_c      : positive := Width_g / 8;

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
        Carry     : Bytes_t(0 to Bytes_c - 1);         -- bytes not yet output, from lane 0
        CarryCnt  : natural range 0 to Bytes_c;
        Flush     : std_logic;                          -- the carry is the last beat of a packet
        Out_Valid : std_logic;
        Out_Data  : std_logic_vector(Width_g - 1 downto 0);
        Out_Be    : std_logic_vector(Bytes_c - 1 downto 0);
        Out_Last  : std_logic;
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
        variable InReady_v : std_logic;
        variable InBytes_v : Bytes_t(0 to Bytes_c - 1);
        variable InCnt_v   : natural range 0 to Bytes_c;
        variable Total_v   : natural range 0 to 2 * Bytes_c;
        variable Comb_v    : Bytes_t(0 to 2 * Bytes_c - 1);
    begin
        -- *** hold variables stable ***
        v := r;

        -- *** Output handshake ***
        if Out_Ready = '1' then
            v.Out_Valid := '0';
        end if;
        OutFree_v := (r.Out_Valid = '0') or (Out_Ready = '1');

        -- *** Valid bytes of the input beat (In_Be contiguous from lane 0) ***
        InCnt_v := 0;

        for i in 0 to Bytes_c - 1 loop
            if In_Be(i) = '1' then
                InCnt_v := i + 1;
            end if;
        end loop;

        Total_v := r.CarryCnt + InCnt_v;

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

        -- *** Input accepted when the output is free and no second beat of a packet end is pending ***
        if OutFree_v and (r.Flush = '0') then
            InReady_v := '1';
        else
            InReady_v := '0';
        end if;

        -- *** Pack ***
        if r.Flush = '1' then
            -- Second output beat of a packet end: the carry
            if OutFree_v then
                v.Out_Data  := toData(r.Carry, r.CarryCnt);
                v.Out_Be    := lanesBe(r.CarryCnt);
                v.Out_Last  := '1';
                v.Out_Valid := '1';
                v.CarryCnt  := 0;
                v.Flush     := '0';
            end if;
        elsif (InReady_v = '1') and (In_Valid = '1') then
            if Total_v > Bytes_c then
                -- A full output beat, the rest stays in the carry (the last beat of the packet with In_Last)
                v.Out_Data  := toData(Comb_v(0 to Bytes_c - 1), Bytes_c);
                v.Out_Be    := (others => '1');
                v.Out_Last  := '0';
                v.Out_Valid := '1';
                v.Carry     := Comb_v(Bytes_c to 2 * Bytes_c - 1);
                v.CarryCnt  := Total_v - Bytes_c;
                v.Flush     := In_Last;
            elsif In_Last = '1' then
                -- Last beat of the packet, also of a packet without any byte
                v.Out_Data  := toData(Comb_v(0 to Bytes_c - 1), Total_v);
                v.Out_Be    := lanesBe(Total_v);
                v.Out_Last  := '1';
                v.Out_Valid := '1';
                v.CarryCnt  := 0;
            else
                -- At most one beat of bytes: held, so that an empty closing beat can still mark the last of them
                v.Carry    := Comb_v(0 to Bytes_c - 1);
                v.CarryCnt := Total_v;
            end if;
        end if;

        -- *** Outputs ***
        In_Ready <= InReady_v;

        -- *** Assign to signal ***
        r_next <= v;
    end process;

    -----------------------------------------------------------------------------------------------
    -- Outputs
    -----------------------------------------------------------------------------------------------
    Out_Valid <= r.Out_Valid;
    Out_Data  <= r.Out_Data;
    Out_Be    <= r.Out_Be;
    Out_Last  <= r.Out_Last;

    -----------------------------------------------------------------------------------------------
    -- Sequential Process
    -----------------------------------------------------------------------------------------------
    p_seq : process (Clk) is
    begin
        if rising_edge(Clk) then
            r <= r_next;
            if Rst = '1' then
                r.CarryCnt  <= 0;
                r.Flush     <= '0';
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
            if (Rst = '0') and (In_Valid = '1') then

                for i in 0 to Bytes_c - 2 loop
                    assert not ((In_Be(i) = '0') and (In_Be(i + 1) = '1'))
                        report errorMessage(EntityName_c, "In_Be must be contiguous from lane 0")
                        severity error;
                end loop;

            end if;
        end if;
    end process;

    -- synthesis translate_on

end architecture;
