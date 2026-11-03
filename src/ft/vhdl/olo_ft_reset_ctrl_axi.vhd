---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Commanded reset with an AXI4-Lite register interface: a full-word write of a 32-bit key drives
-- a registered reset pulse of a fixed number of clock cycles on RstOut (32-bit data width).
--
-- Documentation:
-- https://github.com/open-logic/open-logic/blob/main/doc/ft/olo_ft_reset_ctrl_axi.md
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
entity olo_ft_reset_ctrl_axi is
    generic (
        RstPulseCycles_g  : positive range 1 to 65535     := 16;
        Key_g             : std_logic_vector(31 downto 0) := x"50495045";
        AxiAddrWidth_g    : positive range 4 to 30        := 12;
        ReadTimeoutClks_g : positive                      := 100
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
        -- Reset Output
        RstOut            : out   std_logic
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of olo_ft_reset_ctrl_axi is

    constant EntityName_c : string := "olo_ft_reset_ctrl_axi";

    -- Register map (word addresses)
    constant IdWord_c     : natural := 0;
    constant CtrlWord_c   : natural := 1;
    constant StatusWord_c : natural := 2;

    -- ID register content: ASCII "RST" in [31:8], register map version 1 in [7:0]
    constant Id_c : std_logic_vector(31 downto 0) := x"52535401";

    constant PulseCntWidth_c : positive := log2ceil(RstPulseCycles_g + 1);
    constant CmdCntMax_c     : natural  := 2**16 - 1;

    type TwoProcess_r is record
        KeyPend   : std_logic;
        PulseCnt  : unsigned(PulseCntWidth_c - 1 downto 0);
        CmdCnt    : unsigned(15 downto 0);
        RstOut    : std_logic;
        RbRdData  : std_logic_vector(31 downto 0);
        RbRdValid : std_logic;
    end record;

    -- Power-up state: RstOut is '1' until the first clock edge after the release of Rst
    constant PowerUp_c : TwoProcess_r := (
        KeyPend   => '0',
        PulseCnt  => (others => '0'),
        CmdCnt    => (others => '0'),
        RstOut    => '1',
        RbRdData  => (others => '0'),
        RbRdValid => '0'
    );

    signal r      : TwoProcess_r := PowerUp_c;
    signal r_next : TwoProcess_r;

    -- Register bus (from the AXI-Lite slave)
    signal Rb_Addr    : std_logic_vector(AxiAddrWidth_g - 1 downto 0);
    signal Rb_Wr      : std_logic;
    signal Rb_ByteEna : std_logic_vector(3 downto 0);
    signal Rb_WrData  : std_logic_vector(31 downto 0);
    signal Rb_Rd      : std_logic;

    -- Write response handshake
    signal Axi_BValid : std_logic;

begin

    assert (Key_g /= x"00000000") and (Key_g /= x"FFFFFFFF")
        report errorMessage(EntityName_c, "Key_g must not be all zeros or all ones " &
               "(the values of a stuck data bus).")
        severity error;

    -- *** Combinatorial Process ***
    p_comb : process (all) is
        variable v          : TwoProcess_r;
        variable WordAddr_v : natural;
        variable KeyWr_v    : boolean;
    begin
        v := r;

        -- Pulse defaults
        v.RbRdValid := '0';

        WordAddr_v := fromUslv(Rb_Addr(AxiAddrWidth_g - 1 downto 2));

        -- Write decode: a command is a full-word write of the key to CTRL. Every write updates the
        -- pending flag, so a key seen earlier never acts on a later write. Writes to read-only or
        -- unmapped words are ignored (the AXI response is OKAY).
        KeyWr_v := (Rb_Wr = '1') and (WordAddr_v = CtrlWord_c) and
                   (Rb_WrData = Key_g) and (Rb_ByteEna = "1111");
        if Rb_Wr = '1' then
            v.KeyPend := choose(KeyWr_v, '1', '0');
        end if;

        -- The command acts at the write response handshake of the same transaction. The slave
        -- raises Rb_Wr and BValid in the same cycle, so the current write is evaluated directly
        -- and a write response held off by BReady through the pending flag.
        if (Axi_BValid = '1') and (S_AxiLite_BReady = '1') and (KeyWr_v or r.KeyPend = '1') then
            v.PulseCnt := to_unsigned(RstPulseCycles_g, PulseCntWidth_c);
            if r.CmdCnt /= CmdCntMax_c then
                v.CmdCnt := r.CmdCnt + 1;
            end if;
            v.KeyPend := '0';
        elsif r.PulseCnt /= 0 then
            v.PulseCnt := r.PulseCnt - 1;
        end if;

        -- Registered reset output
        if v.PulseCnt /= 0 then
            v.RstOut := '1';
        else
            v.RstOut := '0';
        end if;

        -- Read decode. Unmapped addresses are intentionally not acknowledged: the AXI-Lite slave
        -- signals an error to the master via its read timeout.
        if Rb_Rd = '1' then
            if WordAddr_v = IdWord_c then
                v.RbRdData  := Id_c;
                v.RbRdValid := '1';
            elsif WordAddr_v = CtrlWord_c then
                v.RbRdData  := (others => '0');
                v.RbRdValid := '1';
            elsif WordAddr_v = StatusWord_c then
                v.RbRdData               := (others => '0');
                v.RbRdData(31 downto 16) := std_logic_vector(r.CmdCnt);
                v.RbRdData(0)            := r.RstOut;
                v.RbRdValid              := '1';
            end if;
        end if;

        r_next <= v;
    end process;

    -- Outputs
    RstOut           <= r.RstOut;
    S_AxiLite_BValid <= Axi_BValid;

    -- *** Sequential Process ***
    p_seq : process (Clk) is
    begin
        if rising_edge(Clk) then
            r <= r_next;
            if Rst = '1' then
                r.KeyPend   <= '0';
                r.PulseCnt  <= (others => '0');
                r.CmdCnt    <= (others => '0');
                r.RstOut    <= '1';
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
            S_AxiLite_BValid  => Axi_BValid,
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

end architecture;
