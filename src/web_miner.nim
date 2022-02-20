# Copyright (c) 2021 zenywallet

import blocks
import yespower
import os

const srcPath = currentSourcePath().parentDir()
{.passL: "--extern-pre-js " & srcPath / "web_miner_loader.js".}

{.emit: """
#include <emscripten.h>
""".}

type
  MinerData = object
    header: BlockHeaderObj
    target: array[32, byte]
    nid: int

  MinerParam = object
    data: ptr MinerData
    abort: bool

proc emscripten_sleep(ms: uint) {.importc.}

var minerParam: MinerParam
var minerDatas: ptr UncheckedArray[MinerData]
var minerDataShift: int

proc miner(param: ptr MinerParam) {.thread.} =
  var yhash: YespowerHash
  while not param.abort:
    let data = param.data
    discard yespower_hash(cast[ptr UncheckedArray[byte]](addr data[].header), 80, yhash)
    var find = true
    for j in countdown(31, 0):
      if yhash[j] > data[].target[j]:
        find = false
        break
      elif yhash[j] < data[].target[j]:
        break
    if find:
      var header = addr data[].header
      var nid = data[].nid
      {.emit: """
        EM_ASM({
          try {
            var headerStr = Array.prototype.map.call(new Uint8Array(Module.HEAPU8.buffer, $0, 80), function(x) {return ('00' + x.toString(16)).slice(-2)}).join('');
            postMessage({header: headerStr, nid: $1});
          } catch(e) {
            console.error('except:', e);
          }
        }, `header`, `nid`);
      """.}

    inc(cast[var uint32](addr data[].header.nonce))
    emscripten_sleep(0)

proc init*() {.exportc.} =
  minerDatas = cast[ptr UncheckedArray[MinerData]](allocShared0(sizeof(MinerData) * 2))
  minerDataShift = 0

proc setMinerData*(minerData: ptr MinerData, nonce: uint32, nid: int) {.exportc: "set_miner_data".} =
  var shift = minerDataShift
  if shift == 0:
    minerDataShift = 1
  else:
    minerDataShift = 0
  minerDatas[][shift] = minerData[]
  minerDatas[][shift].header.nonce = nonce
  minerDatas[][shift].nid = nid
  minerParam.data = addr minerDatas[][shift]

proc start*() {.exportc.} =
  minerParam.abort = false
  miner(addr minerParam)

proc stop*() {.exportc.} =
  minerParam.abort = true
