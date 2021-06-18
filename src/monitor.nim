# Copyright (c) 2021 zenywallet

import algorithm
import bytes
import blocks

type
  ArrayBlockHash* = array[32, byte]

  MonitorInfo* = object
    height*: int
    hash*: ArrayBlockHash
    blkTime*: int64
    lastHeight*: int

proc `$`*(data: ArrayBlockHash): string =
  var b = data
  algorithm.reverse(b)
  bytes.toHex(b)


var monitorInfos*: ptr UncheckedArray[MonitorInfo]
var monitorInfosCount*: int

proc setMonitorInfo*(workerId: int, height: int, hash: BlockHash, time: int64, lastHeight: int = -1) =
  var info = addr monitorInfos[][workerId]
  info.height = height
  if cast[seq[byte]](hash).len == 32:
    copyMem(addr info.hash[0], unsafeAddr cast[ptr seq[byte]](unsafeAddr hash)[][0], sizeof(info.hash))
  info.blkTime = time
  if lastHeight >= 0:
    info.lastHeight = lastHeight
