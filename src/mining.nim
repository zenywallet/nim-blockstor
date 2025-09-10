# Copyright (c) 2021 zenywallet

import std/os
import std/times
import std/posix
import std/sequtils
import std/strformat
import bytes, blocks, tx, address, script
import yespower, seed, rpc
import opcodes
import utils

const MINER_THREAD_NUM = 4
const NETWORK_ID = NetworkId.BitZeny_testnet
const RPC_URL = "http://127.0.0.1:19252/"
const RPC_USER_PASSWORD = "rpcuser:rpcpassword"
const PAYOUT_ADDRESS = "your payout address"

type
  MinerData = object
    header: BlockHeaderObj
    target: array[32, byte]
    blockId: uint32

  MinerParam = object
    data: ptr MinerData
    abort: bool

  MessageCmd = enum
    None
    FindBlock
    UpdateBlock

  Message = ref object
    cmd: MessageCmd
    header: BlockHeaderObj
    blockId: uint32
    blockHash: BlockHash

const WitnessCommitmentHeader = @[byte 0xaa, 0x21, 0xa9, 0xed]

var minerParams: ptr UncheckedArray[MinerParam]
var minerDatas: ptr UncheckedArray[MinerData]
var messageChannel: ptr Channel[Message]
var abort: bool = false

proc miner(param: ptr MinerParam) {.thread.} =
  var yhash: YespowerHash
  while not param.abort:
    let data = param.data
    discard yespower_hash(cast[ptr UncheckedArray[byte]](addr data[].header), 80, yhash)
    block findBlock:
      for j in countdown(31, 0):
        if yhash[j] > data[].target[j]:
          break findBlock
        elif yhash[j] < data[].target[j]:
          break
      messageChannel[].send(Message(cmd: MessageCmd.FindBlock, header: data[].header,
                                    blockId: data[].blockId, blockHash: yhash.toBytes.BlockHash))
    inc(cast[var uint32](addr data[].header.nonce))

proc updateBlockInvoker() {.thread.} =
  while not abort:
    var msg = new Message
    msg.cmd = MessageCmd.UpdateBlock
    messageChannel[].send(msg)
    sleep(1000)

proc doAbort() =
  abort = true
  var msg = new Message
  msg.cmd = MessageCmd.None
  messageChannel[].send(msg)

