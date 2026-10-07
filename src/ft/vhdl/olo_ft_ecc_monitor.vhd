---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- EDAC monitor for the fault-tolerant (ft) area: aggregates the SEC/DED indications of up to 255
-- ft instances into per-channel saturating counters with sticky DED flags, event pulses and a
-- RAM-style read port with per-channel read-and-clear.
--
-- Documentation:
-- https://github.com/open-logic/open-logic/blob/main/doc/ft/olo_ft_ecc_monitor.md
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

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity olo_ft_ecc_monitor is
    generic (
        Channels_g     : positive range 1 to 255;
        CounterWidth_g : positive range 1 to 16 := 16
    );
    port (
        -- Control Ports
        Clk        : in    std_logic;
        Rst        : in    std_logic;
        Clr        : in    std_logic                                                   := '0';
        -- Event Inputs
        In_EccSec  : in    std_logic_vector(Channels_g - 1 downto 0);
        In_EccDed  : in    std_logic_vector(Channels_g - 1 downto 0);
        In_Valid   : in    std_logic_vector(Channels_g - 1 downto 0)                   := (others => '1');
        -- Status
        DedSticky  : out   std_logic_vector(Channels_g - 1 downto 0);
        Evt_Sec    : out   std_logic;
        Evt_Ded    : out   std_logic;
        -- Read Port
        Rd_Channel : in    std_logic_vector(max(log2ceil(Channels_g), 1) - 1 downto 0) := (others => '0');
        Rd_Ena     : in    std_logic                                                   := '0';
        Rd_Clr     : in    std_logic                                                   := '0';
        Rd_SecCnt  : out   std_logic_vector(CounterWidth_g - 1 downto 0);
        Rd_DedCnt  : out   std_logic_vector(CounterWidth_g - 1 downto 0);
        Rd_Valid   : out   std_logic
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of olo_ft_ecc_monitor is

    -- All counters saturate at this value
    constant CounterMax_c : unsigned(CounterWidth_g - 1 downto 0) := (others => '1');

    type Counter_a is array (0 to Channels_g - 1) of unsigned(CounterWidth_g - 1 downto 0);

    type TwoProcess_r is record
        SecCnt    : Counter_a;
        DedCnt    : Counter_a;
        DedSticky : std_logic_vector(Channels_g - 1 downto 0);
        EvtSec    : std_logic;
        EvtDed    : std_logic;
        RdSecCnt  : std_logic_vector(CounterWidth_g - 1 downto 0);
        RdDedCnt  : std_logic_vector(CounterWidth_g - 1 downto 0);
        RdValid   : std_logic;
    end record;

    signal r, r_next : TwoProcess_r;

begin

    -- *** Combinatorial Process ***
    p_comb : process (all) is
        variable v       : TwoProcess_r;
        variable RdIdx_v : natural;
    begin
        v := r;

        -- Read sampling first: a simultaneous clear or event acts after the sample, so the read
        -- returns the state as of the beginning of the cycle.
        v.RdValid := '0';
        RdIdx_v   := fromUslv(Rd_Channel);
        if Rd_Ena = '1' then
            v.RdValid := '1';
            if RdIdx_v < Channels_g then
                v.RdSecCnt := std_logic_vector(r.SecCnt(RdIdx_v));
                v.RdDedCnt := std_logic_vector(r.DedCnt(RdIdx_v));
                -- Atomic read-and-clear of the addressed channel
                if Rd_Clr = '1' then
                    v.SecCnt(RdIdx_v)    := (others => '0');
                    v.DedCnt(RdIdx_v)    := (others => '0');
                    v.DedSticky(RdIdx_v) := '0';
                end if;
            else
                -- Channel index beyond Channels_g-1 (possible for non-power-of-two channel counts)
                v.RdSecCnt := (others => '0');
                v.RdDedCnt := (others => '0');
            end if;
        end if;

        -- Global clear
        if Clr = '1' then

            for i in 0 to Channels_g - 1 loop
                v.SecCnt(i) := (others => '0');
                v.DedCnt(i) := (others => '0');
            end loop;

            v.DedSticky := (others => '0');
        end if;

        -- Count events last: an event arriving in the same cycle as a clear is counted after the
        -- clear, so no event is ever lost.
        v.EvtSec := '0';
        v.EvtDed := '0';

        for i in 0 to Channels_g - 1 loop
            if In_Valid(i) = '1' then
                if In_EccSec(i) = '1' then
                    if v.SecCnt(i) /= CounterMax_c then
                        v.SecCnt(i) := v.SecCnt(i) + 1;
                    end if;
                    v.EvtSec := '1';
                end if;
                if In_EccDed(i) = '1' then
                    if v.DedCnt(i) /= CounterMax_c then
                        v.DedCnt(i) := v.DedCnt(i) + 1;
                    end if;
                    v.DedSticky(i) := '1';
                    v.EvtDed       := '1';
                end if;
            end if;
        end loop;

        r_next <= v;
    end process;

    -- Outputs
    DedSticky <= r.DedSticky;
    Evt_Sec   <= r.EvtSec;
    Evt_Ded   <= r.EvtDed;
    Rd_SecCnt <= r.RdSecCnt;
    Rd_DedCnt <= r.RdDedCnt;
    Rd_Valid  <= r.RdValid;

    -- *** Sequential Process ***
    p_seq : process (Clk) is
    begin
        if rising_edge(Clk) then
            r <= r_next;
            if Rst = '1' then
                r.SecCnt    <= (others => (others => '0'));
                r.DedCnt    <= (others => (others => '0'));
                r.DedSticky <= (others => '0');
                r.EvtSec    <= '0';
                r.EvtDed    <= '0';
                r.RdValid   <= '0';
            end if;
        end if;
    end process;

end architecture;
