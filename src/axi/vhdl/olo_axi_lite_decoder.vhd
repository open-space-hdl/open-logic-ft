---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- This entity connects one AXI4-Lite master to Ports_g AXI4-Lite slaves. Every slave port owns
-- an address window of 2**PortAddrWidth_g bytes, selected by the address bits above the window.
-- Accesses to an address without slave port are answered with DECERR.
--
-- Documentation:
-- https://github.com/open-logic/open-logic/blob/main/doc/axi/olo_axi_lite_decoder.md
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
    use work.olo_axi_pkg_protocol.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity olo_axi_lite_decoder is
    generic (
        AxiAddrWidth_g  : positive := 32;
        AxiDataWidth_g  : positive := 32;
        Ports_g         : positive := 4;
        PortAddrWidth_g : positive := 16
    );
    port (
        -- Control Signals
        Clk               : in    std_logic;
        Rst               : in    std_logic;
        -- AXI-Lite Slave Interface
        -- AR channel
        S_AxiLite_ArAddr  : in    std_logic_vector(AxiAddrWidth_g - 1 downto 0);
        S_AxiLite_ArValid : in    std_logic;
        S_AxiLite_ArReady : out   std_logic;
        -- AW channel
        S_AxiLite_AwAddr  : in    std_logic_vector(AxiAddrWidth_g - 1 downto 0);
        S_AxiLite_AwValid : in    std_logic;
        S_AxiLite_AwReady : out   std_logic;
        -- W channel
        S_AxiLite_WData   : in    std_logic_vector(AxiDataWidth_g - 1 downto 0);
        S_AxiLite_WStrb   : in    std_logic_vector(AxiDataWidth_g / 8 - 1 downto 0);
        S_AxiLite_WValid  : in    std_logic;
        S_AxiLite_WReady  : out   std_logic;
        -- B channel
        S_AxiLite_BResp   : out   std_logic_vector(1 downto 0);
        S_AxiLite_BValid  : out   std_logic;
        S_AxiLite_BReady  : in    std_logic;
        -- R channel
        S_AxiLite_RData   : out   std_logic_vector(AxiDataWidth_g - 1 downto 0);
        S_AxiLite_RResp   : out   std_logic_vector(1 downto 0);
        S_AxiLite_RValid  : out   std_logic;
        S_AxiLite_RReady  : in    std_logic;
        -- AXI-Lite Master Interfaces (port p in the slice of index p)
        -- AR channel
        M_AxiLite_ArAddr  : out   std_logic_vector(Ports_g * PortAddrWidth_g - 1 downto 0);
        M_AxiLite_ArValid : out   std_logic_vector(Ports_g - 1 downto 0);
        M_AxiLite_ArReady : in    std_logic_vector(Ports_g - 1 downto 0);
        -- AW channel
        M_AxiLite_AwAddr  : out   std_logic_vector(Ports_g * PortAddrWidth_g - 1 downto 0);
        M_AxiLite_AwValid : out   std_logic_vector(Ports_g - 1 downto 0);
        M_AxiLite_AwReady : in    std_logic_vector(Ports_g - 1 downto 0);
        -- W channel
        M_AxiLite_WData   : out   std_logic_vector(Ports_g * AxiDataWidth_g - 1 downto 0);
        M_AxiLite_WStrb   : out   std_logic_vector(Ports_g * AxiDataWidth_g / 8 - 1 downto 0);
        M_AxiLite_WValid  : out   std_logic_vector(Ports_g - 1 downto 0);
        M_AxiLite_WReady  : in    std_logic_vector(Ports_g - 1 downto 0);
        -- B channel
        M_AxiLite_BResp   : in    std_logic_vector(Ports_g * 2 - 1 downto 0);
        M_AxiLite_BValid  : in    std_logic_vector(Ports_g - 1 downto 0);
        M_AxiLite_BReady  : out   std_logic_vector(Ports_g - 1 downto 0);
        -- R channel
        M_AxiLite_RData   : in    std_logic_vector(Ports_g * AxiDataWidth_g - 1 downto 0);
        M_AxiLite_RResp   : in    std_logic_vector(Ports_g * 2 - 1 downto 0);
        M_AxiLite_RValid  : in    std_logic_vector(Ports_g - 1 downto 0);
        M_AxiLite_RReady  : out   std_logic_vector(Ports_g - 1 downto 0)
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of olo_axi_lite_decoder is

    -- *** Constants ***
    constant EntityName_c : string  := "olo_axi_lite_decoder";
    constant IdxBits_c    : natural := log2ceil(Ports_g);
    constant StrbWidth_c  : natural := AxiDataWidth_g / 8;

    -- *** Types ***
    type WrFsm_t is (WrCollect_s, WrMaster_s, WrResp_s, WrSlaveResp_s);
    type RdFsm_t is (RdAddr_s, RdMaster_s, RdData_s, RdSlaveResp_s);

    -- *** Two Process Method ***
    type TwoProcess_r is record
        -- Write
        WrFsm    : WrFsm_t;
        AwReady  : std_logic;
        WReady   : std_logic;
        WrAddr   : std_logic_vector(PortAddrWidth_g - 1 downto 0);
        WrData   : std_logic_vector(AxiDataWidth_g - 1 downto 0);
        WrStrb   : std_logic_vector(StrbWidth_c - 1 downto 0);
        WrPort   : natural range 0 to Ports_g - 1;
        WrMapped : std_logic;
        MAwValid : std_logic_vector(Ports_g - 1 downto 0);
        MWValid  : std_logic_vector(Ports_g - 1 downto 0);
        MBReady  : std_logic_vector(Ports_g - 1 downto 0);
        SBValid  : std_logic;
        SBResp   : std_logic_vector(1 downto 0);
        -- Read
        RdFsm    : RdFsm_t;
        ArReady  : std_logic;
        RdAddr   : std_logic_vector(PortAddrWidth_g - 1 downto 0);
        RdPort   : natural range 0 to Ports_g - 1;
        MArValid : std_logic_vector(Ports_g - 1 downto 0);
        MRReady  : std_logic_vector(Ports_g - 1 downto 0);
        SRValid  : std_logic;
        SRData   : std_logic_vector(AxiDataWidth_g - 1 downto 0);
        SRResp   : std_logic_vector(1 downto 0);
    end record;

    signal r, r_next : TwoProcess_r;

    -- *** Functions ***
    -- Index of the slave port addressed (may be beyond Ports_g - 1 if Ports_g is not a power of two)
    function portIndex (Addr : std_logic_vector) return natural is
    begin
        if IdxBits_c = 0 then
            return 0;
        end if;
        return to_integer(unsigned(Addr(PortAddrWidth_g + IdxBits_c - 1 downto PortAddrWidth_g)));
    end function;

begin

    -----------------------------------------------------------------------------------------------
    -- Assertions
    -----------------------------------------------------------------------------------------------
    assert AxiDataWidth_g mod 8 = 0
        report errorMessage(EntityName_c, "AxiDataWidth_g must be a multiple of 8")
        severity failure;
    assert AxiAddrWidth_g >= PortAddrWidth_g + IdxBits_c
        report errorMessage(EntityName_c, "AxiAddrWidth_g must be at least PortAddrWidth_g + log2ceil(Ports_g)")
        severity failure;

    -----------------------------------------------------------------------------------------------
    -- Combinatorial Process
    -----------------------------------------------------------------------------------------------
    p_comb : process (all) is
        variable v         : TwoProcess_r;
        variable Idx_v     : natural;
        variable AwReady_v : std_logic;
        variable WReady_v  : std_logic;
        variable BValid_v  : std_logic;
        variable BResp_v   : std_logic_vector(1 downto 0);
        variable ArReady_v : std_logic;
        variable RValid_v  : std_logic;
        variable RData_v   : std_logic_vector(AxiDataWidth_g - 1 downto 0);
        variable RResp_v   : std_logic_vector(1 downto 0);
    begin
        -- *** hold variables stable ***
        v := r;

        -- *** Select the inputs of the active slave ports ***
        AwReady_v := '0';
        WReady_v  := '0';
        BValid_v  := '0';
        BResp_v   := (others => '0');
        ArReady_v := '0';
        RValid_v  := '0';
        RData_v   := (others => '0');
        RResp_v   := (others => '0');

        for p in 0 to Ports_g - 1 loop
            if p = r.WrPort then
                AwReady_v := M_AxiLite_AwReady(p);
                WReady_v  := M_AxiLite_WReady(p);
                BValid_v  := M_AxiLite_BValid(p);
                BResp_v   := M_AxiLite_BResp(2 * p + 1 downto 2 * p);
            end if;
            if p = r.RdPort then
                ArReady_v := M_AxiLite_ArReady(p);
                RValid_v  := M_AxiLite_RValid(p);
                RData_v   := M_AxiLite_RData((p + 1) * AxiDataWidth_g - 1 downto p * AxiDataWidth_g);
                RResp_v   := M_AxiLite_RResp(2 * p + 1 downto 2 * p);
            end if;
        end loop;

        -- *** Write Transactions ***
        case r.WrFsm is

            when WrCollect_s =>
                -- Accept address and data in any order
                if r.AwReady = '1' and S_AxiLite_AwValid = '1' then
                    v.AwReady := '0';
                    v.WrAddr  := S_AxiLite_AwAddr(PortAddrWidth_g - 1 downto 0);
                    Idx_v     := portIndex(S_AxiLite_AwAddr);
                    if Idx_v < Ports_g then
                        v.WrPort   := Idx_v;
                        v.WrMapped := '1';
                    else
                        v.WrPort   := 0;
                        v.WrMapped := '0';
                    end if;
                end if;
                if r.WReady = '1' and S_AxiLite_WValid = '1' then
                    v.WReady := '0';
                    v.WrData := S_AxiLite_WData;
                    v.WrStrb := S_AxiLite_WStrb;
                end if;
                -- Forward the transaction once both are available
                if v.AwReady = '0' and v.WReady = '0' then
                    if v.WrMapped = '1' then
                        v.MAwValid(v.WrPort) := '1';
                        v.MWValid(v.WrPort)  := '1';
                        v.WrFsm              := WrMaster_s;
                    else
                        v.SBValid := '1';
                        v.SBResp  := AxiResp_DecErr_c;
                        v.WrFsm   := WrSlaveResp_s;
                    end if;
                end if;

            when WrMaster_s =>
                -- Address and data handshakes of the slave port
                if AwReady_v = '1' then
                    v.MAwValid(r.WrPort) := '0';
                end if;
                if WReady_v = '1' then
                    v.MWValid(r.WrPort) := '0';
                end if;
                if v.MAwValid(r.WrPort) = '0' and v.MWValid(r.WrPort) = '0' then
                    v.MBReady(r.WrPort) := '1';
                    v.WrFsm             := WrResp_s;
                end if;

            when WrResp_s =>
                -- Response of the slave port
                if BValid_v = '1' then
                    v.MBReady(r.WrPort) := '0';
                    v.SBValid           := '1';
                    v.SBResp            := BResp_v;
                    v.WrFsm             := WrSlaveResp_s;
                end if;

            when WrSlaveResp_s =>
                -- Response to the master
                if S_AxiLite_BReady = '1' then
                    v.SBValid := '0';
                    v.AwReady := '1';
                    v.WReady  := '1';
                    v.WrFsm   := WrCollect_s;
                end if;

            -- coverage off
            when others => v.WrFsm := WrCollect_s; -- unreachable code
            -- coverage on

        end case;

        -- *** Read Transactions ***
        case r.RdFsm is

            when RdAddr_s =>
                -- Accept the address
                if r.ArReady = '1' and S_AxiLite_ArValid = '1' then
                    v.ArReady := '0';
                    v.RdAddr  := S_AxiLite_ArAddr(PortAddrWidth_g - 1 downto 0);
                    Idx_v     := portIndex(S_AxiLite_ArAddr);
                    if Idx_v < Ports_g then
                        v.RdPort          := Idx_v;
                        v.MArValid(Idx_v) := '1';
                        v.RdFsm           := RdMaster_s;
                    else
                        v.RdPort  := 0;
                        v.SRValid := '1';
                        v.SRData  := (others => '0');
                        v.SRResp  := AxiResp_DecErr_c;
                        v.RdFsm   := RdSlaveResp_s;
                    end if;
                end if;

            when RdMaster_s =>
                -- Address handshake of the slave port
                if ArReady_v = '1' then
                    v.MArValid(r.RdPort) := '0';
                    v.MRReady(r.RdPort)  := '1';
                    v.RdFsm              := RdData_s;
                end if;

            when RdData_s =>
                -- Read data of the slave port
                if RValid_v = '1' then
                    v.MRReady(r.RdPort) := '0';
                    v.SRValid           := '1';
                    v.SRData            := RData_v;
                    v.SRResp            := RResp_v;
                    v.RdFsm             := RdSlaveResp_s;
                end if;

            when RdSlaveResp_s =>
                -- Read data to the master
                if S_AxiLite_RReady = '1' then
                    v.SRValid := '0';
                    v.ArReady := '1';
                    v.RdFsm   := RdAddr_s;
                end if;

            -- coverage off
            when others => v.RdFsm := RdAddr_s; -- unreachable code
            -- coverage on

        end case;

        -- *** Assign to signal ***
        r_next <= v;
    end process;

    -----------------------------------------------------------------------------------------------
    -- Outputs
    -----------------------------------------------------------------------------------------------
    S_AxiLite_ArReady <= r.ArReady;
    S_AxiLite_AwReady <= r.AwReady;
    S_AxiLite_WReady  <= r.WReady;
    S_AxiLite_BResp   <= r.SBResp;
    S_AxiLite_BValid  <= r.SBValid;
    S_AxiLite_RData   <= r.SRData;
    S_AxiLite_RResp   <= r.SRResp;
    S_AxiLite_RValid  <= r.SRValid;

    M_AxiLite_ArValid <= r.MArValid;
    M_AxiLite_AwValid <= r.MAwValid;
    M_AxiLite_WValid  <= r.MWValid;
    M_AxiLite_BReady  <= r.MBReady;
    M_AxiLite_RReady  <= r.MRReady;

    g_ports : for p in 0 to Ports_g - 1 generate
        M_AxiLite_ArAddr((p + 1) * PortAddrWidth_g - 1 downto p * PortAddrWidth_g) <= r.RdAddr;
        M_AxiLite_AwAddr((p + 1) * PortAddrWidth_g - 1 downto p * PortAddrWidth_g) <= r.WrAddr;
        M_AxiLite_WData((p + 1) * AxiDataWidth_g - 1 downto p * AxiDataWidth_g)    <= r.WrData;
        M_AxiLite_WStrb((p + 1) * StrbWidth_c - 1 downto p * StrbWidth_c)          <= r.WrStrb;
    end generate;

    -----------------------------------------------------------------------------------------------
    -- Sequential Process
    -----------------------------------------------------------------------------------------------
    p_seq : process (Clk) is
    begin
        if rising_edge(Clk) then
            r <= r_next;
            if Rst = '1' then
                r.WrFsm    <= WrCollect_s;
                r.AwReady  <= '1';
                r.WReady   <= '1';
                r.WrPort   <= 0;
                r.MAwValid <= (others => '0');
                r.MWValid  <= (others => '0');
                r.MBReady  <= (others => '0');
                r.SBValid  <= '0';
                r.RdFsm    <= RdAddr_s;
                r.ArReady  <= '1';
                r.RdPort   <= 0;
                r.MArValid <= (others => '0');
                r.MRReady  <= (others => '0');
                r.SRValid  <= '0';
            end if;
        end if;
    end process;

end architecture;
