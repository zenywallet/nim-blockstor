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

var fomantic = {
  tab: 0,
  checkbox: 0,
  rating: {
    icon: 0,
    initialRating: 0,
    maxRating: 0,
    fireOnInit: 0,
    clearable: 0,
    interactive: 0,
    onRate: function() {},
    onChange: function() {}
  },
  toast: {
    title: 0,
    message: 0,
    class: 0,
    className: {
      toast: 0
    },
    displayTime: 0
  },
  modal: {
    onShow: function() {},
    onVisible: function() {},
    onHide: function() {},
    onHidden: function() {},
    onApprove: function() {},
    onDeny: function() {}
  }
};

var nodejs = {
  global: 0,
  Module: function() {},
  fs: {
    readFileSync: function() {},
    readFile: function() {}
  },
  FS: {
    createDataFile: 0,
    createPreloadedFile: 0
  },
  nodePath: 0,
  process: {
    versions: {
      node: 0
    },
    on: function() {}
  }
};

var jq = {
  val: function() {}
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
