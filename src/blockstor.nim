# Copyright (c) 2020 zenywallet

import net, nativesockets
import nimcrypto, byteutils, strutils, sequtils
import endians, times

proc toBytes[T](x: var T): seq[byte] {.inline.} =
  when T is uint8:
    @[byte x]
  else:
    result = newSeq[byte](sizeof(T))
    when T is uint16:
      littleEndian16(addr result[0], addr x)
    elif T is uint32:
      littleEndian32(addr result[0], addr x)
    elif T is uint64:
      littleEndian64(addr result[0], addr x)
    else:
      raiseAssert("unsupported type")

proc toBytesBE[T](x: var T): seq[byte] {.inline.} =
  when T is uint8:
    @[byte x]
  else:
    result = newSeq[byte](sizeof(T))
    when T is uint16:
      bigEndian16(addr result[0], addr x)
    elif T is uint32:
      bigEndian32(addr result[0], addr x)
    elif T is uint64:
      bigEndian64(addr result[0], addr x)
    else:
      raiseAssert("unsupported type")

proc toBytes[T](x: T): seq[byte] {.inline.} =
  when T is uint8:
    @[byte x]
  else:
    var v = x
    v.toBytes

proc toBytesBE[T](x: T): seq[byte] {.inline.} =
  when T is uint8:
    @[byte x]
  else:
    var v = x
    v.toBytesBE

proc toBytes(s: string): seq[byte] {.inline.} = cast[seq[byte]](s.toSeq)

proc var_int[T](val: T): seq[byte] =
  if val < 0xfd:
    @[byte val]
  elif val <= 0xffff:
    concat(@[byte 0xfd], (uint16(val)).toBytes)
  elif val <= 0xffffffff:
    concat(@[byte 0xfe], (uint32(val)).toBytes)
  else:
    concat(@[byte 0xff], (uint64(val)).toBytes)

proc var_str(val: string): seq[byte] = concat(var_int(val.len), val.toBytes)

proc pad(length: int): seq[byte] {.inline.} = newSeq[byte](length)

proc command(val: string): seq[byte] {.inline.} = concat(cast[seq[byte]](val.toSeq), pad(12 - val.len))

var server_ip = "127.0.0.1"
var port: uint16 = 19253 # main 9253, testnet 19253
const PROTOCOL_VERSION = 70015
const MESSAGE_START = 0x59454e59 # main 0xdaa5bef9, testnet 0x59454e59
let ProtocolVersionBytes = (uint32(PROTOCOL_VERSION)).toBytes
let MessageStartBytes = (uint32(MESSAGE_START)).toBytesBE

proc msg_version(): seq[byte] =
  let now = getTime()
  result = concat(ProtocolVersionBytes,
                  (uint64(0xd)).toBytes,
                  (uint64(now.toUnix)).toBytes,
                  pad(26),
                  pad(26),
                  (uint64(0xa5a5)).toBytes,
                  var_str("/blockstor:0.2.0/"),
                  (uint32(0)).toBytes)

proc message(cmd: string, payload: seq[byte]): seq[byte] =
  var checksum = sha256.digest((sha256.digest(payload)).data).data
  result = concat(MessageStartBytes,
                  command(cmd),
                  (uint32(payload.len)).toBytes,
                  checksum[0..<4],
                  payload)

proc toString(s: openarray[byte]): string =
  result = newStringOfCap(len(s))
  for c in s:
    result.add(cast[char](c))

proc unsafeCast[T](x: var byte): T {.inline.} = cast[ptr T](addr x)[]
proc toUint64(x: var byte): uint64 {.inline.} = cast[ptr uint64](addr x)[]
proc toUint32(x: var byte): uint32 {.inline.} = cast[ptr uint32](addr x)[]
proc toUint16(x: var byte): uint16 {.inline.} = cast[ptr uint16](addr x)[]
proc toUint8(x: var byte): uint8 {.inline.} = cast[ptr uint8](addr x)[]

proc main() =
  var address: IpAddress = parseIpAddress(server_ip)
  var sin: Sockaddr_in
  sin.sin_family = type(sin.sin_family)(AF_INET.toInt)
  copyMem(addr sin.sin_addr, unsafeAddr address.address_v4[0], sizeof(sin.sin_addr))
  sin.sin_port = ntohs(port)

  var sock = createNativeSocket()
  const SO_RCVBUF: cint = 8
  var tcp_rmem = sock.getSockOptInt(SOL_SOCKET, SO_RCVBUF)
  echo "RECVBUF=", tcp_rmem
  var buf = newSeq[byte](tcp_rmem)
  echo "connect ret=", sock.connect(cast[ptr SockAddr](addr sin), sizeof(sin).SockLen)
  var data = message("version", msg_version())
  echo "send ret=", sock.send(addr data[0], cast[cint](data.len), cast[cint](0))
  var recvlen = sock.recv(addr buf[0], cast[cint](buf.len), cast[cint](0))
  echo "recvlen=", recvlen
  if recvlen > 0:
    echo recvlen
    echo buf[0..<recvlen]
    echo buf[16..<20]
    echo unsafeCast[uint32](buf[0])
    echo (unsafeCast[uint32](buf[0])).toBytes
  sock.close()

when isMainModule:
  main()
