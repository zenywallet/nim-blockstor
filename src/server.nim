# Copyright (c) 2021 zenywallet

#[
import nativesockets, posix, epoll
import strutils, sequtils, tables
from cgi import decodeUrl
import os
import bytes, files
import std/sha1
import base64
import times
import stats

const ULIMIT_SIZE* = 65536
const CLIENT_MAX = 32000
const CLIENT_SEARCH_LIMIT = 30000
const WORKER_THREAD_NUM = 16
const EPOLL_EVENTS_SIZE = 10
const HTTP_VERSION = 1.1
const CLCL = 168626701'u32 # "\c\L\c\L"
const RECVBUF_EXPAND_BREAK_SIZE = 131072 * 5
const MAX_FRAME_SIZE = 131072 * 5
const WORKER_QUEUE_LIMIT = 10000
const WEBSOCKET_PROTOCOL = "deoxy-0.1"
const WEBSOCKET_ENTRY_POINT = "/ws"
const REQ_LIMIT_DISPATCH_PERIOD = 60
const REQ_LIMIT_DISPATCH_MAX = 1200
const REQ_LIMIT_HTTPS_ACCEPT_PERIOD = 60
const REQ_LIMIT_HTTPS_ACCEPT_MAX = 120
const REQ_LIMIT_HTTP_ACCEPT_PERIOD = 60
const REQ_LIMIT_HTTP_ACCEPT_MAX = 120
const ENABLE_KEEPALIVE = false
const ENABLE_TCP_NODELAY = true

const ENABLE_SSL = defined(ENABLE_SSL)
when ENABLE_SSL:
  import openssl
  import nimcrypto except toHex

when (compiles do: include config):
  include config
else:
  include config_default

type
  ClientBase* = ref object of RootObj
    idx: int
    fd: int
    recvBuf: ptr UncheckedArray[byte]
    recvBufSize: int
    recvCurSize: int
    sendBuf: ptr UncheckedArray[byte]
    sendBufSize: int
    keepAlive: bool
    wsUpgrade: bool
    payloadSize: int
    when ENABLE_SSL:
      ssl: SSL
      sslErr: int
    ip: uint32
    invoke: bool
    whackaMole: bool

  ClientObj* = object of ClientBase
    pStream*: pointer

  Client* = ptr ClientObj

  ClientObjArray = array[CLIENT_MAX, ClientObj]

  StatusCode* = enum
    Status100 = "100 Continue"
    Status101 = "101 Switching Protocols"
    Status200 = "200 OK"
    Status201 = "201 Created"
    Status202 = "202 Accepted"
    Status203 = "203 Non-Authoritative Information"
    Status204 = "204 No Content"
    Status205 = "205 Reset Content"
    Status206 = "206 Partial Content"
    Status300 = "300 Multiple Choices"
    Status301 = "301 Moved Permanently"
    Status302 = "302 Found"
    Status303 = "303 See Other"
    Status304 = "304 Not Modified"
    Status305 = "305 Use Proxy"
    Status306 = "306 (Unused)"
    Status307 = "307 Temporary Redirect"
    Status308 = "308 Permanent Redirect"
    Status400 = "400 Bad Request"
    Status401 = "401 Unauthorized"
    Status402 = "402 Payment Required"
    Status403 = "403 Forbidden"
    Status404 = "404 Not Found"
    Status405 = "405 Method Not Allowed"
    Status406 = "406 Not Acceptable"
    Status407 = "407 Proxy Authentication Required"
    Status408 = "408 Request Timeout"
    Status409 = "409 Conflict"
    Status410 = "410 Gone"
    Status411 = "411 Length Required"
    Status412 = "412 Precondition Failed"
    Status413 = "413 Payload Too Large"
    Status414 = "414 URI Too Long"
    Status415 = "415 Unsupported Media Type"
    Status416 = "416 Range Not Satisfiable"
    Status417 = "417 Expectation Failed"
    Status418 = "418 I'm a teapot"
    Status421 = "421 Misdirected Request"
    Status425 = "425 Too Early"
    Status426 = "426 Upgrade Required"
    Status428 = "428 Precondition Required"
    Status429 = "429 Too Many Requests"
    Status431 = "431 Request Header Fields Too Large"
    Status451 = "451 Unavailable For Legal Reasons"
    Status500 = "500 Internal Server Error"
    Status501 = "501 Not Implemented"
    Status502 = "502 Bad Gateway"
    Status503 = "503 Service Unavailable"
    Status504 = "504 Gateway Timeout"
    Status505 = "505 HTTP Version Not Supported"
    Status506 = "506 Variant Also Negotiates"
    Status510 = "510 Not Extended"
    Status511 = "511 Network Authentication Required"

  ThreadArgType* {.pure.} = enum
    Void
    WorkerParams

  ThreadArg* = object
    case argType*: ThreadArgType
    of ThreadArgType.Void:
      discard
    of ThreadArgType.WorkerParams:
      workerParams*: tuple[threadId: int, bufLen: int]

  SendResult* {.pure.} = enum
    Error = -1
    None = 0
    Success = 1
    Pending = 2
    Invalid = 3

  Headers = Table[string, string]

  WebSocketOpCode* = enum
    Continue = 0x0
    Text = 0x1
    Binary = 0x2
    Close = 0x8
    Ping = 0x9
    Pong = 0xa

  ServerError* = object of CatchableError
  ServerNeedRestartError* = object of CatchableError
  ServerSslCertError* = object of CatchableError

template debug(x: varargs[string, `$`]) =
  when DEBUG_LOG:
    echo join(x)
  else:
    discard

template error(x: varargs[string, `$`]) = echo join(x)

template errorQuit(x: varargs[string, `$`]) =
  var msg = join(x)
  echo msg
  raise newException(ServerError, msg)

proc toWebSocketOpCode(opcode: int8): WebSocketOpCode =
  case opcode
  of 0x2: WebSocketOpcode.Binary
  of 0x0: WebSocketOpcode.Continue
  of 0x8: WebSocketOpcode.Close
  of 0x1: WebSocketOpcode.Text
  of 0x9: WebSocketOpcode.Ping
  of 0xa: WebSocketOpcode.Pong
  else: raise

proc reallocClientBuf(buf: ptr UncheckedArray[byte], size: int): ptr UncheckedArray[byte] =
  result = cast[ptr UncheckedArray[byte]](reallocShared(buf, size))

proc addSendBuf(client: Client, data: seq[byte] | string) =
  var nextSize = client.sendBufSize + data.len
  client.sendBuf = reallocClientBuf(client.sendBuf, nextSize)
  copyMem(addr client.sendBuf[client.sendBufSize], unsafeAddr data[0], data.len)
  client.sendBufSize = nextSize

