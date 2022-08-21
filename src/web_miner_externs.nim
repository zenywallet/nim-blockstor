# Copyright (c) 2022 zenywallet

asm """
var web_miner_externs = {
  minerMod: {
    onRuntimeInitialized: function() {},
    preRun: [],
    postRun: [],
    print: function() {},
    printErr: function() {},
    setStatus: function() {},
    getExceptionMessage: function() {}
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

var MinerData = {
  header: {},
  target: {},
  nid: 0
};

var FindData = {
  cmd: {},
  data: {
    header: {},
    nid: {}
  }
};
"""
