# Copyright (c) 2021 zenywallet

import deoxy
import ed25519
import seed
import lz4
import json
import db, sophia
import address

const DECODE_BUF_SIZE = 1048576

type
  StreamStage {.pure.} = enum
    None
    Negotiate
    Ready

  StreamObj = object
    deoxyObj: ptr DeoxyEncrypt
    stage: StreamStage
    seed: DeoxySalt
    prv: Ed25519PrivateKey
    streamId: uint64

  StreamError* = object of CatchableError


var decBuf {.threadvar.}: ptr UncheckedArray[byte]
var decBufSize {.threadvar.}: int

var globalDbInsts: DbInsts
var streamDbInsts {.threadvar.}: DbInsts
var globalNetworks: seq[Network]
var networks {.threadvar.}: seq[Network]

proc setDbInsts*(dbInsts: DbInsts, networks: seq[Network]) =
  globalDbInsts = dbInsts
  globalNetworks = networks

proc initExClient*(pClient: ptr Client) =
  pClient.pStream = nil

proc freeExClient*(pClient: ptr Client) =
  var sobj = cast[ptr StreamObj](pClient.pStream)
  if not sobj.isNil:
    deoxy.free(sobj.deoxyObj)
    deallocShared(sobj)
    pClient.pStream = nil

proc initWorker*() =
  if decBuf.isNil:
    decBuf = cast[ptr UncheckedArray[byte]](allocShared0(DECODE_BUF_SIZE))
    decBufSize = DECODE_BUF_SIZE

  {.cast(gcsafe).}:
    deepCopy(streamDbInsts, globalDbInsts)
    deepCopy(networks, globalNetworks)

proc freeWorker*() =
  if not decBuf.isNil:
    decBufSize = 0
    decBuf.deallocShared()

proc streamConnect*(client: ptr Client): tuple[sendFlag: bool, sendResult: SendResult] =
  client.freeExClient()
  var sobj = cast[ptr StreamObj](allocShared0(sizeof(StreamObj)))
  var kpSeed: Ed25519Seed
  if cryptSeed(kpSeed) != 0:
    raise newException(StreamError, "seed failed")
  var pub: Ed25519PublicKey
  ed25519.createKeypair(pub, sobj.prv, kpSeed)
  zeroMem(addr kpSeed[0], sizeof(Ed25519Seed))
  if cryptSeed(sobj.seed) != 0:
    raise newException(StreamError, "seed failed")
  sobj.deoxyObj = deoxy.create()
  sobj.stage = StreamStage.Negotiate
  sobj.streamId = 0
  client.pStream = sobj

  var pubseed = (pub, sobj.seed).toBytes
  var sendRet = client.wsServerSend(pubseed, WebSocketOpcode.Binary)

  result = (true, sendRet)

proc sendCmd(client: ptr Client, json: JsonNode): SendResult =
  var sobj = cast[ptr StreamObj](client.pStream)
  var bdata = ($json).toBytes
  var outdata = newSeq[byte](LZ4_COMPRESSBOUND(bdata.len))
  var outsize: uint = outdata.len.uint
  var encLen = sobj.deoxyObj.enc(cast[ptr UncheckedArray[byte]](addr bdata[0]), cast[uint](bdata.len),
                            cast[ptr UncheckedArray[byte]](addr outdata[0]), outsize)
  if encLen > 0:
    return client.wsServerSend(outdata[0..<encLen], WebSocketOpcode.Binary)
  result = SendResult.None

proc sendCmd(client: ptr Client, cmdType: string, data: seq[byte] | string = ""): SendResult =
  var json: JsonNode
  if data.len > 0:
    json = %*{"type": cmdType, "data": data}
  else:
    json = %*{"type": cmdType}
  return client.sendCmd(json)

proc streamMain(client: ptr Client, opcode: WebSocketOpCode,
                data: ptr UncheckedArray[byte], size: int): SendResult =
  echo "ws opcode=", opcode, " size=", size
  case opcode
  of WebSocketOpcode.Binary, WebSocketOpcode.Text, WebSocketOpcode.Continue:
    var sobj = cast[ptr StreamObj](client.pStream)
    if sobj.stage == StreamStage.Ready:
      var decLen = sobj.deoxyObj.dec(data, size.uint, cast[ptr UncheckedArray[byte]](addr decBuf[0]), decBufSize.uint)
      if decLen > 0:
        try:
          var json = parseJson(decBuf.toString(decLen))
          echo json.pretty

          return SendResult.Success
        except:
          let e = getCurrentException()
          echo e.name, ": ", e.msg

    elif sobj.stage == StreamStage.Negotiate:
      if size == 64:
        let pub_cli: Ed25519PublicKey = cast[ptr array[32, byte]](addr data[0])[]
        let seed_cli: DeoxySalt = cast[ptr array[32, byte]](addr data[32])[]
        var shared: Ed25519SharedSecret
        ed25519.keyExchange(shared, pub_cli, sobj.prv)
        sobj.deoxyObj.setKey(shared, sobj.seed, seed_cli)
        zeroMem(addr sobj.seed[0], sizeof(DeoxySalt))
        zeroMem(addr sobj.prv[0], sizeof(Ed25519PrivateKey))
        sobj.stage = StreamStage.Ready
        return client.sendCmd("ready")

    result = SendResult.None

  of WebSocketOpcode.Ping:
    result = client.wsServerSend(data.toString(size), WebSocketOpcode.Pong)

  of WebSocketOpcode.Pong:
    echo "pong ", data.toString(size)
    result = SendResult.Success

  else: # WebSocketOpcode.Close
    result = SendResult.None
