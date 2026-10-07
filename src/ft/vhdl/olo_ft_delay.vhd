---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- ECC-protected delay element using SECDED (Single Error Correction, Double Error Detection)
-- Hamming code. Wraps olo_base_delay with a codeword-wide word, so every storage tap (SRL,
-- BRAM and the output register) holds an ECC codeword. The ECC is transparent to the user:
-- data is encoded at the input and decoded/corrected at the output.
--
-- Documentation:
-- https://github.com/open-logic/open-logic/blob/main/doc/ft/olo_ft_delay.md
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
    use work.olo_ft_pkg_ecc.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity olo_ft_delay is
    generic (
        Width_g         : positive;
        Delay_g         : natural;
        Resource_g      : string                            := "AUTO";
        BramThreshold_g : positive range 3 to positive'high := 128;
        RstState_g      : boolean                           := true;
        RamBehavior_g   : string                            := "RBW";
        RamStyle_g      : string                            := "auto";
        EccPipeline_g   : natural range 0 to 1              := 0
    );
    port (
        -- Control Ports
        Clk               : in    std_logic;
        Rst               : in    std_logic;
        -- Data
        In_Data           : in    std_logic_vector(Width_g - 1 downto 0);
        In_Valid          : in    std_logic                                                := '1';
        Out_Data          : out   std_logic_vector(Width_g - 1 downto 0);
        Out_EccSec        : out   std_logic;
        Out_EccDed        : out   std_logic;
        -- Error injection (latched, applied to the next In_Valid beat)
        In_ErrInj_BitFlip : in    std_logic_vector(eccCodewordWidth(Width_g) - 1 downto 0) := (others => '0');
        In_ErrInj_Valid   : in    std_logic                                                := '0'
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of olo_ft_delay is

    constant EntityName_c    : string   := "olo_ft_delay";
    constant CodewordWidth_c : positive := eccCodewordWidth(Width_g);

    -- The optional output register (EccPipeline_g = 1) adds one sample of delay, so the wrapped
    -- delay is shortened accordingly to keep the total at exactly Delay_g samples.
    constant BaseDelay_c : natural := Delay_g - EccPipeline_g;

    -- Encoder -> delay line (codeword domain)
    signal EncCodeword : std_logic_vector(CodewordWidth_c - 1 downto 0);

    -- Delay line -> decoder (codeword domain)
    signal DlyCodeword : std_logic_vector(CodewordWidth_c - 1 downto 0);

    -- Combinational decoder outputs
    signal DecData   : std_logic_vector(Width_g - 1 downto 0);
    signal DecEccSec : std_logic;
    signal DecEccDed : std_logic;

begin

    assert Delay_g >= EccPipeline_g
        report errorMessage(EntityName_c, "EccPipeline_g=1 requires Delay_g >= 1")
        severity error;

    -- Encoder: combinational encode, the injection latch inside the codec is armed by
    -- In_ErrInj_Valid and cleared/applied on the next In_Valid beat.
    i_enc : entity work.olo_ft_ecc_encode
        generic map (
            Width_g    => Width_g,
            Pipeline_g => 0,
            UseReady_g => false
        )
        port map (
            Clk            => Clk,
            Rst            => Rst,
            In_Valid       => In_Valid,
            In_Ready       => open,
            In_Data        => In_Data,
            Out_Valid      => open,
            Out_Codeword   => EncCodeword,
            ErrInj_BitFlip => In_ErrInj_BitFlip,
            ErrInj_Valid   => In_ErrInj_Valid
        );

    -- Base delay with codeword-wide word. Every storage tap holds an ECC codeword, so a single
    -- upset in any storage medium (SRL, BRAM, output register) is corrected at decode.
    i_delay : entity work.olo_base_delay
        generic map (
            Width_g         => CodewordWidth_c,
            Delay_g         => BaseDelay_c,
            Resource_g      => Resource_g,
            BramThreshold_g => BramThreshold_g,
            RstState_g      => RstState_g,
            RamBehavior_g   => RamBehavior_g,
            RamStyle_g      => RamStyle_g
        )
        port map (
            Clk      => Clk,
            Rst      => Rst,
            In_Data  => EncCodeword,
            In_Valid => In_Valid,
            Out_Data => DlyCodeword
        );

    -- Decoder: combinational decode + SEC/DED flags, time-aligned with the data
    i_dec : entity work.olo_ft_ecc_decode
        generic map (
            Width_g    => Width_g,
            Pipeline_g => 0,
            UseReady_g => false
        )
        port map (
            Clk            => Clk,
            Rst            => Rst,
            In_Valid       => '1',
            In_Codeword    => DlyCodeword,
            Out_Ready      => '1',
            Out_Data       => DecData,
            Out_EccSec     => DecEccSec,
            Out_EccDed     => DecEccDed,
            ErrInj_BitFlip => (others => '0'),
            ErrInj_Valid   => '0'
        );

    -- Combinational output (EccPipeline_g = 0)
    g_comb : if EccPipeline_g = 0 generate
        Out_Data   <= DecData;
        Out_EccSec <= DecEccSec;
        Out_EccDed <= DecEccDed;
    end generate;

    -- Registered output (EccPipeline_g = 1): one In_Valid-gated register on the decoded outputs.
    -- It contributes the one sample removed from the wrapped delay, so the total stays Delay_g.
    -- The reset value is the decoded zero codeword (data zero, no flags), consistent with the
    -- RstState_g behavior of the wrapped delay.
    g_reg : if EccPipeline_g = 1 generate
        signal DataReg : std_logic_vector(Width_g - 1 downto 0) := (others => '0');
        signal SecReg  : std_logic                              := '0';
        signal DedReg  : std_logic                              := '0';
    begin

        p_outreg : process (Clk) is
        begin
            if rising_edge(Clk) then
                if In_Valid = '1' then
                    DataReg <= DecData;
                    SecReg  <= DecEccSec;
                    DedReg  <= DecEccDed;
                end if;

                if Rst = '1' then
                    DataReg <= (others => '0');
                    SecReg  <= '0';
                    DedReg  <= '0';
                end if;
            end if;
        end process;

        Out_Data   <= DataReg;
        Out_EccSec <= SecReg;
        Out_EccDed <= DedReg;
    end generate;

end architecture;
