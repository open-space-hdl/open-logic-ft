---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- ECC-protected AXI4 master with simple interface. Composes olo_axi_master_simple with external
-- SECDED-protected data buffers: the bulk write/read data buffering happens in olo_ft_fifo_sync
-- instances (byte enables and the last flag are part of the codeword), while the wrapped master
-- runs with small, register-based internal FIFOs coverable by vendor TMR.
--
-- Documentation:
-- https://github.com/open-logic/open-logic/blob/main/doc/ft/olo_ft_axi_master_simple.md
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
    use work.olo_ft_pkg_ecc.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity olo_ft_axi_master_simple is
    generic (
        AxiAddrWidth_g            : positive range 12 to 64  := 32;
        AxiDataWidth_g            : positive range 8 to 1024 := 32;
        AxiMaxBeats_g             : positive range 1 to 256  := 256;
        AxiMaxOpenTransactions_g  : positive range 1 to 8    := 8;
        UserTransactionSizeBits_g : positive                 := 24;
        DataFifoDepth_g           : positive                 := 1024;
        ImplRead_g                : boolean                  := true;
        ImplWrite_g               : boolean                  := true;
        RamBehavior_g             : string                   := "RBW";
        RamStyle_g                : string                   := "auto";
        IntFifoRamStyle_g         : string                   := "registers"
    );
    port (
        -- Control Signals
        Clk               : in    std_logic;
        Rst               : in    std_logic;
        -- User Command Interface Write
        CmdWr_Addr        : in    std_logic_vector(AxiAddrWidth_g - 1 downto 0)                                        := (others => '0');
        CmdWr_Size        : in    std_logic_vector(UserTransactionSizeBits_g - 1 downto 0)                             := (others => '0');
        CmdWr_LowLat      : in    std_logic                                                                            := '0';
        CmdWr_Valid       : in    std_logic                                                                            := '0';
        CmdWr_Ready       : out   std_logic;
        -- User Command Interface Read
        CmdRd_Addr        : in    std_logic_vector(AxiAddrWidth_g - 1 downto 0)                                        := (others => '0');
        CmdRd_Size        : in    std_logic_vector(UserTransactionSizeBits_g - 1 downto 0)                             := (others => '0');
        CmdRd_LowLat      : in    std_logic                                                                            := '0';
        CmdRd_Valid       : in    std_logic                                                                            := '0';
        CmdRd_Ready       : out   std_logic;
        -- Write Data
        Wr_Data           : in    std_logic_vector(AxiDataWidth_g - 1 downto 0)                                        := (others => '0');
        Wr_Be             : in    std_logic_vector(AxiDataWidth_g / 8 - 1 downto 0)                                    := (others => '0');
        Wr_Valid          : in    std_logic                                                                            := '0';
        Wr_Ready          : out   std_logic;
        Wr_EccSec         : out   std_logic;
        Wr_EccDed         : out   std_logic;
        -- Read Data
        Rd_Data           : out   std_logic_vector(AxiDataWidth_g - 1 downto 0);
        Rd_Last           : out   std_logic;
        Rd_Valid          : out   std_logic;
        Rd_Ready          : in    std_logic                                                                            := '1';
        Rd_EccSec         : out   std_logic;
        Rd_EccDed         : out   std_logic;
        -- Response
        Wr_Done           : out   std_logic;
        Wr_Error          : out   std_logic;
        Rd_Done           : out   std_logic;
        Rd_Error          : out   std_logic;
        -- Error injection (latched, applied to the next accepted beat of the respective buffer)
        Wr_ErrInj_BitFlip : in    std_logic_vector(eccCodewordWidth(AxiDataWidth_g + AxiDataWidth_g / 8) - 1 downto 0) := (others => '0');
        Wr_ErrInj_Valid   : in    std_logic                                                                            := '0';
        Rd_ErrInj_BitFlip : in    std_logic_vector(eccCodewordWidth(AxiDataWidth_g + 1) - 1 downto 0)                  := (others => '0');
        Rd_ErrInj_Valid   : in    std_logic                                                                            := '0';
        -- AXI Address Write Channel
        M_Axi_AwAddr      : out   std_logic_vector(AxiAddrWidth_g - 1 downto 0);
        M_Axi_AwLen       : out   std_logic_vector(7 downto 0);
        M_Axi_AwSize      : out   std_logic_vector(2 downto 0);
        M_Axi_AwBurst     : out   std_logic_vector(1 downto 0);
        M_Axi_AwLock      : out   std_logic;
        M_Axi_AwCache     : out   std_logic_vector(3 downto 0);
        M_Axi_AwProt      : out   std_logic_vector(2 downto 0);
        M_Axi_AwValid     : out   std_logic;
        M_Axi_AwReady     : in    std_logic                                                                            := '0';
        -- AXI Write Data Channel
        M_Axi_WData       : out   std_logic_vector(AxiDataWidth_g - 1 downto 0);
        M_Axi_WStrb       : out   std_logic_vector(AxiDataWidth_g / 8 - 1 downto 0);
        M_Axi_WLast       : out   std_logic;
        M_Axi_WValid      : out   std_logic;
        M_Axi_WReady      : in    std_logic                                                                            := '0';
        -- AXI Write Response Channel
        M_Axi_BResp       : in    std_logic_vector(1 downto 0)                                                         := (others => '0');
        M_Axi_BValid      : in    std_logic                                                                            := '0';
        M_Axi_BReady      : out   std_logic;
        -- AXI Read Address Channel
        M_Axi_ArAddr      : out   std_logic_vector(AxiAddrWidth_g - 1 downto 0);
        M_Axi_ArLen       : out   std_logic_vector(7 downto 0);
        M_Axi_ArSize      : out   std_logic_vector(2 downto 0);
        M_Axi_ArBurst     : out   std_logic_vector(1 downto 0);
        M_Axi_ArLock      : out   std_logic;
        M_Axi_ArCache     : out   std_logic_vector(3 downto 0);
        M_Axi_ArProt      : out   std_logic_vector(2 downto 0);
        M_Axi_ArValid     : out   std_logic;
        M_Axi_ArReady     : in    std_logic                                                                            := '0';
        -- AXI Read Data Channel
        M_Axi_RData       : in    std_logic_vector(AxiDataWidth_g - 1 downto 0)                                        := (others => '0');
        M_Axi_RResp       : in    std_logic_vector(1 downto 0)                                                         := (others => '0');
        M_Axi_RLast       : in    std_logic                                                                            := '0';
        M_Axi_RValid      : in    std_logic                                                                            := '0';
        M_Axi_RReady      : out   std_logic
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of olo_ft_axi_master_simple is

    -- Buffer word layouts: {Be, Data} on the write side, {Last, Data} on the read side, so the
    -- sidebands are part of the ECC codeword.
    constant WrBufWidth_c : positive := AxiDataWidth_g + AxiDataWidth_g / 8;
    constant RdBufWidth_c : positive := AxiDataWidth_g + 1;

    -- The internal FIFOs of the wrapped master only cover the burst-issuance window. Two maximum
    -- bursts allow back-to-back operation (recommendation from the olo_axi_master_simple doc).
    constant IntFifoDepth_c : positive := 2 * AxiMaxBeats_g;

    -- Write buffer -> wrapped master
    signal WrBuf_InData   : std_logic_vector(WrBufWidth_c - 1 downto 0);
    signal WrBuf_OutData  : std_logic_vector(WrBufWidth_c - 1 downto 0);
    signal WrBuf_OutValid : std_logic                                         := '0';
    signal WrBuf_OutReady : std_logic;
    signal WrBuf_OutSec   : std_logic;
    signal WrBuf_OutDed   : std_logic;
    signal MWr_Data       : std_logic_vector(AxiDataWidth_g - 1 downto 0)     := (others => '0');
    signal MWr_Be         : std_logic_vector(AxiDataWidth_g / 8 - 1 downto 0) := (others => '0');

    -- Wrapped master -> read buffer
    signal RdBuf_InData  : std_logic_vector(RdBufWidth_c - 1 downto 0);
    signal RdBuf_OutData : std_logic_vector(RdBufWidth_c - 1 downto 0);
    signal MRd_Data      : std_logic_vector(AxiDataWidth_g - 1 downto 0);
    signal MRd_Last      : std_logic;
    signal MRd_Valid     : std_logic;
    signal MRd_Ready     : std_logic := '0';

begin

    -----------------------------------------------------------------------------------------------
    -- Write Data Buffer (ECC-protected)
    -----------------------------------------------------------------------------------------------
    g_write : if ImplWrite_g generate

        WrBuf_InData <= Wr_Be & Wr_Data;

        i_wr_buf : entity work.olo_ft_fifo_sync
            generic map (
                Width_g       => WrBufWidth_c,
                Depth_g       => DataFifoDepth_g,
                RamStyle_g    => RamStyle_g,
                RamBehavior_g => RamBehavior_g
            )
            port map (
                Clk               => Clk,
                Rst               => Rst,
                In_Data           => WrBuf_InData,
                In_Valid          => Wr_Valid,
                In_Ready          => Wr_Ready,
                Out_Data          => WrBuf_OutData,
                Out_Valid         => WrBuf_OutValid,
                Out_Ready         => WrBuf_OutReady,
                Out_EccSec        => WrBuf_OutSec,
                Out_EccDed        => WrBuf_OutDed,
                In_ErrInj_BitFlip => Wr_ErrInj_BitFlip,
                In_ErrInj_Valid   => Wr_ErrInj_Valid
            );

        MWr_Data <= WrBuf_OutData(AxiDataWidth_g - 1 downto 0);
        MWr_Be   <= WrBuf_OutData(WrBufWidth_c - 1 downto AxiDataWidth_g);

        -- One-cycle pulses (one per beat handed to the wrapped master), directly countable
        Wr_EccSec <= WrBuf_OutSec and WrBuf_OutValid and WrBuf_OutReady;
        Wr_EccDed <= WrBuf_OutDed and WrBuf_OutValid and WrBuf_OutReady;
    end generate;

    g_nowrite : if not ImplWrite_g generate
        Wr_Ready  <= '0';
        Wr_EccSec <= '0';
        Wr_EccDed <= '0';
    end generate;

    -----------------------------------------------------------------------------------------------
    -- Read Data Buffer (ECC-protected)
    -----------------------------------------------------------------------------------------------
    g_read : if ImplRead_g generate

        RdBuf_InData <= MRd_Last & MRd_Data;

        i_rd_buf : entity work.olo_ft_fifo_sync
            generic map (
                Width_g       => RdBufWidth_c,
                Depth_g       => DataFifoDepth_g,
                RamStyle_g    => RamStyle_g,
                RamBehavior_g => RamBehavior_g
            )
            port map (
                Clk               => Clk,
                Rst               => Rst,
                In_Data           => RdBuf_InData,
                In_Valid          => MRd_Valid,
                In_Ready          => MRd_Ready,
                Out_Data          => RdBuf_OutData,
                Out_Valid         => Rd_Valid,
                Out_Ready         => Rd_Ready,
                Out_EccSec        => Rd_EccSec,
                Out_EccDed        => Rd_EccDed,
                In_ErrInj_BitFlip => Rd_ErrInj_BitFlip,
                In_ErrInj_Valid   => Rd_ErrInj_Valid
            );

        Rd_Data <= RdBuf_OutData(AxiDataWidth_g - 1 downto 0);
        Rd_Last <= RdBuf_OutData(AxiDataWidth_g);
    end generate;

    g_noread : if not ImplRead_g generate
        Rd_Data   <= (others => '0');
        Rd_Last   <= '0';
        Rd_Valid  <= '0';
        Rd_EccSec <= '0';
        Rd_EccDed <= '0';
    end generate;

    -----------------------------------------------------------------------------------------------
    -- Wrapped AXI Master
    -----------------------------------------------------------------------------------------------
    i_master : entity work.olo_axi_master_simple
        generic map (
            AxiAddrWidth_g            => AxiAddrWidth_g,
            AxiDataWidth_g            => AxiDataWidth_g,
            AxiMaxBeats_g             => AxiMaxBeats_g,
            AxiMaxOpenTransactions_g  => AxiMaxOpenTransactions_g,
            UserTransactionSizeBits_g => UserTransactionSizeBits_g,
            DataFifoDepth_g           => IntFifoDepth_c,
            ImplRead_g                => ImplRead_g,
            ImplWrite_g               => ImplWrite_g,
            RamBehavior_g             => RamBehavior_g,
            RamStyle_g                => IntFifoRamStyle_g
        )
        port map (
            Clk           => Clk,
            Rst           => Rst,
            CmdWr_Addr    => CmdWr_Addr,
            CmdWr_Size    => CmdWr_Size,
            CmdWr_LowLat  => CmdWr_LowLat,
            CmdWr_Valid   => CmdWr_Valid,
            CmdWr_Ready   => CmdWr_Ready,
            CmdRd_Addr    => CmdRd_Addr,
            CmdRd_Size    => CmdRd_Size,
            CmdRd_LowLat  => CmdRd_LowLat,
            CmdRd_Valid   => CmdRd_Valid,
            CmdRd_Ready   => CmdRd_Ready,
            Wr_Data       => MWr_Data,
            Wr_Be         => MWr_Be,
            Wr_Valid      => WrBuf_OutValid,
            Wr_Ready      => WrBuf_OutReady,
            Rd_Data       => MRd_Data,
            Rd_Last       => MRd_Last,
            Rd_Valid      => MRd_Valid,
            Rd_Ready      => MRd_Ready,
            Wr_Done       => Wr_Done,
            Wr_Error      => Wr_Error,
            Rd_Done       => Rd_Done,
            Rd_Error      => Rd_Error,
            M_Axi_AwAddr  => M_Axi_AwAddr,
            M_Axi_AwLen   => M_Axi_AwLen,
            M_Axi_AwSize  => M_Axi_AwSize,
            M_Axi_AwBurst => M_Axi_AwBurst,
            M_Axi_AwLock  => M_Axi_AwLock,
            M_Axi_AwCache => M_Axi_AwCache,
            M_Axi_AwProt  => M_Axi_AwProt,
            M_Axi_AwValid => M_Axi_AwValid,
            M_Axi_AwReady => M_Axi_AwReady,
            M_Axi_WData   => M_Axi_WData,
            M_Axi_WStrb   => M_Axi_WStrb,
            M_Axi_WLast   => M_Axi_WLast,
            M_Axi_WValid  => M_Axi_WValid,
            M_Axi_WReady  => M_Axi_WReady,
            M_Axi_BResp   => M_Axi_BResp,
            M_Axi_BValid  => M_Axi_BValid,
            M_Axi_BReady  => M_Axi_BReady,
            M_Axi_ArAddr  => M_Axi_ArAddr,
            M_Axi_ArLen   => M_Axi_ArLen,
            M_Axi_ArSize  => M_Axi_ArSize,
            M_Axi_ArBurst => M_Axi_ArBurst,
            M_Axi_ArLock  => M_Axi_ArLock,
            M_Axi_ArCache => M_Axi_ArCache,
            M_Axi_ArProt  => M_Axi_ArProt,
            M_Axi_ArValid => M_Axi_ArValid,
            M_Axi_ArReady => M_Axi_ArReady,
            M_Axi_RData   => M_Axi_RData,
            M_Axi_RResp   => M_Axi_RResp,
            M_Axi_RLast   => M_Axi_RLast,
            M_Axi_RValid  => M_Axi_RValid,
            M_Axi_RReady  => M_Axi_RReady
        );

end architecture;
