# Copyright (c) 2020 zenywallet

import json
import ../opcodes, bytes, reader
import arraylib

type
  ChunkType* = enum
    Code
    Data
    PushData1
    PushData2
    PushData4

  ChunkData* = distinct Array[byte]

  Chunk* = object
    case chunkType*: ChunkType
    of Code:
      op*: Opcode
    of Data:
      data*: Array[byte]
    of PushData1, PushData2, PushData4:
      val*: uint

  Chunks* = Array[Chunk]

  Script* = distinct Array[byte]

  ScriptError* = object of CatchableError

proc `$`*(data: Chunks): string = $cast[Array[byte]](data)

proc `$`*(data: Script): string = $cast[Array[byte]](data)

proc getScriptChunks*(script: Script): Chunks =
  var reader = newReader(script)
  try:
    while reader.readable():
      var bval = reader.getUint8
      var op = OpcodeMap[bval]
      if bval < OP_PUSHDATA1.ord and bval > 0:
        result.add(Chunk(chunkType: Data, data: reader.getBytes(bval.int)))
      elif op == OP_PUSHDATA1:
        result.add(Chunk(chunkType: PushData1, val: reader.getUint8.uint))
      elif op == OP_PUSHDATA2:
        result.add(Chunk(chunkType: PushData2, val: reader.getUint16.uint))
      elif op == OP_PUSHDATA4:
        result.add(Chunk(chunkType: PushData4, val: reader.getUint32.uint))
      elif op == OP_RETURN:
        result.add(Chunk(chunkType: Code, op: op))
        result.add(Chunk(chunkType: Data, data: reader.getBytes(reader.left)))
        return
      elif op != NA:
        result.add(Chunk(chunkType: Code, op: op))
      else:
        raise newException(ScriptError, "invalid opcode=" & $bval)
  except:
    let e = getCurrentException()
    echo e.name, ": ", e.msg
    echo "script=", script, " result=", result

proc filterCodeSeparator*(chunks: Chunks): Chunks =
  var findSep = false
  for c in chunks:
    if c.chunkType == Code and c.op == OP_CODESEPARATOR:
      findSep = true
      break
  if findSep:
    var separatorPos = -1
    var findCheckSig = false
    for i, c in chunks:
      if c.chunkType == Code:
        if c.op == OP_CODESEPARATOR:
          separatorPos = i
        elif c.op == OP_CHECKSIG:
          findCheckSig = true
          break
    if findCheckSig:
      for c in chunks[separatorPos+1..^1]:
        if c.chunkType == Code and c.op == OP_CODESEPARATOR:
          continue
        result.add(c)
    else:
      if separatorPos < chunks.high:
        result = chunks[separatorPos+1..^1]
  else:
    result = chunks

proc toBytes*(op: Opcode): Array[byte] = @^[byte op.uint8]

proc toBytes*(chunk: Chunk): Array[byte] =
  if chunk.chunkType == Code:
    result = @^[byte chunk.op.uint8]
  elif chunk.chunkType == Data:
    var length = chunk.data.len
    if length < OP_PUSHDATA1.ord and length > 0:
      result = concat(@^[byte length], chunk.data)
    else:
      result = chunk.data
  elif chunk.chunkType == PushData1:
    result = (chunk.val.uint8).toBytes
  elif chunk.chunkType == PushData2:
    result = chunk.val.uint16.toBytes
  elif chunk.chunkType == PushData4:
    result = chunk.val.uint32.toBytes

proc toBytes*(chunks: Chunks): Array[byte] =
  for chunk in chunks:
    result.add(chunk.toBytes)

proc toBytes*(data: ChunkData): Array[byte] =
  var b = cast[Array[byte]](data)
  if b.len > 0:
    result = concat(varInt(b.len), b)

proc `%`*(chunks: Chunks): JsonNode =
  var s: string
  for chunk in chunks:
    if chunk.chunkType == Code:
      if s.len > 0:
        s.add(" " & $chunk.op)
      else:
        s.add($chunk.op)
    elif chunk.chunkType == Data:
      if s.len > 0:
        s.add(" " & chunk.data.toHex)
      else:
        s.add(chunk.data.toHex)
  result = newJString(s)
