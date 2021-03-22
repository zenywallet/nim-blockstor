# Copyright (c) 2021 zenywallet

import nativesockets, posix, epoll
import strutils, sequtils, tables
from cgi import decodeUrl
import os
import bytes, files

const CLIENT_MAX = 32000
const CLIENT_SEARCH_LIMIT = 30000
const WORKER_THREAD_NUM = 16
const EPOLL_EVENTS_SIZE = 10
const HTTP_VERSION = 1.1
const HTTP_PORT = 8000
const SERVER_HOST_NAME = "localhost:8000"
const RELEASE_MODE = defined(release)
const CLCL = 168626701'u32 # "\c\L\c\L"
const RECVBUF_EXPAND_BREAK_SIZE = 131072 * 5

type
  Client* = object
    fd: int
    recvBuf: ptr UncheckedArray[byte]
    recvBufSize: int
    recvCurSize: int
    sendBuf: ptr UncheckedArray[byte]
    sendBufSize: int
    keepAlive: bool

  ClientArray = array[CLIENT_MAX, Client]

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
    case type*: ThreadArgType
    of ThreadArgType.Void:
      discard
    of ThreadArgType.WorkerParams:
      workerParams*: tuple[threadId: int, bufLen: int]

  SendResult {.pure.} = enum
    Error = -1
    None = 0
    Success = 1
    Pending = 2
    Invalid = 3

  Headers = Table[string, string]

  ServerError* = object of CatchableError

var active = true
var abortFlag = false
var serverSock: SocketHandle = osInvalidSocket
var clients: ptr ClientArray = nil
var clIdx = 0
var events: array[EPOLL_EVENTS_SIZE, EpollEvent]
var epfd: cint = -1

var workerChannel: Channel[tuple[appId: int, idx: int, events: uint32, evData: uint64]]
var workerThreads: array[WORKER_THREAD_NUM, Thread[ThreadArg]]

var dispatcherThread: Thread[ThreadArg]
var acceptThread: Thread[ThreadArg]
var mainThread: Thread[ThreadArg]

template debug(x: varargs[string, `$`]) =
  when RELEASE_MODE:
    discard
  else:
    echo join(x)

template error(x: varargs[string, `$`]) = echo join(x)

proc initClient() =
  var tmp = cast[ptr ClientArray](allocShared0(sizeof(ClientArray)))
  for i in 0..<CLIENT_MAX:
    tmp[i].fd = osInvalidSocket.int
    tmp[i].recvBuf = nil
    tmp[i].recvBufSize = 0
    tmp[i].recvCurSize = 0
    tmp[i].sendBuf = nil
    tmp[i].sendBufSize = 0
    tmp[i].keepAlive = true
  clients = tmp

proc freeClient() =
  var tmp = clients
  clients = nil
  for i in 0..<CLIENT_MAX:
    var client = tmp[i]
    if client.fd != osInvalidSocket.int:
      client.fd.SocketHandle.close()
    if not client.recvBuf.isNil:
      deallocShared(cast[pointer](client.recvBuf))
    if not client.sendBuf.isNil:
      deallocShared(cast[pointer](client.sendBuf))
  deallocShared(tmp)

proc getErrnoStr(): string =
  case errno
  of EADDRINUSE: "errno=EADDRINUSE(" & $errno & ")"
  else: "errno=" & $errno

proc quitServer() =
  debug "quit"
  active = false
  if serverSock != osInvalidSocket:
    if epfd >= 0:
      var ev: EpollEvent
      ev.events = EPOLLRDHUP
      var retCtl = epoll_ctl(epfd, EPOLL_CTL_ADD, serverSock, addr ev)
      if retCtl != 0:
        error "error: quit epoll_ctl ret=", retCtl, " ", getErrnoStr()
        quit(QuitFailure)
    var retShutdown = serverSock.shutdown(SHUT_RD)
    if retShutdown != 0:
      error "error: quit shutdown ret=", retShutdown, " ", getErrnoStr()
      quit(QuitFailure)
    serverSock.close()

proc abort() =
  debug "abort"
  abortFlag = true
  quitServer()

proc reallocClientBuf(buf: ptr UncheckedArray[byte], size: int): ptr UncheckedArray[byte] =
  result = cast[ptr UncheckedArray[byte]](reallocShared(buf, size))

