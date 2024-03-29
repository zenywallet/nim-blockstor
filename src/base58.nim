# Copyright (c) 2020 zenywallet

import math

const base58Chars = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
const base58Map = [int8 -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
                        -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
                        -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
                        -1,  0,  1,  2,  3,  4,  5,  6,  7,  8, -1, -1, -1, -1, -1, -1,
                        -1,  9, 10, 11, 12, 13, 14, 15, 16, -1, 17, 18, 19, 20, 21, -1,
                        22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, -1, -1, -1, -1, -1,
                        -1, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, -1, 44, 45, 46,
                        47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, -1, -1, -1, -1, -1,
                        -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
                        -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
                        -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
                        -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
                        -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
                        -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
                        -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
                        -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1]

const log58_256 = 1.365658237309762
const log256_58 = 0.7322476243909466

proc enc*(data: seq[byte]): string =
  let size = int(ceil(data.len.float * log58_256))
  var b = newSeqUninitialized[byte](size)
  var zeroLen = 0

  for d in data:
    if d != 0:
      break
    b[zeroLen] = '1'.byte
    inc(zeroLen)

  var pos = b.len
  for i in zeroLen..data.high:
    let d = data[i]
    var c = d.int
    var j = b.high

    while c > 0 or j >= pos:
      if j < pos:
        dec(pos)
        b[pos] = 0'u8
      else:
        c = c + b[j].int * 256
      b[j] = (c mod 58).byte
      c = c div 58
      dec(j)

  let validLen = b.len - pos
  let bLen = zeroLen + validLen
  let offset = pos - zerolen
  for i in zeroLen..<bLen:
    b[i] = base58Chars[b[i + offset]].byte
  when defined(CSTRING_SAFE):
    result = newStringOfCap(bLen)
    for i in 0..<bLen:
      result.add(cast[char](b[i]))
  else:
    b.setLen(bLen)
    result = cast[string](b)

proc dec*(data: string): seq[byte] =
  var zeroLen = 0

  for d in data:
    if d != '1':
      break
    inc(zeroLen)

  let size = int(ceil((data.len - zeroLen).float * log256_58)) + zeroLen
  var b = newSeqUninitialized[byte](size)

  for i in 0..<zeroLen:
    b[i] = 0'u8

  var pos = b.len
  for i in zeroLen..data.high:
    let d = data[i]
    var c = base58Map[d.ord].int
    if c == -1:
      return
    for j in countdown(b.high, pos):
      c = c + b[j].int * 58
      b[j] = (c mod 256).byte
      c = c div 256
    if c > 0:
      dec(pos)
      b[pos] = c.byte

  if pos > zeroLen:
    let validLen = b.len - pos
    let bLen = zeroLen + validLen
    copyMem(addr b[zeroLen], addr b[pos], validLen)
    b.setLen(bLen)
  result = b


when isMainModule:
  proc enc_reference*(data: seq[byte]): string =
    for d in data:
      if d != 0:
        break
      result.add('1')
    var b: seq[byte]
    for i in result.len..data.high:
      let d = data[i]
      var c = d.int
      var j = 0
      while c > 0 or j < b.len:
        if j >= b.len:
          b.add(0)
        else:
          c = c + b[j].int * 256
        b[j] = (c mod 58).byte
        c = c div 58
        inc(j)
    for i in countdown(b.high, 0):
      result.add(base58Chars[b[i]])

  proc dec_reference*(data: string): seq[byte] =
    for d in data:
      if d != '1':
        break
      result.add(0'u8)
    var b: seq[byte]
    for i in result.len..data.high:
      let d = data[i]
      var c = base58Map[d.ord].int
      if c == -1:
        return
      for j in 0..b.high:
        c = c + b[j].int * 58
        b[j] = (c mod 256).byte
        c = c div 256
      if c > 0:
        b.add(c.byte)
    for i in countdown(b.high, 0):
      result.add(b[i])


  import times, sequtils

  var d = cast[seq[byte]]("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".toSeq)

  var a1 = epochTime()
  for i in 0..<10000:
    discard dec_reference(enc_reference(d))
  var a2 = epochTime()
  for i in 0..<10000:
    discard dec_reference(enc(d))
  var a3 = epochTime()
  for i in 0..<10000:
    discard dec(enc_reference(d))
  var a4 = epochTime()
  for i in 0..<10000:
    discard dec(enc(d))
  var a5 = epochTime()
  echo a2 - a1
  echo a3 - a2
  echo a4 - a3
  echo a5 - a4
