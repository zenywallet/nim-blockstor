# Copyright (c) 2021 zenywallet

import os, strutils
import regex

const uiFile = currentSourcePath().parentDir() / "../public/ui.js"
const uiFileTmp = currentSourcePath().parentDir() / "../public/ui.js_tmp"
const removePathStr = currentSourcePath().parentDir() / "../public/"

var patchString = "if(!(eventTypeId == 2 && ((e.key == 'v' && (e.ctrlKey || e.metaKey)) || " &
                  "e.key == 'F5' || e.key == 'F11' || e.key == 'F12' || e.key == 'Escape'))) "

proc patch(file: string) =
  var s = readFile(file)
  if s.find(patchString) >= 0:
    echo "patch exists"
  else:
    var pos = s.find("var registerKeyEventCallback =")
    if pos < 0:
      pos = s.find("function registerKeyEventCallback(")
    if pos >= 0:
      pos = s.find("e.preventDefault();", pos)
      if pos >= 0:
        s = s[0..<pos] & patchString & s[pos..^1]
        s = s.replace(removePathStr)
      else:
        echo "patch failed 2"
    else:
      echo "patch failed 1"

  s = s.replace(re2"""class\s+ExitStatus\s*\{\s*name\s*=\s*"ExitStatus"\s*;\s*constructor\s*\(\s*status\s*\)\s*\{""",
    """class ExitStatus {
  constructor(status) {
    this.name = "ExitStatus";""")

  s = s.replace(re2"""class\s*\{\s*name\s*=\s*"ErrnoError"\s*;""",
    """class {""")
  s = s.replace(re2"""constructor\s*\(\s*errno\s*\)\s*\{""",
    """constructor(status) {
      this.name = "ErrnoError";""")

  s = s.replace("""  FSNode: class {
    node_ops={};
    stream_ops={};
    readMode=292 | 73;
    writeMode=146;
    mounted=null;
    constructor(parent, name, mode, rdev) {""",
    """  FSNode: class {
    constructor(parent, name, mode, rdev) {
      this.node_ops={};
      this.stream_ops={};
      this.readMode=292 | 73;
      this.writeMode=146;
      this.mounted=null;""")

  s = s.replace("""  FSStream: class {
    shared={};""",
    """  FSStream: class {
    constructor() {
      this.shared={};
    }""")

  s = s.replace("""    class LazyUint8Array {
      lengthKnown=false;
      chunks=[];""",
    """    class LazyUint8Array {
      constructor() {
        this.lengthKnown=false;
        this.chunks=[];
      }""")

  s = s.replace("""var FS = {""",
    """var errno = 0;
var FS = {""")

  writeFile(file, s)


if fileExists(uiFileTmp):
  patch(uiFileTmp)
elif fileExists(uiFile):
  patch(uiFile)