proc setClient(fd: int): int =
  var usedCount = 0
  for i in clIdx..<CLIENT_MAX:
    if clients[i].fd < 0:
      clients[i].fd = fd
      inc(clIdx)
      if clIdx >= CLIENT_MAX:
        clIdx = 0
      return i
    else:
      inc(usedCount)
      if usedCount > CLIENT_SEARCH_LIMIT:
        return -1
  for i in 0..<clIdx:
    if clients[i].fd < 0:
      clients[i].fd = fd
      inc(clIdx)
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

const BusyBody = "<!DOCTYPE html><meta charset=\"utf-8\"><i>Sorry, It is a break time.</i>"
const BadRequest = "<!DOCTYPE html><meta charset=\"utf-8\"><i>Oops, something's wrong?</i>"
const NotFound = "<!DOCTYPE html><meta charset=\"utf-8\"><i>You just found emptiness.</i>"
const InternalError = "<!DOCTYPE html><meta charset=\"utf-8\">the fire is dead.<br>the room is freezing."
const Empty = ""

proc sendInstant*(s: SocketHandle, data: string) =
  var sendRet: int
  while true:
    sendRet = s.send(data.cstring, data.len.cint, 0'i32)
    if sendRet < 0 and errno == EINTR:
      continue
    break

proc sendInstant*(client: ptr Client, data: string) {.inline.} =
  sendInstant(client.fd.SocketHandle, data)

proc addSendBuf(client: ptr Client, data: string) =
  var nextSize = client.sendBufSize + data.len
  client.sendBuf = reallocClientBuf(client.sendBuf, nextSize)
  copyMem(addr client.sendBuf[client.sendBufSize], unsafeAddr data[0], data.len)
  client.sendBufSize = nextSize

proc send*(client: ptr Client, data: string): SendResult =
  if not client.sendBuf.isNil:
    client.addSendBuf(data)
    return SendResult.Pending

  while true:
    var sendRet = client.fd.SocketHandle.send(data.cstring, data.len.cint, 0'i32)
    if sendRet > 0:
      return SendResult.Success
    elif sendRet < 0:
      if errno == EAGAIN or errno == EWOULDBLOCK:
        client.addSendBuf(data)
        return SendResult.Pending
      if errno == EINTR:
        continue
      return SendResult.Error
    else:
      return SendResult.None

proc sendFlush(client: ptr Client): SendResult =
  if client.sendBuf.isNil:
    return SendResult.None

  while true:
    var sendRet = client.fd.SocketHandle.send(cast[cstring](client.sendBuf), client.sendBufSize.cint, 0'i32)
    if sendRet > 0:
      debug "flush sendRet=", sendRet
      client.sendBufSize = 0
      deallocShared(cast[pointer](client.sendBuf))
      client.sendBuf = nil
      return SendResult.Success
    elif sendRet < 0:
      if errno == EAGAIN or errno == EWOULDBLOCK:
        return SendResult.Pending
      if errno == EINTR:
        continue
      return SendResult.Error
    else:
      return SendResult.None

proc waitEventAgain(evData: uint64, fd: int | SocketHandle, exEvents: uint32 = 0) =
  var ev: EpollEvent
  ev.events = EPOLLIN or EPOLLRDHUP or exEvents
  ev.data.u64 = evData
  var ret = epoll_ctl(epfd, EPOLL_CTL_ADD, fd.cint, addr ev)
  if ret < 0:
    error "error: epoll_ctl ret=", ret, " errno=", errno
    abort()

proc close(client: ptr Client) =
  debug "close ", client.fd
  client.fd.SocketHandle.close()
  client.recvCurSize = 0
  client.recvBufSize = 0
  if not client.recvBuf.isNil:
    deallocShared(cast[pointer](client.recvBuf))
    client.recvBuf = nil
  if not client.sendBuf.isNil:
    deallocShared(cast[pointer](client.sendBuf))
    client.sendBuf = nil
  client.keepAlive = true
  client.fd = osInvalidSocket.int

var webMain* = proc(client: ptr Client, url: string, headers: Headers): SendResult =
  debug "web url=", url, " headers=", headers
  var file = getConstFile(url)
  if file.content.len > 0:
    if headers.hasKey("If-None-Match") and headers["If-None-Match"] == file.md5:
      result = client.send(Empty.addHeader(Status304))
    else:
      if headers.hasKey("Accept-Encoding"):
        var acceptEnc = headers["Accept-Encoding"].split(",")
        acceptEnc.apply(proc(x: string): string = x.strip)
        if acceptEnc.contains("deflate"):
          return client.send(file.deflate.addHeaderDeflate(file.md5, Status200, file.mime))
      return client.send(file.content.addHeader(file.md5, Status200, file.mime))
  else:
    return client.send(NotFound.addHeader(Status404))

proc workerMain(client: ptr Client, buf: ptr UncheckedArray[byte], size: int): SendResult =
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
            error "invalid request cmd=", cmd
            return SendResult.Invalid
          var urlpath = cgi.decodeUrl(cmdparams[1])
          if urlpath.split("/").contains(".."):
            error "invalid request path: ", urlpath
            return SendResult.Invalid
          url = normalizedPath(urlpath)
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
          if headers["Host"] != SERVER_HOST_NAME:
            error "invalid request host headers=", headers
            return SendResult.Invalid
        else:
          error "invalid request no host headers=", headers
          return SendResult.Invalid

        retMain = client.webMain(url, headers)
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
  var recvBuf = newSeq[byte](arg.workerParams.bufLen)

  proc reserveRecvBuf(client: ptr Client, size: int) =
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

  proc addRecvBuf(client: ptr Client, data: ptr UncheckedArray[byte], size: int) =
    client.reserveRecvBuf(size)
    copyMem(addr client.recvBuf[client.recvCurSize], addr data[0], size)
    client.recvCurSize = client.recvCurSize + size

  while true:
    block channelBlock:
      var channelData = workerChannel.recv()
      if not active:
        return
      var appId = channelData.appId
      var idx = channelData.idx
      var events = channelData.events
      var evData = channelData.evData
      debug "appId=", appId, " idx=", idx, " ev=", events, " tid=", arg.workerParams.threadId

      var client = addr clients[idx]
      var clientFd = client.fd
      var clientSock = clientFd.SocketHandle

      try:
        if client.sendBuf != nil:
          if (events and EPOLLOUT) > 0:
            var retFlush = client.sendFlush()
            if retFlush == SendResult.Pending:
              waitEventAgain(evData, clientFd, EPOLLOUT)
              break channelBlock
            if retFlush != SendResult.Success or not client.keepAlive:
              client.close()
              break channelBlock
          if (events and (EPOLLIN or EPOLLRDHUP)) == 0:
            waitEventAgain(evData, clientFd)
            break channelBlock

        template retWorkerHandler(retWorker: SendResult) {.dirty.} =
          case retWorker
          of SendResult.Success:
            if not client.keepAlive:
              client.close()
              break channelBlock
          of SendResult.Pending:
            waitEventAgain(evData, clientFd, EPOLLOUT)
            break channelBlock
          of SendResult.Invalid:
            var retSend = client.send(BadRequest.addHeader(Status400))
            client.close()
            break channelBlock
          of SendResult.None, SendResult.Error:
            client.close()
            break channelBlock

        if client.recvBufSize == 0:
          while true:
            var recvlen = clientSock.recv(addr recvBuf[0], recvBuf.len.cint, 0.cint)
            if recvlen > 0:
              if recvlen >= 4 and recvBuf[recvlen - 4].toUint32 == CLCL:
                var retWorker = workerMain(client, cast[ptr UncheckedArray[byte]](addr recvBuf[0]), recvlen)
                retWorkerHandler(retWorker)
              else:
                client.addRecvBuf(cast[ptr UncheckedArray[byte]](addr recvBuf[0]), recvlen)
                if recvlen == recvBuf.len:
                  break
              waitEventAgain(evData, clientFd)
              break channelBlock
            elif recvlen == 0:
              client.close()
              break channelBlock
            else:
              if errno == EAGAIN or errno == EWOULDBLOCK:
                waitEventAgain(evData, clientFd)
                break channelBlock
              if errno == EINTR:
                continue
              client.close()
              break channelBlock

        while true:
          client.reserveRecvBuf(arg.workerParams.bufLen)
          var recvlen = clientSock.recv(addr client.recvBuf[client.recvCurSize], arg.workerParams.bufLen.cint, 0.cint)
          if recvlen > 0:
            client.recvCurSize = client.recvCurSize + recvlen
            if client.recvCurSize >= 4 and client.recvBuf[client.recvCurSize - 4].toUint32 == CLCL:
              var retWorker = workerMain(client, cast[ptr UncheckedArray[byte]](client.recvBuf), client.recvCurSize)
              client.recvCurSize = 0
              client.recvBufSize = 0
              deallocShared(cast[pointer](client.recvBuf))
              client.recvBuf = nil
              retWorkerHandler(retWorker)
            elif recvlen == arg.workerParams.bufLen:
              continue
            waitEventAgain(evData, clientFd)
            break channelBlock
          elif recvlen == 0:
            client.close()
            break channelBlock
          else:
            if errno == EAGAIN or errno == EWOULDBLOCK:
              waitEventAgain(evData, clientFd)
              break channelBlock
            if errno == EINTR:
              continue
            client.close()
            break channelBlock

      except:
        client.close()
        let e = getCurrentException()
        error e.name, ": ", e.msg

proc dispatcher(arg: ThreadArg) {.thread.} =
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
        workerChannel.send((appId, idx, events[i].events, evData))
    elif nfd < 0:
        if errno == EINTR:
          continue
        error "error: epoll_wait ret=", nfd, " errno=", errno
        abort()

proc acceptClient(arg: ThreadArg) {.thread.} =
  while active:
    var sockAddress: Sockaddr_in
    var addrLen = sizeof(sockAddress).SockLen
    var clientSock = accept(serverSock, cast[ptr SockAddr](addr sockAddress), addr addrLen)
    var clientFd = clientSock.int
    var address = $inet_ntoa(sockAddress.sin_addr)

    if clientFd < 0:
      if errno == EINTR:
        continue
      elif errno == EINVAL:
        if not active:
          break
      error "error: accept errno=", errno
      abort()

    debug "client ip=", address, " fd=", clientFd

    var idx = setClient(clientFd)
    if idx < 0:
      error "error: server full"
      clientSock.sendInstant(BusyBody.addHeader(Status503))
      clientSock.close()
      continue

    clientSock.setBlocking(false)

    var ev: EpollEvent
    ev.events = EPOLLIN or EPOLLRDHUP
    ev.data.u64 = idx.uint
    var ret = epoll_ctl(epfd, EPOLL_CTL_ADD, clientFd.cint, addr ev)
    if ret < 0:
      error "error: epoll_ctl ret=", ret, " errno=", errno
      abort()

proc main(arg: ThreadArg) {.thread.} =
  serverSock = createNativeSocket()
  var aiList = getAddrInfo("0.0.0.0", Port(HTTP_PORT), Domain.AF_INET)
  serverSock.setSockOptInt(SOL_SOCKET, SO_REUSEADDR, 1)
  var retBind = serverSock.bindAddr(aiList.ai_addr, aiList.ai_addrlen.SockLen)
  if retBind < 0:
    error "error: bind ret=", retBind, " ", getErrnoStr()
    quit(QuitFailure)
  freeaddrinfo(aiList)

  var retListen = serverSock.listen()
  if retListen < 0:
    error "error: listen ret=", retListen, " ", getErrnoStr()
    quit(QuitFailure)

  var tcp_rmem = serverSock.getSockOptInt(SOL_SOCKET, SO_RCVBUF)
  debug "RECVBUF=", tcp_rmem

  epfd = epoll_create1(O_CLOEXEC)
  if epfd < 0:
    error "error: epfd=", epfd, " errno=", errno
    quit(QuitFailure)

  initClient()

  workerChannel.open()
  for i in 0..<WORKER_THREAD_NUM:
    createThread(workerThreads[i], worker, ThreadArg(type: ThreadArgType.WorkerParams,
                                                    workerParams: (i, tcp_rmem)))

  createThread(dispatcherThread, dispatcher, ThreadArg(type: ThreadArgType.Void))
  createThread(acceptThread, acceptClient, ThreadArg(type: ThreadArgType.Void))

  var waitThreads: seq[Thread[ThreadArg]]
  waitThreads.add(dispatcherThread)
  waitThreads.add(acceptThread)
  joinThreads(waitThreads)

  for i in 0..<WORKER_THREAD_NUM:
    workerChannel.send((0, 0, 0'u32, 0'u64))
  joinThreads(workerThreads)

  workerChannel.close()
  var retEpfdClose = epfd.close()
  if retEpfdClose != 0:
    error "error: close epfd=", epfd, " ret=", retEpfdClose, " ", getErrnoStr()
    quit(QuitFailure)

  freeClient()

  if abortFlag:
    quit(QuitFailure)

proc start*(): seq[Thread[ThreadArg]] =
  createThread(mainThread, main, ThreadArg(type: ThreadArgType.Void))
  result.add(mainThread)

proc stop*() {.inline.} = quitServer()

onSignal(SIGINT, SIGTERM):
  debug "bye from signal ", sig
  quitServer()


when isMainModule:
  var threads: seq[Thread[ThreadArg]]
  threads = threads.concat(start())
  joinThreads(threads)
