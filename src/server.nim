# Copyright (c) 2021 zenywallet

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
