#!/usr/bin/env bash
set -eEuo pipefail

export DMD_DOWNLOAD_DIR=${DMD_DOWNLOAD_DIR-~/data/software/dmd}

find "$DMD_DOWNLOAD_DIR" -mindepth 1 -maxdepth 1 -type d            -print -exec rm -rf '{}' '+'
find "$DMD_DOWNLOAD_DIR" -mindepth 1 -maxdepth 1 -name '*.nixified' -print -delete

rdmd -g --build-only -J. dver

echo 'void main() {}' > /tmp/test.d

./dver -vd      2.100.0 dmd -c /tmp/test.d
./dver -vd --32 2.100.0 dmd -c /tmp/test.d
./dver -vd      2.055 dmd -c /tmp/test.d
./dver -vd --32 2.055 dmd -c /tmp/test.d
./dver -vd --32 2.030 dmd -c /tmp/test.d
./dver -vd --32 1.022 dmd -c /tmp/test.d
./dver -vd --32 0.175 dmd -c /tmp/test.d
./dver -vd --32 0.100 dmd -c /tmp/test.d
