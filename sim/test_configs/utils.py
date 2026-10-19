# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2025 by Oliver Bründler
# Authors: Oliver Bruendler
# ---------------------------------------------------------------------------------------------------

# ---------------------------------------------------------------------------------------------------
# Imports
# ---------------------------------------------------------------------------------------------------
from functools import partial
from pathlib import Path
import os
import re

# ---------------------------------------------------------------------------------------------------
# Functionality
# ---------------------------------------------------------------------------------------------------
def named_config(tb, map : dict, pre_config = None, short_name = None):
    cfg_name = "-".join([f"{k}={v}" for k, v in map.items()])
    if short_name is not None:
        cfg_name = short_name
    if pre_config is not None:
        pre_config = partial(pre_config, generics=map)
    tb.add_config(name=cfg_name, generics = map, pre_config=pre_config)

# ---------------------------------------------------------------------------------------------------
# IEEE Warning Check
# ---------------------------------------------------------------------------------------------------
# The first test of a test bench (FirstCommands) prints IEEE_MARKER after the reset release. In the configurations of
# the check the IEEE warnings are enabled, and the post check fails on any numeric_std metavalue warning after the
# marker. A metavalue warning of the control process (IEEE_CONTROL) before the marker shows that the warnings are
# enabled. GHDL prints the instance of a warning in the next line (--backtrace-severity=warning), in two formats:
# "/tb/i_dut/p_comb" (mcode backend) and ".tb(sim).i_dut@entity(rtl).p_comb" (LLVM backend).
IEEE_MARKER = "OLO_IEEE_CHECK_START"
IEEE_CONTROL = "p_control"
IEEE_INSTANCE = re.compile(r"^\s*instance:\s*(\S+)")

def instance_name(instance):
    """
    Last element of a GHDL instance path, without architecture and entity
    """
    return re.sub(r"@.*|\(.*\)", "", re.split(r"[/.]", instance)[-1])

def metavalue_warnings(lines, first, last):
    """
    Numeric_std metavalue warnings in lines[first:last]
    :return: List of (message, instance)
    """
    found = []
    for i in range(first, last):
        if "NUMERIC_STD" in lines[i] and "metavalue" in lines[i]:
            match = IEEE_INSTANCE.match(lines[i+1]) if i+1 < len(lines) else None
            found.append((lines[i], match.group(1) if match else ""))
    return found

def no_metavalue_after_marker(output_path):
    """
    Post check of the IEEE warning check: no metavalue warning after the marker, one of the control before it
    """
    lines = (Path(output_path) / "output.txt").read_text(encoding="utf-8", errors="replace").splitlines()
    return ieee_check(lines)

def ieee_check(lines):
    """
    IEEE warning check of the simulator output lines
    :return: True if the check passes
    """
    start = next((i for i, line in enumerate(lines) if IEEE_MARKER in line), None)
    if start is None:
        print(f"IEEE warning check: marker {IEEE_MARKER} not found")
        return False
    if not any(instance_name(instance) == IEEE_CONTROL for _, instance in metavalue_warnings(lines, 0, start)):
        print(f"IEEE warning check: no metavalue warning of {IEEE_CONTROL} before the marker, the IEEE warnings are "
              f"not enabled")
        return False
    found = metavalue_warnings(lines, start+1, len(lines))
    print(f"IEEE warning check: {len(found)} metavalue warnings after the marker")
    for message, instance in found[:10]:
        print(f"IEEE warning check: {message} {instance}")
    return not found

def ieee_warning_configs(tb):
    """
    Add the configurations of the IEEE warning check to a test bench with the test FirstCommands and the generic
    ReadFirst_g. GHDL only. Add them after the IEEE warning suppression of run.py, which sets its options in the
    configurations that exist at that point.
    :param tb: Testbench
    """
    if os.environ.get('VUNIT_SIMULATOR') != 'ghdl':
        return
    for name, read_first in [("WriteFirst", False), ("ReadFirst", True)]:
        # A new list for each configuration: VUnit appends the generics to ghdl.sim_flags in place
        sim_options = {"disable_ieee_warnings": False,
                       "ghdl.sim_flags": ["--ieee-asserts=disable-at-0", "--backtrace-severity=warning"]}
        tb.add_config(name=f"ieee_warnings-{name}", generics={'ReadFirst_g': read_first}, sim_options=sim_options,
                      post_check=no_metavalue_after_marker)
