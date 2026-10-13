---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- This entity splits every packet of a stream into chunks of ChunkBeats_g beats, each chunk
-- ending with Out_Last. The last chunk of a packet is shorter if the packet ends early (no
-- padding) and is marked by Out_InLast. Data passes through without added latency.
--
-- Documentation:
-- https://github.com/open-logic/open-logic/blob/main/doc/base/olo_base_chunker.md
--
-- Note: The link points to the documentation of the latest release. If you
--       use an older version, the documentation might not match the code.

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity olo_base_chunker is
    generic (
        Width_g      : positive;
        ChunkBeats_g : positive
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
        Out_Last     : out   std_logic;
        Out_InLast   : out   std_logic
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of olo_base_chunker is

    -- *** Two Process Method ***
    type TwoProcess_r is record
        BeatCnt : natural range 0 to ChunkBeats_g - 1;
    end record;

    signal r, r_next : TwoProcess_r;

begin

    -----------------------------------------------------------------------------------------------
    -- Combinatorial Process
    -----------------------------------------------------------------------------------------------
    p_comb : process (all) is
        variable v          : TwoProcess_r;
        variable ChunkEnd_v : std_logic;
    begin
        -- *** hold variables stable ***
        v := r;

        -- *** End of the chunk: chunk full or end of the input packet ***
        if r.BeatCnt = ChunkBeats_g - 1 then
            ChunkEnd_v := '1';
        else
            ChunkEnd_v := In_Last;
        end if;

        -- *** Count the beats of the current chunk ***
        if In_Valid = '1' and Out_Ready = '1' then
            if ChunkEnd_v = '1' then
                v.BeatCnt := 0;
            else
                v.BeatCnt := r.BeatCnt + 1;
            end if;
        end if;

        -- *** Outputs ***
        Out_Last <= ChunkEnd_v;

        -- *** Assign to signal ***
        r_next <= v;
    end process;

    -----------------------------------------------------------------------------------------------
    -- Pass-Through
    -----------------------------------------------------------------------------------------------
    Out_Valid  <= In_Valid;
    In_Ready   <= Out_Ready;
    Out_Data   <= In_Data;
    Out_Be     <= In_Be;
    Out_InLast <= In_Last;

    -----------------------------------------------------------------------------------------------
    -- Sequential Process
    -----------------------------------------------------------------------------------------------
    p_seq : process (Clk) is
    begin
        if rising_edge(Clk) then
            r <= r_next;
            if Rst = '1' then
                r.BeatCnt <= 0;
            end if;
        end if;
    end process;

end architecture;
