# Copyright (c) 2021 zenywallet

import deoxy
import ed25519
import seed
import lz4
import json
import db, sophia
import address
import bytes
import uthash
import ptlock
import monitor

const DECODE_BUF_SIZE = 1048576
const SERVER_LABELS = ["BitZeny_mainnet", "BitZeny_testnet"]

type
  StreamStage {.pure.} = enum
    None
    Negotiate
    Ready

  StreamId = uint64

  StreamObj = object
    deoxyObj: ptr DeoxyEncrypt
    stage: StreamStage
    seed: DeoxySalt
    prv: Ed25519PrivateKey
    streamId: StreamId

  StreamError* = object of CatchableError


type
  StreamIdTag* {.pure.} = enum
    Unknown

  StreamIdToTagObj* = object
    pair*: KVPair[StreamId]
    tagType*: StreamIdTag
    size*: cint
    tag*: UncheckedArray[byte]

  StreamIdToTag* = ptr StreamIdToTagObj

  MsgDataObj* = object
    size: cint
    data: UncheckedArray[byte]

  MsgData* = ptr MsgDataObj

  MsgId = uint64


proc newTag*(tag: seq[byte], pair: KVPair[StreamId] = nil,
            tagType: StreamIdTag = StreamIdTag.Unknown): StreamIdToTag =
  let p = cast[StreamIdToTag](allocShared0(sizeof(StreamIdToTagObj) + tag.len))
  p.pair = pair
  p.tagType = tagType
  p.size = tag.len.cint
  copyMem(addr p.tag, unsafeAddr tag[0], tag.len)
  result = p

proc `$`*(val: StreamIdToTag): string =
  let tag = (addr val.tag).toBytes(val.size.int)
  result = "(type: " & $val.tagType & ", tag: " & $tag & ")"

proc freeVal[T](val: T) =
  when T is StreamIdToTag:
    val.deallocShared()
  elif T is MsgData:
    val.deallocShared()

loadUthashModules()

# streamId - client
var clientTableObj: KVHandle[ptr Client] = nil
var clientTable: ptr KVHandle[ptr Client] = addr clientTableObj

# tags - streamId
var streamTableObj: KVHandle[StreamId] = nil
var streamTable: ptr KVHandle[StreamId] = addr streamTableObj

# streamId - tags
var tagTableObj: KVHandle[StreamIdToTag] = nil
var tagTable: ptr KVHandle[StreamIdToTag] = addr tagTableObj

var tableLockObj: PthreadLock
var tableLock: ptr PthreadLock = addr tableLockObj


# msgId - streamId
var msgRevTableObj: KVHandle[StreamId] = nil
var msgRevTable: ptr KVHandle[StreamId] = addr msgRevTableObj

# streamId - pair(key: msgId, val: streamId)
var msgTableObj: KVHandle[KVPair[StreamId]] = nil
var msgTable: ptr KVHandle[KVPair[StreamId]] = addr msgTableObj

# msgId - message
var msgDataTableObj: KVHandle[MsgData] = nil
var msgDataTable: ptr KVHandle[MsgData] = addr msgDataTableObj

var msgTableLockObj: PthreadLock
var msgTableLock: ptr PthreadLock = addr msgTableLockObj


proc setTag*(streamId: StreamId, tag: seq[byte], tagType: StreamIdTag = StreamIdTag.Unknown) =
  let sb = streamId.toBytes
  withWriteLock tableLock:
    for t in tagTable.items(sb):
      let tval = (addr t.val.tag).toBytes(t.val.size.int)
      if tval == tag:
        return

    let pair = streamTable.addRet(tag, streamId)
    tagTable.add(sb, newTag(tag, pair, tagType))

proc delTag*(streamId: StreamId, tag: seq[byte]) =
  withWriteLock tableLock:
    tagTable.del(streamId.toBytes, proc (x: StreamIdToTag): bool =
      let tval = (addr x.tag).toBytes(x.size.int)
      result = tval == tag
      if result:
        streamTable.del(x.pair)
      )

proc setTag*(client: ptr Client, tag: seq[byte], tagType: StreamIdTag = StreamIdTag.Unknown) =
  var sobj = cast[ptr StreamObj](client.pStream)
  sobj.streamId.setTag(tag, tagType)

proc delTag*(client: ptr Client, tag: seq[byte]) =
  var sobj = cast[ptr StreamObj](client.pStream)
  sobj.streamId.delTag(tag)

proc newMsg*(msg: seq[byte]): MsgData =
  let p = cast[MsgData](allocShared0(sizeof(MsgDataObj) + msg.len))
  p.size = msg.len.cint
  copyMem(addr p.data, unsafeAddr msg[0], msg.len)
  result = p

proc setMsg*(streamId: StreamId, msgId: MsgId) =
  let pair = msgRevTable.addRet(msgId.toBytes, streamId)
  msgTable.add(streamId.toBytes, pair)

