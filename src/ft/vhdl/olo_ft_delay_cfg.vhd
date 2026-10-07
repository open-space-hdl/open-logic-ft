---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- ECC-protected configurable delay element using SECDED (Single Error Correction, Double Error
-- Detection) Hamming code. Wraps olo_base_delay_cfg with a codeword-wide word, so every storage
-- tap holds an ECC codeword. The ECC is transparent to the user: data is encoded at the input
-- and decoded/corrected at the output. RstState_g additionally suppresses reading storage that
-- was never written since reset (no spurious error flags during warm-up).
--
-- Documentation:
-- https://github.com/open-logic/open-logic/blob/main/doc/ft/olo_ft_delay_cfg.md
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
entity olo_ft_delay_cfg is
    generic (
        Width_g       : positive;
        MaxDelay_g    : positive             := 256;
        SupportZero_g : boolean              := false;
        RstState_g    : boolean              := true;
        RamBehavior_g : string               := "RBW";
        RamStyle_g    : string               := "auto";
        EccPipeline_g : natural range 0 to 1 := 0
    );
    port (
        -- Control Ports
        Clk               : in    std_logic;
        Rst               : in    std_logic;
        Delay             : in    std_logic_vector(log2ceil(MaxDelay_g + 1) - 1 downto 0);
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
architecture rtl of olo_ft_delay_cfg is

    constant CodewordWidth_c : positive := eccCodewordWidth(Width_g);

    -- With the optional output register (EccPipeline_g = 1) the wrapped delay runs one sample
    -- shorter, so the base entity must support a delay of zero (combinational bypass).
    constant BaseSupportZero_c : boolean := SupportZero_g or (EccPipeline_g = 1);

    -- Encoder -> delay line (codeword domain)
    signal EncCodeword : std_logic_vector(CodewordWidth_c - 1 downto 0);

    -- Delay applied to the wrapped entity (Delay - EccPipeline_g, clamped at zero)
    signal BaseDelay : std_logic_vector(Delay'range);

    -- Delay line -> decoder (codeword domain)
    signal DlyCodeword : std_logic_vector(CodewordWidth_c - 1 downto 0);

    -- Combinational decoder outputs
    signal DecData   : std_logic_vector(Width_g - 1 downto 0);
    signal DecEccSec : std_logic;
    signal DecEccDed : std_logic;

    -- Outputs before the warm-up gate
    signal UngatedData   : std_logic_vector(Width_g - 1 downto 0);
    signal UngatedEccSec : std_logic;
    signal UngatedEccDed : std_logic;

begin

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

    -- Delay seen by the wrapped entity
    g_basedelay_comb : if EccPipeline_g = 0 generate
        BaseDelay <= Delay;
    end generate;

    g_basedelay_reg : if EccPipeline_g = 1 generate
        BaseDelay <= std_logic_vector(unsigned(Delay) - 1) when unsigned(Delay) /= 0 else
                     (others => '0');
    end generate;

    -- Base configurable delay with codeword-wide word. Every storage tap holds an ECC codeword,
    -- so a single upset in any storage medium is corrected at decode.
    i_delay : entity work.olo_base_delay_cfg
        generic map (
            Width_g       => CodewordWidth_c,
            MaxDelay_g    => MaxDelay_g,
            SupportZero_g => BaseSupportZero_c,
            RamBehavior_g => RamBehavior_g,
            RamStyle_g    => RamStyle_g
        )
        port map (
            Clk      => Clk,
            Rst      => Rst,
            Delay    => BaseDelay,
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
        UngatedData   <= DecData;
        UngatedEccSec <= DecEccSec;
        UngatedEccDed <= DecEccDed;
    end generate;

    -- Registered output (EccPipeline_g = 1): one In_Valid-gated register on the decoded outputs.
    -- It contributes the one sample removed from the wrapped delay, so the total stays Delay.
    -- With SupportZero_g the Delay = 0 bypass goes combinationally around the register.
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

        g_zero : if SupportZero_g generate
            UngatedData   <= DecData when fromUslv(Delay) = 0 else DataReg;
            UngatedEccSec <= DecEccSec when fromUslv(Delay) = 0 else SecReg;
            UngatedEccDed <= DecEccDed when fromUslv(Delay) = 0 else DedReg;
        end generate;

        g_nozero : if not SupportZero_g generate
            UngatedData   <= DataReg;
            UngatedEccSec <= SecReg;
            UngatedEccDed <= DedReg;
        end generate;

    end generate;

    -- Warm-up gate: suppress output data and error flags while the configured delay reaches
    -- back to storage that was never written since reset (would decode as garbage codewords
    -- with spurious error flags). Covers reset and delay increases beyond the written history.
    g_rststate : if RstState_g generate
        signal WarmCnt : natural range 0 to MaxDelay_g := 0;
    begin

        p_warmup : process (Clk) is
        begin
            if rising_edge(Clk) then
                if In_Valid = '1' and WarmCnt < MaxDelay_g then
                    WarmCnt <= WarmCnt + 1;
                end if;

                if Rst = '1' then
                    WarmCnt <= 0;
                end if;
            end if;
        end process;

        Out_Data   <= (others => '0') when WarmCnt < fromUslv(Delay) else UngatedData;
        Out_EccSec <= '0' when WarmCnt < fromUslv(Delay) else UngatedEccSec;
        Out_EccDed <= '0' when WarmCnt < fromUslv(Delay) else UngatedEccDed;
    end generate;

    g_norststate : if not RstState_g generate
        Out_Data   <= UngatedData;
        Out_EccSec <= UngatedEccSec;
        Out_EccDed <= UngatedEccDed;
    end generate;

end architecture;
