# Copyright (c) 2021 zenywallet

import os, strutils

const uiFile = currentSourcePath().parentDir() / "../public/ui.js"
const uiFileTmp = currentSourcePath().parentDir() / "../public/ui.js_tmp"

var patchString = "if(eventTypeId != 2 || e.key != 'v' || (!e.ctrlKey && !e.metaKey)) "

proc patch(file: string) =
  var s = readFile(file)
  if s.find(patchString) >= 0:
    echo "patch exists"
    return
  var pos = s.find("function registerKeyEventCallback(")
  if pos < 0:
    echo "patch failed"
    return
  pos = s.find("e.preventDefault();", pos)
  if pos < 0:
    echo "patch failed"
    return
  writeFile(file, s[0..<pos] & patchString & s[pos..^1])


if fileExists(uiFileTmp):
  patch(uiFileTmp)
elif fileExists(uiFile):
  patch(uiFile)
