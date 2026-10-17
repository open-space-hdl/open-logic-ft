# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2025 by Oliver Bründler
# Authors: Oliver Bruendler
# ---------------------------------------------------------------------------------------------------

# ---------------------------------------------------------------------------------------------------
# Imports
# ---------------------------------------------------------------------------------------------------
from .utils import named_config

# ---------------------------------------------------------------------------------------------------
# Functionality
# ---------------------------------------------------------------------------------------------------

def add_configs(olo_tb):
    """
    Add all axi testbench configurations to the VUnit Library
    :param olo_tb: Testbench library
    """
    ### olo_axi_lite_slave ###
    axi_lite_slave_tb = 'olo_axi_lite_slave_tb'
    tb = olo_tb.test_bench(axi_lite_slave_tb)
    for AxiAddrWidth in [8, 12, 16, 32]:
        for AxiDataWidth in [8, 16, 32, 128]:
            named_config(tb, {'AxiAddrWidth_g': AxiAddrWidth, 'AxiDataWidth_g': AxiDataWidth})

    ### olo_axi_master_simple ###
    axi_master_simple_tb = 'olo_axi_master_simple_tb'
    tb = olo_tb.test_bench(axi_master_simple_tb)
    for ImplRead in [True, False]:
        for ImplWrite in [True, False]:
            #Skip illegal case where no functionality is implemented
            if (not ImplRead) and (not ImplWrite): continue
            for AddrWidth in [16, 20, 32]:
                named_config(tb, {'ImplRead_g': ImplRead, 'ImplWrite_g': ImplWrite, 'AxiAddrWidth_g': AddrWidth})
            for DataWidth in [16, 32, 64]:
                named_config(tb, {'ImplRead_g': ImplRead, 'ImplWrite_g': ImplWrite, 'AxiDataWidth_g': DataWidth})
    #Case reported by customer
    named_config(tb, {'ImplRead_g': True, 'ImplWrite_g': True, 'AxiAddrWidth_g': 12, 'AxiDataWidth_g': 8, 'AxiMaxOpenTransactions_g': 1})
    #Transactions split at AxiMaxBeats_g, also with fewer beats than bytes per beat
    for DataWidth, MaxBeats in [(16, 1), (16, 2), (32, 1), (32, 2), (32, 3), (32, 4), (64, 7), (64, 8)]:
        named_config(tb, {'ImplRead_g': True, 'ImplWrite_g': True, 'AxiDataWidth_g': DataWidth, 'AxiMaxBeats_g': MaxBeats})
    #More beats than a 4 KB boundary allows (boundaries of the beat counter width: 1024 bits from 128, 512 bits at 256)
    for DataWidth, MaxBeats in [(512, 128), (512, 256), (1024, 64), (1024, 128), (1024, 256)]:
        named_config(tb, {'ImplRead_g': True, 'ImplWrite_g': True, 'AxiDataWidth_g': DataWidth, 'AxiMaxBeats_g': MaxBeats})
    #Fewer command size bits than the beat counter
    named_config(tb, {'ImplRead_g': True, 'ImplWrite_g': True, 'AxiMaxBeats_g': 256, 'UserTransactionSizeBits_g': 6})

    ### olo_axi_master_full ###
    axi_master_full_tb = 'olo_axi_master_full_tb'
    tb = olo_tb.test_bench(axi_master_full_tb)
    #Check Widths
    for AddrWidth in [16, 20, 32]:
        named_config(tb, {'ImplRead_g': True, 'ImplWrite_g': True, 'AxiAddrWidth_g': AddrWidth})
    for DataWidth in [16, 32, 64]:
        for UserWidth in [8, 16, 32, 64]:
            if UserWidth > DataWidth: continue #Skip illegal configurations
            named_config(tb, {'ImplRead_g': True, 'ImplWrite_g': True,
                                'AxiDataWidth_g': DataWidth, 'UserDataWidth_g': UserWidth})
    #Check 8-bit AXI data and the narrowest address widths for the size width (default size width at 26 bits)
    named_config(tb, {'ImplRead_g': True, 'ImplWrite_g': True, 'AxiDataWidth_g': 8, 'UserDataWidth_g': 8})
    named_config(tb, {'ImplRead_g': True, 'ImplWrite_g': True, 'AxiAddrWidth_g': 12})
    named_config(tb, {'ImplRead_g': True, 'ImplWrite_g': True, 'AxiAddrWidth_g': 26, 'UserTransactionSizeBits_g': 24})
    #Check Partial Implementations
    for ImplRead in [True, False]:
        for ImplWrite in [True, False]:
            named_config(tb, {'ImplRead_g': ImplRead, 'ImplWrite_g': ImplWrite})

            #Skip illegal case where no functionality is implemented
            if (not ImplRead) and (not ImplWrite): continue
    #Transactions split at AxiMaxBeats_g, also with fewer beats than bytes per beat
    for DataWidth, MaxBeats in [(16, 1), (16, 2), (32, 1), (32, 2), (32, 3), (32, 4), (64, 7), (64, 8)]:
        named_config(tb, {'ImplRead_g': True, 'ImplWrite_g': True, 'AxiDataWidth_g': DataWidth, 'AxiMaxBeats_g': MaxBeats})
    #More beats than a 4 KB boundary allows (boundaries of the beat counter width of olo_axi_master_simple)
    for DataWidth, MaxBeats in [(512, 256), (1024, 64), (1024, 128)]:
        named_config(tb, {'ImplRead_g': True, 'ImplWrite_g': True, 'AxiDataWidth_g': DataWidth, 'UserDataWidth_g': 64,
                          'AxiMaxBeats_g': MaxBeats, 'UserTransactionSizeBits_g': 16})

    ### olo_axi_master_full (random back-to-back commands) ###
    axi_master_full_random_tb = 'olo_axi_master_full_random_tb'
    tb = olo_tb.test_bench(axi_master_full_random_tb)
    #Throughput bounds in per mille of the expected rate (write, read). Where the chaining of the commands sets
    #the rate, each bound lies between the measured rate and the rate with one lost clock cycle per command.
    seed = 1
    for StallPercent in [0, 30]:
        for DataWidth, UserWidth, MaxBeats, TpWr, TpRd in [(32, 32, 16, 970, 850), (32, 8, 4, 990, 925),
                                                           (64, 16, 7, 990, 925), (32, 16, 3, 985, 905),
                                                           (8, 8, 4, 850, 715), (128, 32, 16, 990, 925),
                                                           (16, 16, 1, 850, 850), (64, 64, 2, 850, 850)]:
            named_config(tb, {'AxiDataWidth_g': DataWidth, 'UserDataWidth_g': UserWidth, 'AxiMaxBeats_g': MaxBeats,
                              'StallPercent_g': StallPercent, 'Seed_g': seed,
                              'TpWrPermille_g': TpWr, 'TpRdPermille_g': TpRd})
            seed += 1

    ### olo_axi_pl_stage ###
    axi_pl_stage_tb = 'olo_axi_pl_stage_tb'
    tb = olo_tb.test_bench(axi_pl_stage_tb)
    for AddrWidth in [32, 64]:
        named_config(tb, {'AddrWidth_g': AddrWidth})
    for DataWidth in [16, 64]:
        named_config(tb, {'DataWidth_g': DataWidth})
    for IdWidth in [0, 4]:
        named_config(tb, {'IdWidth_g': IdWidth})
    for UserWidth in [0, 4, 16]:
        named_config(tb, {'UserWidth_g': UserWidth})
    for Stages in [1, 4, 12]:
        named_config(tb, {'Stages_g': Stages})

    ### olo_axi_lite_decoder ###
    axi_lite_decoder_tb = 'olo_axi_lite_decoder_tb'
    tb = olo_tb.test_bench(axi_lite_decoder_tb)
    for Ports in [1, 3, 4]:
        named_config(tb, {'Ports_g': Ports})
    named_config(tb, {'Ports_g': 5, 'PortAddrWidth_g': 12, 'AxiAddrWidth_g': 15})
    named_config(tb, {'Ports_g': 2, 'AxiDataWidth_g': 64, 'PortAddrWidth_g': 4})
    named_config(tb, {'Ports_g': 16, 'AxiDataWidth_g': 16, 'PortAddrWidth_g': 10, 'AxiAddrWidth_g': 14})