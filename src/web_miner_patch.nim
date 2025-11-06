# Copyright (c) 2021 zenywallet

import std/os
import std/strutils
import regex

const minerFileTmp1 = currentSourcePath().parentDir() / "../public/miner.js_tmp"
const minerFileTmp2 = currentSourcePath().parentDir() / "../public/miner-simd128.js_tmp"

proc patch(file: string) =
  var s = readFile(file)

  s = s.replace(re2"""class\s+ExitStatus\s*\{\s*name\s*=\s*"ExitStatus"\s*;\s*constructor\s*\(\s*status\s*\)\s*\{""",
    """class ExitStatus {
  constructor(status) {
    this.name = "ExitStatus";""")

  writeFile(file, s)

if fileExists(minerFileTmp1):
  patch(minerFileTmp1)
if fileExists(minerFileTmp2):
  patch(minerFileTmp2)
