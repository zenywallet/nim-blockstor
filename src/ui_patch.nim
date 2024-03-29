# Copyright (c) 2021 zenywallet

import os, strutils

const uiFile = currentSourcePath().parentDir() / "../public/ui.js"
const uiFileTmp = currentSourcePath().parentDir() / "../public/ui.js_tmp"
const removePathStr = currentSourcePath().parentDir() / "../public/"

var patchString = "if(!(eventTypeId == 2 && ((e.key == 'v' && (e.ctrlKey || e.metaKey)) || " &
                  "e.key == 'F5' || e.key == 'F11' || e.key == 'F12' || e.key == 'Escape'))) "

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
  s = s[0..<pos] & patchString & s[pos..^1]
  s = s.replace(removePathStr)
  writeFile(file, s)


if fileExists(uiFileTmp):
  patch(uiFileTmp)
elif fileExists(uiFile):
  patch(uiFile)
