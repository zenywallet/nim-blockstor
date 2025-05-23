# Copyright (c) 2020 zenywallet

const USE_CURL = true

import libcurl, strutils, json, locks
export json

when not USE_CURL:
  import nativesockets, posix
  import bytes
  import regex
  import base64

type
  CoreCommand* = enum
    addMultiSigAddress = "addmultisigaddress"
    addNode = "addnode" # bitcoind v0.8.0+
    backupWallet = "backupwallet"
    createMultiSig = "createmultisig"
    createRawTransaction = "createrawtransaction" # bitcoind v0.7.0+
    decodeRawTransaction = "decoderawtransaction" # bitcoind v0.7.0+
    decodeScript = "decodescript"
    dumpPrivKey = "dumpprivkey"
    dumpWallet = "dumpwallet" # bitcoind v0.9.0+
    encryptWallet = "encryptwallet"
    estimateFee = "estimatefee" # bitcoind v0.10.0x
    estimatePriority = "estimatepriority" # bitcoind v0.10.0+
    generate = "generate" # bitcoind v0.11.0+
    getAccount = "getaccount"
    getAccountAddress = "getaccountaddress"
    getAddedNodeInfo = "getaddednodeinfo" # bitcoind v0.8.0+
    getAddressesByAccount = "getaddressesbyaccount"
    getBalance = "getbalance"
    getBestBlockHash = "getbestblockhash" # bitcoind v0.9.0+
    getBlock = "getblock"
    getBlockchainInfo = "getblockchaininfo" # bitcoind v0.9.2+
    getBlockCount = "getblockcount"
    getBlockHash = "getblockhash"
    getBlockTemplate = "getblocktemplate" # bitcoind v0.7.0+
    getChainTips = "getchaintips" # bitcoind v0.10.0+
    getConnectionCount = "getconnectioncount"
    getDifficulty = "getdifficulty"
    getGenerate = "getgenerate"
    getInfo = "getinfo"
    getMempoolInfo = "getmempoolinfo" # bitcoind v0.10+
    getMiningInfo = "getmininginfo"
    getNetTotals = "getnettotals"
    getNetworkInfo = "getnetworkinfo" # bitcoind v0.9.2+
    getNetworkHashPs = "getnetworkhashps" # bitcoind v0.9.0+
    getNewAddress = "getnewaddress"
    getPeerInfo = "getpeerinfo" # bitcoind v0.7.0+
    getRawChangeAddress = "getrawchangeaddress" # bitcoin v0.9+
    getRawMemPool = "getrawmempool" # bitcoind v0.7.0+
    getRawTransaction = "getrawtransaction" # bitcoind v0.7.0+
    getReceivedByAccount = "getreceivedbyaccount"
    getReceivedByAddress = "getreceivedbyaddress"
    getTransaction = "gettransaction"
    getTxOut = "gettxout" # bitcoind v0.7.0+
    getTxOutProof = "gettxoutproof" # bitcoind v0.11.0+
    getTxOutSetInfo = "gettxoutsetinfo" # bitcoind v0.7.0+
    getUnconfirmedBalance = "getunconfirmedbalance" # bitcoind v0.9.0+
    getWalletInfo = "getwalletinfo" # bitcoind v0.9.2+
    help = "help"
    importAddress = "importaddress" # bitcoind v0.10.0+
    importPrivKey = "importprivkey"
    importWallet = "importwallet" # bitcoind v0.9.0+
    keypoolRefill = "keypoolrefill"
    listAccounts = "listaccounts"
    listAddressGroupings = "listaddressgroupings" # bitcoind v0.7.0+
    listLockUnspent = "listlockunspent" # bitcoind v0.8.0+
    listReceivedByAccount = "listreceivedbyaccount"
    listReceivedByAddress = "listreceivedbyaddress"
    listSinceBlock = "listsinceblock"
    listTransactions = "listtransactions"
    listUnspent = "listunspent" # bitcoind v0.7.0+
    lockUnspent = "lockunspent" # bitcoind v0.8.0+
    move = "move"
    ping = "ping" # bitcoind v0.9.0+
    prioritiseTransaction = "prioritisetransaction" # bitcoind v0.10.0+
    sendFrom = "sendfrom"
    sendMany = "sendmany"
    sendRawTransaction = "sendrawtransaction" # bitcoind v0.7.0+
    sendToAddress = "sendtoaddress"
    setAccount = "setaccount"
    setGenerate = "setgenerate"
    setTxFee = "settxfee"
    signMessage = "signmessage"
    signRawTransaction = "signrawtransaction" # bitcoind v0.7.0+
    stop = "stop"
    submitBlock = "submitblock" # bitcoind v0.7.0+
    validateAddress = "validateaddress"
    verifyChain = "verifychain" # bitcoind v0.9.0+
    verifyMessage = "verifymessage"
    verifyTxOutProof = "verifytxoutproof" # bitcoind v0.11.0+
    walletLock = "walletlock"
    walletPassphrase = "walletpassphrase"
    walletPassphraseChange = "walletpassphrasechange"

