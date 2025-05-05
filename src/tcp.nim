# Copyright (c) 2020 zenywallet

import std/[net, nativesockets, posix]
import std/[strutils, sequtils]
import std/[times, os, re, json, terminal]
import bytes, reader, utils, blocks
import address

when not compileOption("threads"):
  {.error: "requires --threads:on option.".}

const SEND_PING* = defined(SEND_PING)

type
  Version = distinct uint32

  MessageHeader = object
    version: Version
    command: string
    length: int
    checkSum: uint32

  MessageBody = seq[byte]

  Message = ref object
    header: MessageHeader
    body: MessageBody

  InventryType = enum
    ERROR
    MSG_TX
    MSG_BLOCK
    MSG_FILTERED_BLOCK
    MSG_CMPCT_BLOCK
    MSG_WITNESS_TX = 0x40000001
    MSG_WITNESS_BLOCK
    MSG_FILTERED_WITNESS_BLOCK

  Node* = ref object
    serverIp*: string
    port*: uint16
    protocolVersion*: uint32
    messageStart*: uint32
    networkId*: NetworkId
    network*: Network
    sin*: Sockaddr_in
    sock*: SocketHandle
    messageChannel*: ptr Channel[Message]
    recvThread*: Thread[tuple[sock: SocketHandle, recvBufLen: int, messageChannel: ptr Channel[Message]]]

  NodeParams* = tuple[ip: string, port: uint16, protocolVersion: uint32,
                      messageStart: uint32, networkId: NetworkId,
                      rpcUrl: string, rpcUserPass: string,
                      workerEnable: bool]

  BlockParserError* = object of CatchableError


proc msgVersion(node: Node): seq[byte] =
  let now = getTime()
  (node.protocolVersion.uint32, 0xd'u64, now.toUnix.uint64, Pad(26), Pad(26),
    0xa5a5'u64, VarStr("/blockstor:0.2.0/"), 0'u32).toBytes

proc command(s: string): FixedStr {.inline.} = newFixedStr(s, 12)

proc message(node: Node, cmd: string, payload: seq[byte] = @[]): seq[byte] =
  var checksum = sha256d(payload)
  (node.messageStart.uint32.toBE, command(cmd), payload.len.uint32,
    checksum[0..<4], payload).toBytes

proc `$`*(ver: Version): string = "0x" & ver.uint32.toBytesBE.toHex

proc newNode*(params: NodeParams): Node =
  var node = new Node
  node.serverIp = params.ip
  node.port = params.port
  node.protocolVersion = params.protocolVersion
  node.messageStart = params.messageStart
  node.networkId = params.networkId
  node.network = getNetwork(node.networkId)
  var address: IpAddress = parseIpAddress(node.serverIp)
  node.sin.sin_family = type(node.sin.sin_family)(Domain.AF_INET.toInt)
  copyMem(addr node.sin.sin_addr, unsafeAddr address.address_v4[0], sizeof(node.sin.sin_addr))
  node.sin.sin_port = nativesockets.ntohs(node.port)
  node

proc nodeRecvThread(params: tuple[sock: SocketHandle, recvBufLen: int, messageChannel: ptr Channel[Message]]) {.thread.} =
  var recvBuf = newSeq[byte](params.recvBufLen)
  var parseData: seq[byte]

  while true:
    var recvLen = params.sock.recv(addr recvBuf[0], recvBuf.len.cint, 0.cint)
    if recvLen <= 0:
      break
    parseData = parseData & recvBuf[0..<recvLen]
    while true:
      if parseData.len < 24:
        break
      var bodyLen = parseData[16].toUint32.int
      var msgLen = 24 + bodyLen
      if parseData.len < msgLen:
        break
      var header = MessageHeader(version: Version(parseData[0].toUint32.toBE),
                                command: parseData[4..<16].toString.replace(re"\0+$", ""),
                                length: bodyLen,
                                checksum: parseData[20].toUint32)
      var body = MessageBody(parseData[24..<msgLen])
      params.messageChannel[].send(Message(header: header, body: body))
      parseData = parseData[msgLen..^1]

proc startRecvThread(node: Node) =
  const SO_RCVBUF: cint = 8
  var tcp_rmem = node.sock.getSockOptInt(SOL_SOCKET, SO_RCVBUF)
  echo "RECVBUF=", tcp_rmem
  createThread(node.recvThread, nodeRecvThread, (node.sock, tcp_rmem, node.messageChannel))

proc connect*(node: Node): bool =
  node.sock = createNativeSocket()
  result = node.sock.connect(cast[ptr SockAddr](addr node.sin), sizeof(node.sin).SockLen) == 0
  node.messageChannel = cast[ptr Channel[Message]](allocShared0(sizeof(Channel[Message])))
  node.messageChannel[].open()
  node.startRecvThread()

proc close*(node: Node) =
  try:
    discard node.sock.shutdown(SHUT_RDWR)
    node.sock.close()
  except:
    let e = getCurrentException()
    echo e.name, ": ", e.msg
  node.recvThread.joinThread()
  node.messageChannel[].close()
  deallocShared(node.messageChannel)

