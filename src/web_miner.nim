# Copyright (c) 2021 zenywallet

import blocks, bytes
import yespower
import os

const srcPath = currentSourcePath().parentDir()
{.passL: "--extern-pre-js " & srcPath / "web_miner_loader.js".}

{.emit: """
#include <emscripten.h>
""".}

type
  TargetObj* = array[32, byte]

  MinerData = object
    header: BlockHeaderObj
    target: TargetObj
    nid: int

  MinerParam = object
    data: ptr MinerData
    abort: bool

proc `$`*(o: TargetObj): string = $toReverse(o.toBytes)

proc emscripten_sleep(ms: uint) {.importc.}

var minerParam: MinerParam
var minerDatas: ptr UncheckedArray[MinerData]
var minerDataShift: int
var minerCount: int

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
      let header = ($data[].header.toBytes).cstring
      let nid = data[].nid
      {.emit: """
        EM_ASM({
          try {
            postMessage({cmd: "find", data: {header: UTF8ToString($0), nid: $1}});
          } catch(e) {
            console.error('except:', e);
          }
        }, `header`, `nid`);
      """.}

    inc(cast[var uint32](addr data[].header.nonce))
    inc(minerCount)
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

proc getMinerCount(): int {.exportc: "get_miner_count".} =
  result = minerCount
  minerCount = 0

proc start*() {.exportc.} =
  minerParam.abort = false
  miner(addr minerParam)

proc stop*() {.exportc.} =
  minerParam.abort = true
