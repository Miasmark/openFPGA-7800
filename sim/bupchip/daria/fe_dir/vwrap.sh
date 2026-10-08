#!/bin/bash
# Verilator wrapper for the directed tests (fe_dir/run_dir.sh): run_daria.sh
# calls "$VERILATOR" with its own sources; this adds the event monitor
# fe_dir_mon.sv (bound into tb_daria) and calls the real Verilator
# ($VERILATOR_REAL). run_daria.sh, tb_daria.sv and fe_shadow.svh are not
# changed.
# SPDX-License-Identifier: MIT
HERE="$(cd "$(dirname "$0")" && pwd)"
exec "${VERILATOR_REAL:?}" "$@" "$HERE/fe_dir_mon.sv"
