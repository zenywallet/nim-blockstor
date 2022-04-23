# Copyright (c) 2022 zenywallet

import bytes


type
  Array*[T] = object
    len, cap: int
    data: ptr UncheckedArray[T]

proc `=destroy`*[T](x: var Array[T]) =
  if x.data != nil:
    x.data.deallocShared()
    x.data = nil
    x.len = 0
    x.cap = 0

proc `=copy`*[T](a: var Array[T]; b: Array[T]) =
  if a.data == b.data: return
  `=destroy`(a)
  wasMoved(a)
  a.len = b.len
  a.cap = b.cap
  if b.data != nil:
    a.data = cast[typeof(a.data)](allocShared0(sizeof(T) * a.cap))
    copyMem(a.data, b.data, sizeof(T) * a.len)

proc `=sink`*[T](a: var Array[T]; b: Array[T]) =
  `=destroy`(a)
  wasMoved(a)
  a.len = b.len
  a.cap = b.cap
  a.data = b.data

proc nextCap(cap: int): int =
  if cap <= 16:
    result = 32
  else:
    result = cap * 2

proc add*[T](x: var Array[T]; y: sink Array[T]) =
  let newLen = x.len + y.len
  if x.cap < newLen:
    x.cap = nextCap(sizeof(T) * x.cap)
    x.data = cast[ptr UncheckedArray[T]](reallocShared(x.data, sizeof(T) * x.cap))
  copyMem(addr x.data[x.len], addr y.data[0], sizeof(T) * y.len)
  x.len = newLen

proc add*[T](x: var Array[T]; y: sink T) =
  let newLen = x.len + 1
  if x.cap < newLen:
    x.cap = nextCap(sizeof(T) * x.cap)
    x.data = cast[ptr UncheckedArray[T]](reallocShared(x.data, sizeof(T) * x.cap))
  zeroMem(addr x.data[x.len], sizeof(T))
  x.data[x.len] = y
  x.len = newLen

proc add*[T](x: var Array[T]; y: sink seq[T]) =
  let newLen = x.len + y.len
  if x.cap < newLen:
    x.cap = nextCap(sizeof(T) * x.cap)
    x.data = cast[ptr UncheckedArray[T]](reallocShared(x.data, sizeof(T) * x.cap))
  copyMem(addr x.data[x.len], unsafeAddr y[0], sizeof(T) * y.len)
  x.len = newLen

proc add*[T](x: var Array[T]; y: sink openArray[T]) =
  let newLen = x.len + y.len
  if x.cap < newLen:
    x.cap = nextCap(sizeof(T) * x.cap)
    x.data = cast[ptr UncheckedArray[T]](reallocShared(x.data, sizeof(T) * x.cap))
  copyMem(addr x.data[x.len], unsafeAddr y[0], sizeof(T) * y.len)
  x.len = newLen

proc `[]`*[T](x: Array[T]; i: Natural): lent T =
  assert i < x.len
  x.data[i]

proc `[]=`*[T](x: var Array[T]; i: Natural; y: sink T) =
  assert i < x.len
  x.data[i] = y

proc len*[T](x: Array[T]): int {.inline.} = x.len

proc newArray*[T](len: Natural): Array[T] =
  let size = sizeof(T) * len
  result.data = cast[typeof(result.data)](allocShared0(size))
  result.len = len
  result.cap = size

proc newArray*[T](a: var Array[T], len: Natural) =
  let size = sizeof(T) * len
  a.data = cast[typeof(a.data)](allocShared0(size))
  a.len = len
  a.cap = size

proc newArrayUninitialized*[T](len: Natural): Array[T] =
  let size = sizeof(T) * len
  result.data = cast[typeof(result.data)](allocShared(size))
  result.len = len
  result.cap = size

proc newArrayOfCap*[T](len: Natural): Array[T] =
  let size = sizeof(T) * len
  result.data = cast[typeof(result.data)](allocShared(size))
  result.len = 0
  result.cap = size

proc newArray*[T](buf: ptr UncheckedArray[T], len: Natural): Array[T] =
  let size = sizeof(T) * len
  result.data = cast[typeof(result.data)](allocShared0(size))
  copyMem(result.data, buf, size)
  result.len = size
  result.cap = size

proc toArray*[T](x: openArray[T]): Array[T] =
  if x.len > 0:
    let size = sizeof(T) * x.len
    result.data = cast[typeof(result.data)](allocShared0(size))
    copyMem(result.data, unsafeAddr x[0], size)
    result.len = x.len

proc toArray*[T](x: seq[T]): Array[T] =
  if x.len > 0:
    let size = sizeof(T) * x.len
    result.data = cast[typeof(result.data)](allocShared0(size))
    copyMem(result.data, unsafeAddr x[0], size)
    result.len = x.len

proc toBytes*[T](x: Array[T]): seq[byte] =
  result = newSeqOfCap[byte](sizeof(T) * x.len)
  for i in 0..<x.len:
    result.add(x[i].toBytes)

proc toSeq*[T](x: Array[T]): seq[T] =
  result = newSeq[T](x.len)
  for i in 0..<x.len:
    result[i] = x[i]

proc `$`*[T](a: Array[T]): string = $a.toSeq

proc toHex*[T](a: Array[T]): string = a.toBytes.toHex

iterator items*[T](a: Array[T]): lent T =
  for i in 0..<a.len:
    yield a.data[i]

iterator pairs*[T](a: Array[T]): tuple[key: int, val: lent T] =
  for i in 0..<a.len:
    yield (i, a.data[i])

proc high*[T](x: Array[T]): int {.inline.} = x.len - 1

proc low*[T](x: Array[T]): int {.inline.} = 0

proc `@^`*[IDX, T](a: sink array[IDX, T]): Array[T] =
  result = newArray[T](a.len)
  for i in 0..a.len-1:
    result[i] = a[i]

proc `@^`*[T](a: sink seq[T]): Array[T] =
  result = newArray[T](a.len)
  for i in 0..a.len-1:
    result[i] = a[i]
