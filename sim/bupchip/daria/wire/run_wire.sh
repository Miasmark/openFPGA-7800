#!/bin/bash
# Lane I1's whole-core checks of the DARIA wiring: tb_wire (tb_load with
# the checks of tb_wire.sv) driven and judged by wire.py, whose header has
# the commands and the environment.
#   run_wire.sh build | run [SCENARIO ...] | list
# SPDX-License-Identifier: MIT
exec python3 "$(cd "$(dirname "$0")" && pwd)/wire.py" "$@"