proc send*(sock: SocketHandle, data: seq[byte]): bool =
  var ret = sock.send(unsafeAddr data[0], data.len.cint, 0.cint)
  if ret < 0:
    var retry = 0
    while errno == EINTR:
      ret = sock.send(unsafeAddr data[0], data.len.cint, 0.cint)
      if ret >= 0 or retry >= 100:
        break
      inc(retry)
  result = ret > 0

var abort = false

proc start*(node: Node, params: NodeParams, startHeight: int, startBlkHash: BlockHash,
            cb: proc(height: int, hash: BlockHash, blk: Block): bool {.gcsafe.}) =
  var height = startHeight
  var blockHashes: seq[BlockHash]
  var reqHashes: seq[BlockHash]
  var prevBlkHash: BlockHash
  var prevBlkTime: int64
  var prevReqHash0: BlockHash
  var reqHashesWaitCount: int = 0
  when SEND_PING:
    var prevSendTime: float = epochTime()

  proc checkSendErr(flag: bool) =
    if not flag:
      raise newException(BlockParserError, "send error")

  checkSendErr node.sock.send(node.message("version", node.msgVersion()))

  var check_count = 0
  var start_flag = false
  while not abort:
    var queue = node.messageChannel[].peek()
    if queue < 500 and reqHashes.len < 500 and blockHashes.len > 0:
      var data = node.message("getblocks", (node.protocolVersion.uint32, VarInt(1),
                        blockHashes[^1], Pad(32)).toBytes)
      # The last hash may not be the next one, but the latest one.
      # In that case, it will be resolved after processing the blocks.
      checkSendErr node.sock.send(data)

      var invs: seq[byte]
      var n = 0
      for h in blockHashes:
        reqHashes.add(h)
        invs &= (MSG_BLOCK.ord.uint32, h).toBytes
        inc(n)
      blockHashes = @[]
      var getdataMsg = node.message("getdata", (VarInt(n), invs).toBytes)
      checkSendErr node.sock.send(getdataMsg)
      when SEND_PING:
        prevSendTime = epochTime()
    else:
      when SEND_PING:
        let curEpochTime = epochTime()
        if curEpochTime - prevSendTime > 180.0:
          checkSendErr node.sock.send(node.message("ping", curEpochTime.uint64.toBytes))
          prevSendTime = curEpochTime
      else:
        discard

    if queue > 0:
      var message = node.messageChannel[].recv()
      case message.header.command
      of "version":
        checkSendErr node.sock.send(node.message("verack"))

      of "verack":
        var data = node.message("getblocks", (node.protocolVersion.uint32, VarInt(1),
                               startBlkHash, Pad(32)).toBytes)
        checkSendErr node.sock.send(data)

      of "ping":
        checkSendErr node.sock.send(node.message("pong", message.body))

      of "pong":
        discard

      of "inv":
        var reader = newReader(message.body)
        var n = reader.getVarInt
        for i in 0..<n:
          var invType = reader.getUint32

          if InventryType(invType) == InventryType.MSG_BLOCK:
            var hash = BlockHash(reader.getBytes(32))
            blockHashes.add(hash)
          else:
            reader.skip(32)

      of "block":
        var blk = message.body.toBlock
        if reqHashes.len > 0:
          var hash = reqHashes[0]
          reqHashes = reqHashes[1..^1]
          if prevBlkHash == blk.header.prev or prevBlkHash.toBytes.len == 0:
            prevBlkHash = hash
            prevBlkTime = blk.header.time.int64
            inc(height)
            if not cb(height, hash, blk):
              abort = true
          elif reqHashes.len == 0 and blockHashes.len == 0 and hash != prevBlkHash:
            start_flag = false
            check_count = 0
            var data = node.message("getblocks", (node.protocolVersion.uint32, VarInt(1),
                        prevBlkHash, Pad(32)).toBytes)
            checkSendErr node.sock.send(data)

      of "reject":
        var reader = newReader(message.body)
        var reject_message = reader.getVarStr
        var reject_code = reader.getUint8
        var reject_reason = reader.getVarStr
        stdout.eraseLine
        echo message.header.command &
              " message=" & reject_message &
              " code=" & reject_code.toHex &
              " reason=" & reject_reason

      else:
        stdout.eraseLine
        echo "ignore ", message.header.command

      if not start_flag and (reqHashes.len > 0 or blockHashes.len > 0):
        start_flag = true

    else:
      sleep(100)
      if start_flag:
        if reqHashes.len == 0 and blockHashes.len == 0:
          break
        if reqHashesWaitCount > 0:
            dec(reqHashesWaitCount)
        elif reqHashes.len > 0:
          if prevReqHash0 == reqHashes[0]:
            let curEpochTime = epochTime()
            checkSendErr node.sock.send(node.message("ping", curEpochTime.uint64.toBytes))
            reqHashesWaitCount = 200
          else:
            prevReqHash0 = reqHashes[0]
      else:
        inc(check_count)
        if check_count >= 200:
          break


proc stop*() =
  abort = true
