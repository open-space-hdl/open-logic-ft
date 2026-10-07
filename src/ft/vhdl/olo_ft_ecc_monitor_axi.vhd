---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- EDAC monitor with an AXI4-Lite register interface and interrupt output: olo_ft_ecc_monitor
-- behind an olo_axi_lite_slave, exposing the counters and event interrupts through a compact
-- register map (32-bit data width).
--
-- Documentation:
-- https://github.com/open-logic/open-logic/blob/main/doc/ft/olo_ft_ecc_monitor_axi.md
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
entity olo_ft_ecc_monitor_axi is
    generic (
        Channels_g        : positive range 1 to 255;
        CounterWidth_g    : positive range 1 to 16 := 16;
        AxiAddrWidth_g    : positive range 6 to 30 := 12;
        ReadTimeoutClks_g : positive               := 100
    );
    port (
        -- Control Ports
        Clk               : in    std_logic;
        Rst               : in    std_logic;
        -- AXI-Lite Interface
        -- AR channel
        S_AxiLite_ArAddr  : in    std_logic_vector(AxiAddrWidth_g - 1 downto 0);
        S_AxiLite_ArValid : in    std_logic;
        S_AxiLite_ArReady : out   std_logic;
        -- AW channel
        S_AxiLite_AwAddr  : in    std_logic_vector(AxiAddrWidth_g - 1 downto 0);
        S_AxiLite_AwValid : in    std_logic;
        S_AxiLite_AwReady : out   std_logic;
        -- W channel
        S_AxiLite_WData   : in    std_logic_vector(31 downto 0);
        S_AxiLite_WStrb   : in    std_logic_vector(3 downto 0);
        S_AxiLite_WValid  : in    std_logic;
        S_AxiLite_WReady  : out   std_logic;
        -- B channel
        S_AxiLite_BResp   : out   std_logic_vector(1 downto 0);
        S_AxiLite_BValid  : out   std_logic;
        S_AxiLite_BReady  : in    std_logic;
        -- R channel
        S_AxiLite_RData   : out   std_logic_vector(31 downto 0);
        S_AxiLite_RResp   : out   std_logic_vector(1 downto 0);
        S_AxiLite_RValid  : out   std_logic;
        S_AxiLite_RReady  : in    std_logic;
        -- Event Inputs
        In_EccSec         : in    std_logic_vector(Channels_g - 1 downto 0);
        In_EccDed         : in    std_logic_vector(Channels_g - 1 downto 0);
        In_Valid          : in    std_logic_vector(Channels_g - 1 downto 0) := (others => '1');
        -- Interrupt
        Irq               : out   std_logic
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of olo_ft_ecc_monitor_axi is

    constant EntityName_c : string := "olo_ft_ecc_monitor_axi";

    -- Register map (word addresses)
    constant InfoWord_c      : natural  := 0;
    constant CtrlWord_c      : natural  := 1;
    constant IrqStatusWord_c : natural  := 2;
    constant IrqEnaWord_c    : natural  := 3;
    constant CntBaseByte_c   : positive := 16;
    constant CntBaseWord_c   : positive := CntBaseByte_c / 4;

    -- INFO register content: [7:0] Channels_g, [12:8] CounterWidth_g
    constant Info_c : std_logic_vector(31 downto 0) :=
        toUslv(0, 19) & toUslv(CounterWidth_g, 5) & toUslv(Channels_g, 8);

    constant ChannelBits_c : positive := max(log2ceil(Channels_g), 1);

    type TwoProcess_r is record
        IrqStatus    : std_logic_vector(1 downto 0);
        IrqEna       : std_logic_vector(1 downto 0);
        Irq          : std_logic;
        MonClr       : std_logic;
        MonRdEna     : std_logic;
        MonRdClr     : std_logic;
        MonRdChannel : std_logic_vector(ChannelBits_c - 1 downto 0);
        CntRdPend    : std_logic;
        RbRdData     : std_logic_vector(31 downto 0);
        RbRdValid    : std_logic;
    end record;

    signal r, r_next : TwoProcess_r;

    -- Register bus (from the AXI-Lite slave)
    signal Rb_Addr    : std_logic_vector(AxiAddrWidth_g - 1 downto 0);
    signal Rb_Wr      : std_logic;
    signal Rb_ByteEna : std_logic_vector(3 downto 0);
    signal Rb_WrData  : std_logic_vector(31 downto 0);
    signal Rb_Rd      : std_logic;

    -- Monitor core taps
    signal Mon_EvtSec   : std_logic;
    signal Mon_EvtDed   : std_logic;
    signal Mon_RdSecCnt : std_logic_vector(CounterWidth_g - 1 downto 0);
    signal Mon_RdDedCnt : std_logic_vector(CounterWidth_g - 1 downto 0);
    signal Mon_RdValid  : std_logic;

begin

    assert 2**AxiAddrWidth_g >= CntBaseByte_c + 4 * Channels_g
        report errorMessage(EntityName_c, "AxiAddrWidth_g does not cover the register map " &
               "(increase AxiAddrWidth_g or reduce Channels_g).")
        severity error;

    -- *** Combinatorial Process ***
    p_comb : process (all) is
        variable v          : TwoProcess_r;
        variable WordAddr_v : natural;
    begin
        v := r;

        -- Pulse defaults
        v.MonClr    := '0';
        v.MonRdEna  := '0';
        v.MonRdClr  := '0';
        v.RbRdValid := '0';

        WordAddr_v := fromUslv(Rb_Addr(AxiAddrWidth_g - 1 downto 2));

        -- Write decode
        if Rb_Wr = '1' then
            if WordAddr_v = CtrlWord_c then
                -- CTRL.CLR_ALL: global clear strobe
                if Rb_WrData(0) = '1' then
                    v.MonClr := '1';
                end if;
            elsif WordAddr_v = IrqStatusWord_c then
                -- Write-one-to-clear
                v.IrqStatus := r.IrqStatus and (not Rb_WrData(1 downto 0));
            elsif WordAddr_v = IrqEnaWord_c then
                v.IrqEna := Rb_WrData(1 downto 0);
            elsif (WordAddr_v >= CntBaseWord_c) and (WordAddr_v < CntBaseWord_c + Channels_g) then
                -- Any write to a counter word clears the addressed channel. Implemented as a
                -- read-and-clear on the core's read port; the read data is discarded
                -- (CntRdPend stays '0').
                v.MonRdEna     := '1';
                v.MonRdClr     := '1';
                v.MonRdChannel := toUslv(WordAddr_v - CntBaseWord_c, ChannelBits_c);
            end if;
        -- Writes to read-only or unmapped words are ignored (the AXI response is OKAY)
        end if;

        -- Read decode. Unmapped addresses are intentionally not acknowledged: the AXI-Lite slave
        -- signals an error to the master via its read timeout.
        if Rb_Rd = '1' then
            if WordAddr_v = InfoWord_c then
                v.RbRdData  := Info_c;
                v.RbRdValid := '1';
            elsif WordAddr_v = CtrlWord_c then
                v.RbRdData  := (others => '0');
                v.RbRdValid := '1';
            elsif WordAddr_v = IrqStatusWord_c then
                v.RbRdData             := (others => '0');
                v.RbRdData(1 downto 0) := r.IrqStatus;
                v.RbRdValid            := '1';
            elsif WordAddr_v = IrqEnaWord_c then
                v.RbRdData             := (others => '0');
                v.RbRdData(1 downto 0) := r.IrqEna;
                v.RbRdValid            := '1';
            elsif (WordAddr_v >= CntBaseWord_c) and (WordAddr_v < CntBaseWord_c + Channels_g) then
                -- Counter read through the core's read port (response arrives via CntRdPend)
                v.MonRdEna     := '1';
                v.MonRdChannel := toUslv(WordAddr_v - CntBaseWord_c, ChannelBits_c);
                v.CntRdPend    := '1';
            end if;
        end if;

        -- Counter read response: [15:0] SEC counter, [31:16] DED counter (zero-extended)
        if (r.CntRdPend = '1') and (Mon_RdValid = '1') then
            v.RbRdData                                    := (others => '0');
            v.RbRdData(CounterWidth_g - 1 downto 0)       := Mon_RdSecCnt;
            v.RbRdData(16 + CounterWidth_g - 1 downto 16) := Mon_RdDedCnt;
            v.RbRdValid                                   := '1';
            v.CntRdPend                                   := '0';
        end if;

        -- IRQ latching: a set in the same cycle as a W1C wins (no lost events)
        if Mon_EvtSec = '1' then
            v.IrqStatus(0) := '1';
        end if;
        if Mon_EvtDed = '1' then
            v.IrqStatus(1) := '1';
        end if;

        -- Registered interrupt output
        if unsigned(v.IrqStatus and v.IrqEna) /= 0 then
            v.Irq := '1';
        else
            v.Irq := '0';
        end if;

        r_next <= v;
    end process;

    -- Outputs
    Irq <= r.Irq;

    -- *** Sequential Process ***
    p_seq : process (Clk) is
    begin
        if rising_edge(Clk) then
            r <= r_next;
            if Rst = '1' then
                r.IrqStatus <= (others => '0');
                r.IrqEna    <= (others => '0');
                r.Irq       <= '0';
                r.MonClr    <= '0';
                r.MonRdEna  <= '0';
                r.MonRdClr  <= '0';
                r.CntRdPend <= '0';
                r.RbRdValid <= '0';
            end if;
        end if;
    end process;

    -- *** AXI-Lite Slave ***
    i_slave : entity work.olo_axi_lite_slave
        generic map (
            AxiAddrWidth_g    => AxiAddrWidth_g,
            AxiDataWidth_g    => 32,
            ReadTimeoutClks_g => ReadTimeoutClks_g
        )
        port map (
            Clk               => Clk,
            Rst               => Rst,
            S_AxiLite_ArAddr  => S_AxiLite_ArAddr,
            S_AxiLite_ArValid => S_AxiLite_ArValid,
            S_AxiLite_ArReady => S_AxiLite_ArReady,
            S_AxiLite_AwAddr  => S_AxiLite_AwAddr,
            S_AxiLite_AwValid => S_AxiLite_AwValid,
            S_AxiLite_AwReady => S_AxiLite_AwReady,
            S_AxiLite_WData   => S_AxiLite_WData,
            S_AxiLite_WStrb   => S_AxiLite_WStrb,
            S_AxiLite_WValid  => S_AxiLite_WValid,
            S_AxiLite_WReady  => S_AxiLite_WReady,
            S_AxiLite_BResp   => S_AxiLite_BResp,
            S_AxiLite_BValid  => S_AxiLite_BValid,
            S_AxiLite_BReady  => S_AxiLite_BReady,
            S_AxiLite_RData   => S_AxiLite_RData,
            S_AxiLite_RResp   => S_AxiLite_RResp,
            S_AxiLite_RValid  => S_AxiLite_RValid,
            S_AxiLite_RReady  => S_AxiLite_RReady,
            Rb_Addr           => Rb_Addr,
            Rb_Wr             => Rb_Wr,
            Rb_ByteEna        => Rb_ByteEna,
            Rb_WrData         => Rb_WrData,
            Rb_Rd             => Rb_Rd,
            Rb_RdData         => r.RbRdData,
            Rb_RdValid        => r.RbRdValid
        );

    -- *** Monitor Core ***
    i_monitor : entity work.olo_ft_ecc_monitor
        generic map (
            Channels_g     => Channels_g,
            CounterWidth_g => CounterWidth_g
        )
        port map (
            Clk        => Clk,
            Rst        => Rst,
            Clr        => r.MonClr,
            In_EccSec  => In_EccSec,
            In_EccDed  => In_EccDed,
            In_Valid   => In_Valid,
            DedSticky  => open,
            Evt_Sec    => Mon_EvtSec,
            Evt_Ded    => Mon_EvtDed,
            Rd_Channel => r.MonRdChannel,
            Rd_Ena     => r.MonRdEna,
            Rd_Clr     => r.MonRdClr,
            Rd_SecCnt  => Mon_RdSecCnt,
            Rd_DedCnt  => Mon_RdDedCnt,
            Rd_Valid   => Mon_RdValid
        );

end architecture;