proc main() =
  minerParams = cast[ptr UncheckedArray[MinerParam]](allocShared0(sizeof(MinerParam) * MINER_THREAD_NUM))
  minerDatas = cast[ptr UncheckedArray[MinerData]](allocShared0(sizeof(MinerData) * MINER_THREAD_NUM * 2))
  messageChannel = cast[ptr Channel[Message]](allocShared0(sizeof(Channel[Message])))
  messageChannel[].open()

  setRpcConfig(RpcConfig(rpcUrl: RPC_URL, rpcUserPass: RPC_USER_PASSWORD))
  var network = getNetwork(NETWORK_ID)
  var myAddressScript = network.getScript(PAYOUT_ADDRESS)
  echo "network:", NETWORK_ID, " payout:", PAYOUT_ADDRESS

  var blockTemplateParam = %*{"rules": ["segwit"]}
  var blockId, prevFoundBlockId: uint32
  var txCount, prevTxCount: uint32
  var prevHash, prevPrevHash: BlockHash
  var shiftCount: uint32
  var statsCountStart = newSeq[uint32](MINER_THREAD_NUM)
  var statsCountEnd = newSeq[uint32](MINER_THREAD_NUM)
  var statsTimeStart, statsTimeEnd: float
  var statsFind: int
  var updateBlockTemplate = false
  let witnessReserved = pad(32)

  var invokerThread: Thread[void]
  createThread(invokerThread, updateBlockInvoker)

  var minerThreads: array[MINER_THREAD_NUM, Thread[ptr MinerParam]]
  for i in 0..<MINER_THREAD_NUM:
    minerParams[][i].data = addr minerDatas[][i]
    minerParams[][i].abort = false
    createThread(minerThreads[i], miner, addr minerParams[][i])

  var rawBlock: seq[byte]
  var target: seq[byte]

  while not abort:
    var message = messageChannel[].recv()
    if message.cmd == MessageCmd.FindBlock:
      if blockId == message.blockId:
        if rawBlock.len > 80:
          var findBlock = (message.header, rawBlock[80..^1]).toBytes
          var retSubmit = submitBlock.send($findBlock)
          echo "find block - ", message.blockHash
          if retSubmit["error"].kind == JNull:
            if prevFoundBlockId == message.blockId:
              echo "submit success (already submitted the same block height)"
            else:
              echo "submit success"
              prevFoundBlockId = message.blockId
              inc(statsFind)
              updateBlockTemplate = true
          else:
            echo "submit failed ", retSubmit
      else:
        echo "stale block - ", message.blockHash

    elif message.cmd == MessageCmd.UpdateBlock:
      updateBlockTemplate = true

    if updateBlockTemplate:
      var retTmpl = getBlockTemplate.send(blockTemplateParam)
      if retTmpl["error"].kind != JNull:
        echo "get template failed ", retTmpl
        doAbort()
        break
      var blockTmpl = retTmpl["result"]
      prevHash = blockTmpl["previousblockhash"].getStr.Hex.toBlockHash
      var transactions = blockTmpl["transactions"]
      txCount = transactions.len.uint32
      var curTime, prevCurTime: uint32
      curTime = blockTmpl["curtime"].getInt.uint32
      if txCount != prevTxCount or prevHash != prevPrevHash:
        prevTxCount = txCount
        prevPrevHash = prevHash
        target = blockTmpl["target"].getStr.Hex.toHash.toBytes
        var height = blockTmpl["height"].getInt.uint32
        var coinBaseValue = blockTmpl["coinbasevalue"].getBiggestInt.uint64
        var sig = concat(@[byte 3'u8], height.toBytes[0..2])
        var witnessFlag = false
        for t in transactions:
          if t["txid"].getStr != t["hash"].getStr and t["data"].getStr[8..11].Hex.toBytes.toUint16BE == 1'u16:
            witnessFlag = true
            break
        var tx = new Tx
        tx.ver = 1'i32
        tx.flags = Flags(0'u8)
        tx.ins = @[TxIn (tx: Hash(pad(32)), n: 0xffffffff'u32, sig: Sig(sig), sequence: 0xffffffff'u32)]
        if witnessFlag:
          var witnessCommitmentScript: seq[byte]
          if blockTmpl.hasKey("default_witness_commitment"):
            witnessCommitmentScript = blockTmpl["default_witness_commitment"].getStr.Hex.toBytes
          else:
            var txHashes: seq[seq[byte]]
            txHashes.add(witnessReserved)
            for t in transactions:
              txHashes.add(t["hash"].getStr.Hex.toHash.toBytes)
            let witnessRootHash = merkle(txHashes)
            let witnessCommitmentHash = sha256d((witnessRootHash, witnessReserved).toBytes).toBytes
            let witnessCommitment = (WitnessCommitmentHeader, witnessCommitmentHash).toBytes
            witnessCommitmentScript = (OP_RETURN, PushData(witnessCommitment)).toBytes
          tx.outs = @[TxOut (value: 0'u64, script: Script(witnessCommitmentScript)),
                    (value: coinBaseValue, script: Script(myAddressScript))]
        else:
          tx.outs = @[TxOut (value: coinBaseValue, script: Script(myAddressScript))]
        tx.locktime = 0
        var txid = tx.txid

        var txids: seq[seq[byte]]
        txids.add(cast[seq[byte]](txid))
        for t in transactions:
          txids.add(t["txid"].getStr.Hex.toHash.toBytes)

        var header = new BlockHeader
        header.ver = blockTmpl["version"].getInt.int32
        header.prev = prevHash
        header.merkle = merkle(txids)
        header.time = curTime
        header.bits = blockTmpl["bits"].getStr.Hex.toBytes.toReverse.toUint32
        header.nonce = 0'u32

        var blk = new Block
        blk.header = header
        blk.txn = VarInt(1 + txCount)
        blk.txs.add(tx)

        var txdatas: seq[seq[byte]]
        for t in transactions:
          txdatas.add(t["data"].getStr.Hex.toBytes)

        rawBlock = (blk, txdatas).toBytes

        inc(blockId)
        var nonceBase: uint32
        discard cryptSeed(cast[ptr UncheckedArray[byte]](addr nonceBase), 4)
        var shift = MINER_THREAD_NUM * (shiftCount mod 2).int
        for i in 0..<MINER_THREAD_NUM:
          let pdata = addr minerDatas[][i + shift]
          pdata[].header = cast[ptr BlockHeaderObj](addr rawBlock[0])[]
          pdata[].target = cast[ptr array[32, byte]](addr target[0])[]
          pdata[].blockId = blockId
          var nonce = nonceBase + (i * (uint32.high.int / MINER_THREAD_NUM).int).uint32
          copyMem(addr pdata[].header.nonce, addr nonce, 4)
          minerParams[][i].data = pdata
        inc(shiftCount)
        statsTimeStart = 0.0
        echo "new block template #", height
      else:
        if curTime != prevCurTime:
          prevCurTime = curTime
          if shiftCount mod 2 == 0:
            for i in 0..<MINER_THREAD_NUM:
              let pdata = addr minerDatas[][i]
              pdata[] = minerDatas[][i + MINER_THREAD_NUM]
              copyMem(addr pdata[].header.time, addr curTime, 4)
              minerParams[][i].data = pdata
          else:
            for i in 0..<MINER_THREAD_NUM:
              let pdata = addr minerDatas[][i + MINER_THREAD_NUM]
              pdata[] = minerDatas[][i]
              copyMem(addr pdata[].header.time, addr curTime, 4)
              minerParams[][i].data = pdata
          inc(shiftCount)

      template statsStart() {.dirty.} =
        statsTimeStart = epochTime()
        for i in 0..<MINER_THREAD_NUM:
          statsCountStart[i] = minerParams[][i].data[].header.nonce

      template statsEnd() {.dirty.} =
        statsTimeEnd = epochTime()
        for i in 0..<MINER_THREAD_NUM:
          statsCountEnd[i] = minerParams[][i].data[].header.nonce

      if statsTimeStart > 0:
        if epochTime() - statsTimeStart > 5.0:
          statsEnd()
          var elapsed = statsTimeEnd - statsTimeStart
          var hashRateStr: string = fmt"Found:{statsFind} "
          var ths: float
          for i in 0..<MINER_THREAD_NUM:
            var hs = (statsCountEnd[i] - statsCountStart[i]).float / elapsed
            ths = ths + hs
            hashRateStr.add(fmt"{i}:{hs:.3f} ")
          hashRateStr.add(fmt"Total:{ths:.3f} H/s")
          echo hashRateStr
          statsStart()
      else:
        statsStart()

  for i in 0..<MINER_THREAD_NUM:
    minerParams[][i].abort = true

  minerThreads.joinThreads()
  invokerThread.joinThread()

  messageChannel[].close()
  messageChannel.deallocShared()
  minerDatas.deallocShared()
  minerParams.deallocShared()


when isMainModule:
  onSignal(SIGINT, SIGTERM):
    echo "bye from signal ", sig
    doAbort()

  signal(SIGPIPE, SIG_IGN)

  try:
    main()
  except:
    let e = getCurrentException()
    echo e.name, ": ", e.msg
