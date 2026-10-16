---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Package with Galois field GF(2^m) arithmetic for codes such as Reed-Solomon. Elements are vectors in the
-- polynomial basis, tables and code polynomials are built at elaboration.
--
-- Documentation:
-- https://github.com/open-logic/open-logic/blob/main/doc/base/olo_base_pkg_gf.md
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

---------------------------------------------------------------------------------------------------
-- Package Header
---------------------------------------------------------------------------------------------------
-- Field elements are std_logic_vector(m-1 downto 0) in the polynomial basis: bit i is the coefficient of alpha^i,
-- alpha being a root of the field polynomial. The field polynomial is passed as fieldPolynomial: its m low
-- coefficients, the coefficient of x^m is implicit (x^8 + x^7 + x^2 + x + 1 is x"87"); m is its length.
-- The functions ending in Int work on element values as naturals and are meant for elaboration (constants).
package olo_base_pkg_gf is

    -- *** Arithmetic on vectors (synthesizable) ***
    -- Product a * b. With one constant operand synthesis reduces it to an XOR network.
    function gfMult (
        a               : std_logic_vector;
        b               : std_logic_vector;
        fieldPolynomial : std_logic_vector) return std_logic_vector;

    -- alpha^e for any integer e
    function gfAlphaPow (
        e               : integer;
        fieldPolynomial : std_logic_vector) return std_logic_vector;

    -- a^e for e >= 0 (square and multiply)
    function gfPow (
        a               : std_logic_vector;
        e               : natural;
        fieldPolynomial : std_logic_vector) return std_logic_vector;

    -- Multiplicative inverse a^(2^m-2); the inverse of zero is returned as zero
    function gfInv (
        a               : std_logic_vector;
        fieldPolynomial : std_logic_vector) return std_logic_vector;

    -- Product of a constant GF(2) matrix and a vector: XOR of matrix(i) over all bits i of x that are set
    function gfMatMult (
        matrix : IntegerArray_t;
        x      : std_logic_vector) return std_logic_vector;

    -- *** Arithmetic on element values (elaboration) ***
    function gfAddInt (
        a : natural;
        b : natural) return natural;

    function gfMultInt (
        a               : natural;
        b               : natural;
        fieldPolynomial : std_logic_vector) return natural;

    function gfAlphaPowInt (
        e               : integer;
        fieldPolynomial : std_logic_vector) return natural;

    -- a^e for any integer e (0^0 = 1; a negative power of zero is returned as zero)
    function gfPowInt (
        a               : natural;
        e               : integer;
        fieldPolynomial : std_logic_vector) return natural;

    -- The inverse of zero is returned as zero
    function gfInvInt (
        a               : natural;
        fieldPolynomial : std_logic_vector) return natural;

    -- Discrete logarithm to the base alpha; the logarithm of zero is returned as zero
    function gfLogInt (
        a               : natural;
        fieldPolynomial : std_logic_vector) return natural;

    -- Trace a + a^2 + a^4 + ... + a^(2^(m-1)), 0 or 1
    function gfTraceInt (
        a               : natural;
        fieldPolynomial : std_logic_vector) return natural;

    -- True if alpha generates all 2^m - 1 non-zero elements
    function gfIsPrimitive (
        fieldPolynomial : std_logic_vector) return boolean;

    -- *** Tables (elaboration, for ROMs and constants) ***
    -- alpha^i for i = 0 ... 2^m - 2
    function gfAntilogTable (
        fieldPolynomial : std_logic_vector) return IntegerArray_t;

    -- log(a) for a = 0 ... 2^m - 1 (entry 0 is zero)
    function gfLogTable (
        fieldPolynomial : std_logic_vector) return IntegerArray_t;

    -- Inverse of a for a = 0 ... 2^m - 1 (entry 0 is zero)
    function gfInvTable (
        fieldPolynomial : std_logic_vector) return IntegerArray_t;

    -- Reed-Solomon generator g(x) = prod_{i=0}^{roots-1} (x + alpha^(firstRoot + i*rootStep)),
    -- coefficients g_0 ... g_roots (g_roots = 1)
    function gfRsGenerator (
        fieldPolynomial : std_logic_vector;
        roots           : positive;
        firstRoot       : natural;
        rootStep        : positive) return IntegerArray_t;

    -- Conversion from the polynomial basis to the dual basis of (1, b, b^2, ..., b^(m-1)), b = alpha^exponent:
    -- entry i is the dual basis value of alpha^i, with z_0 as the most significant bit (z_j = Tr(u * b^j)).
    -- Use with gfMatMult. CCSDS 131.0-B-5 4.3.9 uses exponent 117 with x"87".
    function gfDualBasisMatrix (
        fieldPolynomial : std_logic_vector;
        exponent        : positive) return IntegerArray_t;

    -- Conversion from the dual basis back to the polynomial basis (inverse of gfDualBasisMatrix)
    function gfDualBasisMatrixInv (
        fieldPolynomial : std_logic_vector;
        exponent        : positive) return IntegerArray_t;

