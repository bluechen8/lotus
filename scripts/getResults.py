#!/usr/bin/env python3

# $lic$
# Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
#
# This file is part of Lotus. Lotus is free software; you can redistribute it
# and/or modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation, version 2.

import random
import sys
import os
import shutil
current_directory = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, current_directory)

from itertools import product
import concurrent.futures
import concurrent
import time
from datetime import datetime
import os
from pathlib import Path
import subprocess
import pandas as pd

import re
import argparse
import threading
from contextlib import contextmanager
import tempfile

from resultsCommon import getAllExperiments, getArgs, setBuildDir, globalData

pd.set_option('display.max_rows', None)
pd.set_option('display.max_columns', None)
pd.set_option('display.width', None)
pd.set_option('display.max_colwidth', None)

def copyFile(src, dst):
    if os.path.isfile(src):
        shutil.copy(src, dst)



if __name__ == "__main__":
    experiments = getAllExperiments()
    args = getArgs(experiments)
    globalData["args"] = args
    setBuildDir()
    regexExps = [re.compile(e) for e in args.experiments]
    def matches_any_regex(regexExps, name):
        for r in regexExps:
            if r.match(name):
                return True
        return False

    filtered_experiments = [exp for exp in experiments if matches_any_regex(regexExps, exp.name)]

    assert len(filtered_experiments) > 0, f"Needs to match at least one experiment -- do --help"

    for exp in filtered_experiments:
        exp.callback(exp)
