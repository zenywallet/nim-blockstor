# Copyright (c) 2021 zenywallet

import std/sequtils # keepIf
import std/strutils # endsWith
import deoxy
import ed25519
import seed
import lz4
import json
import db, sophia
import address
import bytes
import uthash
#import ptlock
import monitor
import utils
import tcp
import rpc
import blocks, tx, script
import mempool
import opcodes

const DECODE_BUF_SIZE = 1048576
when not declared(SERVER_LABELS):
  const SERVER_LABELS = ["BitZeny_mainnet", "BitZeny_testnet"]
const RPC_NODE_COUNT = SERVER_LABELS.len
when not declared(RPC_WORKER_NUM):
  const RPC_WORKER_NUM = 2
const RPC_WORKER_TOTAL = RPC_WORKER_NUM * RPC_NODE_COUNT

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

  MsgDataType {.pure.} = enum
    Direct
    DirectOnce
    Rawtx
    BlockTmpl
    Mining
    MiningFind
    SendMiningBlock

  MsgDataObj* = object
    msgType: MsgDataType
    size: cint
    data: UncheckedArray[byte]

  MsgData* = ptr MsgDataObj

  MsgId = uint64

  MiningScriptObj* = object
    size: cint
    data: UncheckedArray[byte]

  MiningScript* = ptr MiningScriptObj

  ParseCmdSwitch {.pure.} = enum
    None
    On
    Off

  StreamThreadArgType* {.pure.} = enum
    Void
    NodeId

  StreamThreadArg* = object
    case argType*: StreamThreadArgType
    of StreamThreadArgType.Void:
      discard
    of StreamThreadArgType.NodeId:
      threadId: int
      nodeId*: int

  WrapperStreamThreadArg = tuple[threadFunc: proc(arg: StreamThreadArg) {.thread.}, arg: StreamThreadArg]


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
  result = "(argType: " & $val.tagType & ", tag: " & $tag & ")"

proc freeVal[T](val: T) =
  when T is StreamIdToTag:
    val.deallocShared()
  elif T is MsgData:
    val.deallocShared()
  elif T is MiningScript:
    val.deallocShared()

loadUthashModules()

var clientTable: KVHandle[Client] # streamId - client
var streamTable: KVHandle[StreamId] # tags - streamId
var tagTable: KVHandle[StreamIdToTag] # streamId - tags
var tableLock: RWLock

var msgRevTable: KVHandle[StreamId] # msgId - streamId
var msgTable: KVHandle[KVPair[StreamId]] # streamId - pair(key: msgId, val: streamId)
var msgDataTable: KVHandle[MsgData] # msgId - message
var msgTableLock: RWLock

var miningAddrTable: KVHandle[MiningScript]
var miningAddrTableLock: RWLock

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

proc setTag*(client: Client, tag: seq[byte], tagType: StreamIdTag = StreamIdTag.Unknown) =
  var sobj = cast[ptr StreamObj](client.pStream)
  sobj.streamId.setTag(tag, tagType)

proc delTag*(client: Client, tag: seq[byte]) =
  var sobj = cast[ptr StreamObj](client.pStream)
  sobj.streamId.delTag(tag)

proc newMsg*(msg: seq[byte], msgType: MsgDataType = MsgDataType.Direct): MsgData =
  let p = cast[MsgData](allocShared0(sizeof(MsgDataObj) + msg.len))
  p.msgType = msgType
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

proc setMiningScript(streamId: StreamId, nid: int, script: seq[byte]) =
  let p = cast[MiningScript](allocShared0(sizeof(MiningScriptObj) + script.len))
  p.size = script.len.cint
  copyMem(addr p.data, unsafeAddr script[0], script.len)
  withWriteLock miningAddrTableLock:
    miningAddrTable[(streamId, nid.uint16).toBytes] = p

proc getMiningScript(streamId: StreamId, nid: int): seq[byte] =
  withReadLock miningAddrTableLock:
    let miningAddr = miningAddrTable[(streamId, nid.uint16).toBytes]
    if not miningAddr.isNil:
      result = (addr miningAddr.data).toBytes(miningAddr.size.int)

proc delMiningScript*(streamId: StreamId, nid: int) =
  withWriteLock miningAddrTableLock:
    miningAddrTable.del((streamId, nid.uint16).toBytes)

var decBuf {.threadvar.}: ptr UncheckedArray[byte]
var decBufSize {.threadvar.}: int

var globalDbInsts: DbInsts
var streamDbInsts {.threadvar.}: DbInsts
var globalNetworks: seq[Network]
var networks {.threadvar.}: seq[Network]
var globalNodes: seq[NodeParams]
var node {.threadvar.}: NodeParams
var curStreamId: int
var streamWorkerThread: Thread[WrapperStreamThreadArg]
var invokeWorkerThread: Thread[WrapperStreamThreadArg]
var miningWorkerThread: Thread[WrapperStreamThreadArg]
var miningTemplateWorkerThread: Thread[WrapperStreamThreadArg]
var rpcWorkerThreads: array[RPC_WORKER_TOTAL, Thread[WrapperStreamThreadArg]]
type
  StreamWorkerChannelParam = tuple[streamId: StreamId, tag: seq[byte], data: seq[byte], msgType: MsgDataType]
  RpcWorkerChannelParam = tuple[streamId: StreamId, data: JsonNode, msgType: MsgDataType]
  MiningTemplateChannelParam = tuple[streamId: StreamId, nodeId: int, data: JsonNode, msgType: MsgDataType]
