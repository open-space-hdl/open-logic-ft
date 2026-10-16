---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Reed-Solomon decoder over GF(2^m) for a stream of symbols, with symbol interleaving, shortened
-- blocks and an optional dual basis representation (e.g. CCSDS 131.0-B-5 section 4). It corrects
-- up to t symbol errors per codeword and reports the corrected symbols and uncorrectable codewords.
--
-- Documentation:
-- https://github.com/open-logic/open-logic/blob/main/doc/base/olo_base_rs_decode.md
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
    use work.olo_base_pkg_math.all;
    use work.olo_base_pkg_gf.all;
    use work.olo_base_pkg_string.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity olo_base_rs_decode is
    generic (
        FieldPolynomial_g : std_logic_vector;
        CodewordSymbols_g : positive;
        DataSymbols_g     : positive;
        FirstRoot_g       : natural  := 0;
        RootStep_g        : positive := 1;
        InterleaveDepth_g : positive := 1;
        DualBasis_g       : natural  := 0;
        OutputParity_g    : boolean  := false;
        RamStyle_g        : string   := "auto";
        RamBehavior_g     : string   := "RBW"
    );
    port (
        -- Control Signals
        Clk                  : in    std_logic;
        Rst                  : in    std_logic;
        -- Input
        In_Valid             : in    std_logic := '1';
        In_Ready             : out   std_logic;
        In_Data              : in    std_logic_vector(FieldPolynomial_g'length - 1 downto 0);
        In_Last              : in    std_logic := '0';
        -- Output
        Out_Valid            : out   std_logic;
        Out_Ready            : in    std_logic := '1';
        Out_Data             : out   std_logic_vector(FieldPolynomial_g'length - 1 downto 0);
        Out_Parity           : out   std_logic;
        Out_Last             : out   std_logic;
        -- Status (one pulse per codeword)
        Status_Valid         : out   std_logic;
        Status_Last          : out   std_logic;
        Status_Corrected     : out   std_logic_vector(log2ceil((CodewordSymbols_g - DataSymbols_g) / 2 + 1) - 1 downto 0);
        Status_Uncorrectable : out   std_logic
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of olo_base_rs_decode is

    -- *** Constants ***
    constant EntityName_c : string                             := "olo_base_rs_decode";
    constant M_c          : positive                           := FieldPolynomial_g'length;
    constant Poly_c       : std_logic_vector(M_c - 1 downto 0) := FieldPolynomial_g;
    constant Order_c      : positive                           := 2**M_c - 1;
    constant Roots_c      : natural                            := CodewordSymbols_g - DataSymbols_g;
    constant T_c          : natural                            := Roots_c / 2;
    constant Depth_c      : positive                           := InterleaveDepth_g;
    constant MaxBlock_c   : positive                           := Depth_c * CodewordSymbols_g;
    constant MinBlock_c   : positive                           := Depth_c * (Roots_c + 1);
    constant Checks_c     : positive                           := Depth_c * Roots_c;
    constant RamDepth_c   : positive                           := 2**log2ceil(2 * MaxBlock_c);
    constant AddrBits_c   : positive                           := log2ceil(RamDepth_c);
    constant CntBits_c    : positive                           := log2ceil(T_c + 1);
    constant DescDepth_c  : positive                           := 4;

    -- Exponent j0 of the first root as a power of beta = alpha^RootStep_g: alpha^(b0 + i*gamma) = beta^(j0 + i)
    function firstRootIndex return natural is
    begin

        for j in 0 to Order_c - 1 loop
            if (j * RootStep_g) mod Order_c = FirstRoot_g mod Order_c then
                return j;
            end if;
        end loop;

        return 0;
    end function;

    constant J0_c : natural := firstRootIndex;

    -- beta^e as a vector
    function betaPow (e : integer) return std_logic_vector is
    begin
        return gfAlphaPow((RootStep_g mod Order_c) * (e mod Order_c), Poly_c);
    end function;

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
    constant InvTable_c : IntegerArray_t(0 to Order_c) := gfInvTable(Poly_c);

    -- Constant factors (powers of beta)
    constant One_c        : std_logic_vector(M_c - 1 downto 0) := std_logic_vector(to_unsigned(1, M_c));
    constant BetaInv_c    : std_logic_vector(M_c - 1 downto 0) := betaPow(-1);
    constant BetaInvJ0_c  : std_logic_vector(M_c - 1 downto 0) := betaPow(-J0_c);
    constant Beta_c       : std_logic_vector(M_c - 1 downto 0) := betaPow(1);
    constant BetaJ0_c     : std_logic_vector(M_c - 1 downto 0) := betaPow(J0_c);
    constant ForneyStep_c : std_logic_vector(M_c - 1 downto 0) := betaPow(J0_c + Roots_c);

    -- Step of the Chien search per coefficient: beta^k
    function chienSteps return IntegerArray_t is
        variable S_v : IntegerArray_t(0 to T_c);
    begin

        for k in 0 to T_c loop
            S_v(k) := to_integer(unsigned(betaPow(k)));
        end loop;

        return S_v;
    end function;

    constant ChienStep_c : IntegerArray_t(0 to T_c) := chienSteps;

    -- *** Types ***
    subtype Symbol_t is std_logic_vector(M_c - 1 downto 0);

    type Lambda_t is array (0 to T_c) of Symbol_t;

    type Omega_t is array (0 to T_c - 1) of Symbol_t;

    -- Search state of one codeword: locator and evaluator coefficients scaled to the current position, Forney factor
    type Search_r is record
        Lam  : Lambda_t;
        Om   : Omega_t;
        Fac  : Symbol_t;
        Deg  : natural range 0 to T_c;
        Fail : std_logic;
    end record;

    type SearchChain_t is array (0 to Depth_c - 1) of Search_r;

    type Count_t is array (0 to Depth_c - 1) of natural range 0 to T_c;

    -- Block descriptor
    type Desc_r is record
        Base  : unsigned(AddrBits_c - 1 downto 0);
        Len   : natural range 0 to MaxBlock_c;
        Good  : std_logic;
        Scale : Symbol_t;
        ScJ0  : Symbol_t;
        Done  : std_logic;
    end record;

    type DescArray_t is array (0 to DescDepth_c - 1) of Desc_r;

    -- Pipeline stage of the correction path
    type Stage_r is record
        Valid  : std_logic;
        Cw     : natural range 0 to Depth_c - 1;
        First  : std_logic;
        Check  : std_logic;
        Output : std_logic;
        LastO  : std_logic;
        LastP  : std_logic;
        Good   : std_logic;
        Deg    : natural range 0 to T_c;
        Fail   : std_logic;
        SumL   : Symbol_t;
        SumOdd : Symbol_t;
        SumOm  : Symbol_t;
        Fac    : Symbol_t;
        Prod   : Symbol_t;
        Inv    : Symbol_t;
        Data   : Symbol_t;
    end record;

    -- Status of the codewords of one block
    type Status_r is record
        Uncorr : std_logic_vector(0 to Depth_c - 1);
        Corr   : Count_t;
        Target : natural range 0 to 255;
    end record;

    type StatusArray_t is array (0 to 1) of Status_r;

    type OutFsm_t is (Idle_s, Run_s);

    function toStdl (b : boolean) return std_logic is
    begin
        if b then
            return '1';
        end if;
        return '0';
    end function;

    -- *** Two Process Record ***
    type TwoProcess_r is record
        -- Input
        InCount   : natural range 0 to MaxBlock_c - 1;
        InSlot    : natural range 0 to Depth_c - 1;
        InBase    : unsigned(AddrBits_c - 1 downto 0);
        WrAddr    : unsigned(AddrBits_c - 1 downto 0);
        RunA      : Symbol_t;
        RunB      : Symbol_t;
        Occ       : natural range 0 to RamDepth_c;
        -- Descriptors
        Desc      : DescArray_t;
        DescWr    : natural range 0 to DescDepth_c - 1;
        DescKes   : natural range 0 to DescDepth_c - 1;
        DescOut   : natural range 0 to DescDepth_c - 1;
        DescCount : natural range 0 to DescDepth_c;
        KesCount  : natural range 0 to DescDepth_c;
        -- Staging of the key equation results
        StgFull   : std_logic;
        -- Output
        OutFsm    : OutFsm_t;
        OutPos    : natural range 0 to MaxBlock_c - 1;
        OutCw     : natural range 0 to Depth_c - 1;
        OutBase   : unsigned(AddrBits_c - 1 downto 0);
        OutLen    : natural range 0 to MaxBlock_c;
        OutGood   : std_logic;
        ChkStart  : natural range 0 to MaxBlock_c;
        Chain     : SearchChain_t;
        S1        : Stage_r;
        S2        : Stage_r;
        S3        : Stage_r;
        CwRoots   : Count_t;
        CwChanged : Count_t;
        CwDeg     : Count_t;
        CwFail    : std_logic_vector(0 to Depth_c - 1);
        -- Status
        Status    : StatusArray_t;
        StWr      : natural range 0 to 1;
        StRd      : natural range 0 to 1;
        StCount   : natural range 0 to 2;
        StEmit    : natural range 0 to Depth_c;
        Pushed    : natural range 0 to 255;
        Accepted  : natural range 0 to 255;
        StValid   : std_logic;
        StLast    : std_logic;
        StCorr    : natural range 0 to T_c;
        StUncorr  : std_logic;
    end record;

    signal r, r_next : TwoProcess_r;

    -- *** Instantiation Signals ***
    signal SynInReady : std_logic;
    signal SynInValid : std_logic;
    signal SynInData  : Symbol_t;
    signal SynInEnd   : std_logic;
    signal SynValid   : std_logic;
    signal SynData    : std_logic_vector(Roots_c * M_c - 1 downto 0);
    signal SynNext    : std_logic;
    signal BlkValid   : std_logic;
    signal BlkGood    : std_logic;
    signal BlkScale   : std_logic_vector(M_c - 1 downto 0);
    signal BlkScaleJ0 : std_logic_vector(M_c - 1 downto 0);
    signal BlkDone    : std_logic;
    signal StgWrite   : std_logic;
    signal StgIndex   : natural range 0 to Depth_c - 1;
    signal StgLambda  : std_logic_vector((T_c + 1) * M_c - 1 downto 0);
    signal StgOmega   : std_logic_vector(T_c * M_c - 1 downto 0);
    signal StgDeg     : natural range 0 to T_c;
    signal StgFail    : std_logic;
    signal StgFree    : std_logic;
    signal RamWrEna   : std_logic;
    signal RamRdEna   : std_logic;
    signal RamRdAddr  : std_logic_vector(AddrBits_c - 1 downto 0);
    signal RamRdData  : Symbol_t;
    signal PlInValid  : std_logic;
    signal PlInReady  : std_logic;
    signal PlInData   : std_logic_vector(M_c + 1 downto 0);
    signal PlOutData  : std_logic_vector(M_c + 1 downto 0);
    signal PlOutValid : std_logic;

    -- Staging of the key equation results, one entry per codeword (written by the key equation solver)
    type StgLambda_t is array (0 to Depth_c - 1) of Lambda_t;

    type StgOmega_t is array (0 to Depth_c - 1) of Omega_t;

    type StgDeg_t is array (0 to Depth_c - 1) of natural range 0 to T_c;

    signal StgL : StgLambda_t;
    signal StgO : StgOmega_t;
    signal StgD : StgDeg_t;
    signal StgF : std_logic_vector(0 to Depth_c - 1);

    -- *** Components ***
    component olo_private_rs_dec_syndrome is
        generic (
            FieldPolynomial_g : std_logic_vector;
            Roots_g           : positive;
            J0_g              : natural;
            RootStep_g        : positive;
            InterleaveDepth_g : positive
        );
        port (
            Clk       : in    std_logic;
            Rst       : in    std_logic;
            In_Ready  : out   std_logic;
            In_Valid  : in    std_logic;
            In_Data   : in    std_logic_vector(FieldPolynomial_g'length - 1 downto 0);
            In_End    : in    std_logic;
            Out_Valid : out   std_logic;
            Out_Data  : out   std_logic_vector(Roots_g * FieldPolynomial_g'length - 1 downto 0);
            Out_Next  : in    std_logic
        );
    end component;

    component olo_private_rs_dec_kes is
        generic (
            FieldPolynomial_g : std_logic_vector;
            T_g               : positive;
            InterleaveDepth_g : positive
        );
        port (
            Clk         : in    std_logic;
            Rst         : in    std_logic;
            Syn_Valid   : in    std_logic;
            Syn_Data    : in    std_logic_vector(2 * T_g * FieldPolynomial_g'length - 1 downto 0);
            Syn_Next    : out   std_logic;
            Blk_Valid   : in    std_logic;
            Blk_Good    : in    std_logic;
            Blk_Scale   : in    std_logic_vector(FieldPolynomial_g'length - 1 downto 0);
            Blk_ScaleJ0 : in    std_logic_vector(FieldPolynomial_g'length - 1 downto 0);
            Blk_Done    : out   std_logic;
            Stg_Free    : in    std_logic;
            Stg_Write   : out   std_logic;
            Stg_Index   : out   natural range 0 to InterleaveDepth_g - 1;
            Stg_Lambda  : out   std_logic_vector((T_g + 1) * FieldPolynomial_g'length - 1 downto 0);
            Stg_Omega   : out   std_logic_vector(T_g * FieldPolynomial_g'length - 1 downto 0);
            Stg_Deg     : out   natural range 0 to T_g;
            Stg_Fail    : out   std_logic
        );
    end component;

begin

    -- *** Assertions ***
    assert M_c >= 3 and M_c <= 12
        report errorMessage(EntityName_c, "FieldPolynomial_g must have 3 to 12 bits")
        severity failure;
    assert gfIsPrimitive(Poly_c)
        report errorMessage(EntityName_c, "FieldPolynomial_g is not primitive")
        severity failure;
    assert CodewordSymbols_g <= Order_c and DataSymbols_g < CodewordSymbols_g
        report errorMessage(EntityName_c, "require DataSymbols_g < CodewordSymbols_g <= 2^m - 1")
        severity failure;
    assert Roots_c mod 2 = 0
        report errorMessage(EntityName_c, "CodewordSymbols_g - DataSymbols_g must be even")
        severity failure;
    assert (J0_c * RootStep_g) mod Order_c = FirstRoot_g mod Order_c
        report errorMessage(EntityName_c, "RootStep_g must be coprime to 2^m - 1")
        severity failure;

    -- synthesis translate_off
    p_assert : process (Clk) is
    begin
        if rising_edge(Clk) then
            if Rst = '0' and In_Valid = '1' and In_Ready = '1' and In_Last = '1' and r.InSlot /= Depth_c - 1 then
                assert false
                    report errorMessage(EntityName_c, "block length is not a multiple of InterleaveDepth_g, " &
                           "all codewords of the block are reported uncorrectable")
                    severity warning;
            end if;
            if Rst = '0' and BlkDone = '1' and r.KesCount = 0 then
                assert false
                    report errorMessage(EntityName_c, "internal error: key equation solver done without a block")
                    severity error;
            end if;
        end if;
    end process;

    -- synthesis translate_on

    -- *** Combinatorial Process ***
    p_comb : process (all) is
        variable v          : TwoProcess_r;
        variable InReady_v  : std_logic;
        variable Accept_v   : boolean;
        variable End_v      : boolean;
        variable Len_v      : natural range 0 to MaxBlock_c;
        variable NextSlot_v : natural range 0 to Depth_c;
        variable Adv_v      : boolean;
        variable Head_v     : Search_r;
        variable Upd_v      : Search_r;
        variable Issue_v    : boolean;
        variable SumL_v     : Symbol_t;
        variable SumOdd_v   : Symbol_t;
        variable SumOm_v    : Symbol_t;
        variable Err_v      : Symbol_t;
        variable Root_v     : boolean;
        variable Roots_v    : Count_t;
        variable Changed_v  : Count_t;
        variable Deg_v      : Count_t;
        variable Fail_v     : std_logic_vector(0 to Depth_c - 1);
        variable Cw_v       : natural range 0 to Depth_c - 1;
        variable OutData_v  : Symbol_t;
        variable Diff_v     : natural range 0 to 255;
    begin
        -- *** Keep two process variables stable ***
        v := r;

        -- *** Input: buffer, syndromes, block descriptors ***
        InReady_v := '0';
        if SynInReady = '1' and r.Occ < RamDepth_c and r.DescCount < DescDepth_c then
            InReady_v := '1';
        end if;
        Accept_v := InReady_v = '1' and In_Valid = '1';
        End_v    := Accept_v and (In_Last = '1' or r.InCount = MaxBlock_c - 1);
        Len_v    := r.InCount + 1;

        NextSlot_v := r.InSlot + 1;
        if NextSlot_v = Depth_c then
            NextSlot_v := 0;
        end if;

        if Accept_v then
            v.WrAddr := r.WrAddr + 1;
            v.InSlot := NextSlot_v;
            v.Occ    := v.Occ + 1;
            -- Running powers for the scaling of the syndromes: beta^-ntx and beta^-(j0 ntx)
            if r.InSlot = Depth_c - 1 then
                v.RunA := gfMult(r.RunA, BetaInv_c, Poly_c);
                v.RunB := gfMult(r.RunB, BetaInvJ0_c, Poly_c);
            end if;
            if End_v then
                v.Desc(r.DescWr).Base := r.InBase;
                v.Desc(r.DescWr).Len  := Len_v;
                v.Desc(r.DescWr).Done := '0';
                -- InSlot is the position of the symbol in its group of I (no modulo of the length)
                if r.InSlot = Depth_c - 1 and r.InCount >= MinBlock_c - 1 then
                    v.Desc(r.DescWr).Good := '1';
                else
                    v.Desc(r.DescWr).Good := '0';
                end if;
                -- f = beta^-(ntx-1) and f^j0
                v.Desc(r.DescWr).Scale := gfMult(v.RunA, Beta_c, Poly_c);
                v.Desc(r.DescWr).ScJ0  := gfMult(v.RunB, BetaJ0_c, Poly_c);
                v.DescWr               := (r.DescWr + 1) mod DescDepth_c;
                v.DescCount            := v.DescCount + 1;
                v.KesCount             := v.KesCount + 1;
                v.InCount              := 0;
                v.InSlot               := 0;
                v.InBase               := r.WrAddr + 1;
                v.RunA                 := One_c;
                v.RunB                 := One_c;
            else
                v.InCount := r.InCount + 1;
            end if;
        end if;

        In_Ready   <= InReady_v;
        RamWrEna   <= '0';
        SynInValid <= '0';
        SynInEnd   <= '0';
        if Accept_v then
            RamWrEna   <= '1';
            SynInValid <= '1';
        end if;
        if End_v then
            SynInEnd <= '1';
        end if;
        SynInData <= gfMatMult(FromDual_c, In_Data);

        -- *** Key equation solver: block handshake ***
        -- Blk_Done is a registered pulse, one per block the solver took while KesCount > 0, so KesCount > 0 whenever
        -- it is set (checked in p_assert). The count check is redundant in hardware; it keeps the constrained counter
        -- in range in simulation, where Blk_Done falls one delta cycle after r.KesCount changes at the clock edge.
        if BlkDone = '1' and r.KesCount > 0 then
            v.Desc(r.DescKes).Done := '1';
            if r.Desc(r.DescKes).Good = '1' then
                v.StgFull := '1';
            end if;
            v.DescKes  := (r.DescKes + 1) mod DescDepth_c;
            v.KesCount := v.KesCount - 1;
        end if;

        -- *** Correction path: issue one position per cycle while the output accepts data ***
        -- A full status queue holds the last position of a block in stage 3
        Adv_v    := PlInReady = '1' and not (r.S3.Valid = '1' and r.S3.LastP = '1' and r.StCount = 2);
        Issue_v  := false;
        SumL_v   := (others => '0');
        SumOdd_v := (others => '0');
        SumOm_v  := (others => '0');
        Head_v   := r.Chain(0);
        Upd_v    := r.Chain(0);

        case r.OutFsm is

            when Idle_s =>
                if r.DescCount > 0 and r.Desc(r.DescOut).Done = '1' then
                    v.OutFsm   := Run_s;
                    v.OutPos   := 0;
                    v.OutCw    := 0;
                    v.OutBase  := r.Desc(r.DescOut).Base;
                    v.OutLen   := r.Desc(r.DescOut).Len;
                    v.OutGood  := r.Desc(r.DescOut).Good;
                    v.ChkStart := r.Desc(r.DescOut).Len - minimum(r.Desc(r.DescOut).Len, Checks_c);
                end if;

            when Run_s =>
                if Adv_v then
                    Issue_v := true;
                    -- Search state of the codeword: from the key equation solver at its first position
                    if r.OutPos < Depth_c then
                        Head_v.Lam  := StgL(r.OutCw);
                        Head_v.Om   := StgO(r.OutCw);
                        Head_v.Fac  := One_c;
                        Head_v.Deg  := StgD(r.OutCw);
                        Head_v.Fail := StgF(r.OutCw);
                    end if;

                    -- Lambda(beta^u), its odd part and Omega_h(beta^u) (Chien search)
                    for k in 0 to T_c loop
                        SumL_v := SumL_v xor Head_v.Lam(k);
                        if k mod 2 = 1 then
                            SumOdd_v := SumOdd_v xor Head_v.Lam(k);
                        end if;
                    end loop;

                    for k in 0 to T_c - 1 loop
                        SumOm_v := SumOm_v xor Head_v.Om(k);
                    end loop;

                    -- Next position of this codeword
                    Upd_v := Head_v;

                    for k in 0 to T_c loop
                        Upd_v.Lam(k) := gfMult(Head_v.Lam(k), std_logic_vector(to_unsigned(ChienStep_c(k), M_c)), Poly_c);
                    end loop;

                    for k in 0 to T_c - 1 loop
                        Upd_v.Om(k) := gfMult(Head_v.Om(k), std_logic_vector(to_unsigned(ChienStep_c(k), M_c)), Poly_c);
                    end loop;

                    Upd_v.Fac := gfMult(Head_v.Fac, ForneyStep_c, Poly_c);
                    if r.OutGood = '1' then
                        v.Chain := r.Chain(1 to Depth_c - 1) & Upd_v;
                    end if;
                    -- The staging is free once all codewords of a good block have taken their entries
                    if r.OutGood = '1' and r.OutPos = Depth_c - 1 then
                        v.StgFull := '0';
                    end if;
                    v.Occ := v.Occ - 1;
                    -- Counters
                    if r.OutCw = Depth_c - 1 then
                        v.OutCw := 0;
                    else
                        v.OutCw := r.OutCw + 1;
                    end if;
                    if r.OutPos = r.OutLen - 1 then
                        -- Next block directly if it is ready, so that blocks follow without a gap
                        v.DescOut   := (r.DescOut + 1) mod DescDepth_c;
                        v.DescCount := v.DescCount - 1;
                        v.OutFsm    := Idle_s;
                        if v.DescCount > 0 and v.Desc(v.DescOut).Done = '1' then
                            v.OutFsm   := Run_s;
                            v.OutPos   := 0;
                            v.OutCw    := 0;
                            v.OutBase  := v.Desc(v.DescOut).Base;
                            v.OutLen   := v.Desc(v.DescOut).Len;
                            v.OutGood  := v.Desc(v.DescOut).Good;
                            v.ChkStart := v.Desc(v.DescOut).Len - minimum(v.Desc(v.DescOut).Len, Checks_c);
                        end if;
                    else
                        v.OutPos := r.OutPos + 1;
                    end if;
                end if;

            -- coverage off
            when others => v.OutFsm := Idle_s; -- unreachable code, safe recovery
            -- coverage on

        end case;

        RamRdEna <= '0';
        if Issue_v then
            RamRdEna <= '1';
        end if;
        RamRdAddr <= std_logic_vector(r.OutBase + r.OutPos);

        -- *** Pipeline ***
        if Adv_v then
            -- Stage 1: position issued, data read from the buffer
            v.S1.Valid := '0';
            if Issue_v then
                v.S1.Valid := '1';
                v.S1.Cw    := r.OutCw;
                v.S1.First := toStdl(r.OutPos < Depth_c);
                v.S1.Check := toStdl(r.OutPos >= r.ChkStart);
                v.S1.LastP := toStdl(r.OutPos = r.OutLen - 1);
                if OutputParity_g then
                    v.S1.Output := '1';
                    v.S1.LastO  := v.S1.LastP;
                else
                    v.S1.Output := toStdl(r.OutPos < r.ChkStart);
                    v.S1.LastO  := toStdl(r.OutPos = r.ChkStart - 1);
                end if;
                v.S1.Good   := r.OutGood;
                v.S1.Deg    := Head_v.Deg;
                v.S1.Fail   := Head_v.Fail;
                v.S1.SumL   := SumL_v;
                v.S1.SumOdd := SumOdd_v;
                v.S1.SumOm  := SumOm_v;
                v.S1.Fac    := Head_v.Fac;
            end if;
            -- Stage 2: Forney numerator and inverse of the denominator
            v.S2      := r.S1;
            v.S2.Data := RamRdData;
            v.S2.Prod := gfMult(r.S1.Fac, r.S1.SumOm, Poly_c);
            v.S2.Inv  := std_logic_vector(to_unsigned(InvTable_c(to_integer(unsigned(r.S1.SumOdd))), M_c));
            -- Stage 3: error value
            v.S3      := r.S2;
            v.S3.Prod := gfMult(r.S2.Prod, r.S2.Inv, Poly_c);
        end if;

        -- Stage 3 output: correction, counters, status
        Root_v    := r.S3.Valid = '1' and r.S3.Good = '1' and r.S3.Fail = '0' and unsigned(r.S3.SumL) = 0;
        Err_v     := r.S3.Prod;
        OutData_v := r.S3.Data;
        if Root_v then
            OutData_v := r.S3.Data xor gfMatMult(ToDual_c, Err_v);
        end if;

        PlInValid <= r.S3.Valid and r.S3.Output;
        PlInData  <= r.S3.LastO & r.S3.Check & OutData_v;

        Roots_v   := r.CwRoots;
        Changed_v := r.CwChanged;
        Deg_v     := r.CwDeg;
        Fail_v    := r.CwFail;
        Cw_v      := r.S3.Cw;
        if Adv_v and r.S3.Valid = '1' then
            -- The first position of a codeword starts its counters
            if r.S3.First = '1' then
                Roots_v(Cw_v)   := 0;
                Changed_v(Cw_v) := 0;
                Deg_v(Cw_v)     := r.S3.Deg;
                Fail_v(Cw_v)    := r.S3.Fail or not r.S3.Good;
            end if;
            if Root_v then
                if Roots_v(Cw_v) < T_c then
                    Roots_v(Cw_v) := Roots_v(Cw_v) + 1;
                else
                    Fail_v(Cw_v) := '1';
                end if;
                -- A multiple root gives the error value zero; the codeword fails through the root count
                if unsigned(Err_v) /= 0 and Changed_v(Cw_v) < T_c then
                    Changed_v(Cw_v) := Changed_v(Cw_v) + 1;
                end if;
            end if;
            v.CwRoots   := Roots_v;
            v.CwChanged := Changed_v;
            v.CwDeg     := Deg_v;
            v.CwFail    := Fail_v;
            if r.S3.Output = '1' and r.S3.LastO = '1' then
                v.Pushed := (r.Pushed + 1) mod 256;
            end if;
            -- Status of the block after its last position
            if r.S3.LastP = '1' then

                for c in 0 to Depth_c - 1 loop
                    if r.S3.Good = '0' then
                        v.Status(r.StWr).Uncorr(c) := '1';
                        v.Status(r.StWr).Corr(c)   := 0;
                    else
                        if Fail_v(c) = '1' or Roots_v(c) /= Deg_v(c) then
                            v.Status(r.StWr).Uncorr(c) := '1';
                        else
                            v.Status(r.StWr).Uncorr(c) := '0';
                        end if;
                        v.Status(r.StWr).Corr(c) := Changed_v(c);
                    end if;
                end loop;

                v.Status(r.StWr).Target := v.Pushed;
                v.StWr                  := 1 - r.StWr;
                v.StCount               := v.StCount + 1;
            end if;
        end if;

        -- *** Status: one pulse per codeword after the last output symbol of the block was accepted ***
        if PlOutValid = '1' and Out_Ready = '1' and PlOutData(M_c + 1) = '1' then
            v.Accepted := (r.Accepted + 1) mod 256;
        end if;
        v.StValid := '0';
        v.StLast  := '0';
        if r.StCount > 0 then
            Diff_v := (r.Accepted - r.Status(r.StRd).Target) mod 256;
            if Diff_v < 128 then
                v.StValid  := '1';
                v.StCorr   := r.Status(r.StRd).Corr(r.StEmit);
                v.StUncorr := r.Status(r.StRd).Uncorr(r.StEmit);
                if r.StEmit = Depth_c - 1 then
                    v.StLast  := '1';
                    v.StEmit  := 0;
                    v.StRd    := 1 - r.StRd;
                    v.StCount := v.StCount - 1;
                else
                    v.StEmit := r.StEmit + 1;
                end if;
            end if;
        end if;

        -- *** Assign to signal ***
        r_next <= v;

    end process;

    -- *** Outputs ***
    Status_Valid         <= r.StValid;
    Status_Last          <= r.StLast;
    Status_Corrected     <= std_logic_vector(to_unsigned(r.StCorr, CntBits_c));
    Status_Uncorrectable <= r.StUncorr;
    BlkValid             <= '1' when r.KesCount > 0 else '0';
    BlkGood              <= r.Desc(r.DescKes).Good;
    BlkScale             <= r.Desc(r.DescKes).Scale;
    BlkScaleJ0           <= r.Desc(r.DescKes).ScJ0;
    StgFree              <= not r.StgFull;

    -- *** Sequential Process ***
    p_seq : process (Clk) is
    begin
        if rising_edge(Clk) then
            r <= r_next;
            if Rst = '1' then
                r.InCount   <= 0;
                r.InSlot    <= 0;
                r.InBase    <= (others => '0');
                r.WrAddr    <= (others => '0');
                r.RunA      <= std_logic_vector(to_unsigned(1, M_c));
                r.RunB      <= std_logic_vector(to_unsigned(1, M_c));
                r.Occ       <= 0;
                r.DescWr    <= 0;
                r.DescKes   <= 0;
                r.DescOut   <= 0;
                r.DescCount <= 0;
                r.KesCount  <= 0;
                r.StgFull   <= '0';
                r.OutFsm    <= Idle_s;
                r.S1.Valid  <= '0';
                r.S2.Valid  <= '0';
                r.S3.Valid  <= '0';
                r.StWr      <= 0;
                r.StRd      <= 0;
                r.StCount   <= 0;
                r.StEmit    <= 0;
                r.Pushed    <= 0;
                r.Accepted  <= 0;
                r.StValid   <= '0';
                r.StLast    <= '0';
            end if;
        end if;
    end process;

    -- *** Staging registers (written by the key equation solver) ***
    p_stg : process (Clk) is
    begin
        if rising_edge(Clk) then
            if StgWrite = '1' then

                for k in 0 to T_c loop
                    StgL(StgIndex)(k) <= StgLambda((k + 1) * M_c - 1 downto k * M_c);
                end loop;

                for k in 0 to T_c - 1 loop
                    StgO(StgIndex)(k) <= StgOmega((k + 1) * M_c - 1 downto k * M_c);
                end loop;

                StgD(StgIndex) <= StgDeg;
                StgF(StgIndex) <= StgFail;
            end if;
        end if;
    end process;

    -----------------------------------------------------------------------------------------------
    -- Instantiations
    -----------------------------------------------------------------------------------------------
    -- Buffer of the received symbols
    i_buffer : entity work.olo_base_ram_sdp
        generic map (
            Depth_g       => RamDepth_c,
            Width_g       => M_c,
            RamStyle_g    => RamStyle_g,
            RamBehavior_g => RamBehavior_g
        )
        port map (
            Clk     => Clk,
            Wr_Addr => std_logic_vector(r.WrAddr),
            Wr_Ena  => RamWrEna,
            Wr_Data => In_Data,
            Rd_Addr => RamRdAddr,
            Rd_Ena  => RamRdEna,
            Rd_Data => RamRdData
        );

    -- Syndromes
    i_syndrome : component olo_private_rs_dec_syndrome
        generic map (
            FieldPolynomial_g => Poly_c,
            Roots_g           => Roots_c,
            J0_g              => J0_c,
            RootStep_g        => RootStep_g,
            InterleaveDepth_g => Depth_c
        )
        port map (
            Clk       => Clk,
            Rst       => Rst,
            In_Ready  => SynInReady,
            In_Valid  => SynInValid,
            In_Data   => SynInData,
            In_End    => SynInEnd,
            Out_Valid => SynValid,
            Out_Data  => SynData,
            Out_Next  => SynNext
        );

    -- Key equation solver
    i_kes : component olo_private_rs_dec_kes
        generic map (
            FieldPolynomial_g => Poly_c,
            T_g               => T_c,
            InterleaveDepth_g => Depth_c
        )
        port map (
            Clk         => Clk,
            Rst         => Rst,
            Syn_Valid   => SynValid,
            Syn_Data    => SynData,
            Syn_Next    => SynNext,
            Blk_Valid   => BlkValid,
            Blk_Good    => BlkGood,
            Blk_Scale   => BlkScale,
            Blk_ScaleJ0 => BlkScaleJ0,
            Blk_Done    => BlkDone,
            Stg_Free    => StgFree,
            Stg_Write   => StgWrite,
            Stg_Index   => StgIndex,
            Stg_Lambda  => StgLambda,
            Stg_Omega   => StgOmega,
            Stg_Deg     => StgDeg,
            Stg_Fail    => StgFail
        );

    -- Output register (registered ready for the correction pipeline)
    i_out : entity work.olo_base_pl_stage
        generic map (
            Width_g => M_c + 2
        )
        port map (
            Clk       => Clk,
            Rst       => Rst,
            In_Valid  => PlInValid,
            In_Ready  => PlInReady,
            In_Data   => PlInData,
            Out_Valid => PlOutValid,
            Out_Ready => Out_Ready,
            Out_Data  => PlOutData
        );

    Out_Valid  <= PlOutValid;
    Out_Data   <= PlOutData(M_c - 1 downto 0);
    Out_Parity <= PlOutData(M_c);
    Out_Last   <= PlOutData(M_c + 1);

end architecture;

---------------------------------------------------------------------------------------------------
-- Syndrome Entity
---------------------------------------------------------------------------------------------------
-- Syndromes S_i = r(beta^(j0+i)) of the I codewords of a block by Horner's rule, in two chains: one
-- receives a block while the key equation solver takes the other codeword by codeword.
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library work;
    use work.olo_base_pkg_array.all;
    use work.olo_base_pkg_gf.all;

entity olo_private_rs_dec_syndrome is
    generic (
        FieldPolynomial_g : std_logic_vector;
        Roots_g           : positive;
        J0_g              : natural;
        RootStep_g        : positive;
        InterleaveDepth_g : positive
    );
    port (
        Clk       : in    std_logic;
        Rst       : in    std_logic;
        -- Received symbols (polynomial basis), In_End with the last symbol of a block
        In_Ready  : out   std_logic;
        In_Valid  : in    std_logic;
        In_Data   : in    std_logic_vector(FieldPolynomial_g'length - 1 downto 0);
        In_End    : in    std_logic;
        -- Syndromes of the next codeword of the oldest complete block (S_0 in the low bits)
        Out_Valid : out   std_logic;
        Out_Data  : out   std_logic_vector(Roots_g * FieldPolynomial_g'length - 1 downto 0);
        Out_Next  : in    std_logic
    );
end entity;

architecture rtl of olo_private_rs_dec_syndrome is

    -- *** Constants ***
    constant M_c     : positive                           := FieldPolynomial_g'length;
    constant Poly_c  : std_logic_vector(M_c - 1 downto 0) := FieldPolynomial_g;
    constant Order_c : positive                           := 2**M_c - 1;
    constant Depth_c : positive                           := InterleaveDepth_g;

    -- *** Types ***
    subtype Syndromes_t is std_logic_vector(Roots_g * M_c - 1 downto 0);

    type Chain_t is array (0 to Depth_c - 1) of Syndromes_t;

    type Chains_t is array (0 to 1) of Chain_t;

    type Fsm_t is (Flush_s, Run_s);

    -- Roots beta^(j0+i) = alpha^(gamma (j0+i)) of the syndromes
    function syndromeRoots return IntegerArray_t is
        variable R_v : IntegerArray_t(0 to Roots_g - 1);
    begin

        for i in 0 to Roots_g - 1 loop
            R_v(i) := gfAlphaPowInt((RootStep_g mod Order_c) * ((J0_g + i) mod Order_c), Poly_c);
        end loop;

        return R_v;
    end function;

    constant Root_c : IntegerArray_t(0 to Roots_g - 1) := syndromeRoots;

    -- *** Two Process Record ***
    type TwoProcess_r is record
        Fsm    : Fsm_t;
        Chains : Chains_t;
        Act    : natural range 0 to 1;
        Cons   : natural range 0 to 1;
        Pend   : std_logic_vector(0 to 1);
        Taken  : natural range 0 to Depth_c - 1;
        Steps  : natural range 0 to Depth_c;
    end record;

    signal r, r_next : TwoProcess_r;

begin

    -- *** Combinatorial Process ***
    p_comb : process (all) is
        variable v      : TwoProcess_r;
        variable Head_v : Syndromes_t;
        variable S_v    : std_logic_vector(M_c - 1 downto 0);
    begin
        -- *** Keep two process variables stable ***
        v := r;

        case r.Fsm is

            -- Clear both chains after reset
            when Flush_s =>

                for c in 0 to 1 loop
                    v.Chains(c) := r.Chains(c)(1 to Depth_c - 1) & Syndromes_t'(others => '0');
                end loop;

                if r.Steps > 1 then
                    v.Steps := r.Steps - 1;
                else
                    v.Fsm := Run_s;
                end if;

            when Run_s =>
                -- Horner step S_i := S_i * beta^(j0+i) + r for the codeword of the received symbol
                if In_Valid = '1' then

                    for i in 0 to Roots_g - 1 loop
                        S_v                                      := r.Chains(r.Act)(0)((i + 1) * M_c - 1 downto i * M_c);
                        S_v                                      := gfMult(S_v, std_logic_vector(to_unsigned(Root_c(i), M_c)), Poly_c);
                        Head_v((i + 1) * M_c - 1 downto i * M_c) := S_v xor In_Data;
                    end loop;

                    v.Chains(r.Act) := r.Chains(r.Act)(1 to Depth_c - 1) & Head_v;
                    if In_End = '1' then
                        v.Pend(r.Act) := '1';
                        v.Act         := 1 - r.Act;
                    end if;
                end if;
                -- The key equation solver takes a codeword: clear it and move on. After the last codeword the
                -- chain is all zero, whatever the length of the block was, and receives the block after next.
                if r.Pend(r.Cons) = '1' and Out_Next = '1' then
                    v.Chains(r.Cons) := r.Chains(r.Cons)(1 to Depth_c - 1) & Syndromes_t'(others => '0');
                    if r.Taken = Depth_c - 1 then
                        v.Pend(r.Cons) := '0';
                        v.Cons         := 1 - r.Cons;
                        v.Taken        := 0;
                    else
                        v.Taken := r.Taken + 1;
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
    In_Ready  <= '1' when r.Fsm = Run_s and r.Pend(r.Act) = '0' else '0';
    Out_Valid <= '1' when r.Fsm = Run_s and r.Pend(r.Cons) = '1' else '0';
    Out_Data  <= r.Chains(r.Cons)(0);

    -- *** Sequential Process ***
    p_seq : process (Clk) is
    begin
        if rising_edge(Clk) then
            r <= r_next;
            if Rst = '1' then
                r.Fsm   <= Flush_s;
                r.Steps <= Depth_c;
                r.Act   <= 0;
                r.Cons  <= 0;
                r.Pend  <= "00";
                r.Taken <= 0;
            end if;
        end if;
    end process;

end architecture;

---------------------------------------------------------------------------------------------------
-- Key Equation Solver Entity
---------------------------------------------------------------------------------------------------
-- Scales the syndromes of each codeword to its transmitted length (S'_i = S_i f^(j0+i)) and solves the
-- key equation with the reformulated inversionless Berlekamp-Massey algorithm (RiBM, one iteration per
-- clock cycle, 2t iterations per codeword).
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library work;
    use work.olo_base_pkg_gf.all;

entity olo_private_rs_dec_kes is
    generic (
        FieldPolynomial_g : std_logic_vector;
        T_g               : positive;
        InterleaveDepth_g : positive
    );
    port (
        Clk         : in    std_logic;
        Rst         : in    std_logic;
        -- Syndromes of the codewords of the block
        Syn_Valid   : in    std_logic;
        Syn_Data    : in    std_logic_vector(2 * T_g * FieldPolynomial_g'length - 1 downto 0);
        Syn_Next    : out   std_logic;
        -- Block
        Blk_Valid   : in    std_logic;
        Blk_Good    : in    std_logic;
        Blk_Scale   : in    std_logic_vector(FieldPolynomial_g'length - 1 downto 0);
        Blk_ScaleJ0 : in    std_logic_vector(FieldPolynomial_g'length - 1 downto 0);
        Blk_Done    : out   std_logic;
        -- Results, one per codeword
        Stg_Free    : in    std_logic;
        Stg_Write   : out   std_logic;
        Stg_Index   : out   natural range 0 to InterleaveDepth_g - 1;
        Stg_Lambda  : out   std_logic_vector((T_g + 1) * FieldPolynomial_g'length - 1 downto 0);
        Stg_Omega   : out   std_logic_vector(T_g * FieldPolynomial_g'length - 1 downto 0);
        Stg_Deg     : out   natural range 0 to T_g;
        Stg_Fail    : out   std_logic
    );
end entity;

architecture rtl of olo_private_rs_dec_kes is

    -- *** Constants ***
    constant M_c     : positive                           := FieldPolynomial_g'length;
    constant Poly_c  : std_logic_vector(M_c - 1 downto 0) := FieldPolynomial_g;
    constant Depth_c : positive                           := InterleaveDepth_g;
    constant One_c   : std_logic_vector(M_c - 1 downto 0) := std_logic_vector(to_unsigned(1, M_c));

    -- *** Types ***
    subtype Symbol_t is std_logic_vector(M_c - 1 downto 0);

    type Syndromes_t is array (0 to 2 * T_g - 1) of Symbol_t;

    type Pe_t is array (0 to 3 * T_g + 1) of Symbol_t;

    type BlkFsm_t is (Idle_s, Scale_s, Skip_s, Wait_s);

    type RiFsm_t is (Idle_s, Run_s, Out_s);

    -- *** Two Process Record ***
    type TwoProcess_r is record
        BlkFsm : BlkFsm_t;
        ScCw   : natural range 0 to Depth_c - 1;
        ScIdx  : natural range 0 to 2 * T_g - 1;
        ScFac  : Symbol_t;
        Buf    : Syndromes_t;
        BufOk  : std_logic;
        BufCw  : natural range 0 to Depth_c - 1;
        Skip   : natural range 0 to Depth_c;
        RiFsm  : RiFsm_t;
        Delta  : Pe_t;
        Theta  : Pe_t;
        Gam    : Symbol_t;
        K      : integer range -(2 * T_g + 2) to 2 * T_g + 2;
        Iter   : natural range 0 to 2 * T_g;
        RiCw   : natural range 0 to Depth_c - 1;
        SynNxt : std_logic;
        Done   : std_logic;
        StgWr  : std_logic;
        StgIdx : natural range 0 to Depth_c - 1;
        StgL   : std_logic_vector((T_g + 1) * M_c - 1 downto 0);
        StgO   : std_logic_vector(T_g * M_c - 1 downto 0);
        StgDeg : natural range 0 to T_g;
        StgF   : std_logic;
    end record;

    signal r, r_next : TwoProcess_r;

begin

    -- *** Combinatorial Process ***
    p_comb : process (all) is
        variable v     : TwoProcess_r;
        variable D0_v  : Symbol_t;
        variable Deg_v : natural range 0 to T_g;
        variable Len_v : integer range -(2 * T_g + 2) to 2 * T_g + 2;
        variable Syn_v : Syndromes_t;
    begin
        -- *** Keep two process variables stable ***
        v := r;

        v.SynNxt := '0';
        v.Done   := '0';
        v.StgWr  := '0';

        -- *** Block sequencer and syndrome scaling ***
        case r.BlkFsm is

            when Idle_s =>
                if Blk_Valid = '1' and Syn_Valid = '1' and r.Done = '0' then
                    if Blk_Good = '0' then
                        v.BlkFsm := Skip_s;
                        v.Skip   := 0;
                    elsif Stg_Free = '1' then
                        v.BlkFsm := Scale_s;
                        v.ScCw   := 0;
                        v.ScIdx  := 0;
                        v.ScFac  := Blk_ScaleJ0;
                    end if;
                end if;

            -- S'_i = S_i * f^(j0+i), one syndrome per cycle
            when Scale_s =>
                if r.BufOk = '0' and r.SynNxt = '0' and Syn_Valid = '1' then

                    for i in 0 to 2 * T_g - 1 loop
                        Syn_v(i) := Syn_Data((i + 1) * M_c - 1 downto i * M_c);
                    end loop;

                    v.Buf(r.ScIdx) := gfMult(Syn_v(r.ScIdx), r.ScFac, Poly_c);
                    v.ScFac        := gfMult(r.ScFac, Blk_Scale, Poly_c);
                    if r.ScIdx = 2 * T_g - 1 then
                        v.ScIdx  := 0;
                        v.ScFac  := Blk_ScaleJ0;
                        v.BufOk  := '1';
                        v.BufCw  := r.ScCw;
                        v.SynNxt := '1';
                        if r.ScCw = Depth_c - 1 then
                            v.BlkFsm := Wait_s;
                        else
                            v.ScCw := r.ScCw + 1;
                        end if;
                    else
                        v.ScIdx := r.ScIdx + 1;
                    end if;
                end if;

            -- Block without decoding: take the syndromes of all codewords
            when Skip_s =>
                if r.Skip = Depth_c then
                    v.Done   := '1';
                    v.BlkFsm := Idle_s;
                elsif r.SynNxt = '0' and Syn_Valid = '1' then
                    v.SynNxt := '1';
                    v.Skip   := r.Skip + 1;
                end if;

            -- Wait until the last codeword is solved
            when Wait_s =>
                if r.RiFsm = Out_s and r.RiCw = Depth_c - 1 then
                    v.Done   := '1';
                    v.BlkFsm := Idle_s;
                end if;

            -- coverage off
            when others => v.BlkFsm := Idle_s; -- unreachable code, safe recovery
            -- coverage on

        end case;

        -- *** RiBM ***
        case r.RiFsm is

            when Idle_s =>
                if r.BufOk = '1' then

                    for i in 0 to 3 * T_g + 1 loop
                        if i < 2 * T_g then
                            v.Delta(i) := r.Buf(i);
                        elsif i = 3 * T_g then
                            v.Delta(i) := One_c;
                        else
                            v.Delta(i) := (others => '0');
                        end if;
                    end loop;

                    v.Theta := v.Delta;
                    v.Gam   := One_c;
                    v.K     := 0;
                    v.Iter  := 0;
                    v.RiCw  := r.BufCw;
                    v.BufOk := '0';
                    v.RiFsm := Run_s;
                end if;

            when Run_s =>
                D0_v := r.Delta(0);

                for i in 0 to 3 * T_g loop
                    v.Delta(i) := gfMult(r.Gam, r.Delta(i + 1), Poly_c) xor gfMult(D0_v, r.Theta(i), Poly_c);
                end loop;

                v.Delta(3 * T_g + 1) := (others => '0');
                if unsigned(D0_v) /= 0 and r.K >= 0 then

                    for i in 0 to 3 * T_g loop
                        v.Theta(i) := r.Delta(i + 1);
                    end loop;

                    v.Theta(3 * T_g + 1) := (others => '0');
                    v.Gam                := D0_v;
                    v.K                  := -r.K - 1;
                else
                    v.K := r.K + 1;
                end if;
                if r.Iter = 2 * T_g - 1 then
                    v.RiFsm := Out_s;
                else
                    v.Iter := r.Iter + 1;
                end if;

            -- Locator lambda_i = delta_(t+i), evaluator omega_i = delta_i, register length L = t - k/2
            when Out_s =>
                Deg_v := 0;

                for i in 0 to T_g loop
                    v.StgL((i + 1) * M_c - 1 downto i * M_c) := r.Delta(T_g + i);
                    if unsigned(r.Delta(T_g + i)) /= 0 then
                        Deg_v := i;
                    end if;
                end loop;

                for i in 0 to T_g - 1 loop
                    v.StgO((i + 1) * M_c - 1 downto i * M_c) := r.Delta(i);
                end loop;

                v.StgDeg := Deg_v;
                v.StgF   := '0';
                if r.K < 0 then
                    v.StgF := '1';
                else
                    Len_v := T_g - r.K / 2;
                    if Len_v /= Deg_v then
                        v.StgF := '1';
                    end if;
                end if;
                v.StgWr  := '1';
                v.StgIdx := r.RiCw;
                v.RiFsm  := Idle_s;

            -- coverage off
            when others => v.RiFsm := Idle_s; -- unreachable code, safe recovery
            -- coverage on

        end case;

        -- *** Assign to signal ***
        r_next <= v;

    end process;

    -- *** Outputs ***
    Syn_Next   <= r.SynNxt;
    Blk_Done   <= r.Done;
    Stg_Write  <= r.StgWr;
    Stg_Index  <= r.StgIdx;
    Stg_Lambda <= r.StgL;
    Stg_Omega  <= r.StgO;
    Stg_Deg    <= r.StgDeg;
    Stg_Fail   <= r.StgF;

    -- *** Sequential Process ***
    p_seq : process (Clk) is
    begin
        if rising_edge(Clk) then
            r <= r_next;
            if Rst = '1' then
                r.BlkFsm <= Idle_s;
                r.BufOk  <= '0';
                r.RiFsm  <= Idle_s;
                r.SynNxt <= '0';
                r.Done   <= '0';
                r.StgWr  <= '0';
            end if;
        end if;
    end process;

end architecture;
