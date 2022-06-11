# Copyright (c) 2022 zenywallet

import bytes {.all.}
import arraylib

type
  Buffer* = object
    len: int
    data: ptr UncheckedArray[byte]

proc `=destroy`*(x: var Buffer) =
  if x.data != nil:
    x.data.deallocShared()
    x.data = nil

proc `=copy`*(a: var Buffer; b: Buffer) =
  if a.data == b.data: return
  `=destroy`(a)
  wasMoved(a)
  a.len = b.len
  if b.data != nil:
    a.data = cast[typeof(a.data)](allocShared0(a.len))
    copyMem(a.data, b.data, a.len)

proc `=sink`*(a: var Buffer; b: Buffer) =
  `=destroy`(a)
  wasMoved(a)
  a.len = b.len
  a.data = b.data

proc add*(x: var Buffer; y: sink Buffer) =
  let newSize = x.len + y.len
  x.data = cast[ptr UncheckedArray[byte]](reallocShared(x.data, newSize))
  copyMem(addr x.data[x.len], addr y.data[0], y.len)
  x.len = newSize

proc add*(x: var Buffer; y: sink seq[byte]) =
  let newSize = x.len + y.len
  x.data = cast[ptr UncheckedArray[byte]](reallocShared(x.data, newSize))
  copyMem(addr x.data[x.len], unsafeAddr y[0], y.len)
  x.len = newSize

proc add*(x: var Buffer; y: sink openArray[byte]) =
  let newSize = x.len + y.len
  x.data = cast[ptr UncheckedArray[byte]](reallocShared(x.data, newSize))
  copyMem(addr x.data[x.len], unsafeAddr y[0], y.len)
  x.len = newSize

proc `[]`*(x: Buffer; i: Natural): lent byte =
  assert i < x.len
  x.data[i]

proc `[]=`*(x: var Buffer; i: Natural; y: sink byte) =
  assert i < x.len
  x.data[i] = y

proc len*(x: Buffer): int {.inline.} = x.len

proc newBuffer*(buf: ptr UncheckedArray[byte], size: Natural): Buffer =
  result.data = cast[typeof(result.data)](allocShared0(size))
  copyMem(result.data, buf, size)
  result.len = size

proc toBuffer*(x: openArray[byte]): Buffer =
  if x.len > 0:
    result.data = cast[typeof(result.data)](allocShared0(x.len))
    copyMem(result.data, unsafeAddr x[0], x.len)
    result.len = x.len

proc toBuffer*(x: seq[byte]): Buffer =
  if x.len > 0:
    result.data = cast[typeof(result.data)](allocShared0(x.len))
    copyMem(result.data, unsafeAddr x[0], x.len)
    result.len = x.len

proc toBuffer*(x: Array[byte]): Buffer =
  if x.len > 0:
    result.data = cast[typeof(result.data)](allocShared0(x.len))
    copyMem(result.data, unsafeAddr x[0], x.len)
    result.len = x.len

proc toBytes*(x: Buffer): Array[byte] =
  result = newArray[byte](x.len)
  for i in 0..<x.len:
    result[i] = x[i]

proc toSeq*(x: Buffer): seq[byte] =
  result = newSeq[byte](x.len)
  for i in 0..<x.len:
    result[i] = x[i]

proc toBytesBE*(x: Buffer): Array[byte] {.inline.} = toBytes(x)

proc toSeqBE*(x: Buffer): seq[byte] {.inline.} = toSeq(x)

when TOHEX_COMPACT:
  proc toHex*(a: Buffer): string =
    result = newStringOfCap(a.len * 2)
    for i in 0..<a.len:
      result.add(hexChars[(a.data[i] and 0xf0'u8) shr 4])
      result.add(hexChars[a.data[i] and 0x0f'u8])
else:
  proc toHex*(a: Buffer): string =
    result = newStringOfCap(a.len * 2)
    for i in 0..<a.len:
      result.add(hexStr[a[i]])

proc `$`*(x: Buffer): string = x.toHex


when isMainModule:
  var a, b: Buffer
  a = @[byte 1].toBuffer
  b = a
  a = @[byte 1, 2].toBuffer
  echo a
  echo b

  b.add(@[byte 2, 3])
  b.add(b)
  echo b