var streamWorkerChannel: ptr Channel[StreamWorkerChannelParam]
var rpcWorkerChannels: array[RPC_NODE_COUNT, ptr Channel[RpcWorkerChannelParam]]
var miningTemplateChannel: ptr Channel[MiningTemplateChannelParam]
var streamActive* = false
var curMsgId: int

proc initExClient*(pClient: Client) =
  pClient.pStream = nil

proc freeExClient*(pClient: Client) {.gcsafe.} =
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
      for nid in streamDbInsts.low..streamDbInsts.high:
        sobj.streamId.delMiningScript(nid)
      withWriteLock msgTableLock:
        for p in msgTable.items(sb):
          let msgIdBytes = (addr p.val.key.data).toBytes(p.val.key.size.int)
          var msgId: MsgId = msgIdBytes.toUint64
          var val = msgDataTable[msgId.toBytes]
          if val.isNil: continue
          var refExists = false
          for m in msgRevTable.items(msgIdBytes):
            refExists = true
            break
          if not refExists:
            msgDataTable.del(msgIdBytes)
    deoxy.free(sobj.deoxyObj)
    deallocShared(sobj)
    pClient.pStream = nil

proc isInvalid*(client: Client): bool = client.fd == osInvalidSocket.int

proc pendingFilter(client: Client): bool =
  result = client.invokeSendEvent() == false
  if result and client.isInvalid():
    result = false
    client.freeExClient()

proc streamWorker(arg: StreamThreadArg) {.thread.} =
  var pendingClient: seq[Client]

  while true:
    var channelData = streamWorkerChannel[].recv()
    if not streamActive:
      break

    if channelData.streamId == 0 and channelData.tag.len == 0:
      pendingClient.keepIf(pendingFilter)
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
      msgDataTable.add(msgId.toBytes, newMsg(channelData.data, channelData.msgType))
      pendingClient = pendingClient.deduplicate()
      pendingClient.keepIf(pendingFilter)
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
      if channelData.msgType == MsgDataType.DirectOnce:
        var tagDelClients: seq[Client]
        for s in streamTable.items(channelData.tag):
          var client = clientTable[s.val.toBytes]
          if not client.isNil:
            var sobj = cast[ptr StreamObj](client.pStream)
            if msgId == 0: getMsgId()
            withWriteLock msgTableLock:
              setMsg(sobj.streamId, msgId)
            pendingClient.add(client)
            addNew = true
            tagDelClients.add(client)
        for client in tagDelClients:
          client.delTag(channelData.tag)
      else:
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

proc invokeWorker(arg: StreamThreadArg) {.thread.} =
  var cnt = 0
  while streamActive:
    sleep(200)
    inc(cnt)
    if cnt >= 5:
      cnt = 0
      echo "invokeWorker disabled"
      #streamWorkerChannel[].send((0'u64, @[], @[], MsgDataType.Direct))

proc streamSend*(tag: seq[byte], json: JsonNode) =
  streamWorkerChannel[].send((0.StreamId, tag, ($json).toBytes, MsgDataType.Direct))

proc streamSend*(tag: string, json: JsonNode) =
  streamWorkerChannel[].send((0.StreamId, tag.toBytes, ($json).toBytes, MsgDataType.Direct))

proc streamSend*(streamId: StreamId, json: JsonNode, msgType: MsgDataType = MsgDataType.Direct) =
  streamWorkerChannel[].send((streamId, @[], ($json).toBytes, msgType))

proc streamSend*(streamId: StreamId, data: seq[byte], msgType: MsgDataType = MsgDataType.Direct) =
  streamWorkerChannel[].send((streamId, @[], data, msgType))

proc streamSendOnce*(tag: seq[byte], json: JsonNode) =
  streamWorkerChannel[].send((0.StreamId, tag, ($json).toBytes, MsgDataType.DirectOnce))

proc streamTagExists*(tag: seq[byte]): bool = streamTable.itemExists(tag)

proc setStreamParams*(dbInsts: DbInsts, networks: seq[Network], nodes: seq[NodeParams]) =
  globalDbInsts = dbInsts
  globalNetworks = networks
  globalNodes = nodes

proc initWorker*() =
  if decBuf.isNil:
    decBuf = cast[ptr UncheckedArray[byte]](allocShared0(DECODE_BUF_SIZE))
    decBufSize = DECODE_BUF_SIZE

  {.cast(gcsafe).}:
    streamDbInsts = globalDbInsts
    networks = globalNetworks

proc freeWorker*() =
  if not decBuf.isNil:
    decBufSize = 0
    decBuf.deallocShared()

type
  TxAddrVal = tuple[hash160: Hash160, addressType: uint8, value: uint64, count: uint32]

proc aggregate(txaddrvals: seq[TxAddrVal]): seq[TxAddrVal] =
  var t = initTable[seq[byte], ref TxAddrVal]()
  for a in txaddrvals:
    var key = (a.hash160, a.addressType).toBytes
    if t.hasKey(key):
      var tkey = t[key]
      tkey.value = tkey.value + a.value
      tkey.count = tkey.count + a.count
    else:
      var ra = new TxAddrVal
      ra[] = a
      t[key] = ra
  for v in t.values:
    result.add(v[])