type
  RpcCommand* = object
    id*: string
    data*: string
  RpcCommands* = seq[RpcCommand]

  RpcError* = object of CatchableError

type RpcConfig* = ref object
  rpcUrl*: string      # http://hostname:port/
  rpcUserPass*: string # rpcuser:rpcpassword

var defaultRpcConfig {.threadvar.}: RpcConfig
defaultRpcConfig = RpcConfig(rpcUrl: "http://127.0.0.1:9252/",
                            rpcUserPass: "rpcuser:rpcpassword")
when not USE_CURL:
  var rpcHostname {.threadvar.}: string
  var rpcPort {.threadvar.}: Port
  var rpcAuthorization {.threadvar.}: string
  var rpcRecvBuf {.threadvar.}: seq[byte]

  var rcvbufSock = createNativeSocket()
  var tcp_rmem = rcvbufSock.getSockOptInt(SOL_SOCKET, SO_RCVBUF)
  rcvbufSock.close()

proc setRpcConfig*(rpcConfig: RpcConfig) =
  defaultRpcConfig = rpcConfig
  when not USE_CURL:
    var m = RegexMatch2()
    if match(rpcConfig.rpcUrl, re2"\w+://([\w\._-]+):(\d+)/?", m):
      rpcHostname = rpcConfig.rpcUrl[m.group(0)]
      rpcPort = rpcConfig.rpcUrl[m.group(1)].parseInt.Port
    rpcAuthorization = base64.encode(rpcConfig.rpcUserPass)
    rpcRecvBuf = newSeq[byte](tcp_rmem)

when USE_CURL:
  proc writeCallback(buffer: cstring, size: int, nitems: int, outstream: pointer): int =
    var outbuf = cast[ref string](outstream)
    outbuf[] &= buffer
    result = size * nitems

  const ADD_POST_HEADER = false
  when ADD_POST_HEADER:
    var headers: PSlist
    headers = slist_append(headers, "Content-Type: application/json")

  proc httpPost(rpcConfig: RpcConfig, postData: string): tuple[code: Code, data: string] =
    var outbuf: ref string = new string
    let curl: Pcurl = easy_init()
    # discard curl.easy_setopt(OPT_VERBOSE, 1)
    discard curl.easy_setopt(OPT_URL, rpcConfig.rpcUrl.cstring)
    discard curl.easy_setopt(OPT_POST, 1)
    discard curl.easy_setopt(OPT_USERPWD, rpcConfig.rpcUserPass.cstring)
    discard curl.easy_setopt(OPT_POSTFIELDS, postData.cstring)
    discard curl.easy_setopt(OPT_WRITEDATA, outbuf)
    discard curl.easy_setopt(OPT_WRITEFUNCTION, writeCallback)
    when ADD_POST_HEADER:
      discard curl.easy_setopt(OPT_HTTPHEADER, headers)
    let ret = curl.easy_perform()
    curl.easy_cleanup()
    (ret, outbuf[])

