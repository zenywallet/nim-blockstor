# Copyright (c) 2022 zenywallet

echo """
var externs = {
  zenyjsMod: {
    onRuntimeInitialized: function() {},
    preRun: [],
    postRun: [],
    print: function() {},
    printErr: function() {},
    setStatus: function() {},
    monitorRunDependencies: function() {}
  },
  cwrap: function() {},
  ccall: function() {},
  _malloc: function() {},
  _free: function() {},
  stackSave: function() {},
  stackAlloc: function() {},
  stackRestore: function() {},
  UTF8ToString: function() {},
  HEAPU8: {},
  HEAPU32: {},
  buffer: 0
};
"""

import os
import nre
import tables
import strutils

var list = initOrderedTable[string, string]()
var resList = initOrderedTable[string, string]()

let targetJs = paramStr(1)
var d = readFile(targetJs)

for s in d.findIter(re""": "[a-zA-Z_][\w]*""""):
  var t = s.match.strip(chars = {' ', ':', '"'})
  list[t] = t

for s in d.findIter(re"[a-zA-Z_][\w]*: "):
  var t = s.match.strip(chars = {' ', ':'})
  list[t] = t

for s in d.findIter(re"\.[a-zA-Z_][\w]*"):
  #echo s.match
  var t = s.match.strip(chars = {'.'})
  if list.hasKey(t):
    resList[t] = t

resList.sort(system.cmp)

var res: string
res.add("var externs2 = {\n")
var last = resList.len
var i = 0
for s in resList.keys:
  inc(i)
  if i == last:
    res.add("  " & s & ": 0\n")
  else:
    res.add("  " & s & ": 0,\n")
res.add("};\n")

echo res
