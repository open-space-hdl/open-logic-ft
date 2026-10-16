---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;
    use ieee.math_real.all;

library vunit_lib;
    context vunit_lib.vunit_context;

library olo;
    use olo.olo_base_pkg_array.all;
    use olo.olo_base_pkg_gf.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
-- vunit: run_all_in_same_sim
entity olo_base_pkg_gf_tb is
    generic (
        runner_cfg     : string
    );
end entity;

architecture sim of olo_base_pkg_gf_tb is

    -- Primitive field polynomials for m = 3 ... 12 (m low coefficients, x^m implicit)
    type PolyArray_t is array (3 to 12) of natural;

    constant Primitive_c : PolyArray_t := (16#3#, 16#3#, 16#5#, 16#3#, 16#3#, 16#1D#, 16#11#, 16#9#, 16#5#, 16#53#);

    -- CCSDS 131.0-B-5: field polynomial x^8 + x^7 + x^2 + x + 1 (4.3.3), generators (4.3.4), dual basis (4.3.9)
    constant Ccsds_c   : std_logic_vector(7 downto 0) := x"87";
    constant Antilog_c : IntegerArray_t               := gfAntilogTable(Ccsds_c);
    constant Log_c     : IntegerArray_t               := gfLogTable(Ccsds_c);
    constant Inv_c     : IntegerArray_t               := gfInvTable(Ccsds_c);
    constant Gen16_c   : IntegerArray_t               := gfRsGenerator(Ccsds_c, 32, 212, 11);
    constant Gen8_c    : IntegerArray_t               := gfRsGenerator(Ccsds_c, 16, 45, 11);
    constant Dual_c    : IntegerArray_t               := gfDualBasisMatrix(Ccsds_c, 117);
    constant DualInv_c : IntegerArray_t               := gfDualBasisMatrixInv(Ccsds_c, 117);

    -- Pseudo random element of GF(2^m)
    procedure randomElement (
        variable seed1 : inout positive;
        variable seed2 : inout positive;
        m              : in    positive;
        variable value : out   natural) is
        variable Rnd_v : real;
    begin
        uniform(seed1, seed2, Rnd_v);
        value := integer(floor(Rnd_v * real(2**m)));
    end procedure;

    -- Field axioms and the agreement of the vector and integer functions for one field
    procedure checkField (
        m              : in    positive;
        variable seed1 : inout positive;
        variable seed2 : inout positive) is
        constant P_c              : std_logic_vector(m - 1 downto 0) := std_logic_vector(to_unsigned(Primitive_c(m), m));
        variable A_v, B_v, C_v    : natural;
        variable Av_v, Bv_v, Cv_v : std_logic_vector(m - 1 downto 0);
    begin

        for i in 0 to 49 loop
            randomElement(seed1, seed2, m, A_v);
            randomElement(seed1, seed2, m, B_v);
            randomElement(seed1, seed2, m, C_v);
            Av_v := std_logic_vector(to_unsigned(A_v, m));
            Bv_v := std_logic_vector(to_unsigned(B_v, m));
            Cv_v := std_logic_vector(to_unsigned(C_v, m));
            check_equal(gfMult(Av_v, Bv_v, P_c), gfMult(Bv_v, Av_v, P_c), "commutative");
            check_equal(gfMult(gfMult(Av_v, Bv_v, P_c), Cv_v, P_c), gfMult(Av_v, gfMult(Bv_v, Cv_v, P_c), P_c),
                        "associative");
            check_equal(gfMult(Av_v, Bv_v xor Cv_v, P_c), gfMult(Av_v, Bv_v, P_c) xor gfMult(Av_v, Cv_v, P_c),
                        "distributive");
            check_equal(gfMultInt(A_v, B_v, P_c), to_integer(unsigned(gfMult(Av_v, Bv_v, P_c))), "integer form");
            check_equal(gfPow(Av_v, 5, P_c), std_logic_vector(to_unsigned(gfPowInt(A_v, 5, P_c), m)), "power");
            check_true(gfTraceInt(A_v, P_c) <= 1, "trace");
            if A_v /= 0 then
                check_equal(gfMult(Av_v, gfInv(Av_v, P_c), P_c), std_logic_vector(to_unsigned(1, m)), "inverse");
                check_equal(gfMultInt(A_v, gfInvInt(A_v, P_c), P_c), 1, "inverse integer");
                check_equal(gfAlphaPowInt(gfLogInt(A_v, P_c), P_c), A_v, "log");
                check_equal(gfPowInt(A_v, -2, P_c), gfMultInt(gfInvInt(A_v, P_c), gfInvInt(A_v, P_c), P_c),
                            "negative power");
            end if;
        end loop;

        check_true(gfIsPrimitive(P_c), "primitive m=" & integer'image(m));
    end procedure;

begin

    -----------------------------------------------------------------------------------------------
    -- TB Control
    -----------------------------------------------------------------------------------------------
    test_runner_watchdog(runner, 100 ms);

    p_control : process is
        variable Seed1_v, Seed2_v : positive := 1;
        variable Acc_v            : natural;
    begin
        test_runner_setup(runner, runner_cfg);

        wait for 1 ns;

        while test_suite loop

            if run("FieldAxioms") then

                for m in 3 to 12 loop
                    checkField(m, Seed1_v, Seed2_v);
                end loop;

                check_equal(gfPowInt(0, 0, Ccsds_c), 1, "0^0");
                check_equal(gfPowInt(0, 3, Ccsds_c), 0, "0^3");
                check_equal(gfInvInt(0, Ccsds_c), 0, "inverse of zero");
                check_equal(gfInv(x"00", Ccsds_c), std_logic_vector'(x"00"), "inverse of zero (vector)");
                check_equal(gfLogInt(0, Ccsds_c), 0, "log of zero");
                check_equal(gfAlphaPow(-1, Ccsds_c), gfInv(x"02", Ccsds_c), "alpha^-1");
                check_equal(gfAddInt(16#5A#, 16#0F#), 16#55#, "add");

            elsif run("Primitive") then
                check_true(gfIsPrimitive(Ccsds_c), "CCSDS polynomial");
                check_false(gfIsPrimitive(x"F"), "x^4 + x^3 + x^2 + x + 1 (order 5)");
                check_false(gfIsPrimitive(x"0"), "x^4 (reducible)");

            elsif run("Tables") then
                check_equal(Antilog_c'length, 255, "antilog length");
                check_equal(Log_c'length, 256, "log length");
                check_equal(Inv_c(0), 0, "inverse of zero");

                for a in 1 to 255 loop
                    check_equal(Antilog_c(Log_c(a)), a, "antilog(log(a))");
                    check_equal(gfMultInt(a, Inv_c(a), Ccsds_c), 1, "table inverse");
                end loop;

            elsif run("CcsdsGenerator") then
                -- Annex G: g(x) for E = 16 (roots alpha^(11 j), j = 112 ... 143) as powers of alpha, symmetric
                check_equal(Gen16_c(0), 1, "G0");
                check_equal(Gen16_c(32), 1, "G32");

                for i in 1 to 16 loop
                    check_equal(Gen16_c(i), Gen16_c(32 - i), "symmetric");
                end loop;

                check_equal(gfLogInt(Gen16_c(1), Ccsds_c), 249, "G1");
                check_equal(gfLogInt(Gen16_c(2), Ccsds_c), 59, "G2");
                check_equal(gfLogInt(Gen16_c(3), Ccsds_c), 66, "G3");
                check_equal(gfLogInt(Gen16_c(8), Ccsds_c), 97, "G8");
                check_equal(gfLogInt(Gen16_c(15), Ccsds_c), 5, "G15");
                check_equal(gfLogInt(Gen16_c(16), Ccsds_c), 24, "G16");
                -- Annex G: E = 8 (j = 120 ... 135)
                check_equal(gfLogInt(Gen8_c(1), Ccsds_c), 30, "E8 G1");
                check_equal(gfLogInt(Gen8_c(4), Ccsds_c), 235, "E8 G4");
                check_equal(gfLogInt(Gen8_c(8), Ccsds_c), 173, "E8 G8");
                check_equal(Gen8_c(16), 1, "E8 G16");

                -- Every root is a zero of g(x)
                for i in 0 to 31 loop
                    Acc_v := 0;

                    for j in 32 downto 0 loop
                        Acc_v := gfAddInt(gfMultInt(Acc_v, gfAlphaPowInt(212 + 11 * i, Ccsds_c), Ccsds_c), Gen16_c(j));
                    end loop;

                    check_equal(Acc_v, 0, "root " & integer'image(i));
                end loop;

            elsif run("CcsdsDualBasis") then
                -- 4.3.9.3: rows of T are the dual basis values of alpha^7 ... alpha^0
                check_equal(Dual_c(7), 2#10001101#, "alpha^7");
                check_equal(Dual_c(6), 2#11101111#, "alpha^6");
                check_equal(Dual_c(5), 2#11101100#, "alpha^5");
                check_equal(Dual_c(4), 2#10000110#, "alpha^4");
                check_equal(Dual_c(3), 2#11111010#, "alpha^3");
                check_equal(Dual_c(2), 2#10011001#, "alpha^2");
                check_equal(Dual_c(1), 2#10101111#, "alpha^1");
                check_equal(Dual_c(0), 2#01111011#, "alpha^0");
                -- 4.3.9.3: rows of T^-1 are the polynomial basis values of l0 ... l7 (l0 = MSB of the dual value)
                check_equal(DualInv_c(7), 2#11000101#, "l0");
                check_equal(DualInv_c(6), 2#01000010#, "l1");
                check_equal(DualInv_c(5), 2#00101110#, "l2");
                check_equal(DualInv_c(4), 2#11111101#, "l3");
                check_equal(DualInv_c(3), 2#11110000#, "l4");
                check_equal(DualInv_c(2), 2#01111001#, "l5");
                check_equal(DualInv_c(1), 2#10101100#, "l6");
                check_equal(DualInv_c(0), 2#11001100#, "l7");
                -- Annex F, F2: example 1 and 2
                check_equal(gfMatMult(DualInv_c, "10111001"), std_logic_vector'("00101010"), "example 1");
                check_equal(gfMatMult(Dual_c, "01011001"), std_logic_vector'("11101000"), "example 2");

                -- Round trip for all elements
                for u in 0 to 255 loop
                    check_equal(gfMatMult(DualInv_c, gfMatMult(Dual_c, std_logic_vector(to_unsigned(u, 8)))),
                                std_logic_vector(to_unsigned(u, 8)), "round trip");
                end loop;

            end if;

        end loop;

        -- TB done
        test_runner_cleanup(runner);
    end process;

end architecture;