proc delMsg*(streamId: StreamId, msgId: MsgId) =
  msgTable.del(streamId.toBytes, proc(pair: KVPair[StreamId]): bool =
    let hkey = (addr pair.key.data).toBytes(pair.key.size.int)
    result = hkey.toUint64 == msgId.uint64
    if result:
      msgRevTable.del(pair)
    )


var decBuf {.threadvar.}: ptr UncheckedArray[byte]
var decBufSize {.threadvar.}: int

var globalDbInsts: DbInsts
var streamDbInsts {.threadvar.}: DbInsts
var globalNetworks: seq[Network]
var networks {.threadvar.}: seq[Network]
var curStreamId: int
var streamWorkerThread: Thread[void]
var invokeWorkerThread: Thread[void]
var testMessageGeneratorThread: Thread[void]
type
  StreamWorkerChannelParam = tuple[streamId: StreamId, tag: seq[byte], data: seq[byte]]
var streamWorkerChannel: ptr Channel[StreamWorkerChannelParam]
var streamActive* = false
var curMsgId: int

proc streamWorker() {.thread.} =
  var pendingClient: seq[ptr Client]

  while true:
    var channelData = streamWorkerChannel[].recv()
    if not streamActive:
      break

    if channelData.streamId == 0 and channelData.tag.len == 0:
      pendingClient.keepItIf(it.invokeSendEvent() == false)
      if pendingClient.len > 0:
        debug "pendingClient ", pendingClient.len
      continue

    var msgId: MsgId = 0

    template getMsgId() {.dirty.} =
      var curId: int = curMsgId
      while true:
        if curId >= int.high:
          raise newException(ServerNeedRestartError, "Unbelievable! We've reached int64 limit")
        if atomicCompareExchangeN(addr curMsgId, addr curId, curId + 1, false, ATOMIC_RELAXED, ATOMIC_RELAXED):
          break
      msgId = curId.uint64

    template addMsgAndInvoke() {.dirty.} =
      msgDataTable.add(msgId.toBytes, newMsg(channelData.data))
      pendingClient = pendingClient.deduplicate()
      pendingClient.keepItIf(it.invokeSendEvent() == false)
      if pendingClient.len > 0:
        debug "pendingClient ", pendingClient.len

    if channelData.streamId > 0:
      var client = clientTable[channelData.streamId.toBytes]
      if not client.isNil:
        getMsgId()
        withWriteLock msgTableLock:
          setMsg(channelData.streamId, msgId)
        pendingClient.add(client)
        addMsgAndInvoke()
    else:
      var addNew = false
      for s in streamTable.items(channelData.tag):
        var client = clientTable[s.val.toBytes]
        if not client.isNil:
          var sobj = cast[ptr StreamObj](client.pStream)
          if msgId == 0: getMsgId()
          withWriteLock msgTableLock:
            setMsg(sobj.streamId, msgId)
          pendingClient.add(client)
          addNew = true
      if addNew:
        addMsgAndInvoke()

