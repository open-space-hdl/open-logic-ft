# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2025 by Oliver Bründler
# Copyright (c) 2025 by Alexander Ruede
# Authors: Oliver Bruendler, Alexander Ruede
# ---------------------------------------------------------------------------------------------------

# ---------------------------------------------------------------------------------------------------
# Imports
# ---------------------------------------------------------------------------------------------------
from .utils import named_config
import importlib.util
import os


def load_cosim(tb_name):
    """cosim() of test/intf/<tb_name>/cosim.py (the test folders are no Python packages)"""
    path = os.path.join(os.path.dirname(__file__), '../../test/intf', tb_name, 'cosim.py')
    spec = importlib.util.spec_from_file_location(f'{tb_name}_cosim', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.cosim

# ---------------------------------------------------------------------------------------------------
# Functionality
# ---------------------------------------------------------------------------------------------------

def add_configs(olo_tb):
    """
    Add all intf testbench configurations to the VUnit Library
    :param olo_tb: Testbench library
    """

    ### olo_intf_can ###
    tb = olo_tb.test_bench('olo_intf_can_tb')
    cosim = load_cosim('olo_intf_can')
    # Bit timing: 10 time quanta (6 + 3, SJW 2) by default, SJW 1, 8 and 25 time quanta, one clock per time quantum
    # (also with the shortest PHASE_SEG2 of 2 quanta, 2 clock cycles after the sample point), and the timing for an
    # oscillator tolerance of 1.58 % (SJW 4, PHASE_SEG2 4) with a second node 1.5 % off
    named_config(tb, {}, pre_config=cosim, short_name='default')
    named_config(tb, {'Sjw_g': 1}, pre_config=cosim)
    named_config(tb, {'Prescaler_g': 5, 'Tseg1_g': 4, 'Tseg2_g': 3, 'Sjw_g': 2}, pre_config=cosim)
    named_config(tb, {'Prescaler_g': 2, 'Tseg1_g': 16, 'Tseg2_g': 8, 'Sjw_g': 4}, pre_config=cosim)
    named_config(tb, {'Prescaler_g': 1, 'Tseg1_g': 16, 'Tseg2_g': 8, 'Sjw_g': 4}, pre_config=cosim)
    named_config(tb, {'Prescaler_g': 1, 'Tseg1_g': 16, 'Tseg2_g': 2, 'Sjw_g': 2}, pre_config=cosim)
    for Offset in [15000, -15000]:
        named_config(tb, {'Tseg1_g': 5, 'Tseg2_g': 4, 'Sjw_g': 4, 'ClkBOffsetPpm_g': Offset}, pre_config=cosim)
    named_config(tb, {'AutoRecover_g': False}, pre_config=cosim)
    named_config(tb, {'SyncTmr_g': True}, pre_config=cosim)

    ### olo_intf_debounce ###
    debounce_tb = 'olo_intf_debounce_tb'
    tb = olo_tb.test_bench(debounce_tb)
    for IdleLevel in [0, 1]:
        for Mode in ["LOW_LATENCY", "GLITCH_FILTER"]:
            named_config(tb, {'IdleLevel_g': IdleLevel, 'Mode_g' : Mode})
    for Mode in ["LOW_LATENCY", "GLITCH_FILTER"]:
        #Cover ranges around 31/32 and 63/64 in detail (clock divider edge cases)
        for Cycles in [10, 30, 31, 32, 50, 60, 61, 62, 63, 64, 65, 100, 200, 735]:
            named_config(tb, {'DebounceCycles_g': Cycles, 'Mode_g': Mode})
        named_config(tb, {'Mode_g': Mode, 'SyncStages_g': 4})
        named_config(tb, {'Mode_g': Mode, 'SyncTmr_g': True})

    ### olo_intf_i2c_master ###
    i2c_master_tb = 'olo_intf_i2c_master_tb'
    tb = olo_tb.test_bench(i2c_master_tb)
    for BusFreq in [int(100e3), int(400e3), int(1e6)]:
        named_config(tb, {'BusFrequency_g': BusFreq})
    for IntTri in [True, False]:
        named_config(tb, {'InternalTriState_g': IntTri})
    # Clock Divider disabled
    named_config(tb, {'ClkDivBits_g': 0})
    # Clock Divider Enabled
    for ClkDiv_g in [0, 1, 2, 5]:
        named_config(tb, {'ClkDivBits_g': 8, 'ClkDiv_g': ClkDiv_g})
    # Synchronizer stages (the clock runs at 16 MHz, the minimum ratio is 4*(SyncStages_g+2))
    for Stages, BusFreq in [(3, int(800e3)), (4, int(500e3))]:
        named_config(tb, {'BusFrequency_g': BusFreq, 'SyncStages_g': Stages})
    for BusFreq in [int(100e3), int(1e6)]:
        named_config(tb, {'BusFrequency_g': BusFreq, 'SyncTmr_g': True})

    ### olo_intf_sync ###
    sync_tb = 'olo_intf_sync_tb'
    tb = olo_tb.test_bench(sync_tb)
    for SyncStages in [2, 4]:
        for ResetLvel in [0, 1]:
            named_config(tb, {'SyncStages_g': SyncStages, 'RstLevel_g': ResetLvel})
            named_config(tb, {'SyncStages_g': SyncStages, 'RstLevel_g': ResetLvel, 'SyncTmr_g': True})

    ### olo_intf_sync SEU ###
    # SEU testbenches are skipped for GHDL with the LLVM backend (see run.py)
    for tb in olo_tb.get_test_benches('*olo_intf_sync_seu_tb', allow_empty=True):
        for Tmr in [True, False]:
            named_config(tb, {'SyncTmr_g': Tmr})

    ### olo_intf_clk_meas ###
    clk_meas_tb = 'olo_intf_clk_meas_tb'
    tb = olo_tb.test_bench(clk_meas_tb)
    freqs = [(100, 100), (123, 7837), (7837, 123)]
    for FreqClk, FreqTest in freqs:
        named_config(tb, {'ClkFrequency_g': FreqClk, 'MaxClkTestFrequency_g': FreqTest})
        named_config(tb, {'ClkFrequency_g': FreqClk, 'MaxClkTestFrequency_g': FreqTest, 'SyncStages_g': 4,
                          'SyncTmr_g': True})

    ### olo_intf_spi_slave ###
    spi_slave_tb = 'olo_intf_spi_slave_tb'
    tb = olo_tb.test_bench(spi_slave_tb)
    #Test different configs for transactions (all combinations)
    for CPHA in [0, 1]:
        for CPOL in [0, 1]:
            for Consecutive in [False, True]:
                #Try TxOnSampleEdge
                named_config(tb, {'SpiCpha_g': CPHA, 'SpiCpol_g': CPOL, 'ConsecutiveTransactions_g' : Consecutive})
    #Test Lsb/Msb first
    for LsbFirst in [True, False]:
        named_config(tb, {'LsbFirst_g': LsbFirst})
    #Test different transaction widths
    for TransWidth in [8, 16]:
        named_config(tb, {'TransWidth_g': TransWidth})
    #Test external tristate
    for InternalTriState in [True, False]:
        named_config(tb, {'InternalTriState_g': InternalTriState})
    #Test maximum clock frequency
    clkFreq = int(100e6)
    for CPHA in [0, 1]:
        named_config(tb, {'SpiCpha_g': CPHA, 'ClkFrequency_g': clkFreq, 'BusFrequency_g': int(clkFreq/8),
                        'ConsecutiveTransactions_g': True})
    #Synchronizer (every additional stage raises the minimum clock ratios of 8 and 10 by 2)
    for CPHA in [0, 1]:
        named_config(tb, {'SpiCpha_g': CPHA, 'SyncTmr_g': True})
        for Stages in [3, 4]:
            for Ratio in [2*Stages+4, 2*Stages+6]:
                named_config(tb, {'SpiCpha_g': CPHA, 'ClkFrequency_g': clkFreq, 'BusFrequency_g': int(clkFreq/Ratio),
                                'ConsecutiveTransactions_g': True, 'SyncStages_g': Stages})

    ### olo_intf_uart ###
    uart_tb = 'olo_intf_uart_tb'
    tb = olo_tb.test_bench(uart_tb)
    for BaudRate in [115200, 10000000]:
        named_config(tb, {'BaudRate_g' : BaudRate})
    for DataBits in [8, 9]:
        for Parity in ["none", "even", "odd"]:
            named_config(tb, {'DataBits_g': DataBits, 'Parity_g' : Parity})
    for StopBits in ["1", "1.5", "2"]:
        named_config(tb, {'StopBits_g' : StopBits})
    for BaudRate in [115200, 10000000]:
        named_config(tb, {'BaudRate_g' : BaudRate, 'SyncStages_g': 4})
        named_config(tb, {'BaudRate_g' : BaudRate, 'SyncTmr_g': True})
    # olo_intr_uart_clkdrift_tb does not require additional configurations

    ### olo_intf_spi_master ###
    spi_master_tb = 'olo_intf_spi_master_tb'
    tb = olo_tb.test_bench(spi_master_tb)
    for FreqBus in [int(1e6), int(10e6)]:
        named_config(tb, {'BusFrequency_g': FreqBus})
    for LsbFirst in [False, True]:
        named_config(tb, {'LsbFirst_g': LsbFirst})
    for CPHA in [0, 1]:
        for CPOL in [0, 1]:
            named_config(tb, {'SpiCpha_g': CPHA, 'SpiCpol_g': CPOL})
    #fixed size TB
    spi_master_fixsize_tb = 'olo_intf_spi_master_fixsize_tb'
    tb = olo_tb.test_bench(spi_master_fixsize_tb)
    for LsbFirst in [False, True]:
        named_config(tb, {'LsbFirst_g': LsbFirst})