proc send*(client: Client, data: seq[byte] | string): SendResult =
  if not client.sendBuf.isNil:
    client.addSendBuf(data)
    return SendResult.Pending

  var sendRet: int
  var pos = 0
  var size = data.len
  while true:
    var d = cast[cstring](unsafeAddr data[pos])
    when ENABLE_SSL:
      if not client.ssl.isNil:
        sendRet = client.ssl.SSL_write(d, size.cint)
      else:
        sendRet = client.fd.SocketHandle.send(d, size.cint, 0'i32)
    else:
      sendRet = client.fd.SocketHandle.send(d, size.cint, 0'i32)
    if sendRet > 0:
      debug "send sendRet=", sendRet, " size=", size
      size = size - sendRet
      if size > 0:
        pos = pos + sendRet
        continue
      return SendResult.Success
    elif sendRet < 0:
      when ENABLE_SSL:
        if not client.ssl.isNil:
          client.sslErr = SSL_get_error(client.ssl, sendRet.cint)
          debug "SSL_send err=", client.sslErr, " errno=", errno
          if client.sslErr == SSL_ERROR_WANT_WRITE or client.sslErr == SSL_ERROR_WANT_READ:
            if pos > 0:
              client.addSendBuf(data[pos..^1])
            else:
              client.addSendBuf(data)
            return SendResult.Pending
          else:
            if errno == EINTR:
              continue
          return SendResult.Error

      if errno == EAGAIN or errno == EWOULDBLOCK:
        if pos > 0:
          client.addSendBuf(data[pos..^1])
        else:
          client.addSendBuf(data)
        return SendResult.Pending
      if errno == EINTR:
        continue
      return SendResult.Error
    else:
      return SendResult.None

proc wsServerSend*(client: Client, data: seq[byte] | string,
                          opcode: WebSocketOpCode = WebSocketOpCode.Binary): SendResult =
  var frame: seq[byte]
  var dataLen = data.len
  var finOp = 0x80.byte or opcode.byte
  if dataLen < 126:
    frame = BytesBE(finOp, dataLen.byte, data)
  elif dataLen >= 126 and dataLen <= 0xffff:
    frame = BytesBE(finOp, 126.byte, dataLen.uint16, data)
  else:
    frame = BytesBE(finOp, 127.byte, dataLen.uint64, data)
  result = client.send(frame)

var active = true
var restartFlag = false
var abortFlag = false
var serverSock: SocketHandle = osInvalidSocket
var httpSock: SocketHandle = osInvalidSocket
var clients: ptr ClientObjArray = nil
var clIdx = 0
var events: array[EPOLL_EVENTS_SIZE, EpollEvent]
var epfd: cint = -1

type
  WorkerChannelParam = tuple[appId: int, idx: int, events: uint32, evData: uint64]
var workerChannel: ptr Channel[WorkerChannelParam]
var workerChannelWaitingCount: int = 0

type
  WrapperThreadArg = tuple[threadFunc: proc(arg: ThreadArg) {.thread.}, arg: ThreadArg]
var workerThreads: array[WORKER_THREAD_NUM, Thread[WrapperThreadArg]]

var dispatcherThread: Thread[WrapperThreadArg]
var acceptThread: Thread[WrapperThreadArg]
var httpThread: Thread[WrapperThreadArg]
var monitorThread: Thread[WrapperThreadArg]
when ENABLE_SSL:
  when SSL_AUTO_RELOAD:
    var fileWatcherThread: Thread[WrapperThreadArg]
var mainThread: Thread[WrapperThreadArg]

proc setRlimitOpenFiles*(rlim: int): bool {.discardable.} =
  var rlp: RLimit
  var ret = getrlimit(RLIMIT_NOFILE, rlp)
  if ret != 0: return false
  debug "RLIMIT_NOFILE prev=", rlp
  if rlp.rlim_cur < rlim:
    if rlp.rlim_max < rlim:
      rlp.rlim_cur = rlp.rlim_max
    else:
      rlp.rlim_cur = rlim
    ret = setrlimit(RLIMIT_NOFILE, rlp)
    if ret != 0: return false
  else:
    debug "RLIMIT_NOFILE cur=", rlp
    return true
  ret = getrlimit(RLIMIT_NOFILE, rlp)
  if ret != 0: return false
  debug "RLIMIT_NOFILE new=", rlp
  if rlp.rlim_cur < rlim: return false
  return true

proc setMaxRlimitOpenFiles*(): bool {.discardable.} =
  var rlp: RLimit
  var ret = getrlimit(RLIMIT_NOFILE, rlp)
  if ret != 0: return false
  debug "RLIMIT_NOFILE prev=", rlp
  rlp.rlim_cur = rlp.rlim_max
  ret = setrlimit(RLIMIT_NOFILE, rlp)
  if ret != 0: return false
  ret = getrlimit(RLIMIT_NOFILE, rlp)
  if ret != 0: return false
  debug "RLIMIT_NOFILE new=", rlp
  if rlp.rlim_cur < rlp.rlim_max: return false
  return true

proc invokeSendEvent*(client: Client, retry: bool = false): bool =
  if retry:
    if not client.invoke:
      return true
  else:
    client.invoke = true
  var ev: EpollEvent
  ev.events = EPOLLIN or EPOLLRDHUP or EPOLLOUT
  ev.data.u64 = client.idx.uint or 0x300000000'u64
  var ret = epoll_ctl(epfd, EPOLL_CTL_MOD, client.fd.cint, addr ev)
  if ret < 0:
    result = false
  else:
    client.invoke = false
    result = true

proc getErrnoStr(): string =
  case errno
  of EADDRINUSE: "errno=EADDRINUSE(" & $errno & ")"
  else: "errno=" & $errno

proc quitServer(restart: bool = false) =
  debug "quit"
  restartFlag = restart
  active = false
  if serverSock != osInvalidSocket:
    if epfd >= 0:
      var ev: EpollEvent
      ev.events = EPOLLRDHUP
      var retCtl = epoll_ctl(epfd, EPOLL_CTL_ADD, serverSock, addr ev)
      if retCtl != 0:
        errorQuit "error: quit epoll_ctl ret=", retCtl, " ", getErrnoStr()
    var retShutdown = serverSock.shutdown(SHUT_RD)
    if retShutdown != 0:
      errorQuit "error: quit shutdown ret=", retShutdown, " ", getErrnoStr()
    serverSock.close()
    serverSock = osInvalidSocket
  if httpSock != osInvalidSocket:
    var retShutdown = httpSock.shutdown(SHUT_RD)
    if retShutdown != 0:
      errorQuit "error: quit shutdown ret=", retShutdown, " ", getErrnoStr()
    httpSock.close()
    httpSock = osInvalidSocket

proc restart*() = quitServer(true)

proc abort() =
  debug "abort"
  abortFlag = true
  quitServer()

when not isMainModule:
  include stream

proc initClient() =
  var p = cast[ptr ClientObjArray](allocShared0(sizeof(ClientObjArray)))
  for i in 0..<CLIENT_MAX:
    p[i].idx = i
    p[i].fd = osInvalidSocket.int
    p[i].recvBuf = nil
    p[i].recvBufSize = 0
    p[i].recvCurSize = 0
    p[i].sendBuf = nil
    p[i].sendBufSize = 0
    p[i].keepAlive = true
    p[i].wsUpgrade = false
    p[i].payloadSize = 0
    when ENABLE_SSL:
      p[i].ssl = nil
    p[i].ip = 0
    p[i].invoke = false
    p[i].whackaMole = false
    when declared(initExClient):
      initExClient(addr p[i])
  clients = p

proc freeClient() =
  var p = clients
  clients = nil
  for i in 0..<CLIENT_MAX:
    var client = addr p[i]
    if client.fd != osInvalidSocket.int:
      client.fd.SocketHandle.close()
    if not client.recvBuf.isNil:
      deallocShared(cast[pointer](client.recvBuf))
    if not client.sendBuf.isNil:
      deallocShared(cast[pointer](client.sendBuf))
    when declared(freeExClient):
      freeExClient(client)
  deallocShared(p)

proc atomic_compare_exchange_n(p: ptr int, expected: ptr int, desired: int, weak: bool,
                              success_memmodel: int, failure_memmodel: int): bool
                              {.importc: "__atomic_compare_exchange_n", nodecl, discardable.}

proc setClient(fd: int): int =
  var usedCount = 0
  for i in clIdx..<CLIENT_MAX:
    var chk = -1
    if atomic_compare_exchange_n(addr clients[i].fd, addr chk, fd, false, 0, 0):
      clIdx = i + 1
      if clIdx >= CLIENT_MAX:
        clIdx = 0
      return i
    else:
      inc(usedCount)
      if usedCount > CLIENT_SEARCH_LIMIT:
        return -1
  for i in 0..<clIdx:
    var chk = -1
    if atomic_compare_exchange_n(addr clients[i].fd, addr chk, fd, false, 0, 0):
      clIdx = i + 1
      if clIdx >= CLIENT_MAX:
        clIdx = 0
      return i
    else:
      inc(usedCount)
      if usedCount > CLIENT_SEARCH_LIMIT:
        return -1
  return -1

proc addHeader*(body: string, code: StatusCode = Status200, mimetype: string = "text/html"): string =
    result = "HTTP/" & $HTTP_VERSION & " " & $code & "\c\L" &
            "Content-Type: " & mimetype & "\c\L" &
            "Content-Length: " & $body.len & "\c\L\c\L" &
            body

proc addHeader*(body: string, etag: string, code: StatusCode = Status200, mimetype: string = "text/html"): string =
    result = "HTTP/" & $HTTP_VERSION & " " & $code & "\c\L" &
            "Content-Type: " & mimetype & "\c\L" &
            "ETag: " & etag & "\c\L" &
            "Content-Length: " & $body.len & "\c\L\c\L" &
            body

proc addHeaderDeflate*(body: string, etag: string, code: StatusCode = Status200, mimetype: string = "text/html"): string =
    result = "HTTP/" & $HTTP_VERSION & " " & $code & "\c\L" &
            "Content-Type: " & mimetype & "\c\L" &
            "ETag: " & etag & "\c\L" &
            "Content-Encoding: deflate\c\L" &
            "Content-Length: " & $body.len & "\c\L\c\L" &
            body

proc addHeaderBrotli*(body: string, etag: string, code: StatusCode = Status200, mimetype: string = "text/html"): string =
    result = "HTTP/" & $HTTP_VERSION & " " & $code & "\c\L" &
            "Content-Type: " & mimetype & "\c\L" &
            "ETag: " & etag & "\c\L" &
            "Content-Encoding: br\c\L" &
            "Content-Length: " & $body.len & "\c\L\c\L" &
            body

proc redirect301(location: string): string =
  result = "HTTP/" & $HTTP_VERSION & " " & $Status301 & "\c\L" &
          "Content-Type: text/html\c\L" &
          "Content-Length: 0\c\L" &
          "Location: " & location & "\c\L\c\L"

const BusyBody = "<!DOCTYPE html><meta charset=\"utf-8\"><i>Sorry, It is a break time.</i>"
const BadRequest = "<!DOCTYPE html><meta charset=\"utf-8\"><i>Oops, something's wrong?</i>"
const NotFound = "<!DOCTYPE html><meta charset=\"utf-8\"><i>You just found emptiness.</i>"
const InternalError = "<!DOCTYPE html><meta charset=\"utf-8\">the fire is dead.<br>the room is freezing."
const TooMany = "<!DOCTYPE html><meta charset=\"utf-8\"><i>Take your time.</i>"
const Empty = ""

proc sendInstant*(s: SocketHandle, data: string) =
  var sendRet: int
  while true:
    sendRet = s.send(data.cstring, data.len.cint, 0'i32)
    if sendRet < 0 and errno == EINTR:
      continue
    break

when ENABLE_SSL:
  proc sendInstant*(ssl: SSL, data: string) {.inline.} =
    var sendRet: int
    while true:
      sendRet = ssl.SSL_write(data.cstring, data.len.cint)
      if sendRet < 0 and errno == EINTR:
        continue
      break

proc sendInstant*(client: Client, data: string) {.inline.} =
  when ENABLE_SSL:
    if not client.ssl.isNil:
      client.ssl.sendInstant(data)
    else:
      client.fd.SocketHandle.sendInstant(data)
  else:
    client.fd.SocketHandle.sendInstant(data)



proc sendFlush(client: Client): SendResult =
  if client.sendBuf.isNil:
    return SendResult.None

  var sendRet: int
  var pos = 0
  var size = client.sendBufSize
  while true:
    var d = cast[cstring](addr client.sendBuf[pos])
    when ENABLE_SSL:
      if not client.ssl.isNil:
        sendRet = client.ssl.SSL_write(d, size.cint)
      else:
        sendRet = client.fd.SocketHandle.send(d, size.cint, 0'i32)
    else:
      sendRet = client.fd.SocketHandle.send(d, size.cint, 0'i32)
    if sendRet > 0:
      debug "flush sendRet=", sendRet, " size=", size
      size = size - sendRet
      if size > 0:
        pos = pos + sendRet
        continue
      client.sendBufSize = 0
      deallocShared(cast[pointer](client.sendBuf))
      client.sendBuf = nil
      return SendResult.Success
    elif sendRet < 0:
      when ENABLE_SSL:
        if not client.ssl.isNil:
          client.sslErr = SSL_get_error(client.ssl, sendRet.cint)
          debug "SSL_send err=", client.sslErr, " errno=", errno
          if client.sslErr == SSL_ERROR_WANT_WRITE or client.sslErr == SSL_ERROR_WANT_READ:
            copyMem(addr client.sendBuf[0], d, size)
            client.sendBufSize = size
            return SendResult.Pending
          else:
            if errno == EINTR:
              continue
          return SendResult.Error

      if errno == EAGAIN or errno == EWOULDBLOCK:
        copyMem(addr client.sendBuf[0], d, size)
        client.sendBufSize = size
        return SendResult.Pending
      if errno == EINTR:
        continue
      return SendResult.Error
    else:
      return SendResult.None

proc getFrame(data: ptr UncheckedArray[byte],
              size: int): tuple[find: bool, fin: bool, opcode: int8,
                                payload: ptr UncheckedArray[byte], payloadSize: int,
                                next: ptr UncheckedArray[byte], size: int] =
  if size < 2:
    return (false, false, -1.int8, nil, 0, data, size)

  var b1 = data[1]
  var mask = ((b1 and 0x80.byte) != 0)
  if not mask:
    raise newException(ServerError, "websocket client no mask")
  var b0 = data[0]
  var fin = ((b0 and 0xf0.byte) == 0x80.byte)
  var opcode = (b0 and 0x0f.byte).int8

  var payloadLen = (b1 and 0x7f.byte).int
  var frameHeadSize: int
  if payloadLen < 126:
    frameHeadSize = 6
  elif payloadLen == 126:
    if size < 4:
      return (false, fin, opcode, nil, 0, data, size)
    payloadLen = data[2].toUint16BE.int
    frameHeadSize = 8
  elif payloadLen == 127:
    if size < 10:
      return (false, fin, opcode, nil, 0, data, size)
    payloadLen = data[2].toUint64BE.int # exception may occur. value out of range [RangeDefect]
    frameHeadSize = 14
  else:
    return (false, fin, opcode, nil, 0, data, size)

  var frameSize = frameHeadSize + payloadLen
  if frameSize > MAX_FRAME_SIZE:
    raise newException(ServerError, "websocket frame size is too big frameSize=" & $frameSize)

  if size < frameSize:
    return (false, fin, opcode, nil, 0, data, size)

  var maskData: array[4, byte]
  copyMem(addr maskData[0], addr data[frameHeadSize - 4], 4)
  var payload = cast[ptr UncheckedArray[byte]](addr data[frameHeadSize])
  for i in 0..<payloadLen:
    payload[i] = payload[i] xor maskData[i mod 4]

  if size > frameSize:
    return (true, fin, opcode, payload, payloadLen, cast[ptr UncheckedArray[byte]](addr data[frameSize]), size - frameSize)
  else:
    return (true, fin, opcode, payload, payloadLen, nil, 0)

proc waitEventAgain(client: Client, evData: uint64, fd: int | SocketHandle, exEvents: uint32 = 0) =
  var ev: EpollEvent
  if client.invoke:
    ev.events = EPOLLIN or EPOLLRDHUP or EPOLLOUT
    ev.data.u64 = client.idx.uint or 0x300000000'u64
    var ret = epoll_ctl(epfd, EPOLL_CTL_ADD, fd.cint, addr ev)
    if ret < 0:
      error "error: epoll_ctl ret=", ret, " errno=", errno
      abort()
    else:
      client.invoke = false
  else:
    ev.events = EPOLLIN or EPOLLRDHUP or exEvents
    ev.data.u64 = evData
    var ret = epoll_ctl(epfd, EPOLL_CTL_ADD, fd.cint, addr ev)
    if ret < 0:
      error "error: epoll_ctl ret=", ret, " errno=", errno
      abort()

proc close(client: Client) =
  debug "close ", client.fd
  when declared(freeExClient):
    freeExClient(client)
  client.whackaMole = false
  client.invoke = false
  client.ip = 0
  when ENABLE_SSL:
    if not client.ssl.isNil:
      SSL_free(client.ssl)
      client.ssl = nil
      client.sslErr = SSL_ERROR_NONE
  client.fd.SocketHandle.close()
  client.recvCurSize = 0
  client.recvBufSize = 0
  if not client.recvBuf.isNil:
    deallocShared(cast[pointer](client.recvBuf))
    client.recvBuf = nil
  client.sendBufSize = 0
  if not client.sendBuf.isNil:
    deallocShared(cast[pointer](client.sendBuf))
    client.sendBuf = nil
  client.keepAlive = true
  client.wsUpgrade = false
  client.payloadSize = 0
  client.fd = osInvalidSocket.int

when not declared(webMain):
  proc webMainDefault(client: Client, url: string, headers: Headers): SendResult =
    debug "web url=", url, " headers=", headers
    when DYNAMIC_FILES:
      var retFile = getDynamicFile(url)
    else:
      var retFile = getConstFile(url)
    if retFile.err == FileContentSuccess:
      var file = retFile.data
      if headers.hasKey("If-None-Match") and headers["If-None-Match"] == file.md5:
        result = client.send(Empty.addHeader(Status304))
      else:
        when not DYNAMIC_FILES or DYNAMIC_COMPRESS:
          if headers.hasKey("Accept-Encoding"):
            var acceptEnc = headers["Accept-Encoding"].split(",")
            acceptEnc.apply(proc(x: string): string = x.strip)
            if acceptEnc.contains("br"):
              return client.send(file.brotli.addHeaderBrotli(file.md5, Status200, file.mime))
            elif acceptEnc.contains("deflate"):
              return client.send(file.deflate.addHeaderDeflate(file.md5, Status200, file.mime))
        return client.send(file.content.addHeader(file.md5, Status200, file.mime))
    else:
      when not DYNAMIC_FILES:
        var fileAcme = getAcmeChallenge(url)
        if fileAcme.content.len > 0:
          return client.send(fileAcme.content.addHeader(Status200, fileAcme.mime))

      if url == "/reset":
        return client.send(
          """<!DOCTYPE html><meta charset="utf-8"><script>localStorage.clear();location.href="/"</script>"""
          .addHeader(Status200))

      return client.send(NotFound.addHeader(Status404))

when not declared(streamMain):
  proc streamMainDefault(client: Client, opcode: WebSocketOpCode,
                        data: ptr UncheckedArray[byte], size: int): SendResult =
    debug "ws opcode=", opcode, " size=", size
    case opcode
    of WebSocketOpcode.Binary, WebSocketOpcode.Text, WebSocketOpcode.Continue:
      result = client.wsServerSend(data.toString(size), WebSocketOpcode.Binary)
    of WebSocketOpcode.Ping:
      result = client.wsServerSend(data.toString(size), WebSocketOpcode.Pong)
    of WebSocketOpcode.Pong:
      debug "pong ", data.toString(size)
      result = SendResult.Success
    else: # WebSocketOpcode.Close
      result = SendResult.None

when not declared(invokeSendMain):
  proc invokeSendMainDefault(client: Client): SendResult =
    result = SendResult.None

proc workerMain(client: Client, buf: ptr UncheckedArray[byte], size: int, appId: int): SendResult =
  var i = 0
  var cur = 0
  var first = true
  var cmd = ""
  var url = ""
  var keepAlive = false
  var retMain = SendResult.None
  var headers = initTable[string, string]()

  while i  < size - 3:
    if buf[i] == byte('\c') and buf[i + 1] == byte('\L'):
      var reqdata = (cast[ptr UncheckedArray[byte]](addr buf[cur])).toString(i - cur)
      if first:
        first = false
        var cmdparams = reqdata.split(" ").filter(proc(x: string): bool = x.len > 0)
        if cmdparams.len >= 2:
          cmd = cmdparams[0]
          if cmd != "GET":
            error "invalid request cmd=", cmd.toBytes
            return SendResult.Invalid
          var urlpath = cgi.decodeUrl(cmdparams[1])
          if urlpath.split("/").contains(".."):
            error "invalid request path: ", urlpath
            return SendResult.Invalid
          url = normalizedPath(urlpath)
          if urlpath.endsWith("/") and not url.endsWith("/"):
            url = url & "/"
          if cmdparams.len >= 3 and cmdparams[2] == "HTTP/1.1":
            keepAlive = true
      else:
        var pos = reqdata.find(":")
        if pos > 0:
          headers[reqdata[0..pos-1]] = reqdata[pos+1..^1].strip
        else:
          error "invalid request reqdata=", reqdata
          return SendResult.Invalid

      inc(i, 2)
      if buf[i] == byte('\c') and buf[i + 1] == byte('\L'):
        if headers.hasKey("Host"):
          if appId == 1:
            if headers["Host"] != HTTP_HOST_NAME:
              error "invalid request host mismatch ", headers["Host"], " ", HTTP_HOST_NAME
              return SendResult.Invalid
            return client.send(redirect301(REDIRECT_URL & url))
          else:
            if headers["Host"] != HTTPS_HOST_NAME:
              error "invalid request host mismatch ", headers["Host"], " ", HTTPS_HOST_NAME
              return SendResult.Invalid
        else:
          error "invalid request no host headers=", headers
          return SendResult.Invalid

        if url == WEBSOCKET_ENTRY_POINT:
          if headers.hasKey("Sec-WebSocket-Version") and
            headers.hasKey("Sec-WebSocket-Key") and
            headers.hasKey("Sec-WebSocket-Protocol") and
            headers["Sec-WebSocket-Protocol"] == WEBSOCKET_PROTOCOL:
            var key = headers["Sec-WebSocket-Key"]
            var sh = secureHash(key & "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
            var acceptKey = base64.encode(sh.Sha1Digest)
            var res = "HTTP/1.1 " & $Status101 & "\c\L" &
                      "Upgrade: websocket\c\L" &
                      "Connection: Upgrade\c\L" &
                      "Sec-WebSocket-Accept: " & acceptKey & "\c\L" &
                      "Sec-WebSocket-Protocol: " & WEBSOCKET_PROTOCOL & "\c\L" &
                      "Sec-WebSocket-Version: 13\c\L\c\L"
            client.wsUpgrade = true
            debug "ws upgrade url=", url, " headers=", headers
            when declared(streamConnect):
              var sendRet = client.send(res)
              if sendRet == SendResult.Success or sendRet == SendResult.Pending:
                var (sendFlag, sendResult) = client.streamConnect()
                if sendFlag and sendResult != SendResult.Success:
                  sendRet = sendResult
              return sendRet
            else:
              return client.send(res)
          else:
            error "error: websocket protocol headers=", headers
            raise newException(ServerError, "websocket protocol error")

        when declared(webMain):
          retMain = client.webMain(url, headers)
        else:
          retMain = client.webMainDefault(url, headers)
        if not keepAlive or (headers.hasKey("Connection") and
                                  headers["Connection"] == "close"):
          client.keepAlive = false
          return retMain

        inc(i, 2)
        if i >= size:
          return retMain

        first = true
        cmd = ""
        url = ""
        keepAlive = false
        headers = initTable[string, string]()

      cur = i
    inc(i)

  return retMain

proc worker(arg: ThreadArg) {.thread.} =
  when declared(initWorker):
    initWorker()
  var recvBuf = newSeq[byte](arg.workerParams.bufLen)

  proc reserveRecvBuf(client: Client, size: int) =
    if client.recvBuf.isNil:
      client.recvBuf = cast[ptr UncheckedArray[byte]](allocShared0(sizeof(byte) * (size + arg.workerParams.bufLen)))
      client.recvBufSize = size + arg.workerParams.bufLen
    var left = client.recvBufSize - client.recvCurSize
    if size > left:
      var nextSize = client.recvCurSize + size + arg.workerParams.bufLen
      if nextSize > RECVBUF_EXPAND_BREAK_SIZE:
        raise newException(ServerError, "client request too large")
      client.recvBuf = reallocClientBuf(client.recvBuf, nextSize)
      client.recvBufSize = nextSize

  proc addRecvBuf(client: Client, data: ptr UncheckedArray[byte], size: int) =
    client.reserveRecvBuf(size)
    copyMem(addr client.recvBuf[client.recvCurSize], addr data[0], size)
    client.recvCurSize = client.recvCurSize + size

  when DYNAMIC_FILES:
    initDynamicFile()

  while true:
    block channelBlock:
      var channelData = workerChannel[].recv()
      if not active:
        when declared(freeWorker):
          freeWorker()
        return
      var appId = channelData.appId
      var idx = channelData.idx
      var events = channelData.events
      var evData = channelData.evData
      debug "appId=", appId, " idx=", idx, " ev=", events, " tid=", arg.workerParams.threadId

      var client = addr clients[idx]
      var clientFd = client.fd
      var clientSock = clientFd.SocketHandle
      client.whackaMole = false

      try:
        when ENABLE_SSL:
          ERR_clear_error()

          if appId == 4:
            while true:
              let retSslAccept = SSL_accept(client.ssl)
              if retSslAccept < 0:
                var ev: EpollEvent
                client.sslErr = SSL_get_error(client.ssl, retSslAccept)
                debug "SSL_accept err=", client.sslErr, " errno=", errno
                if client.sslErr == SSL_ERROR_WANT_READ:
                  ev.events = EPOLLIN or EPOLLRDHUP
                elif client.sslErr == SSL_ERROR_WANT_WRITE:
                  ev.events = EPOLLIN or EPOLLRDHUP or EPOLLOUT
                else:
                  if errno == EINTR:
                    continue
                  client.close()
                  break channelBlock

                ev.data.u64 = client.idx.uint or 0x400000000'u64
                var ret = epoll_ctl(epfd, EPOLL_CTL_ADD, clientFd.cint, addr ev)
                if ret < 0:
                  error "error: epoll_ctl ret=", ret, " errno=", errno
                  abort()
              elif retSslAccept == 0:
                client.close()
              else:
                client.waitEventAgain(client.idx.uint, clientFd)
              break channelBlock

        if client.sendBuf != nil:
          if (events and EPOLLOUT) > 0:
            var retFlush = client.sendFlush()
            if retFlush == SendResult.Pending:
              when ENABLE_SSL:
                if client.sslErr == SSL_ERROR_WANT_READ:
                  client.waitEventAgain(evData, clientFd)
                else:
                  client.waitEventAgain(evData, clientFd, EPOLLOUT)
              else:
                client.waitEventAgain(evData, clientFd, EPOLLOUT)
              break channelBlock
            if retFlush != SendResult.Success or not client.keepAlive:
              client.close()
              break channelBlock
          if (events and (EPOLLIN or EPOLLRDHUP)) == 0 and appId != 3:
            client.waitEventAgain(evData, clientFd)
            break channelBlock

        if appId == 3:
          when declared(invokeSendMain):
            var retInvoke = client.invokeSendMain()
          else:
            var retInvoke = client.invokeSendMainDefault()

          if retInvoke == SendResult.Pending:
            when ENABLE_SSL:
              if client.sslErr == SSL_ERROR_WANT_READ:
                client.waitEventAgain(evData, clientFd)
              else:
                client.waitEventAgain(evData, clientFd, EPOLLOUT)
            else:
              client.waitEventAgain(evData, clientFd, EPOLLOUT)
            break channelBlock
          evData = evData and 0xffffffff'u64 # drop AppId
          if (events and (EPOLLIN or EPOLLRDHUP)) == 0:
            client.waitEventAgain(evData, clientFd)
            break channelBlock

        if appId == 2:
          if client.wsUpgrade:
            error "error: ws too many ", inet_ntoa(InAddr(s_addr: client.ip))
            client.close()
            break channelBlock
          else:
            error "error: too many ", inet_ntoa(InAddr(s_addr: client.ip))
            clientSock.sendInstant(TooMany.addHeader(Status429))
            clientSock.close()
            break channelBlock

        template retWorkerHandler(retWorker: SendResult) {.dirty.} =
          case retWorker
          of SendResult.Success:
            if not client.keepAlive:
              client.close()
              break channelBlock
          of SendResult.Pending:
            when ENABLE_SSL:
              if client.sslErr == SSL_ERROR_WANT_READ:
                client.waitEventAgain(evData, clientFd)
              else:
                client.waitEventAgain(evData, clientFd, EPOLLOUT)
            else:
              client.waitEventAgain(evData, clientFd, EPOLLOUT)
            break channelBlock
          of SendResult.Invalid:
            client.sendInstant(BadRequest.addHeader(Status400))
            client.close()
            break channelBlock
          of SendResult.None, SendResult.Error:
            client.close()
            break channelBlock

        template retStreamHandler(retStream: SendResult) {.dirty.} =
          case retStream
          of SendResult.Success:
            discard
          of SendResult.Pending:
            when ENABLE_SSL:
              if client.sslErr != SSL_ERROR_WANT_READ:
                exEvents = EPOLLOUT
            else:
              exEvents = EPOLLOUT
          of SendResult.None, SendResult.Error, SendResult.Invalid:
            client.close()
            break channelBlock

        var recvlen: int
        if client.recvBufSize == 0:
          while true:
            when ENABLE_SSL:
              if not client.ssl.isNil:
                recvlen = client.ssl.SSL_read(addr recvBuf[0], recvBuf.len.cint)
              else:
                recvlen = clientSock.recv(addr recvBuf[0], recvBuf.len.cint, 0.cint)

            else:
              recvlen = clientSock.recv(addr recvBuf[0], recvBuf.len.cint, 0.cint)
            if recvlen > 0:
              if client.wsUpgrade:
                var exEvents = 0'u32
                var (find, fin, opcode, payload, payloadSize,
                    next, size) = getFrame(cast[ptr UncheckedArray[byte]](addr recvBuf[0]), recvlen)
                while find:
                  if fin:
                    when declared(streamMain):
                      var retStream = client.streamMain(opcode.toWebSocketOpCode, payload, payloadSize)
                    else:
                      var retStream = client.streamMainDefault(opcode.toWebSocketOpCode, payload, payloadSize)
                    retStreamHandler(retStream)
                  else:
                    if not payload.isNil and payloadSize > 0:
                      client.addRecvBuf(payload, payloadSize)
                      client.payloadSize = payloadSize
                    break
                  (find, fin, opcode, payload, payloadSize, next, size) = getFrame(next, size)

                if not next.isNil and size > 0:
                  client.addRecvBuf(next, size)
                  if recvlen == recvBuf.len:
                    break

                client.waitEventAgain(evData, clientFd, exEvents)
                break channelBlock

              elif recvlen >= 4 and recvBuf[recvlen - 4].toUint32 == CLCL:
                var retWorker = workerMain(client, cast[ptr UncheckedArray[byte]](addr recvBuf[0]), recvlen, appId)
                retWorkerHandler(retWorker)
              elif recvlen >= 4 and recvBuf[0..3].toString != "GET ":
                  error "invalid request cmd=", recvBuf[0..<recvlen]
                  clientSock.sendInstant(Empty.addHeader(Status405))
                  client.close()
                  break channelBlock
              else:
                client.addRecvBuf(cast[ptr UncheckedArray[byte]](addr recvBuf[0]), recvlen)
                if recvlen == recvBuf.len:
                  break
              client.waitEventAgain(evData, clientFd)
              break channelBlock
            elif recvlen == 0:
              client.close()
              break channelBlock
            else:
              when ENABLE_SSL:
                if not client.ssl.isNil:
                  client.sslErr = SSL_get_error(client.ssl, recvlen.cint)
                  debug "SSL_read err=", client.sslErr, " errno=", errno
                  if client.sslErr == SSL_ERROR_WANT_READ:
                    client.waitEventAgain(evData, clientFd)
                    break channelBlock
                  elif client.sslErr == SSL_ERROR_WANT_WRITE:
                    client.waitEventAgain(evData, clientFd, EPOLLOUT)
                    break channelBlock
                  else:
                    if errno == EINTR:
                      continue
                  client.close()
                  break channelBlock

              if errno == EAGAIN or errno == EWOULDBLOCK:
                client.waitEventAgain(evData, clientFd)
                break channelBlock
              if errno == EINTR:
                continue
              client.close()
              break channelBlock

        while true:
          client.reserveRecvBuf(arg.workerParams.bufLen)
          when ENABLE_SSL:
            if not client.ssl.isNil:
              recvlen = client.ssl.SSL_read(addr client.recvBuf[client.recvCurSize], arg.workerParams.bufLen.cint)
            else:
              recvlen = clientSock.recv(addr client.recvBuf[client.recvCurSize], arg.workerParams.bufLen.cint, 0.cint)
          else:
            recvlen = clientSock.recv(addr client.recvBuf[client.recvCurSize], arg.workerParams.bufLen.cint, 0.cint)
          if recvlen > 0:
            client.recvCurSize = client.recvCurSize + recvlen
            if client.wsUpgrade:
              var exEvents = 0'u32
              var p = cast[ptr UncheckedArray[byte]](addr client.recvBuf[client.payloadSize])
              var (find, fin, opcode, payload, payloadSize,
                  next, size) = getFrame(p, client.recvCurSize - client.payloadSize)
              while find:
                if not payload.isNil and payloadSize > 0:
                  copyMem(p, payload, payloadSize)
                  client.payloadSize = client.payloadSize + payloadSize
                  p = cast[ptr UncheckedArray[byte]](addr client.recvBuf[client.payloadSize])
                if fin:
                  when declared(streamMain):
                    var retStream = client.streamMain(opcode.toWebSocketOpCode,
                                                      cast[ptr UncheckedArray[byte]](addr client.recvBuf[0]),
                                                      client.payloadSize)
                  else:
                    var retStream = client.streamMainDefault(opcode.toWebSocketOpCode,
                                                      cast[ptr UncheckedArray[byte]](addr client.recvBuf[0]),
                                                      client.payloadSize)
                  retStreamHandler(retStream)
                  client.payloadSize = 0
                  client.recvCurSize = 0
                (find, fin, opcode, payload, payloadSize, next, size) = getFrame(next, size)

              if not next.isNil and size > 0:
                copyMem(p, next, size)
                client.recvCurSize = client.payloadSize + size
                if recvlen == arg.workerParams.bufLen:
                  continue
              else:
                client.recvCurSize = client.payloadSize

              client.waitEventAgain(evData, clientFd, exEvents)
              break channelBlock

            elif client.recvCurSize >= 4 and client.recvBuf[client.recvCurSize - 4].toUint32 == CLCL:
              var retWorker = workerMain(client, cast[ptr UncheckedArray[byte]](client.recvBuf), client.recvCurSize, appId)
              client.recvCurSize = 0
              client.recvBufSize = 0
              deallocShared(cast[pointer](client.recvBuf))
              client.recvBuf = nil
              retWorkerHandler(retWorker)
            elif recvlen == arg.workerParams.bufLen:
              continue
            client.waitEventAgain(evData, clientFd)
            break channelBlock
          elif recvlen == 0:
            client.close()
            break channelBlock
          else:
            when ENABLE_SSL:
              if not client.ssl.isNil:
                client.sslErr = SSL_get_error(client.ssl, recvlen.cint)
                debug "SSL_read err=", client.sslErr, " errno=", errno
                if client.sslErr == SSL_ERROR_WANT_READ:
                  client.waitEventAgain(evData, clientFd)
                  break channelBlock
                elif client.sslErr == SSL_ERROR_WANT_WRITE:
                  client.waitEventAgain(evData, clientFd, EPOLLOUT)
                  break channelBlock
                else:
                  if errno == EINTR:
                    continue
                client.close()
                break channelBlock

            if errno == EAGAIN or errno == EWOULDBLOCK:
              client.waitEventAgain(evData, clientFd)
              break channelBlock
            if errno == EINTR:
              continue
            client.close()
            break channelBlock

      except ServerNeedRestartError:
        let e = getCurrentException()
        error e.name, ": ", e.msg
        restart()

      except:
        client.close()
        let e = getCurrentException()
        error e.name, ": ", e.msg

proc dispatcher(arg: ThreadArg) {.thread.} =
  var reqStats = newCheckReqs(REQ_LIMIT_DISPATCH_PERIOD)

  while true:
    var nfd = epoll_wait(epfd, cast[ptr EpollEvent](addr events),
                        EPOLL_EVENTS_SIZE.cint, 3000.cint)
    if not active:
      break
    if nfd > 0:
      for i in 0..<nfd:
        var evData = events[i].data.u64
        var appId = (evData shr 32).int
        var idx = (evData and 0xffffffff'u64).int
        var clientFd = clients[idx].fd
        var ret = epoll_ctl(epfd, EPOLL_CTL_DEL, clientFd.cint, nil)
        if ret < 0:
          error "error: epoll_ctl ret=", ret, " errno=", errno
          abort()

        if appId != 3:
          var reqCount = reqStats.checkReq(clients[idx].ip)
          if reqCount > REQ_LIMIT_DISPATCH_MAX:
            appId = 2

        workerChannel[].send((appId, idx, events[i].events, evData))
        workerChannelWaitingCount = workerChannel[].peek()
    elif nfd < 0:
        if errno == EINTR:
          continue
        error "error: epoll_wait ret=", nfd, " errno=", errno
        abort()

when ENABLE_SSL:
  import macros except error
  export tables

  macro certFilesTable(): untyped =
    var certsTable: seq[tuple[key: string, val: tuple[
      idx: int, cert: string, privkey: string, fullchain: string]]]

    for idx, site in CERT_SITES:
      let certPath = CERT_PATH / site / CERT_FILE
      let privkeyPath = CERT_PATH / site / PRIVKEY_FILE
      let fullchainPath = CERT_PATH / site / CHAIN_FILE
      certsTable.add((site, (idx, certPath, privkeyPath, fullchainPath)))

    newConstStmt(
      postfix(newIdentNode("certsTable"), "*"),
      newCall("toTable",
        newLit(certsTable)
      )
    )
  certFilesTable()

  type
    SiteCtx = object
      ctx: SSL_CTX
      updated: bool
      watchdog: cint

  var siteCtxs: array[CERT_SITES.len, SiteCtx]

  when ENABLE_SSL:
    when SSL_AUTO_RELOAD:
      import std/inotify
      import ptlock

      type
        SslFileHash* = object
          cert: array[32, byte]
          priv: array[32, byte]
          chain: array[32, byte]

      var sslFileChanged = false
      var sslFileUpdateLock: RWLock
      var sslFileHash: ptr UncheckedArray[SslFileHash]
      var inoty: FileHandle
      var inotyWatchFlag: bool

      proc setSslFilesWatch() =
        if inoty == -1:
          inoty = inotify_init()
          if inoty == -1:
            error "error: inotify_init err=", errno
            return
        for i, site in CERT_SITES:
          if siteCtxs[i].watchdog == -1:
            let sitePath = CERT_PATH / site
            siteCtxs[i].watchdog = inotify_add_watch(inoty, cstring(sitePath), IN_CLOSE_WRITE)
            if siteCtxs[i].watchdog == -1:
              error "error: inotify_add_watch err=", errno, " ", sitePath
            else:
              inotyWatchFlag = true

      proc setSslFileHash(init: bool = false) =
        if sslFileHash.isNil:
          if init:
            rwlockInit(sslFileUpdateLock)
            sslFileHash = cast[ptr UncheckedArray[SslFileHash]](allocShared0(sizeof(SslFileHash) * CERT_SITES.len))
            inoty = -1
            for i in 0..<CERT_SITES.len:
              siteCtxs[i].watchdog = -1
            setSslFilesWatch()
          else:
            return
        else:
          setSslFilesWatch()

        var changeFlag = false
        for i, site in CERT_SITES:
          try:
            let certs = certsTable[site]
            let cert = sha256.digest(readFile(certs.cert)).data
            let priv = sha256.digest(readFile(certs.privkey)).data
            let chain = sha256.digest(readFile(certs.fullchain)).data
            if init == false:
              if sslFileHash[i].cert != cert or
                sslFileHash[i].priv != priv or
                sslFileHash[i].chain != chain:
                changeFlag = true
                debug "SSL file changed"
            copyMem(addr sslFileHash[i].cert[0], unsafeAddr cert[0], 32)
            copyMem(addr sslFileHash[i].priv[0], unsafeAddr priv[0], 32)
            copyMem(addr sslFileHash[i].chain[0], unsafeAddr chain[0], 32)
          except:
            let e = getCurrentException()
            error "setSslFileHash ", e.name, ": ", e.msg
        if changeFlag:
          withWriteLock sslFileUpdateLock:
            sslFileChanged = true

      proc initSslFileHash() {.inline.} = setSslFileHash(true)

      proc freeSslFileHash() =
        if inoty != -1:
          for i in 0..<CERT_SITES.len:
            if siteCtxs[i].watchdog != -1:
              discard inoty.inotify_rm_watch(siteCtxs[i].watchdog)
          discard inoty.close()
        if not sslFileHash.isNil:
          var p = sslFileHash
          sslFileHash = nil
          deallocShared(p)
        rwlockDestroy(sslFileUpdateLock)

      proc checkSslFileHash() {.inline.} = setSslFileHash()

  proc selfSignedCertificate(ctx: SSL_CTX) =
    var x509: X509 = X509_new()
    var pkey: EVP_PKEY = EVP_PKEY_new()
    var rsa: RSA = RSA_new()
    var exp: BIGNUM = BN_new()
    var big: BIGNUM = BN_new()
    var serial: ASN1_INTEGER = ASN1_INTEGER_new()

    defer:
      ASN1_INTEGER_free(serial)
      BN_free(big)
      BN_free(exp)
      if not rsa.isNil: RSA_free(rsa)
      EVP_PKEY_free(pkey)
      X509_free(x509)

    template checkErr(err: cint) {.dirty.} =
      if err == 0:
        raise newException(ServerSslCertError, "self certificate check error")

    checkErr BN_set_word(exp, RSA_F4)
    checkErr RSA_generate_key_ex(rsa, 2048, exp, nil)
    checkErr BN_pseudo_rand(big, 64, 0, 0)
    BN_to_ASN1_INTEGER(big, serial)
    checkErr X509_set_serialNumber(x509, serial)
    checkErr EVP_PKEY_assign_RSA(pkey, rsa)
    rsa = nil
    checkErr X509_set_version(x509, 2)
    X509_gmtime_adj(X509_get_notBefore(x509), -60 * 60)
    X509_gmtime_adj(X509_get_notAfter(x509), 60 * 60 * 24 * 365 * 10)
    checkErr X509_set_pubkey(x509, pkey)
    var name: X509_NAME = X509_get_subject_name(x509)
    checkErr X509_NAME_add_entry_by_txt(name, "C", MBSTRING_ASC, "JP", -1, -1, 0)
    checkErr X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC, "Blockstor Self-Signed Certificate", -1, -1, 0)
    checkErr X509_set_issuer_name(x509, name)
    checkErr X509_sign(x509, pkey, EVP_sha1())

    var retCert = SSL_CTX_use_certificate(ctx, x509)
    if retCert != 1:
      error "error: self certificate"
      raise newException(ServerSslCertError, "self certificate")
    var retPriv = SSL_CTX_use_PrivateKey(ctx, pkey)
    if retPriv != 1:
      error "error: self private key"
      raise newException(ServerSslCertError, "self private key")

  proc newSslCtx(site: string = "", selfSignedCertFallback: bool = false): SSL_CTX =
    var ctx = SSL_CTX_new(TLS_server_method())
    try:
      let certs = certsTable[site]
      var retCert = SSL_CTX_use_certificate_file(ctx, cstring(certs.cert), SSL_FILETYPE_PEM)
      if retCert != 1:
        error "error: certificate file"
        raise newException(ServerSslCertError, "certificate file")
      var retPriv = SSL_CTX_use_PrivateKey_file(ctx, cstring(certs.privkey), SSL_FILETYPE_PEM)
      if retPriv != 1:
        error "error: private key file"
        raise newException(ServerSslCertError, "private key file")
      var retChain = SSL_CTX_use_certificate_chain_file(ctx, cstring(certs.fullchain))
      if retChain != 1:
        error "error: chain file"
        raise newException(ServerSslCertError, "chain file")
    except:
      if not selfSignedCertFallback:
        ctx.SSL_CTX_free()
        raise
      ctx.selfSignedCertificate()

    SSL_CTX_set_options(ctx, (SSL_OP_NO_SSLv2 or SSL_OP_NO_SSLv3 or
                          SSL_OP_NO_TLSv1 or SSL_OP_NO_TLSv1_1).clong)
    SSL_CTX_set_mode(ctx, (SSL_MODE_ENABLE_PARTIAL_WRITE or SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER).clong)
    result = ctx

  proc serverNameCallback(ssl: SSL; out_alert: ptr cint; arg: pointer): cint {.cdecl.} =
    try:
      let sitename = $SSL_get_servername(ssl, TLSEXT_NAMETYPE_host_name)
      debug "sitename=", sitename
      let certs = certsTable[sitename]
      let ctx = siteCtxs[certs.idx].ctx
      if SSL_set_SSL_CTX(ssl, ctx).isNil:
        error "error: SSL_set_SSL_CTX site=", sitename
        return SSL_TLSEXT_ERR_NOACK
      return SSL_TLSEXT_ERR_OK
    except:
      return SSL_TLSEXT_ERR_OK

  SSL_load_error_strings()
  SSL_library_init()
  OpenSSL_add_all_algorithms()

proc acceptClient(arg: ThreadArg) {.thread.} =
  when ENABLE_SSL:
    when SSL_AUTO_RELOAD:
      initSslFileHash()
    var ctx = newSslCtx(selfSignedCertFallback = true)
    for i, site in CERT_SITES:
      siteCtxs[i].ctx = newSslCtx(site, selfSignedCertFallback = true)
      siteCtxs[i].updated = false
    SSL_CTX_set_tlsext_servername_callback(ctx, serverNameCallback)

  var reqStats = newCheckReqs(REQ_LIMIT_HTTPS_ACCEPT_PERIOD)

  while true:
    var sockAddress: Sockaddr_in
    var addrLen = sizeof(sockAddress).SockLen
    var clientSock = accept(serverSock, cast[ptr SockAddr](addr sockAddress), addr addrLen)
    if not active: break
    var clientFd = clientSock.int
    if clientFd < 0:
      if errno == EINTR:
        continue
      error "error: accept errno=", errno
      abort()

    when ENABLE_KEEPALIVE:
      clientSock.setSockOptInt(SOL_SOCKET, SO_KEEPALIVE, 1)
    when ENABLE_TCP_NODELAY:
      clientSock.setSockOptInt(Protocol.IPPROTO_TCP.int, TCP_NODELAY, 1)
    var ip = sockAddress.sin_addr.s_addr
    var address = inet_ntoa(sockAddress.sin_addr)

    debug "client ip=", $address, " fd=", clientFd

    when ENABLE_SSL:
      when SSL_AUTO_RELOAD:
        withWriteLock sslFileUpdateLock:
          if sslFileChanged:
            sslFileChanged = false
            var oldCtx = ctx
            ctx = newSslCtx(selfSignedCertFallback = true)
            oldCtx.SSL_CTX_free()
            for i, site in CERT_SITES:
              if siteCtxs[i].updated:
                var oldCtx = siteCtxs[i].ctx
                siteCtxs[i].ctx = newSslCtx(site, selfSignedCertFallback = true)
                siteCtxs[i].updated = false
                oldCtx.SSL_CTX_free()
            SSL_CTX_set_tlsext_servername_callback(ctx, serverNameCallback)
            debug "SSL ctx updated"

      var ssl = SSL_new(ctx)
      if SSL_set_fd(ssl, clientFd.cint) != 1:
        error "error: SSL_set_fd"
        SSL_free(ssl)
        clientSock.close()
        continue

    template acceptInstant(body: untyped) =
      clientSock.setBlocking(false)
      var retryCount: int
      while true:
        let retSslAccept = SSL_accept(ssl)
        if retSslAccept >= 0:
          body
          break
        if retryCount >= 10:
          debug "accept giveup"
          break
        sleep(10)
        inc(retryCount)
        debug "accept retry count=", retryCount, " ", SSL_get_error(ssl, retSslAccept)

    template busyErrorContinue() =
      when ENABLE_SSL:
        acceptInstant:
          ssl.sendInstant(BusyBody.addHeader(Status503))
        SSL_free(ssl)
      else:
        clientSock.sendInstant(BusyBody.addHeader(Status503))
      clientSock.close()
      continue

    if workerChannelWaitingCount > WORKER_QUEUE_LIMIT:
      error "error: worker busy"
      busyErrorContinue()

    var reqCount = reqStats.checkReq(ip)
    if reqCount > REQ_LIMIT_HTTPS_ACCEPT_MAX:
      error "error: too many ", $address
      when ENABLE_SSL:
        acceptInstant:
          ssl.sendInstant(TooMany.addHeader(Status429))
        SSL_free(ssl)
      else:
        clientSock.sendInstant(TooMany.addHeader(Status429))
      clientSock.close()
      continue

    var idx = setClient(clientFd)
    if idx < 0:
      error "error: server full"
      busyErrorContinue()

    when ENABLE_SSL:
      clients[idx].ssl = ssl
    clients[idx].ip = ip

    clientSock.setBlocking(false)

    var ev: EpollEvent
    when ENABLE_SSL:
      ev.events = EPOLLIN or EPOLLRDHUP or EPOLLOUT
      ev.data.u64 = idx.uint or 0x400000000'u64
    else:
      ev.events = EPOLLIN or EPOLLRDHUP
      ev.data.u64 = idx.uint
    var ret = epoll_ctl(epfd, EPOLL_CTL_ADD, clientFd.cint, addr ev)
    if ret < 0:
      error "error: epoll_ctl ret=", ret, " errno=", errno
      abort()

proc http(arg: ThreadArg) {.thread.} =
  var reqStats = newCheckReqs(REQ_LIMIT_HTTP_ACCEPT_PERIOD)

  while true:
    var sockAddress: Sockaddr_in
    var addrLen = sizeof(sockAddress).SockLen
    var clientSock = accept(httpSock, cast[ptr SockAddr](addr sockAddress), addr addrLen)
    if not active: break
    var clientFd = clientSock.int
    if clientFd < 0:
      if errno == EINTR:
        continue
      error "error: accept errno=", errno
      abort()

    var ip = sockAddress.sin_addr.s_addr
    var address = inet_ntoa(sockAddress.sin_addr)

    debug "client ip=", $address, " fd=", clientFd

    template busyErrorContinue() =
      clientSock.sendInstant(BusyBody.addHeader(Status503))
      clientSock.close()
      continue

    if workerChannelWaitingCount > WORKER_QUEUE_LIMIT:
      error "error: worker busy"
      busyErrorContinue()

    var reqCount = reqStats.checkReq(ip)
    if reqCount > REQ_LIMIT_HTTP_ACCEPT_MAX:
      error "error: too many ", $address
      clientSock.sendInstant(TooMany.addHeader(Status429))
      clientSock.close()
      continue

    var idx = setClient(clientFd)
    if idx < 0:
      error "error: server full"
      busyErrorContinue()

    clients[idx].ip = ip

    clientSock.setBlocking(false)

    var ev: EpollEvent
    ev.events = EPOLLIN or EPOLLRDHUP
    ev.data.u64 = idx.uint or 0x100000000'u64
    var ret = epoll_ctl(epfd, EPOLL_CTL_ADD, clientFd.cint, addr ev)
    if ret < 0:
      error "error: epoll_ctl ret=", ret, " errno=", errno
      abort()

proc serverMonitor(arg: ThreadArg) {.thread.} =
  var prevTime = getTime()
  var sec = 0
  while active:
    if sec >= 60:
      sec = 0
      when ENABLE_SSL:
        when SSL_AUTO_RELOAD:
          if not sslFileChanged:
            var curTime = getTime()
            let dur = curTime - prevTime
            if dur >= initDuration(hours = 1):
              checkSslFileHash()
              prevTime = curTime

      for i in 0..<CLIENT_MAX:
        if clients[i].fd != osInvalidSocket.int and not clients[i].wsUpgrade:
          if clients[i].whackaMole:
            debug "Whack-A-Mole shutdown i=", i
            let retShutdown = clients[i].fd.SocketHandle.shutdown(SHUT_RD)
            if retShutdown != 0:
              error "error: Whack-A-Mole shutdown ret=", retShutdown, " ", getErrnoStr()
          else:
            debug "Whack-A-Mole set i=", i
            clients[i].whackaMole = true

    sleep(1000)
    inc(sec)

  when ENABLE_SSL:
    when SSL_AUTO_RELOAD:
      freeSslFileHash()

when ENABLE_SSL:
  when SSL_AUTO_RELOAD:
    proc fileWatcher(arg: ThreadArg) {.thread.} =
      var evs = newSeq[byte](sizeof(InotifyEvent) * 512)
      while active:
        if not inotyWatchFlag:
          sleep(1000)
          continue
        let n = read(inoty, evs[0].addr, evs.len)
        if n <= 0: break
        var updated = false
        withWriteLock sslFileUpdateLock:
          for e in inotify_events(evs[0].addr, n):
            if e[].len > 0:
              debug "file updated name=", $cast[cstring](addr e[].name)
              for i in 0..<CERT_SITES.len:
                if siteCtxs[i].watchdog == e[].wd:
                  siteCtxs[i].updated = true
                  if $cast[cstring](addr e[].name) == CHAIN_FILE:
                    # certbot writes fullchain file last, your script must also copy fullchain file last
                    updated = true
                  break
          if updated:
            sleep(3000)
            sslFileChanged = true

proc createServer(port: Port): SocketHandle =
  var sock = createNativeSocket()
  var aiList = getAddrInfo("0.0.0.0", port, Domain.AF_INET)
  sock.setSockOptInt(SOL_SOCKET, SO_REUSEADDR, 1)
  var retBind = sock.bindAddr(aiList.ai_addr, aiList.ai_addrlen.SockLen)
  if retBind < 0:
    errorQuit "error: bind ret=", retBind, " ", getErrnoStr()
  freeaddrinfo(aiList)

  var retListen = sock.listen()
  if retListen < 0:
    errorQuit "error: listen ret=", retListen, " ", getErrnoStr()
  result = sock

proc threadWrapper(wrapperArg: WrapperThreadArg) {.thread.} =
  try:
    wrapperArg.threadFunc(wrapperArg.arg)
  except:
    let e = getCurrentException()
    echo e.name, ": ", e.msg
    abort()

proc main(arg: ThreadArg) {.thread.} =
  while true:
    serverSock = createServer(Port(HTTPS_PORT))
    httpSock = createServer(Port(HTTP_PORT))

    var tcp_rmem = serverSock.getSockOptInt(SOL_SOCKET, SO_RCVBUF)
    debug "RECVBUF=", tcp_rmem

    epfd = epoll_create1(O_CLOEXEC)
    if epfd < 0:
      errorQuit "error: epfd=", epfd, " errno=", errno

    when declared(initStream):
      initStream()

    initClient()

    workerChannel = cast[ptr Channel[WorkerChannelParam]](allocShared0(sizeof(Channel[WorkerChannelParam])))
    workerChannel[].open()
    for i in 0..<WORKER_THREAD_NUM:
      createThread(workerThreads[i], threadWrapper,
                  (worker, ThreadArg(argType: ThreadArgType.WorkerParams, workerParams: (i, tcp_rmem))))

    createThread(dispatcherThread, threadWrapper, (dispatcher, ThreadArg(argType: ThreadArgType.Void)))
    createThread(acceptThread, threadWrapper, (acceptClient, ThreadArg(argType: ThreadArgType.Void)))
    createThread(httpThread, threadWrapper, (http, ThreadArg(argType: ThreadArgType.Void)))
    createThread(monitorThread, threadWrapper, (serverMonitor, ThreadArg(argType: ThreadArgType.Void)))
    when ENABLE_SSL:
      when SSL_AUTO_RELOAD:
        createThread(fileWatcherThread, threadWrapper, (fileWatcher, ThreadArg(argType: ThreadArgType.Void)))
        joinThreads(fileWatcherThread, monitorThread, httpThread, acceptThread, dispatcherThread)
      else:
        joinThreads(monitorThread, httpThread, acceptThread, dispatcherThread)
    else:
      joinThreads(monitorThread, httpThread, acceptThread, dispatcherThread)

    for i in 0..<WORKER_THREAD_NUM:
      workerChannel[].send((0, 0, 0'u32, 0'u64))
    joinThreads(workerThreads)

    workerChannel[].close()
    workerChannel.deallocShared()
    var retEpfdClose = epfd.close()
    if retEpfdClose != 0:
      errorQuit "error: close epfd=", epfd, " ret=", retEpfdClose, " ", getErrnoStr()

    freeClient()

    when declared(freeStream):
      freeStream()

    if restartFlag:
      active = true
    else:
      break

proc start*() = threadWrapper((main, ThreadArg(argType: ThreadArgType.Void)))

proc stop*() {.inline.} =
  if not abortFlag:
    quitServer()


when isMainModule:
  onSignal(SIGINT, SIGTERM):
    debug "bye from signal ", sig
    quitServer()

  signal(SIGPIPE, SIG_IGN)

  setMaxRlimitOpenFiles()
  start()
]#

import caprese
import caprese/server_types

const ENABLE_SSL = defined(ENABLE_SSL)

when (compiles do: include config):
  include config
else:
  include config_default

type
  ClientExt {.clientExt.} = object
    pStream: pointer
    fd: int
    streamId: ClientId

caprese.base:
  type
    ServerNeedRestartError* = object of CatchableError

  include stream

server(ssl = true, ip = "0.0.0.0", port = HTTPS_PORT):
  initWorker()

  routes(host = HTTPS_HOST_NAME):
    public(importPath = "../public")

    stream "/ws":
      onOpen:
        client.streamId = client.markPending()
        discard client.streamConnect()

      var retStream = client.streamMain(opcode, data, size)
      if retStream == SendResult.None:
        client.freeExClient()
      retStream

    get "/ws": "WebSocket Protocol: deoxy-0.1".addHeader().send()

    send("Not Found".addHeader(Status404))

server(ip = "0.0.0.0", port = HTTP_PORT):
  routes(host = HTTP_HOST_NAME):
    send(redirect301("https://" & HTTPS_HOST_NAME & reqUrl))

serverManager()

proc start*() =
  initStream()
  serverStart()
  serverWait()

proc stop*() =
  serverStop()
  freeStream()
