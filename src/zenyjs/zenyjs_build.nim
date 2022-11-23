# Copyright (c) 2022 zenywallet

import std/osproc
import os
import strformat
import strutils
import re

const KEEP_TMP_FILES = defined(KEEP_TMP_FILES)

if paramCount() < 1:
  echo "usage: zenyjs_build <target_file.nim>"
  quit(QuitFailure)

let targetNim = paramStr(1)
let splittedFile = splitFile(targetNim)
if splittedFile.ext != ".nim":
  echo "Error: ", targetNim, " is not nim file"
  quit(QuitFailure)

let target = splittedFile.name
let tmpjs = target & ".js_tmp"
let tmpjs2 = target & ".js_tmp2"
let targetjs = target & ".js"

discard execCmd "nim c -d:release -d:emscripten --noMain:on --gc:orc -o:zenyjs.js zenyjs.nim"
discard execCmd "nim js -d:release --gc:orc -o:" & tmpjs & " " & targetNim

# remove {.threadvar.} in the times module
var f = open(tmpjs, fmRead)
var f2 = open(tmpjs2, fmWrite)
var stage = 0
for line in lines(f):
  if stage == 0 and line.startsWith("if (globalThis.") and line.endsWith(" === undefined) {"):
    stage = 1
  elif stage == 1:
    f2.writeLine(line.replace("  globalThis.", "var "))
    stage = 2
  elif stage == 2:
    stage = 0
  else:
    f2.writeLine(line)
f2.close()
f.close()

discard execCmd "nim c -r zenyjs_externs.nim " & tmpjs2 & " > zenyjs_externs.js"
discard execCmd fmt"""
if [ -x "$(command -v google-closure-compiler)" ]; then
  closure_compiler="google-closure-compiler"
else
  closure_compiler="java -jar $(ls ../../closure-compiler-*.jar | sort -r | head -n1)"
fi
echo "use $closure_compiler"
$closure_compiler --compilation_level ADVANCED --jscomp_off=checkVars \
--jscomp_off=checkTypes --jscomp_off=uselessCode --js_output_file={targetjs} \
--externs zenyjs_externs.js {tmpjs2} 2>&1 | cut -c 1-240
"""

when not KEEP_TMP_FILES:
  discard execCmd "rm zenyjs_externs"
  discard execCmd "rm zenyjs_externs.js"
  discard execCmd "rm \"" & tmpjs2 & "\""
  discard execCmd "rm \"" & tmpjs & "\""
  discard execCmd "rm zenyjs.js"
echo "build done. zenyjs.wasm " & targetjs