else:
  proc parseHeader(data: seq[byte]): tuple[code, contentLength, headerSize: int] =
    var i = 0
    var cur = 0
    var code = 0
    var contentLength = 0

    let last = data.len - 1
    while i < last:
      if equalMem(unsafeAddr data[i], "\c\L".cstring, 2):
        var reqdata = (cast[ptr UncheckedArray[byte]](unsafeAddr data[cur])).toString(i - cur)
        if reqdata.startsWith("HTTP/"):
          code = reqdata[9..11].parseInt
          inc(i, 2)
          cur = i
          break
        inc(i, 2)
        cur = i
      else:
        inc(i)

    while i < last:
      if equalMem(unsafeAddr data[i], "\c\L".cstring, 2):
        var reqdata = (cast[ptr UncheckedArray[byte]](unsafeAddr data[cur])).toString(i - cur)
        if reqdata.startsWith("Content-Length: "):
          contentLength = reqdata["Content-Length: ".len..^1].parseInt
          inc(i, 2)
          cur = i
          break
        inc(i, 2)
        cur = i
      else:
        inc(i)

    while i < last:
      if equalMem(unsafeAddr data[i], "\c\L".cstring, 2):
        if i == cur:
          return (code, contentLength, i + 2)
        inc(i, 2)
        cur = i
      else:
        inc(i)

  proc httpPost(rpcConfig: RpcConfig, postData: string): tuple[code: Code, data: string] =
    var sock = createNativeSocket()
    sock.setSockOptInt(Protocol.IPPROTO_TCP.int, TCP_NODELAY, 1)

    var aiList: ptr AddrInfo
    try:
      aiList = getAddrInfo(rpcHostname, rpcPort, Domain.AF_INET)
    except:
      sock.close()
      return (E_COULDNT_RESOLVE_HOST, "")

    let retConnect = sock.connect(aiList.ai_addr, aiList.ai_addrlen.SockLen)
    freeaddrinfo(aiList)
    if retConnect != 0:
      return (E_COULDNT_CONNECT, "")

    var data = "POST / HTTP/1.1\c\L" &
      "Authorization: Basic " & rpcAuthorization & "\c\L" &
      "Content-Length: " & $postData.len & "\c\L" &
      "\c\L" & postData

    while true:
      var sendRet = sock.send(addr data[0], data.len.cint, 0'i32)
      if sendRet < 0 and errno == EINTR:
        continue
      break

    sock.setBlocking(false)

    var buf: seq[byte]
    var code = 0
    var contentLength = 0
    var headerSize = 0

    var nfds = sock.cint + 1.cint
    var tv = Timeval(tv_sec: 3.Time, tv_usec: 0.Suseconds)
    var reading {.noinit.}: TFdSet
    var readfds {.noinit.}: TFdSet
    FD_ZERO(reading)
    FD_SET(sock, reading)
    while true:
      var waitCount = 0
      while true:
        copyMem(addr readfds, addr reading, sizeof(TFdSet))
        var retSel = select(nfds, addr readfds, nil, nil, addr tv)
        if retSel == 0:
          inc(waitCount)
          if waitCount >= 10:
            return (E_OPERATION_TIMEOUTED, "")
          continue
        break

      while true:
        var recvLen = sock.recv(addr rpcRecvBuf[0], rpcRecvBuf.len, 0'i32)
        if recvLen > 0:
          buf = buf & rpcRecvBuf[0..<recvLen]
          break
        elif recvLen < 0:
          if errno == EINTR:
            continue
          return (E_RECV_ERROR, "")
        else:
          return (E_RECV_ERROR, "")

      (code, contentLength, headerSize) = parseHeader(buf)
      if code != 200 and code != 0:
        return (E_HTTP_RETURNED_ERROR, buf[headerSize..^1].toString())
      let totalSize = contentLength + headerSize
      if totalSize == buf.len:
        return (E_OK, buf[headerSize..^1].toString())

proc filterAlphaNumeric(s: string): string =
  var check = true
  for c in s:
    check = c.isAlphaNumeric() and check
  if check:
    result = s
  else:
    raise newException(RpcError, "invalid parameters")

proc wrapStr*(s: string): string = "\"" & filterAlphaNumeric(s) & "\""

proc wrapStr*(val: SomeInteger | BiggestInt | JsonNode): string = $val

var rpcId: uint = 0
var rpcIdLock: Lock
initLock(rpcIdLock)

proc getId(): string =
  var id: uint
  withLock rpcIdLock:
    inc(rpcId)
    id = rpcId
  result = "bs" & $id

proc setParams*(cmd: CoreCommand, args: varargs[string, wrapStr]): RpcCommand =
  var params: string
  for v in args:
    if params.len > 0:
      params.add(",")
    params.add(v)
  var id = getId()
  if params.len > 0:
    result = RpcCommand(id: id, data: "{\"id\":\"" & $id & "\",\"method\":\"" & $cmd & "\",\"params\":[" & $params & "]}")
  else:
    result = RpcCommand(id: id, data: "{\"id\":\"" & $id & "\",\"method\":\"" & $cmd & "\"}")

proc send*(cmd: CoreCommand, rpcConfig: RpcConfig, args: varargs[string, wrapStr]): JsonNode =
  let rpcCmd = setParams(cmd, args)
  let ret = httpPost(rpcConfig, rpcCmd.data)
  if ret.code == E_OK:
    if ret.data.len == 0:
      raise newException(RpcError, "no data")
    result = parseJson(ret.data)
    if not result.hasKey("id") or result["id"].getStr != rpcCmd.id:
      raise newException(RpcError, $result)
  else:
    raise newException(RpcError, $ret.code)

template send*(cmd: CoreCommand, args: varargs[string, wrapStr]): JsonNode =
  send(cmd, defaultRpcConfig, args)

proc send*(rpcCmd: RpcCommand, rpcConfig: RpcConfig = defaultRpcConfig): JsonNode =
  let ret = httpPost(rpcConfig, rpcCmd.data)
  if ret.code == E_OK:
    if ret.data.len == 0:
      raise newException(RpcError, "no data")
    result = parseJson(ret.data)
    if not result.hasKey("id") or result["id"].getStr != rpcCmd.id:
      raise newException(RpcError, $result)
  else:
    raise newException(RpcError, $ret.code)

proc send*(rpcCmds: RpcCommands, rpcConfig: RpcConfig = defaultRpcConfig): JsonNode =
  var cmds: string
  var ids: seq[string]
  for x in rpcCmds:
    if cmds.len > 0:
      cmds.add(",")
    cmds.add(x.data)
    ids.add(x.id)
  cmds = "[" & cmds & "]"
  let ret = httpPost(rpcConfig, cmds)
  if ret.code == E_OK:
    if ret.data.len == 0:
      raise newException(RpcError, "no data")
    result = parseJson(ret.data)
    if result.len == ids.len:
      var i = 0
      for r in result:
        if not r.hasKey("id") or r["id"].getStr != ids[i]:
          raise newException(RpcError, $result)
        inc(i)
    else:
      raise newException(RpcError, $result)
  else:
    raise newException(RpcError, $ret.code)


when isMainModule:
  try:
    var rpcConfig = RpcConfig(
      rpcUrl: "http://127.0.0.1:9252/",
      rpcUserPass: "rpcuser:rpcpassword")
    setRpcConfig(rpcConfig)

    let d0 = getBlockHash.send(0)
    echo d0
    echo getBlock.send(d0["result"].getStr, 0)
    let d1 = getBlockHash.setParams(1).send()
    echo d1
    echo getBlock.setParams(d1["result"].getStr, 0).send()
    echo getBlockchainInfo.send()
    echo getBlockchainInfo.setParams().send()

    var rpcCmds: RpcCommands
    rpcCmds.add(getBlockHash.setParams(0))
    rpcCmds.add(getBlockHash.setParams(1))
    rpcCmds.add(getBlockHash.setParams(2))
    echo rpcCmds.send()

    echo getBlockTemplate.send(%*{"rules": ["segwit"]})

  except:
    let e = getCurrentException()
    echo e.name, ": ", e.msg
