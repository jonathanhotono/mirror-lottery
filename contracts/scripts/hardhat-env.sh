#!/usr/bin/env bash
set -euo pipefail

export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$PWD/.hardhat-config}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$PWD/.hardhat-cache}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$PWD/.hardhat-data}"

exec hardhat "$@"
