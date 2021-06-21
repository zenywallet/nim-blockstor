# Copyright (c) 2021 zenywallet

asm """
var externs = {
  deoxyMod: {
    onRuntimeInitialized: function() {},
    preRun: [],
    postRun: [],
    print: function() {},
    printErr: function() {},
    canvas: function() {},
    setStatus: function() {},
    getExceptionMessage: function() {}
  },
  cwrap: function() {},
  ccall: function() {},
  _malloc: function() {},
  _free: function() {},
  UTF8ToString: function() {},
  HEAPU8: {},
  HEAPU32: {},
  buffer: 0
};

var addEventListener = function() {};
var devicePixelRatio = 0;
var innerWidth = 0;
var innerHeight = 0;
var outerWidth = 0;
var outerHeight = 0;
var pageXOffset = 0;
var pageYOffset = 0;
var event = {};
"""
