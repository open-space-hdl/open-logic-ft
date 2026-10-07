---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- ECC-protected asynchronous FIFO using SECDED (Single Error Correction, Double Error
-- Detection) Hamming code, with TMR-hardened Gray-pointer and reset crossings. Data is
-- encoded on write and decoded/corrected on read; the interface matches olo_base_fifo_async.
--
-- Documentation:
-- https://github.com/open-logic/open-logic/blob/main/doc/ft/olo_ft_fifo_async.md
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
entity olo_ft_fifo_async is
    generic (
        Width_g         : positive;
        Depth_g         : positive;
        AlmFullOn_g     : boolean               := false;
        AlmFullLevel_g  : natural               := 0;
        AlmEmptyOn_g    : boolean               := false;
        AlmEmptyLevel_g : natural               := 0;
        RamStyle_g      : string                := "auto";
        RamBehavior_g   : string                := "RBW";
        ReadyRstState_g : std_logic             := '1';
        Optimization_g  : string                := "SPEED";
        SyncStages_g    : positive range 2 to 4 := 2
    );
    port (
        -- Input interface
        In_Clk            : in    std_logic;
        In_Rst            : in    std_logic;
        In_RstOut         : out   std_logic;
        In_Data           : in    std_logic_vector(Width_g - 1 downto 0);
        In_Valid          : in    std_logic                                                := '1';
        In_Ready          : out   std_logic;
        In_Full           : out   std_logic;
        In_Empty          : out   std_logic;
        In_AlmFull        : out   std_logic;
        In_AlmEmpty       : out   std_logic;
        In_Level          : out   std_logic_vector(log2ceil(Depth_g + 1) - 1 downto 0);
        -- Output Interface
        Out_Clk           : in    std_logic;
        Out_Rst           : in    std_logic;
        Out_RstOut        : out   std_logic;
        Out_Data          : out   std_logic_vector(Width_g - 1 downto 0);
        Out_Valid         : out   std_logic;
        Out_Ready         : in    std_logic                                                := '1';
        Out_EccSec        : out   std_logic;
        Out_EccDed        : out   std_logic;
        Out_Full          : out   std_logic;
        Out_Empty         : out   std_logic;
        Out_AlmFull       : out   std_logic;
        Out_AlmEmpty      : out   std_logic;
        Out_Level         : out   std_logic_vector(log2ceil(Depth_g + 1) - 1 downto 0);
        -- Error injection (independent of the data handshake, on the input clock domain)
        In_ErrInj_BitFlip : in    std_logic_vector(eccCodewordWidth(Width_g) - 1 downto 0) := (others => '0');
        In_ErrInj_Valid   : in    std_logic                                                := '0'
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of olo_ft_fifo_async is

    constant CodewordWidth_c : positive := eccCodewordWidth(Width_g);
    constant AddrWidth_c     : positive := log2ceil(Depth_g) + 1;
    constant RamAddrWidth_c  : positive := log2ceil(Depth_g);

    -- Encoder <-> core (input clock domain)
    signal EncOut_Codeword : std_logic_vector(CodewordWidth_c - 1 downto 0);
    signal EncOut_Valid    : std_logic;
    signal EncOut_Ready    : std_logic;

    -- Cross-synced resets (from the TMR reset crossing)
    signal RstInInt  : std_logic;
    signal RstOutInt : std_logic;

    -- Core <-> RAM
    signal RamWrAddr : std_logic_vector(RamAddrWidth_c - 1 downto 0);
    signal RamWrEna  : std_logic;
    signal RamWrData : std_logic_vector(CodewordWidth_c - 1 downto 0);
    signal RamRdAddr : std_logic_vector(RamAddrWidth_c - 1 downto 0);
    signal RamRdData : std_logic_vector(CodewordWidth_c - 1 downto 0);

    -- Core <-> TMR CDC (Gray pointers)
    signal WrGrayOut : std_logic_vector(AddrWidth_c - 1 downto 0);
    signal WrGrayIn  : std_logic_vector(AddrWidth_c - 1 downto 0);
    signal RdGrayOut : std_logic_vector(AddrWidth_c - 1 downto 0);
    signal RdGrayIn  : std_logic_vector(AddrWidth_c - 1 downto 0);

    -- Core <-> decoder (output clock domain)
    signal FifoOut_Codeword : std_logic_vector(CodewordWidth_c - 1 downto 0);
    signal FifoOut_Valid    : std_logic;
    signal FifoOut_Ready    : std_logic;

begin

    -- Encoder (input clock domain). Codec owns the injection latch.
    i_enc : entity work.olo_ft_ecc_encode
        generic map (
            Width_g    => Width_g,
            Pipeline_g => 0,
            UseReady_g => true
        )
        port map (
            Clk            => In_Clk,
            Rst            => In_Rst,
            In_Valid       => In_Valid,
            In_Ready       => In_Ready,
            In_Data        => In_Data,
            Out_Valid      => EncOut_Valid,
            Out_Ready      => EncOut_Ready,
            Out_Codeword   => EncOut_Codeword,
            ErrInj_BitFlip => In_ErrInj_BitFlip,
            ErrInj_Valid   => In_ErrInj_Valid
        );

    -- Shared FIFO control core (stores the codeword)
    i_core : entity work.olo_private_fifo_async_core
        generic map (
            Width_g         => CodewordWidth_c,
            Depth_g         => Depth_g,
            AlmFullOn_g     => AlmFullOn_g,
            AlmFullLevel_g  => AlmFullLevel_g,
            AlmEmptyOn_g    => AlmEmptyOn_g,
            AlmEmptyLevel_g => AlmEmptyLevel_g,
            ReadyRstState_g => ReadyRstState_g,
            Optimization_g  => Optimization_g
        )
        port map (
            In_Clk       => In_Clk,
            In_RstSync   => RstInInt,
            In_Data      => EncOut_Codeword,
            In_Valid     => EncOut_Valid,
            In_Ready     => EncOut_Ready,
            In_Full      => In_Full,
            In_Empty     => In_Empty,
            In_AlmFull   => In_AlmFull,
            In_AlmEmpty  => In_AlmEmpty,
            In_Level     => In_Level,
            Out_Clk      => Out_Clk,
            Out_RstSync  => RstOutInt,
            Out_Data     => FifoOut_Codeword,
            Out_Valid    => FifoOut_Valid,
            Out_Ready    => FifoOut_Ready,
            Out_Full     => Out_Full,
            Out_Empty    => Out_Empty,
            Out_AlmFull  => Out_AlmFull,
            Out_AlmEmpty => Out_AlmEmpty,
            Out_Level    => Out_Level,
            Ram_Wr_Addr  => RamWrAddr,
            Ram_Wr_Ena   => RamWrEna,
            Ram_Wr_Data  => RamWrData,
            Ram_Rd_Addr  => RamRdAddr,
            Ram_Rd_Data  => RamRdData,
            WrGray_Out   => WrGrayOut,
            WrGray_In    => WrGrayIn,
            RdGray_Out   => RdGrayOut,
            RdGray_In    => RdGrayIn
        );

    -- Storage (plain RAM holding the codeword)
    i_ram : entity work.olo_base_ram_sdp
        generic map (
            Depth_g       => Depth_g,
            Width_g       => CodewordWidth_c,
            RamStyle_g    => RamStyle_g,
            IsAsync_g     => true,
            RamBehavior_g => RamBehavior_g
        )
        port map (
            Clk     => In_Clk,
            Wr_Addr => RamWrAddr,
            Wr_Ena  => RamWrEna,
            Wr_Data => RamWrData,
            Rd_Clk  => Out_Clk,
            Rd_Addr => RamRdAddr,
            Rd_Data => RamRdData
        );

    -- Wr -> Rd pointer crossing (TMR-hardened)
    i_cc_wr_rd : entity work.olo_ft_cc_bits
        generic map (
            Width_g      => AddrWidth_c,
            SyncStages_g => SyncStages_g
        )
        port map (
            In_Clk   => In_Clk,
            In_Rst   => RstInInt,
            In_Data  => WrGrayOut,
            Out_Clk  => Out_Clk,
            Out_Rst  => RstOutInt,
            Out_Data => WrGrayIn
        );

    -- Rd -> Wr pointer crossing (TMR-hardened)
    i_cc_rd_wr : entity work.olo_ft_cc_bits
        generic map (
            Width_g      => AddrWidth_c,
            SyncStages_g => SyncStages_g
        )
        port map (
            In_Clk   => Out_Clk,
            In_Rst   => RstOutInt,
            In_Data  => RdGrayOut,
            Out_Clk  => In_Clk,
            Out_Rst  => RstInInt,
            Out_Data => RdGrayIn
        );

    -- Reset crossing (TMR-hardened)
    i_rst_cc : entity work.olo_ft_cc_reset
        port map (
            A_Clk    => In_Clk,
            A_RstIn  => In_Rst,
            A_RstOut => RstInInt,
            B_Clk    => Out_Clk,
            B_RstIn  => Out_Rst,
            B_RstOut => RstOutInt
        );

    In_RstOut  <= RstInInt;
    Out_RstOut <= RstOutInt;

    -- Decoder (output clock domain)
    i_dec : entity work.olo_ft_ecc_decode
        generic map (
            Width_g    => Width_g,
            Pipeline_g => 0,
            UseReady_g => true
        )
        port map (
            Clk            => Out_Clk,
            Rst            => RstOutInt,
            In_Valid       => FifoOut_Valid,
            In_Ready       => FifoOut_Ready,
            In_Codeword    => FifoOut_Codeword,
            Out_Valid      => Out_Valid,
            Out_Ready      => Out_Ready,
            Out_Data       => Out_Data,
            Out_EccSec     => Out_EccSec,
            Out_EccDed     => Out_EccDed,
            ErrInj_BitFlip => (others => '0'),
            ErrInj_Valid   => '0'
        );

end architecture;
