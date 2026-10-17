---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- ECC-protected synchronous FIFO with stream interfaces only (no levels, no status flags) and an
-- optional pipeline in the ECC decoder. Private building block of the ft AXI masters.
--
-- Documentation:
-- https://github.com/open-logic/open-logic/blob/main/doc/ft/olo_ft_private_fifo_stream.md
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
    use work.olo_ft_pkg_ecc.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity olo_ft_private_fifo_stream is
    generic (
        Width_g       : positive;
        Depth_g       : positive;
        EccPipeline_g : natural range 0 to 2 := 0;
        RamStyle_g    : string               := "auto";
        RamBehavior_g : string               := "RBW"
    );
    port (
        -- Control Ports
        Clk               : in    std_logic;
        Rst               : in    std_logic;
        -- Input Data
        In_Data           : in    std_logic_vector(Width_g - 1 downto 0);
        In_Valid          : in    std_logic                                                := '1';
        In_Ready          : out   std_logic;
        -- Output Data
        Out_Data          : out   std_logic_vector(Width_g - 1 downto 0);
        Out_Valid         : out   std_logic;
        Out_Ready         : in    std_logic                                                := '1';
        Out_EccSec        : out   std_logic;
        Out_EccDed        : out   std_logic;
        -- Error injection (independent of the data handshake)
        In_ErrInj_BitFlip : in    std_logic_vector(eccCodewordWidth(Width_g) - 1 downto 0) := (others => '0');
        In_ErrInj_Valid   : in    std_logic                                                := '0'
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of olo_ft_private_fifo_stream is

    constant CodewordWidth_c : positive := eccCodewordWidth(Width_g);

    signal EncOut_Codeword : std_logic_vector(CodewordWidth_c - 1 downto 0);
    signal EncOut_Valid    : std_logic;
    signal EncOut_Ready    : std_logic;

    signal FifoOut_Codeword : std_logic_vector(CodewordWidth_c - 1 downto 0);
    signal FifoOut_Valid    : std_logic;
    signal FifoOut_Ready    : std_logic;

begin

    -- Combinational encoder: the input side behaves like olo_base_fifo_sync
    i_enc : entity work.olo_ft_ecc_encode
        generic map (
            Width_g    => Width_g,
            Pipeline_g => 0,
            UseReady_g => true
        )
        port map (
            Clk            => Clk,
            Rst            => Rst,
            In_Valid       => In_Valid,
            In_Ready       => In_Ready,
            In_Data        => In_Data,
            Out_Valid      => EncOut_Valid,
            Out_Ready      => EncOut_Ready,
            Out_Codeword   => EncOut_Codeword,
            ErrInj_BitFlip => In_ErrInj_BitFlip,
            ErrInj_Valid   => In_ErrInj_Valid
        );

    i_fifo : entity work.olo_base_fifo_sync
        generic map (
            Width_g       => CodewordWidth_c,
            Depth_g       => Depth_g,
            RamStyle_g    => RamStyle_g,
            RamBehavior_g => RamBehavior_g
        )
        port map (
            Clk       => Clk,
            Rst       => Rst,
            In_Data   => EncOut_Codeword,
            In_Valid  => EncOut_Valid,
            In_Ready  => EncOut_Ready,
            Out_Data  => FifoOut_Codeword,
            Out_Valid => FifoOut_Valid,
            Out_Ready => FifoOut_Ready
        );

    -- Decoder with EccPipeline_g register stages: the ECC flags travel with their word
    i_dec : entity work.olo_ft_ecc_decode
        generic map (
            Width_g    => Width_g,
            Pipeline_g => EccPipeline_g,
            UseReady_g => true
        )
        port map (
            Clk            => Clk,
            Rst            => Rst,
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
