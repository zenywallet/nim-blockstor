# Copyright (c) 2020 zenywallet

import math

const base58Chars = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
var base58Map = [int8 -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
                -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
                -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
                -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, -1, -1, -1, -1, -1, -1,
                -1, 9, 10, 11, 12, 13, 14, 15, 16, -1, 17, 18, 19, 20, 21, -1,
                22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, -1, -1, -1, -1, -1,
                -1, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, -1, 44, 45, 46,
                47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, -1, -1, -1, -1, -1]
const log58_256 = 1.36565823730977
const log256_58 = 0.732247624390947

proc enc*(data: seq[byte]): string =
  let size = int(ceil(float(data.len) * log58_256))
  var buf = newSeq[byte](size)
  var carry: float
  for d in data:
    carry = d.float
    for j in countdown(size - 1, 0):
      carry = carry + buf[j].float * 256.0
      buf[j] = byte(carry mod 58.0)
      carry = carry / 58.0
  var skip = 0
  for b in buf:
    if b != 0:
      break
    inc(skip)
  for d in data:
    if d != 0:
      break
    dec(skip)
  for b in buf[skip..^1]:
    result.add(base58Chars[b])

proc dec*(str: string): seq[byte] =
  let size = int(ceil(float(str.len) * log256_58))
  var buf = newSeq[byte](size)
  var carry: float
  for c in str:
    if (c.uint8 and 0x80'u8) != 0'u8:
      return
    var d = base58Map[c.int8]
    if d == -1:
      return
    carry = d.float
    for j in countdown(size - 1, 0):
      carry = carry + buf[j].float * 58.0
      buf[j] = byte(carry mod 256.0)
      carry = carry / 256.0
  var skip = 0
  for b in buf:
    if b != 0:
      break
    inc(skip)
  for c in str:
    if c != '1':
      break
    dec(skip)
  if skip > 0:
    buf = buf[skip..^1]
  result = buf
