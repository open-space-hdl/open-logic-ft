---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Systematic Reed-Solomon encoder over GF(2^m) for a stream of symbols, with symbol interleaving,
-- shortened blocks and an optional dual basis representation (e.g. CCSDS 131.0-B-5 section 4).
--
-- Documentation:
-- https://github.com/open-logic/open-logic/blob/main/doc/base/olo_base_rs_encode.md
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
    use work.olo_base_pkg_array.all;
    use work.olo_base_pkg_gf.all;
    use work.olo_base_pkg_string.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity olo_base_rs_encode is
    generic (
        FieldPolynomial_g : std_logic_vector;
        CodewordSymbols_g : positive;
        DataSymbols_g     : positive;
        FirstRoot_g       : natural  := 0;
        RootStep_g        : positive := 1;
        InterleaveDepth_g : positive := 1;
        DualBasis_g       : natural  := 0
    );
    port (
        -- Control Signals
        Clk        : in    std_logic;
        Rst        : in    std_logic;
        -- Input
        In_Valid   : in    std_logic := '1';
        In_Ready   : out   std_logic;
        In_Data    : in    std_logic_vector(FieldPolynomial_g'length - 1 downto 0);
        In_Last    : in    std_logic := '0';
        -- Output
        Out_Valid  : out   std_logic;
        Out_Ready  : in    std_logic := '1';
        Out_Data   : out   std_logic_vector(FieldPolynomial_g'length - 1 downto 0);
        Out_Parity : out   std_logic;
        Out_Last   : out   std_logic
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of olo_base_rs_encode is

    -- *** Constants ***
    constant EntityName_c : string                             := "olo_base_rs_encode";
    constant M_c          : positive                           := FieldPolynomial_g'length;
    constant Poly_c       : std_logic_vector(M_c - 1 downto 0) := FieldPolynomial_g;
    constant Roots_c      : natural                            := CodewordSymbols_g - DataSymbols_g;
    constant Depth_c      : positive                           := InterleaveDepth_g;
    constant MaxData_c    : positive                           := Depth_c * DataSymbols_g;
    constant Checks_c     : positive                           := Depth_c * Roots_c;
    constant Gen_c        : IntegerArray_t(0 to Roots_c)       := gfRsGenerator(Poly_c, Roots_c, FirstRoot_g, RootStep_g);

    -- Conversion matrices of the dual basis (identity for the polynomial basis)
    function basisMatrix (inverse : boolean) return IntegerArray_t is
        variable Identity_v : IntegerArray_t(0 to M_c - 1);
    begin
        if DualBasis_g = 0 then

            for i in 0 to M_c - 1 loop
                Identity_v(i) := 2**i;
            end loop;

            return Identity_v;
        elsif inverse then
            return gfDualBasisMatrixInv(Poly_c, DualBasis_g);
        else
            return gfDualBasisMatrix(Poly_c, DualBasis_g);
        end if;
    end function;

    constant ToDual_c   : IntegerArray_t(0 to M_c - 1) := basisMatrix(false);
    constant FromDual_c : IntegerArray_t(0 to M_c - 1) := basisMatrix(true);

    -- *** Types ***
    subtype Symbol_t is std_logic_vector(M_c - 1 downto 0);

    -- Remainder register of one codeword, index i holds the coefficient of x^i
    type Remainder_t is array (0 to Roots_c - 1) of Symbol_t;

    -- One remainder per codeword; entry 0 belongs to the codeword of the next symbol
    type Chain_t is array (0 to Depth_c - 1) of Remainder_t;

    type Fsm_t is (Flush_s, Data_s, Align_s, Parity_s);

    -- *** Two Process Record ***
    type TwoProcess_r is record
        Fsm       : Fsm_t;
        Chain     : Chain_t;
        Count     : natural range 0 to MaxData_c;
        Slot      : natural range 0 to Depth_c - 1;
        Steps     : natural range 0 to Checks_c;
        OutValid  : std_logic;
        OutData   : Symbol_t;
        OutParity : std_logic;
        OutLast   : std_logic;
    end record;

    signal r, r_next : TwoProcess_r;

begin

    -- *** Assertions ***
    assert M_c >= 3 and M_c <= 12
        report errorMessage(EntityName_c, "FieldPolynomial_g must have 3 to 12 bits")
        severity failure;
    assert gfIsPrimitive(Poly_c)
        report errorMessage(EntityName_c, "FieldPolynomial_g is not primitive")
        severity failure;
    assert CodewordSymbols_g <= 2**M_c - 1 and DataSymbols_g < CodewordSymbols_g
        report errorMessage(EntityName_c, "require DataSymbols_g < CodewordSymbols_g <= 2^m - 1")
        severity failure;

    -- *** Combinatorial Process ***
    p_comb : process (all) is
        variable v         : TwoProcess_r;
        variable OutFree_v : boolean;
        variable Head_v    : Remainder_t;
        variable Fb_v      : Symbol_t;
        variable Next_v    : natural range 0 to Depth_c;
    begin
        -- *** Keep two process variables stable ***
        v := r;

        -- *** Output handshake ***
        OutFree_v := (r.OutValid = '0') or (Out_Ready = '1');
        if Out_Ready = '1' then
            v.OutValid := '0';
        end if;

        -- *** Default: head of the chain unchanged ***
        Head_v   := r.Chain(0);
        In_Ready <= '0';

        case r.Fsm is

            -- Clear all remainders after reset
            when Flush_s =>
                Head_v  := (others => (others => '0'));
                v.Chain := r.Chain(1 to Depth_c - 1) & Head_v;
                if r.Steps > 1 then
                    v.Steps := r.Steps - 1;
                else
                    v.Fsm := Data_s;
                end if;

            -- Pass the data and divide each codeword by g(x)
            when Data_s =>
                if OutFree_v then
                    In_Ready <= '1';
                end if;
                if OutFree_v and In_Valid = '1' then
                    -- Remainder update of the codeword of this symbol
                    Fb_v := gfMatMult(FromDual_c, In_Data) xor r.Chain(0)(Roots_c - 1);

                    for i in Roots_c - 1 downto 1 loop
                        Head_v(i) := r.Chain(0)(i - 1) xor gfMult(Fb_v, std_logic_vector(to_unsigned(Gen_c(i), M_c)), Poly_c);
                    end loop;

                    Head_v(0) := gfMult(Fb_v, std_logic_vector(to_unsigned(Gen_c(0), M_c)), Poly_c);
                    v.Chain   := r.Chain(1 to Depth_c - 1) & Head_v;
                    -- Data output
                    v.OutValid  := '1';
                    v.OutData   := In_Data;
                    v.OutParity := '0';
                    v.OutLast   := '0';
                    -- End of the block: bring the first codeword to the head of the chain (4.4.1 order)
                    v.Count := r.Count + 1;
                    Next_v  := r.Slot + 1;
                    if Next_v = Depth_c then
                        Next_v := 0;
                    end if;
                    v.Slot := Next_v;
                    if In_Last = '1' or r.Count = MaxData_c - 1 then
                        if Next_v = 0 then
                            v.Fsm   := Parity_s;
                            v.Steps := Checks_c;
                        else
                            v.Fsm   := Align_s;
                            v.Steps := Depth_c - Next_v;
                        end if;
                    end if;
                end if;

            -- Rotate the chain without symbols (block length not a multiple of the interleaving depth)
            when Align_s =>
                v.Chain := r.Chain(1 to Depth_c - 1) & Head_v;
                if r.Steps > 1 then
                    v.Steps := r.Steps - 1;
                else
                    v.Fsm   := Parity_s;
                    v.Steps := Checks_c;
                end if;

            -- Output the check symbols: highest coefficient first, codewords in rotation
            when Parity_s =>
                if OutFree_v then

                    for i in Roots_c - 1 downto 1 loop
                        Head_v(i) := r.Chain(0)(i - 1);
                    end loop;

                    Head_v(0)   := (others => '0');
                    v.Chain     := r.Chain(1 to Depth_c - 1) & Head_v;
                    v.OutValid  := '1';
                    v.OutData   := gfMatMult(ToDual_c, r.Chain(0)(Roots_c - 1));
                    v.OutParity := '1';
                    v.OutLast   := '0';
                    if r.Steps > 1 then
                        v.Steps := r.Steps - 1;
                    else
                        v.OutLast := '1';
                        v.Fsm     := Data_s;
                        v.Count   := 0;
                        v.Slot    := 0;
                    end if;
                end if;

            -- coverage off
            when others => v.Fsm := Flush_s; -- unreachable code, safe recovery
            -- coverage on

        end case;

        -- *** Assign to signal ***
        r_next <= v;

    end process;

    -- *** Outputs ***
    Out_Valid  <= r.OutValid;
    Out_Data   <= r.OutData;
    Out_Parity <= r.OutParity;
    Out_Last   <= r.OutLast;

    -- *** Sequential Process ***
    p_seq : process (Clk) is
    begin
        if rising_edge(Clk) then
            r <= r_next;
            if Rst = '1' then
                r.Fsm      <= Flush_s;
                r.Steps    <= Depth_c;
                r.Count    <= 0;
                r.Slot     <= 0;
                r.OutValid <= '0';
            end if;
        end if;
    end process;

end architecture;
