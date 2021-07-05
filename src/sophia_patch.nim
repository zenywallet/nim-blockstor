# Copyright (c) 2021 zenywallet

import os, strutils

const sophiaFile = currentSourcePath().parentDir() / "../deps/sophia/sophia/std/ss_filterof.h"

proc patch(file: string) =
  var s = readFile(file)
  s = s.replace("&ss_lz4filter", "NULL")
  s = s.replace("&ss_zstdfilter", "NULL")
  writeFile(file, s)

if fileExists(sophiaFile):
  patch(sophiaFile)
