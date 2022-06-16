# Copyright (c) 2020 zenywallet

import bytes
import arraylib

type
  ArrayReader* = ref object
    data*: Array[byte]
    pos*: int
    size*: int

  PtrReader* = ref object
    data*: ptr UncheckedArray[byte]
    pos*: int
    size*: int

  Reader* = ArrayReader | PtrReader

  ReaderError* = object of CatchableError


proc newReader*(data: Array[byte]): ArrayReader =
  ArrayReader(data: data, pos: 0, size: data.len.int)

proc newReader*[T](data: T): ArrayReader =
  let data = cast[Array[byte]](data)
  ArrayReader(data: data, pos: 0, size: data.len.int)

proc newReader*(data: ptr UncheckedArray[byte], size: int): PtrReader =
  PtrReader(data: data, pos: 0, size: size)

proc newReader*(data: var Array[byte]): PtrReader =
  PtrReader(data: cast[ptr UncheckedArray[byte]](addr data[0]), pos: 0, size: data.len.int)

proc newReader*[T](data: var T): PtrReader =
  let data = cast[Array[byte]](data)
  PtrReader(data: cast[ptr UncheckedArray[byte]](addr data[0]), pos: 0, size: data.len.int)

proc getUint64*(r: Reader): uint64 =
  if r.size < r.pos + 8:
    raise newException(ReaderError, "uint64: out of range")
  result = r.data[r.pos].toUint64
  inc(r.pos, 8)

proc getUint32*(r: Reader): uint32 =
  if r.size < r.pos + 4:
    raise newException(ReaderError, "uint32: out of range")
  result = r.data[r.pos].toUint32
  inc(r.pos, 4)

proc getUint16*(r: Reader): uint16 =
  if r.size < r.pos + 2:
    raise newException(ReaderError, "uint16: out of range")
  result = r.data[r.pos].toUint16
  inc(r.pos, 2)

proc getUint8*(r: Reader): uint8 =
  if r.size < r.pos + 1:
    raise newException(ReaderError, "uint8: out of range")
  result = r.data[r.pos].toUint8
  inc(r.pos)

template getInt64*(r: Reader): int64 = cast[int64](getUint64(r))

template getInt32*(r: Reader): int32 = cast[int32](getUint32(r))

template getInt16*(r: Reader): int16 = cast[int16](getUint16(r))

template getInt8*(r: Reader): int8 = cast[int8](getUint8(r))

proc skip*(r: Reader, skipByte: int) =
  if r.size < r.pos + skipByte:
    raise newException(ReaderError, "skip: out of range")
  inc(r.pos, skipByte)

proc getVarInt*(r: Reader): int =
  var u8 = r.getUint8
  if u8 < 0xfd:
    result = u8.int
  elif u8 == 0xfd:
    result = r.getUint16.int
  elif u8 == 0xfe:
    var u32 = r.getUint32
    when uint32.high.uint64 > int.high.uint64:
      if u32.uint64 > int.high.uint64:
        raise newException(ReaderError, "varint: out of range")
    result = u32.int
  elif u8 == 0xff:
    var u64 = r.getUint64
    if u64 > int.high.uint64:
      raise newException(ReaderError, "varint: out of range")
    result = u64.int

proc getBytes*(r: ArrayReader, size: int): Array[byte] =
  if r.size < r.pos + size:
    raise newException(ReaderError, "bytes: out of range")
  result = r.data[r.pos..<r.pos+size]
  inc(r.pos, size)

proc getBytes*(r: PtrReader, size: int): Array[byte] =
  if r.size < r.pos + size:
    raise newException(ReaderError, "bytes: out of range")
  result = cast[ptr UncheckedArray[byte]](addr r.data[r.pos]).toBytes(size)
  inc(r.pos, size)

proc getVarStr*(r: Reader): string =
  var len = r.getVarInt
  var data = r.getBytes(len)
  result = data.toString

proc readable*(r: Reader): bool = r.size > r.pos

proc left*(r: Reader): int = r.size - r.pos

proc len*(r: Reader): int = r.size