end package;

---------------------------------------------------------------------------------------------------
-- Package Body
---------------------------------------------------------------------------------------------------
package body olo_base_pkg_gf is

    -- *** Arithmetic on vectors ***
    function gfMult (
        a               : std_logic_vector;
        b               : std_logic_vector;
        fieldPolynomial : std_logic_vector) return std_logic_vector is
        constant M_c    : positive                           := fieldPolynomial'length;
        constant Poly_c : std_logic_vector(M_c - 1 downto 0) := fieldPolynomial;
        variable A_v    : std_logic_vector(M_c - 1 downto 0) := a;
        variable B_v    : std_logic_vector(M_c - 1 downto 0) := b;
        variable P_v    : std_logic_vector(M_c - 1 downto 0) := (others => '0');
        variable Msb_v  : std_logic;
    begin

        -- Shift and add over the bits of b, A_v = a * x^i mod F(x)
        for i in 0 to M_c - 1 loop
            P_v   := P_v xor (A_v and (A_v'range => B_v(i)));
            Msb_v := A_v(M_c - 1);
            A_v   := (A_v(M_c - 2 downto 0) & '0') xor (Poly_c and (Poly_c'range => Msb_v));
        end loop;

        return P_v;
    end function;

    function gfAlphaPow (
        e               : integer;
        fieldPolynomial : std_logic_vector) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned(gfAlphaPowInt(e, fieldPolynomial), fieldPolynomial'length));
    end function;

    function gfPow (
        a               : std_logic_vector;
        e               : natural;
        fieldPolynomial : std_logic_vector) return std_logic_vector is
        constant M_c : positive                           := fieldPolynomial'length;
        variable R_v : std_logic_vector(M_c - 1 downto 0) := std_logic_vector(to_unsigned(1, M_c));
        variable S_v : std_logic_vector(M_c - 1 downto 0) := a;
        variable E_v : natural                            := e;
    begin

        while E_v > 0 loop
            if E_v mod 2 = 1 then
                R_v := gfMult(R_v, S_v, fieldPolynomial);
            end if;
            S_v := gfMult(S_v, S_v, fieldPolynomial);
            E_v := E_v / 2;
        end loop;

        return R_v;
    end function;

    function gfInv (
        a               : std_logic_vector;
        fieldPolynomial : std_logic_vector) return std_logic_vector is
    begin
        return gfPow(a, 2**fieldPolynomial'length - 2, fieldPolynomial);
    end function;

    function gfMatMult (
        matrix : IntegerArray_t;
        x      : std_logic_vector) return std_logic_vector is
        constant M_c : positive                           := x'length;
        constant X_c : std_logic_vector(M_c - 1 downto 0) := x;
        variable R_v : std_logic_vector(M_c - 1 downto 0) := (others => '0');
    begin

        for i in 0 to M_c - 1 loop
            R_v := R_v xor (std_logic_vector(to_unsigned(matrix(matrix'low + i), M_c)) and (R_v'range => X_c(i)));
        end loop;

        return R_v;
    end function;

    -- *** Arithmetic on element values ***
    function gfAddInt (
        a : natural;
        b : natural) return natural is
        constant Bits_c : positive := 31;
    begin
        return to_integer(to_unsigned(a, Bits_c) xor to_unsigned(b, Bits_c));
    end function;

    function gfMultInt (
        a               : natural;
        b               : natural;
        fieldPolynomial : std_logic_vector) return natural is
        constant M_c : positive := fieldPolynomial'length;
    begin
        return to_integer(unsigned(gfMult(std_logic_vector(to_unsigned(a, M_c)),
                                          std_logic_vector(to_unsigned(b, M_c)), fieldPolynomial)));
    end function;

    function gfAlphaPowInt (
        e               : integer;
        fieldPolynomial : std_logic_vector) return natural is
        constant Order_c : positive := 2**fieldPolynomial'length - 1;
        variable R_v     : natural  := 1;
    begin

        for i in 1 to e mod Order_c loop
            R_v := gfMultInt(R_v, 2, fieldPolynomial);
        end loop;

        return R_v;
    end function;

    function gfPowInt (
        a               : natural;
        e               : integer;
        fieldPolynomial : std_logic_vector) return natural is
        constant Order_c : positive := 2**fieldPolynomial'length - 1;
    begin
        if a = 0 then
            if e = 0 then
                return 1;
            end if;
            return 0;
        end if;
        return gfAlphaPowInt((gfLogInt(a, fieldPolynomial) * (e mod Order_c)) mod Order_c, fieldPolynomial);
    end function;

    function gfInvInt (
        a               : natural;
        fieldPolynomial : std_logic_vector) return natural is
    begin
        if a = 0 then
            return 0;
        end if;
        return gfPowInt(a, -1, fieldPolynomial);
    end function;

    function gfLogInt (
        a               : natural;
        fieldPolynomial : std_logic_vector) return natural is
        constant Order_c : positive := 2**fieldPolynomial'length - 1;
        variable X_v     : natural  := 1;
    begin

        for i in 0 to Order_c - 1 loop
            if X_v = a then
                return i;
            end if;
            X_v := gfMultInt(X_v, 2, fieldPolynomial);
        end loop;

        return 0;
    end function;

    function gfTraceInt (
        a               : natural;
        fieldPolynomial : std_logic_vector) return natural is
        variable T_v : natural := 0;
        variable Y_v : natural := a;
    begin

        for i in 0 to fieldPolynomial'length - 1 loop
            T_v := gfAddInt(T_v, Y_v);
            Y_v := gfMultInt(Y_v, Y_v, fieldPolynomial);
        end loop;

        return T_v;
    end function;

    function gfIsPrimitive (
        fieldPolynomial : std_logic_vector) return boolean is
        constant Order_c : positive := 2**fieldPolynomial'length - 1;
        variable X_v     : natural  := 1;
    begin

        for i in 1 to Order_c loop
            X_v := gfMultInt(X_v, 2, fieldPolynomial);
            if X_v = 1 then
                return i = Order_c;
            end if;
        end loop;

        return false;
    end function;

    -- *** Tables ***
    function gfAntilogTable (
        fieldPolynomial : std_logic_vector) return IntegerArray_t is
        constant Order_c : positive := 2**fieldPolynomial'length - 1;
        variable T_v     : IntegerArray_t(0 to Order_c - 1);
    begin
        T_v(0) := 1;

        for i in 1 to Order_c - 1 loop
            T_v(i) := gfMultInt(T_v(i - 1), 2, fieldPolynomial);
        end loop;

        return T_v;
    end function;

    function gfLogTable (
        fieldPolynomial : std_logic_vector) return IntegerArray_t is
        constant Order_c   : positive                         := 2**fieldPolynomial'length - 1;
        constant Antilog_c : IntegerArray_t(0 to Order_c - 1) := gfAntilogTable(fieldPolynomial);
        variable T_v       : IntegerArray_t(0 to Order_c)     := (others => 0);
    begin

        for i in 0 to Order_c - 1 loop
            T_v(Antilog_c(i)) := i;
        end loop;

        return T_v;
    end function;

    function gfInvTable (
        fieldPolynomial : std_logic_vector) return IntegerArray_t is
        constant Order_c   : positive                         := 2**fieldPolynomial'length - 1;
        constant Antilog_c : IntegerArray_t(0 to Order_c - 1) := gfAntilogTable(fieldPolynomial);
        variable T_v       : IntegerArray_t(0 to Order_c)     := (others => 0);
    begin

        for i in 0 to Order_c - 1 loop
            T_v(Antilog_c(i)) := Antilog_c((Order_c - i) mod Order_c);
        end loop;

        return T_v;
    end function;

    function gfRsGenerator (
        fieldPolynomial : std_logic_vector;
        roots           : positive;
        firstRoot       : natural;
        rootStep        : positive) return IntegerArray_t is
        variable G_v    : IntegerArray_t(0 to roots) := (0 => 1, others => 0);
        variable Root_v : natural;
    begin

        -- Multiply by (x + root) for every root, the degree grows by one per step
        for i in 0 to roots - 1 loop
            Root_v := gfAlphaPowInt(firstRoot + i * rootStep, fieldPolynomial);

            for j in i + 1 downto 1 loop
                G_v(j) := gfAddInt(G_v(j - 1), gfMultInt(G_v(j), Root_v, fieldPolynomial));
            end loop;

            G_v(0) := gfMultInt(G_v(0), Root_v, fieldPolynomial);
        end loop;

        return G_v;
    end function;

    function gfDualBasisMatrix (
        fieldPolynomial : std_logic_vector;
        exponent        : positive) return IntegerArray_t is
        constant M_c  : positive := fieldPolynomial'length;
        constant B_c  : natural  := gfAlphaPowInt(exponent, fieldPolynomial);
        variable T_v  : IntegerArray_t(0 to M_c - 1);
        variable Ai_v : natural  := 1;
        variable Bj_v : natural;
        variable Z_v  : natural;
    begin

        for i in 0 to M_c - 1 loop
            Z_v  := 0;
            Bj_v := 1;

            for j in 0 to M_c - 1 loop
                Z_v  := 2 * Z_v + gfTraceInt(gfMultInt(Ai_v, Bj_v, fieldPolynomial), fieldPolynomial);
                Bj_v := gfMultInt(Bj_v, B_c, fieldPolynomial);
            end loop;

            T_v(i) := Z_v;
            Ai_v   := gfMultInt(Ai_v, 2, fieldPolynomial);
        end loop;

        return T_v;
    end function;

    function gfDualBasisMatrixInv (
        fieldPolynomial : std_logic_vector;
        exponent        : positive) return IntegerArray_t is
        constant M_c     : positive                     := fieldPolynomial'length;
        constant T_c     : IntegerArray_t(0 to M_c - 1) := gfDualBasisMatrix(fieldPolynomial, exponent);
        variable Inv_v   : IntegerArray_t(0 to M_c - 1) := (others => 0);
        variable Found_v : boolean;
    begin

        -- Entry j is the polynomial basis value u with dual basis value 2^j
        for j in 0 to M_c - 1 loop
            Found_v := false;

            for u in 0 to 2**M_c - 1 loop
                if not Found_v and
                   to_integer(unsigned(gfMatMult(T_c, std_logic_vector(to_unsigned(u, M_c))))) = 2**j then
                    Inv_v(j) := u;
                    Found_v  := true;
                end if;
            end loop;

            assert Found_v
                report "olo_base_pkg_gf: gfDualBasisMatrixInv: the powers of alpha^exponent are no basis"
                severity failure;
        end loop;

        return Inv_v;
    end function;

end package body;
