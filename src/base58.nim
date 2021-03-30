# Copyright (c) 2020 zenywallet

const base58Chars = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
var base58Map = [int8 -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
                -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
                -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
                -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, -1, -1, -1, -1, -1, -1,
                -1, 9, 10, 11, 12, 13, 14, 15, 16, -1, 17, 18, 19, 20, 21, -1,
                22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, -1, -1, -1, -1, -1,
                -1, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, -1, 44, 45, 46,
                47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, -1, -1, -1, -1, -1]

proc enc*(data: seq[byte]): string =
  for d in data:
    if d != 0:
      break
    result.add('1')
  var b: seq[byte]
  for d in data[result.len..data.high]:
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

proc dec*(data: string): seq[byte] =
  for d in data:
    if d != '1':
      break
    result.add(0'u8)
  var b: seq[byte]
  for d in data[result.len..data.high]:
    var idx = cast[int8](d)
    if idx < 0:
      return
    var c = base58Map[idx].int
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
