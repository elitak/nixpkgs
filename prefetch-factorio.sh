#! /usr/bin/env bash
# NB demo is usually behind a few versions and needs to be fetchable by http anyway!!
VER=0.15.31; for build in headless alpha demo; do nix-prefetch-url file://$HOME/Downloads/factorio_${build}_x64_${VER}.tar.xz  --name factorio_${build}_x64-${VER}.tar.xz; done