proc invokeWorker() {.thread.} =
  var cnt = 0
  while streamActive:
    sleep(200)
    inc(cnt)
    if cnt >= 5:
      cnt = 0
      streamWorkerChannel[].send((0'u64, @[], @[]))

proc streamSend*(tag: seq[byte], json: JsonNode) =
  streamWorkerChannel[].send((0.StreamId, tag, ($json).toBytes))

proc streamSend*(tag: string, json: JsonNode) =
  streamWorkerChannel[].send((0.StreamId, tag.toBytes, ($json).toBytes))

proc streamSend*(streamId: StreamId, json: JsonNode) =
  streamWorkerChannel[].send((streamId, @[], ($json).toBytes))

proc setDbInsts*(dbInsts: DbInsts, networks: seq[Network]) =
  globalDbInsts = dbInsts
  globalNetworks = networks

proc initExClient*(pClient: ptr Client) =
  pClient.pStream = nil

proc freeExClient*(pClient: ptr Client) =
  var sobj = cast[ptr StreamObj](pClient.pStream)
  if not sobj.isNil:
    if sobj.streamId > 0:
      let sb = sobj.streamId.toBytes
      withWriteLock tableLock:
        clientTable.del(sb)
        tagTable.del(sb, proc (x: StreamIdToTag): bool =
          streamTable.del(x.pair)
          result = true
          )
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

proc initStream*() =
  ptlockInit(tableLock)
  curStreamId = 1
  streamWorkerChannel = cast[ptr Channel[StreamWorkerChannelParam]](allocShared0(sizeof(Channel[StreamWorkerChannelParam])))
  streamWorkerChannel[].open()
  streamActive = true
  curMsgId = 1
  createThread(streamWorkerThread, streamWorker)
  createThread(invokeWorkerThread, invokeWorker)

  proc testMessageGenerator() {.thread.} =
    while streamActive:
      streamSend("testmessage".toBytes, %*{"type": "push", "data": "hello!"})
      sleep(3000)
  createThread(testMessageGeneratorThread, testMessageGenerator)

proc freeStream*() =
  streamActive = false
  streamWorkerChannel[].send((0'u64, @[], @[]))
  var threads: seq[Thread[void]]
  threads.add(testMessageGeneratorThread)
  threads.add(invokeWorkerThread)
  threads.add(streamWorkerThread)
  threads.joinThreads()
  streamWorkerChannel[].close()
  streamWorkerChannel.deallocShared()
  withWriteLock tableLock:
    tagTable.clear()
    streamTable.clear()
    clientTable.clear()
  ptlockDestroy(tableLock)

  withWriteLock msgTableLock:
    msgDataTable.clear()
    msgRevTable.clear()
    msgTable.clear()
  ptlockDestroy(msgTableLock)

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

  var curId: int = curStreamId
  while true:
    if curId >= int.high:
      raise newException(ServerNeedRestartError, "Unbelievable! We've reached int64 limit")
    if atomicCompareExchangeN(addr curStreamId, addr curId, curId + 1, false, ATOMIC_RELAXED, ATOMIC_RELAXED):
      break

  sobj.streamId = curId.StreamId
  client.pStream = sobj

  withWriteLock tableLock:
    clientTable[sobj.streamId.toBytes] = client

  var pubseed = (pub, sobj.seed).toBytes
  var sendRet = client.wsServerSend(pubseed, WebSocketOpcode.Binary)

  result = (true, sendRet)

proc sendCmd(client: ptr Client, data: seq[byte]): SendResult =
  let sobj = cast[ptr StreamObj](client.pStream)
  var outdata = newSeq[byte](LZ4_COMPRESSBOUND(data.len))
  let outsize: uint = outdata.len.uint
  let encLen = sobj.deoxyObj.enc(cast[ptr UncheckedArray[byte]](unsafeAddr data[0]), cast[uint](data.len),
                            cast[ptr UncheckedArray[byte]](addr outdata[0]), outsize)
  if encLen > 0:
    return client.wsServerSend(outdata[0..<encLen], WebSocketOpcode.Binary)
  result = SendResult.None

proc sendCmd(client: ptr Client, s: string): SendResult {.inline.} = client.sendCmd(s.toBytes)

proc sendCmd(client: ptr Client, json: JsonNode): SendResult {.inline.} = client.sendCmd(($json).toBytes)

proc parseCmd(client: ptr Client, json: JsonNode): SendResult =
  result = SendResult.None
  echo json.pretty
  if json.hasKey("cmd"):
    let cmd = json["cmd"].getStr
    if cmd == "noralist":
      result = client.sendCmd(%*{"type": "noralist", "data": SERVER_LABELS})
    elif cmd == "status-on":
      client.setTag("status".toBytes)
    elif cmd == "status-off":
      client.delTag("status".toBytes)
    elif cmd == "mempool-on":
      client.setTag("mempool".toBytes)
    elif cmd == "mempool-off":
      client.delTag("mempool".toBytes)
    elif cmd == "status":
      for i in 0..<monitorInfosCount:
        var m = monitorInfos[][i]
        let jsonData = %*{"type": "status", "data":
                          {"network": SERVER_LABELS[i],
                          "height": m.height, "hash": $m.hash,
                          "blkTime": m.blkTime.fromUnix.format("yyyy-MM-dd HH:mm:ss"),
                          "lastHeight": m.lastHeight}}
        result = client.sendCmd(jsonData)


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
          result = client.parseCmd(json)

          sobj.streamId.setTag("testmessage".toBytes)

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
        return client.sendCmd(%*{"type": "ready"})

    result = SendResult.None

  of WebSocketOpcode.Ping:
    result = client.wsServerSend(data.toString(size), WebSocketOpcode.Pong)

  of WebSocketOpcode.Pong:
    echo "pong ", data.toString(size)
    result = SendResult.Success

  else: # WebSocketOpcode.Close
    result = SendResult.None

proc invokeSendMain(client: ptr Client): SendResult =
  result = SendResult.None
  let sobj = cast[ptr StreamObj](client.pStream)
  let sb = sobj.streamId.toBytes
  withWriteLock msgTableLock:
    for p in msgTable.items(sb):
      let hkey = (addr p.val.key.data).toBytes(p.val.key.size.int)
      var msgId: MsgId = hkey.toUint64
      var val = msgDataTable[msgId.toBytes]
      if val.isNil:
        debug "msg not found msgId=", msgId
        continue
      let data = (addr val.data).toBytes(val.size.int)
      if data.len > 0:
        result = client.sendCmd(data)
        delMsg(sobj.streamId, msgId)
        var refExists = false
        var mb = msgId.toBytes
        for m in msgRevTable.items(mb):
          refExists = true
          break
        if not refExists:
          msgDataTable.del(mb)
        if result == SendResult.Pending:
          break