proc rpcWorker(arg: StreamThreadArg) {.thread.} =
  {.cast(gcsafe).}:
    streamDbInsts = globalDbInsts
    networks = globalNetworks
    node = globalNodes[arg.nodeId]
  var network = networks[arg.nodeId]

  var dbInst = streamDbInsts[arg.nodeId]
  setRpcConfig(RpcConfig(rpcUrl: node.rpcUrl, rpcUserPass: node.rpcUserPass))

  var blockTemplateParam = %*{"rules": ["segwit"]}
  var blockId, prevFoundBlockId: uint32
  var txCount, prevTxCount: uint32
  var prevHash, prevPrevHash: BlockHash
  var blockTmpl: JsonNode

  while true:
    var channelData = rpcWorkerChannels[arg.nodeId][].recv()
    if not streamActive:
      break

    block workerMain:
      var retJson = %*{"type": "", "data": {"err": 0, "res": {}, "nid": arg.nodeId}}
      var json = channelData.data

      template errSendBreak(err: int) {.dirty.} =
        retJson["data"]["err"] = newJint(err)
        if json.hasKey("data"):
          retJson["data"]["res"] = json["data"]
        streamSend(channelData.streamId, retJson, channelData.msgType)
        break workerMain

      try:
        if json.kind != JNull and json.hasKey("ref"):
          retJson["ref"] = json["ref"]
        if channelData.msgType == MsgDataType.Rawtx:
          var data = json["data"]
          retJson["type"] = newJString("tx")
          if not data.hasKey("txid"):
            errSendBreak(1)
          var txidStr = data["txid"].getStr
          var txidHash = txidStr.Hex.toHash
          var txObj: Tx
          var blk: DbBlockHashResult
          var tx = dbInst.getTx(txidHash)
          if tx.err == DbStatus.NotFound:
            var mtx = mempool.mempoolTx(arg.nodeId, txidHash, network)
            if mtx.kind == JNull:
              errSendBreak(2)
            else:
              retJson["data"]["res"] = mtx
              retJson["data"]["res"]["txid"] = newJString(txidStr)
              streamSend(channelData.streamId, retJson, MsgDataType.Rawtx)
              break workerMain
          if tx.res.skip == 1:
            errSendBreak(3)

          var ret_rawtx = rpc.getRawTransaction.send(txidStr, 0)
          if ret_rawtx["result"].kind != JString:
            blk = dbInst.getBlockHash(tx.res.height)
            if blk.err != DbStatus.Success:
              errSendBreak(1)
            var ret_blk = rpc.getBlock.send($blk.res.hash, 0)
            if ret_blk["result"].kind != JString:
              errSendBreak(1)
            var idx = tx.res.id - blk.res.start_id
            var b = ret_blk["result"].getStr.Hex.toBytes.toBlock
            txobj = b.txs[idx]
          else:
            blk = dbInst.getBlockHash(tx.res.height)
            if blk.err != DbStatus.Success:
              errSendBreak(1)
            txobj = ret_rawtx["result"].getStr.Hex.toBytes.toTx

          var fee: uint64 = 0
          var txinvals: seq[TxAddrVal]
          var txoutvals: seq[TxAddrVal]
          var reward = false
          for i in txobj.ins:
            var in_txid = i.tx
            var n = i.n
            if n == 0xffffffff'u32:
              reward = true
            else:
              var ret_tx = dbInst.getTx(in_txid)
              if ret_tx.err == DbStatus.NotFound:
                errSendBreak(1)
              if ret_tx.res.skip == 1:
                errSendBreak(3)
              var id = ret_tx.res.id
              var ret_txout = dbInst.getTxout(id, n)
              if ret_txout.err == DbStatus.NotFound:
                errSendBreak(1)
              txinvals.add((ret_txout.res.address_hash, ret_txout.res.address_type, ret_txout.res.value, 1'u32))

          for n, o in txobj.outs:
            var addrHash = getAddressHash160(o.script)
            txoutvals.add((addrHash.hash160, uint8(addrHash.addressType), o.value, 1'u32))

          var addrins = newJArray()
          var addrouts = newJArray()
          if reward:
            for t in txinvals.aggregate:
              addrins.add(%*{"addr": network.getAddress(t.hash160, t.addressType.AddressType),
                            "val": t.value.toJson, "count": t.count})
            for t in txoutvals.aggregate:
              addrouts.add(%*{"addr": network.getAddress(t.hash160, t.addressType.AddressType),
                            "val": t.value.toJson, "count": t.count})
          else:
            for t in txinvals.aggregate:
              addrins.add(%*{"addr": network.getAddress(t.hash160, t.addressType.AddressType),
                            "val": t.value.toJson, "count": t.count})
              fee = fee + t.value
            for t in txoutvals.aggregate:
              addrouts.add(%*{"addr": network.getAddress(t.hash160, t.addressType.AddressType),
                            "val": t.value.toJson, "count": t.count})
              fee = fee - t.value

          retJson["data"]["res"] = %*{"txid": txidStr,
                                      "ins": addrins, "outs": addrouts,
                                      "fee": fee.toJson, "height": tx.res.height,
                                      "time": blk.res.time, "id": tx.res.id}
          streamSend(channelData.streamId, retJson, MsgDataType.Rawtx)

        elif channelData.msgType == MsgDataType.BlockTmpl:
          var retTmpl = getBlockTemplate.send(blockTemplateParam)
          miningTemplateChannel[].send((0'u64, arg.nodeId, retTmpl["result"], MsgDataType.BlockTmpl))

        elif channelData.msgType == MsgDataType.SendMiningBlock:
          var data = json["data"]
          var retSubmitBlock = submitBlock.send(data.getStr)
          retJson["type"] = newJString("find")
          retJson["data"]["res"] = retSubmitBlock
          streamSend(channelData.streamId, retJson, MsgDataType.SendMiningBlock)

      except:
        let e = getCurrentException()
        echo "rpcWorker ", e.name, ": ", e.msg
        errSendBreak(1)


const WitnessCommitmentHeader = @[byte 0xaa, 0x21, 0xa9, 0xed]

proc miningWorker(arg: StreamThreadArg) {.thread.} =
    while streamActive:
      for i in 0..<RPC_NODE_COUNT:
        if streamTable.itemExists(("mining", i.uint16).toBytes):
          rpcWorkerChannels[i][].send((0'u64, newJNull(), MsgDataType.BlockTmpl))
      sleep(3000)

proc miningTemplateWorker(arg: StreamThreadArg) {.thread.} =
  var prevTxCount: array[RPC_NODE_COUNT, uint32]
  var prevPrevHash: array[RPC_NODE_COUNT, BlockHash]
  var prevCurTime: array[RPC_NODE_COUNT, uint32]
  var curTime: array[RPC_NODE_COUNT, uint32]
  var curTarget: array[RPC_NODE_COUNT, string]
  var curCoinBaseValue: array[RPC_NODE_COUNT, uint64]
  var curHeader: array[RPC_NODE_COUNT, BlockHeader]
  var curTx: array[RPC_NODE_COUNT, Tx]
  var curTxids: array[RPC_NODE_COUNT, seq[seq[byte]]]
  var curTxdatas: array[RPC_NODE_COUNT, seq[seq[byte]]]
  var curWitnessFlags: array[RPC_NODE_COUNT, bool]
  var curWitnessCommitmentScript: array[RPC_NODE_COUNT, seq[byte]]
  var pendingStream: seq[tuple[streamId: StreamId, nodeId: int]]
  var streamBlockHeaders: seq[Table[seq[byte], BlockHeader]]
  for i in 0..<RPC_NODE_COUNT:
    streamBlockHeaders.add(initTable[seq[byte], BlockHeader]())
  let witnessReserved = pad(32)

  while true:
    var channelData = miningTemplateChannel[].recv()
    if not streamActive:
      break

    if channelData.msgType == MsgDataType.BlockTmpl:
      let nodeId = channelData.nodeId
      let blockTmpl = channelData.data
      let prevHash = blockTmpl["previousblockhash"].getStr.Hex.toBlockHash
      let transactions = blockTmpl["transactions"]
      let txCount = transactions.len.uint32
      curTime[nodeId] = blockTmpl["curtime"].getInt.uint32

      template sendMiningData() {.dirty.} =
        let script = streamId.getMiningScript(nodeId).Script
        if curWitnessFlags[nodeId]:
          curTx[nodeId].outs = @[TxOut (value: 0'u64, script: Script(curWitnessCommitmentScript[nodeId])),
                                (value: curCoinBaseValue[nodeId], script: script)]
        else:
          curTx[nodeId].outs = @[TxOut (value: curCoinBaseValue[nodeId], script: script)]
        curTxids[nodeId][0] = curTx[nodeId].txid.toBytes
        curHeader[nodeId].merkle = merkle(curTxids[nodeId])

        var headerTmp = new BlockHeader
        headerTmp[] = curHeader[nodeId][]
        streamBlockHeaders[nodeId][streamId.toBytes] = headerTmp

        let retJson = %*{"type": "mining", "data": {"header": curHeader[nodeId].toBytes.toHex,
                        "target": curTarget[nodeId], "nid": nodeId}}
        streamId.streamSend(retJson)

      if txCount != prevTxCount[nodeId] or prevHash != prevPrevHash[nodeId]:
        prevTxCount[nodeId] = txCount
        prevPrevHash[nodeId] = prevHash

        curTarget[nodeId] = blockTmpl["target"].getStr
        let height = blockTmpl["height"].getInt.uint32
        curCoinBaseValue[nodeId] = blockTmpl["coinbasevalue"].getBiggestInt.uint64
        let sig = concat(@[byte 3'u8], height.toBytes[0..2])

        curWitnessFlags[nodeId] = false
        for t in transactions:
          if t["txid"].getStr != t["hash"].getStr and t["data"].getStr[8..11].Hex.toBytes.toUint16BE == 1'u16:
            curWitnessFlags[nodeId] = true
            if blockTmpl.hasKey("default_witness_commitment"):
              curWitnessCommitmentScript[nodeId] = blockTmpl["default_witness_commitment"].getStr.Hex.toBytes
            else:
              var txHashes: seq[seq[byte]]
              txHashes.add(witnessReserved)
              for t2 in transactions:
                txHashes.add(t2["hash"].getStr.Hex.toHash.toBytes)
              let witnessRootHash = merkle(txHashes)
              let witnessCommitmentHash = sha256d((witnessRootHash, witnessReserved).toBytes).toBytes
              let witnessCommitment = (WitnessCommitmentHeader, witnessCommitmentHash).toBytes
              curWitnessCommitmentScript[nodeId] = (OP_RETURN, PushData(witnessCommitment)).toBytes
            break

        var header = new BlockHeader
        header.ver = blockTmpl["version"].getInt.int32
        header.prev = prevHash
        # header.merkle TBD
        header.time = curTime[nodeId]
        header.bits = blockTmpl["bits"].getStr.Hex.toBytes.toReverse.toUint32
        header.nonce = 0'u32
        curHeader[nodeId] = header

        var tx = new Tx
        tx.ver = 1'i32
        tx.flags = Flags(0'u8)
        tx.ins = @[TxIn (tx: Hash(pad(32)), n: 0xffffffff'u32, sig: Sig(sig), sequence: 0xffffffff'u32)]
        # tx.outs TBD
        tx.locktime = 0
        curTx[nodeId] = tx

        curTxids[nodeId] = @[]
        curTxids[nodeId].add(@[])
        curTxdatas[nodeId] = @[]
        for t in transactions:
          curTxids[nodeId].add(t["txid"].getStr.Hex.toHash.toBytes)
          curTxdatas[nodeId].add(t["data"].getStr.Hex.toBytes)

        streamBlockHeaders[nodeId].clear()
        for s in streamTable.items(("mining", nodeId.uint16).toBytes):
          var client = clientTable[s.val.toBytes]
          if not client.isNil:
            let streamId = cast[ptr StreamObj](client.pStream).streamId
            sendMiningData()
      else:
        if curTime[nodeId] != prevCurTime[nodeId]:
          prevCurTime[nodeId] = curTime[nodeId]
          curHeader[nodeId].time = curTime[nodeId]
          for s in streamTable.items(("mining", nodeId.uint16).toBytes):
            var client = clientTable[s.val.toBytes]
            if not client.isNil:
              let streamId = cast[ptr StreamObj](client.pStream).streamId
              let sb = streamId.toBytes
              if streamBlockHeaders[nodeId].hasKey(sb):
                let h = streamBlockHeaders[nodeId][sb]
                h.time = curTime[nodeId]
                let retJson = %*{"type": "mining", "data": {"header": h.toBytes.toHex,
                                "target": curTarget[nodeId], "nid": nodeId}}
                streamId.streamSend(retJson)
        else:
          for s in pendingStream.deduplicate():
            let nodeId = s.nodeId
            let streamId = s.streamId
            sendMiningData()
          pendingStream = @[]

    elif channelData.msgType == MsgDataType.Mining:
      let streamId = channelData.streamId
      let nodeId = channelData.nodeId
      pendingStream.add((streamId, nodeId))

    elif channelData.msgType == MsgDataType.MiningFind:
      let streamId = channelData.streamId
      let nodeId = channelData.nodeId
      let headerStr = channelData.data["header"].getStr

      let script = streamId.getMiningScript(nodeId).Script
      curTx[nodeId].outs = @[TxOut (value: curCoinBaseValue[nodeId], script: script)]

      var blk = new Block
      blk.header = headerStr.Hex.toBytes.toHeader
      blk.txs.add(curTx[nodeId])
      blk.txn = VarInt(1 + curTxdatas[nodeId].len)

      var rawBlockHexStr = $(blk, curTxDatas).toBytes
      rpcWorkerChannels[nodeId][].send((streamId, %*{"data": rawBlockHexStr}, MsgDataType.SendMiningBlock))



proc streamThreadWrapper(wrapperArg: WrapperStreamThreadArg) {.thread.} =
  echo wrapperArg
  try:
    wrapperArg.threadFunc(wrapperArg.arg)
  except:
    let e = getCurrentException()
    echo e.name, ": ", e.msg
    abort()

proc initStream*() =
  rwlockInit(tableLock)
  rwlockInit(msgTableLock)
  rwlockInit(miningAddrTableLock)
  curStreamId = 1
  streamWorkerChannel = cast[ptr Channel[StreamWorkerChannelParam]](allocShared0(sizeof(Channel[StreamWorkerChannelParam])))
  streamWorkerChannel[].open()
  for i in 0..<RPC_NODE_COUNT:
    rpcWorkerChannels[i] = cast[ptr Channel[RpcWorkerChannelParam]](allocShared0(sizeof(Channel[RpcWorkerChannelParam])))
    rpcWorkerChannels[i][].open()
  streamActive = true
  curMsgId = 1
  miningTemplateChannel = cast[ptr Channel[MiningTemplateChannelParam]](allocShared0(sizeof(Channel[MiningTemplateChannelParam])))
  miningTemplateChannel[].open()
  createThread(streamWorkerThread, streamThreadWrapper, (streamWorker, StreamThreadArg(argType: StreamThreadArgType.Void)))
  createThread(invokeWorkerThread, streamThreadWrapper, (invokeWorker, StreamThreadArg(argType: StreamThreadArgType.Void)))

  var threadId = 0
  for i in 0..<RPC_NODE_COUNT:
    for j in 0..<RPC_WORKER_NUM:
      createThread(rpcWorkerThreads[threadId], streamThreadWrapper,
                  (rpcWorker, StreamThreadArg(argType: StreamThreadArgType.NodeId, threadId: threadId, nodeId: i)))
      inc(threadId)
  createThread(miningTemplateWorkerThread, streamThreadWrapper, (miningTemplateWorker, StreamThreadArg(argType: StreamThreadArgType.Void)))
  createThread(miningWorkerThread, streamThreadWrapper, (miningWorker, StreamThreadArg(argType: StreamThreadArgType.Void)))

proc freeStream*() =
  streamActive = false
  for i in 0..<RPC_NODE_COUNT:
    for j in 0..<RPC_WORKER_NUM:
      rpcWorkerChannels[i][].send((0'u64, newJNull(), MsgDataType.Direct))
  streamWorkerChannel[].send((0'u64, @[], @[], MsgDataType.Direct))
  miningTemplateChannel[].send((0'u64, 0, newJNull(), MsgDataType.Direct))
  joinThreads(miningWorkerThread, miningTemplateWorkerThread, invokeWorkerThread, streamWorkerThread)
  miningTemplateChannel[].close()
  miningTemplateChannel.deallocShared()
  for i in 0..<RPC_NODE_COUNT:
    rpcWorkerChannels[i][].close()
    rpcWorkerChannels[i].deallocShared()
  streamWorkerChannel[].close()
  streamWorkerChannel.deallocShared()
  withWriteLock tableLock:
    tagTable.clear()
    streamTable.clear()
    clientTable.clear()
  rwlockDestroy(tableLock)

  withWriteLock msgTableLock:
    msgDataTable.clear()
    msgRevTable.clear()
    msgTable.clear()
  rwlockDestroy(msgTableLock)

  withWriteLock miningAddrTableLock:
    miningAddrTable.clear()
  rwlockDestroy(miningAddrTableLock)

proc streamConnect*(client: Client): tuple[sendFlag: bool, sendResult: SendResult] =
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

proc sendCmd(client: Client, data: seq[byte]): SendResult =
  let sobj = cast[ptr StreamObj](client.pStream)
  var outdata = newSeq[byte](LZ4_COMPRESSBOUND(data.len))
  let outsize: uint = outdata.len.uint
  let encLen = sobj.deoxyObj.enc(cast[ptr UncheckedArray[byte]](unsafeAddr data[0]), cast[uint](data.len),
                            cast[ptr UncheckedArray[byte]](addr outdata[0]), outsize)
  if encLen > 0:
    return client.wsServerSend(outdata[0..<encLen], WebSocketOpcode.Binary)
  result = SendResult.None

proc sendCmd(client: Client, s: string): SendResult {.inline.} = client.sendCmd(s.toBytes)

proc sendCmd(client: Client, json: JsonNode): SendResult {.inline.} = client.sendCmd(($json).toBytes)

proc parseCmd(client: Client, json: JsonNode): SendResult =
  result = SendResult.None
  echo json.pretty

  if json.hasKey("cmd"):
    var cmd = json["cmd"].getStr
    var cmdSwitch: ParseCmdSwitch = ParseCmdSwitch.None
    if cmd.endsWith("-on"):
      cmdSwitch = ParseCmdSwitch.On
      cmd = cmd[0..^4]
    elif cmd.endsWith("-off"):
      cmdSwitch = ParseCmdSwitch.Off
      cmd = cmd[0..^5]
    if cmd == "addr":
      let reqData = json["data"]
      let nid = reqData["nid"].getInt
      let astr = reqData["addr"].getStr
      if nid > streamDbInsts.high or nid < streamDbInsts.low:
        raise newException(StreamError, "invalid nid")
      let (hash160, addressType) = networks[nid].getHash160AddressType(astr)
      if addressType == AddressType.Unknown:
        raise newException(StreamError, "invalid address")
      if cmdSwitch == ParseCmdSwitch.On:
        client.setTag((hash160, addressType, nid.uint16).toBytes)
      elif cmdSwitch == ParseCmdSwitch.Off:
        client.delTag((hash160, addressType, nid.uint16).toBytes)
        return
      var resJson: JsonNode
      if json.hasKey("ref"):
        resJson = %*{"type": "addr", "data": {}, "ref": json["ref"]}
      else:
        resJson = %*{"type": "addr", "data": {}}
      var aval = streamDbInsts[nid].getAddrval(networks[nid].getHash160(astr))
      if aval.err == DbStatus.Success:
        resJson["data"] = %*{"nid": nid, "addr": astr, "val": aval.res.value.toJson, "utxo_count": aval.res.utxo_count}
      else:
        resJson["data"] = %*{"nid": nid, "addr": astr}
      result = client.sendCmd(resJson)  # Send by tag is always after this sending.
    elif cmd == "addrs":
      let reqData = json["data"]
      let nid = reqData["nid"].getInt
      let astr = reqData["addr"].getStr
      if nid > streamDbInsts.high or nid < streamDbInsts.low:
        raise newException(StreamError, "invalid nid")
      if cmdSwitch == ParseCmdSwitch.Off:
        let (hash160, addressType) = networks[nid].getHash160AddressType(astr)
        client.delTag((hash160, addressType, nid.uint16).toBytes)
        return
      var resJson: JsonNode
      if json.hasKey("ref"):
        resJson = %*{"type": "addrs", "data": [], "ref": json["ref"]}
      else:
        resJson = %*{"type": "addrs", "data": []}
      var resData = resJson["data"]
      if cmdSwitch == ParseCmdSwitch.On:
        for a in reqData["addrs"]:
          var astr = a.getStr
          let (hash160, addressType) = networks[nid].getHash160AddressType(astr)
          client.setTag((hash160, addressType, nid.uint16).toBytes)
          var aval = streamDbInsts[nid].getAddrval(networks[nid].getHash160(astr))
          if aval.err == DbStatus.Success:
            resData.add(%*{"nid": nid, "addr": astr, "val": aval.res.value.toJson, "utxo_count": aval.res.utxo_count})
          else:
            resData.add(%*{"nid": nid, "addr": astr})
      else:
        for a in reqData["addrs"]:
          var astr = a.getStr
          var aval = streamDbInsts[nid].getAddrval(networks[nid].getHash160(astr))
          if aval.err == DbStatus.Success:
            resData.add(%*{"nid": nid, "addr": astr, "val": aval.res.value.toJson, "utxo_count": aval.res.utxo_count})
          else:
            resData.add(%*{"nid": nid, "addr": astr})
      result = client.sendCmd(resJson)
    elif cmd == "utxo":
      let reqData = json["data"]
      let nid = reqData["nid"].getInt
      let astr = reqData["addr"].getStr
      if nid > streamDbInsts.high or nid < streamDbInsts.low:
        raise newException(StreamError, "invalid nid")
      var utxos = newJArray()
      var count = 0
      var limit = 101
      if reqData.hasKey("limit"):
        limit = reqData["limit"].getInt + 1
        if limit > 1001:
          limit = 1001
      var cont = false
      var next: uint64
      var rev = 0
      if reqData.hasKey("rev") and reqData["rev"].getInt > 0:
        rev = 1
      var gte = uint64.low
      var lte = uint64.high
      if reqData.hasKey("gte"):
        gte = reqData["gte"].toUint64
      if reqData.hasKey("lte"):
        lte = reqData["lte"].toUint64
      if reqData.hasKey("gt"):
        let gt = reqData["gt"].toUint64
        if gt.uint64 == uint64.high:
          raise newException(StreamError, "invalid gt")
        gte = gt + 1
      if reqData.hasKey("lt"):
        let lt = reqData["lt"].toUint64
        if lt.uint64 == uint64.low:
          raise newException(StreamError, "invalid lt")
        lte = lt - 1
      for u in streamDbInsts[nid].getUnspents(networks[nid].getHash160(astr), (gte: gte, lte: lte, rev: rev)):
        inc(count)
        let sid = u.id
        if count >= limit and (sid < lte or sid > gte):
          cont = true
          next = sid
          break
        let retId = streamDbInsts[nid].getId(sid)
        if retId.err == DbStatus.NotFound:
          raise newException(StreamError, "id not found")
        utxos.add(%*{"id": sid.toJson, "tx": $retId.res, "n": u.n, "val": u.value.toJson})
      var jsonData: JsonNode
      if cont:
        jsonData = %*{"type": "utxo", "data": {"nid": nid, "addr": astr, "utxos": utxos, "next": next.toJson}}
      else:
        jsonData = %*{"type": "utxo", "data": {"nid": nid, "addr": astr, "utxos": utxos}}
      if json.hasKey("ref"):
        jsonData["ref"] = json["ref"]
      echo "jsonData", jsonData
      result = client.sendCmd(jsonData)
    elif cmd == "addrlog":
      let reqData = json["data"]
      let nid = reqData["nid"].getInt
      let astr = reqData["addr"].getStr
      if nid > streamDbInsts.high or nid < streamDbInsts.low:
        raise newException(StreamError, "invalid nid")
      var addrlogs = newJArray()
      var count = 0
      var limit = 101
      if reqData.hasKey("limit"):
        limit = reqData["limit"].getInt + 1
        if limit > 1001:
          limit = 1001
      var cont = false
      var next: uint64
      var rev = 0
      if reqData.hasKey("rev") and reqData["rev"].getInt > 0:
        rev = 1
      var gte = uint64.low
      var lte = uint64.high
      if reqData.hasKey("gte"):
        gte = reqData["gte"].toUint64
      if reqData.hasKey("lte"):
        lte = reqData["lte"].toUint64
      if reqData.hasKey("gt"):
        let gt = reqData["gt"].toUint64
        if gt.uint64 == uint64.high:
          raise newException(StreamError, "invalid gt")
        gte = gt + 1
      if reqData.hasKey("lt"):
        let lt = reqData["lt"].toUint64
        if lt.uint64 == uint64.low:
          raise newException(StreamError, "invalid lt")
        lte = lt - 1
      var addrlist = newSeq[string](AddressType.high.int + 1)
      for u in streamDbInsts[nid].getAddrlogs(networks[nid].getHash160(astr), (gte: gte, lte: lte, rev: rev)):
        inc(count)
        let sid = u.id
        if count >= limit and (sid < lte or sid > gte):
          cont = true
          next = sid
          break
        let retId = streamDbInsts[nid].getId(sid)
        if retId.err == DbStatus.NotFound:
          raise newException(StreamError, "id not found")
        let txid = retId.res
        let retTxid = streamDbInsts[nid].getTx(txid)
        if retTxid.err == DbStatus.NotFound:
          raise newException(StreamError, "txid not found")
        let height = retTxid.res.height
        let retBlock = streamDbInsts[nid].getBlockHash(height)
        if retBlock.err == DbStatus.NotFound:
          raise newException(StreamError, "block not found")
        let time = retBlock.res.time
        let retMined = streamDbInsts[nid].getMinedId(sid)
        var mined = 0
        if retMined.err == DbStatus.Success:
          mined = 1
        addrlogs.add(%*{"id": sid.toJson, "tx": $txid, "trans": u.trans, "val": u.value.toJson, "height": height, "blktime": time, "mined": mined})
      var jsonData: JsonNode
      if cont:
        jsonData = %*{"type": "addrlog", "data": {"nid": nid, "addr": astr, "addrlogs": addrlogs, "next": next.toJson}}
      else:
        jsonData = %*{"type": "addrlog", "data": {"nid": nid, "addr": astr, "addrlogs": addrlogs}}
      if json.hasKey("ref"):
        jsonData["ref"] = json["ref"]
      echo "jsonData", jsonData
      result = client.sendCmd(jsonData)
    elif cmd == "height":
      if json.hasKey("data") and json["data"].hasKey("nid"):
        let reqData = json["data"]
        let nid = reqData["nid"].getInt
        if nid > streamDbInsts.high or nid < streamDbInsts.low:
          raise newException(StreamError, "invalid nid")
        if cmdSwitch == ParseCmdSwitch.On:
          client.setTag(("heightonce", nid.uint16).toBytes)
          client.setTag(("height", nid.uint16).toBytes)
        elif cmdSwitch == ParseCmdSwitch.Off:
          client.delTag(("heightonce", nid.uint16).toBytes)
          client.delTag(("height", nid.uint16).toBytes)
        else:
          client.setTag(("heightonce", nid.uint16).toBytes)
      else:
        for nid in streamDbInsts.low..streamDbInsts.high:
          if cmdSwitch == ParseCmdSwitch.On:
            client.setTag(("heightonce", nid.uint16).toBytes)
            client.setTag(("height", nid.uint16).toBytes)
          elif cmdSwitch == ParseCmdSwitch.Off:
            client.delTag(("heightonce", nid.uint16).toBytes)
            client.delTag(("height", nid.uint16).toBytes)
          else:
            client.setTag(("heightonce", nid.uint16).toBytes)
      return
    elif cmd == "noralist":
      result = client.sendCmd(%*{"type": "noralist", "data": SERVER_LABELS})
    elif cmd == "status":
      if cmdSwitch == ParseCmdSwitch.On:
        client.setTag("status".toBytes)
      elif cmdSwitch == ParseCmdSwitch.Off:
        client.delTag("status".toBytes)
        return
      for i in 0..<monitorInfosCount:
        var m = monitorInfos[][i]
        let jsonData = %*{"type": "status", "data":
                          {"nid": i,
                          "network": SERVER_LABELS[i],
                          "height": m.height, "hash": $m.hash,
                          "blkTime": m.blkTime,
                          "lastHeight": m.lastHeight}}
        result = client.sendCmd(jsonData)
    elif cmd == "mempool":
      if cmdSwitch == ParseCmdSwitch.On:
        client.setTag("mempool".toBytes)
      elif cmdSwitch == ParseCmdSwitch.Off:
        client.delTag("mempool".toBytes)
    elif cmd == "tx":
      let reqData = json["data"]
      let nid = reqData["nid"].getInt
      let sobj = cast[ptr StreamObj](client.pStream)
      let streamId = sobj.streamId
      rpcWorkerChannels[nid][].send((streamId, json, MsgDataType.Rawtx))
    elif cmd == "block":
      let reqData = json["data"]
      let nid = reqData["nid"].getInt
      if nid > streamDbInsts.high or nid < streamDbInsts.low:
        raise newException(StreamError, "invalid nid")
      var blks = newJArray()
      var count = 0
      let height = reqData["height"].getInt
      var limit = 100
      if reqData.hasKey("limit"):
        limit = reqData["limit"].getInt
        if limit > 1000:
          limit = 1000
      for b in streamDbInsts[nid].getBlockHashes(height):
        blks.add(%*{"height": b.height, "hash": b.hash, "time": b.time, "start_id": b.start_id})
        inc(count)
        if count >= limit:
          break
      var jsonData = %*{"type": "block", "data": {"nid": nid, "blocks": blks}}
      if json.hasKey("ref"):
        jsonData["ref"] = json["ref"]
      echo "jsonData", jsonData
      result = client.sendCmd(jsonData)
    elif cmd == "mining":
      let reqData = json["data"]
      let nid = reqData["nid"].getInt
      if nid > streamDbInsts.high or nid < streamDbInsts.low:
        raise newException(StreamError, "invalid nid")
      let sobj = cast[ptr StreamObj](client.pStream)
      let streamId = sobj.streamId
      if cmdSwitch == ParseCmdSwitch.On:
        let astr = reqData["addr"].getStr
        streamId.setMiningScript(nid, networks[nid].getScript(astr))
        client.setTag(("mining", nid.uint16).toBytes)
        miningTemplateChannel[].send((streamId, nid, newJNull(), MsgDataType.Mining))
      elif cmdSwitch == ParseCmdSwitch.Off:
        client.delTag(("mining", nid.uint16).toBytes)
        streamId.delMiningScript(nid)
    elif cmd == "find":
      let reqData = json["data"]
      let nid = reqData["nid"].getInt
      if nid > streamDbInsts.high or nid < streamDbInsts.low:
        raise newException(StreamError, "invalid nid")
      let sobj = cast[ptr StreamObj](client.pStream)
      let streamId = sobj.streamId
      miningTemplateChannel[].send((streamId, nid, %*{"header": reqData["header"].getStr}, MsgDataType.MiningFind))

proc streamMain(client: Client, opcode: WebSocketOpCode,
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

proc invokeSendMain(client: Client): SendResult =
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
      let msgType = val.msgType
      let data = (addr val.data).toBytes(val.size.int)
      if data.len > 0:
        if msgType == MsgDataType.Direct:
          result = client.sendCmd(data)
        elif msgType == MsgDataType.DirectOnce:
          result = client.sendCmd(data)
        elif msgType == MsgDataType.Rawtx:
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
