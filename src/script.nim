# Copyright (c) 2020 zenywallet

import sequtils, json
import opcodes, bytes, reader

type
  ChunkType* = enum
    Code
    Data
    PushData1
    PushData2
    PushData4

  ChunkData* = distinct seq[byte]

  Chunk* = object
    case type*: ChunkType
    of Code:
      op*: Opcode
    of Data:
      data*: seq[byte]
    of PushData1, PushData2, PushData4:
      val*: uint

  Chunks* = seq[Chunk]

  ScriptError* = object of CatchableError


proc getScriptChunks*(script: seq[byte]): Chunks =
  result = @[]
  var reader = newReader(script)
  while reader.readable():
    var bval = reader.getUint8
    var op = OpcodeMap[bval]
    if bval < OP_PUSHDATA1.ord and bval > 0:
      result.add(Chunk(type: Data, data: reader.getBytes(bval.int)))
    elif op == OP_PUSHDATA1:
      result.add(Chunk(type: PushData1, val: reader.getUint8.uint))
    elif op == OP_PUSHDATA2:
      result.add(Chunk(type: PushData2, val: reader.getUint16.uint))
    elif op == OP_PUSHDATA4:
      result.add(Chunk(type: PushData4, val: reader.getUint32.uint))
    elif op == OP_RETURN:
      result.add(Chunk(type: Code, op: op))
      result.add(Chunk(type: Data, data: reader.getBytes(reader.left)))
      return
    elif op != NA:
      result.add(Chunk(type: Code, op: op))
    else:
      raise newException(ScriptError, "invalid opcode=" & $bval)

proc filterCodeSeparator*(chunks: Chunks): Chunks =
  var findSep = false
  for c in chunks:
    if c.type == Code and c.op == OP_CODESEPARATOR:
      findSep = true
      break
  if findSep:
    var separatorPos = -1
    var findCheckSig = false
    for i, c in chunks:
      if c.type == Code:
        if c.op == OP_CODESEPARATOR:
          separatorPos = i
        elif c.op == OP_CHECKSIG:
          findCheckSig = true
          break
    if findCheckSig:
      for c in chunks[separatorPos+1..^1]:
        if c.type == Code and c.op == OP_CODESEPARATOR:
          continue
        result.add(c)
    else:
      if separatorPos < chunks.high: 
        result = chunks[separatorPos+1..^1]
      else:
        result = @[]
  else:
    result = chunks

proc toBytes*(op: Opcode): seq[byte] = @[byte op.uint8]

proc toBytes*(chunk: Chunk): seq[byte] =
  if chunk.type == Code:
    result = @[byte chunk.op.uint8]
  elif chunk.type == Data:
    var length = chunk.data.len
    if length < OP_PUSHDATA1.ord and length > 0:
      result = concat(@[byte length], chunk.data)
    else:
      result = chunk.data
  elif chunk.type == PushData1:
    result = (chunk.val.uint8).toBytes
  elif chunk.type == PushData2:
    result = chunk.val.uint16.toBytes
  elif chunk.type == PushData4:
    result = chunk.val.uint32.toBytes

proc toBytes*(chunks: Chunks): seq[byte] =
  var c: seq[byte]
  for chunk in chunks:
    c.add(chunk.toBytes)
  c

proc toBytes*(data: ChunkData): seq[byte] =
  var b = cast[seq[byte]](data)
  if b.len > 0:
    result = concat(varInt(b.len), b)

proc `%`*(chunks: Chunks): JsonNode =
  var s: string
  for chunk in chunks:
    if chunk.type == Code:
      if s.len > 0:
        s.add(" " & $chunk.op)
      else:
        s.add($chunk.op)
    elif chunk.type == Data:
      if s.len > 0:
        s.add(" " & chunk.data.toHex)
      else:
        s.add(chunk.data.toHex)
  result = newJString(s)
