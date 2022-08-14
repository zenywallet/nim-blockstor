# Copyright (c) 2022 zenywallet

type
  CipherStage {.pure.} = enum
    None
    Negotiate
    Ready

  CipherProcessMode {.pure.} = enum
    Error
    SendPub
    SendReady
    Recv

  CipherError* = object of CatchableError

when defined(js):
  import jsffi
  import jslib

  const RECONNECT_COUNT = 120
  const RECONNECT_WAIT = 15000

  type
    Deoxy* = object
      ws*: JsObject
      stream*: JsObject
      ready*: bool
      reconnectCount: int

  var DeoxyMod = JsObject{}
  var Module: JsObject

  proc init*(module: JsObject) =
    Module = module
    DeoxyMod.cipherCreate = Module.cwrap("cipher_create", NumVar, [].toJs)
    DeoxyMod.cipherFree = Module.cwrap("cipher_free", jsNull, [NumVar])
    DeoxyMod.cipherProcess = Module.cwrap("cipher_process", NumVar, [NumVar, NumVar, NumVar, NumVar, NumVar])
    DeoxyMod.cipherEncrypt = Module.cwrap("cipher_encrypt", NumVar, [NumVar, NumVar, NumVar, NumVar, NumVar])

  proc rawSend*(deoxy: var Deoxy, data: Uint8Array): bool {.discardable.} =
    if not deoxy.ws.isNil and deoxy.ws.readyState == WebSocket.OPEN:
      deoxy.ws.send(data)
      return true
    return false

  proc send*(deoxy: var Deoxy, data: Uint8Array): bool {.discardable.} =
    if not deoxy.ready: return false
    var size = data.length.to(cint)
    var p = Module.malloc(size)
    Module.HEAPU8.set(data, p)
    var pOutBuf = Module.malloc(4)
    var pOutBufLen = Module.malloc(4)
    var retEncrypt = DeoxyMod.cipherEncrypt(deoxy.stream, p, size, pOutBuf, pOutBufLen)
    if retEncrypt.to(bool):
      var outBuf = newUint32Array(Module.HEAPU32.buffer, pOutBuf.to(int), 1)[0]
      var outBufLen = newUint32Array(Module.HEAPU32.buffer, pOutBufLen.to(int), 1)[0]
      var outData = newUint8Array(Module.HEAPU8.buffer, outBuf.to(int), outBufLen.to(int))
      result = deoxy.rawSend(outData)
    else:
      result = false
    Module.free(pOutBufLen)
    Module.free(pOutBuf)
    Module.free(p)

  proc connect*(deoxy: var Deoxy, url, protocols: cstring; onOpen: proc();
                onReady: proc(); onRecv: proc(data: Uint8Array); onClose: proc()) =
    deoxy.ws = newWebSocket(url, protocols)
    deoxy.ws.binaryType = "arraybuffer".cstring
    if deoxy.reconnectCount == 0:
      deoxy.reconnectCount = RECONNECT_COUNT

    template reconnect() {.dirty.} =
      if deoxy.reconnectCount > 0:
        dec(deoxy.reconnectCount)
        let randomWait = Math.round(Math.random() * (RECONNECT_WAIT * 2 / 3).toJs).to(int)
        let ms = Math.round(RECONNECT_WAIT / 3).to(int) + randomWait
        setTimeout(proc() = deoxy.connect(url, protocols, onOpen, onReady, onRecv, onClose), ms)

    deoxy.ws.onerror = proc(evt: JsObject) =
      console.error("websocket error:", evt)

    deoxy.ws.onopen = proc(evt: JsObject) =
      if deoxy.stream.isNil:
        deoxy.reconnectCount = RECONNECT_COUNT
        deoxy.stream = DeoxyMod.cipherCreate()
      onOpen()

    deoxy.ws.onclose = proc(evt: JsObject) =
      console.log("websocket close:", evt.code)
      if not deoxy.stream.isNil:
        DeoxyMod.cipherFree(deoxy.stream)
        deoxy.stream = jsNull
        deoxy.ready = false
      onClose() # In case of an error, a close event may occur without an open event
      reconnect()

    deoxy.ws.onmessage = proc(evt: JsObject) =
      var data = newUint8Array(evt.data)
      var size = data.length.to(cint)
      var p = Module.malloc(size)
      Module.HEAPU8.set(data, p)
      var pOutBuf = Module.malloc(4)
      var pOutBufLen = Module.malloc(4)
      var retProcess = DeoxyMod.cipherProcess(deoxy.stream, p, size, pOutBuf, pOutBufLen).to(int)

      template getOutData() {.dirty.} =
        var outBuf = newUint32Array(Module.HEAPU32.buffer, pOutBuf.to(int), 1)[0]
        var outBufLen = newUint32Array(Module.HEAPU32.buffer, pOutBufLen.to(int), 1)[0]
        var outData = newUint8Array(Module.HEAPU8.buffer, outBuf.to(int), outBufLen.to(int))

      if retProcess == CipherProcessMode.Recv.int:
        getOutData()
        onRecv(outData)
      elif retProcess == CipherProcessMode.SendPub.int or retProcess == CipherProcessMode.SendReady.int:
        getOutData()
        let sendRet = deoxy.rawSend(outData)
        if not sendRet:
          raise newException(CipherError, "rawSend failed")
        if retProcess == CipherProcessMode.SendReady.int:
          deoxy.ready = true
          onReady()

      Module.free(pOutBufLen)
      Module.free(pOutBuf)
      Module.free(p)

  proc close*(deoxy: var Deoxy) =
    if not deoxy.ws.isNil:
      deoxy.reconnectCount = 0
      deoxy.ws.close()
      deoxy.ws = jsNull

  template ready*(deoxy: var Deoxy, body: untyped) =
    block ready:
      proc bodyMain() {.async, discardable.} =
        while not deoxy.ready:
          sleep(100)
        body
      bodyMain()


elif defined(emscripten):
  import ../bytes
  import ../deoxy
  import ../ed25519
  import ../lz4

  const EXPORTED_FUNCTIONS* = ["_cipher_create", "_cipher_free", "_cipher_process", "_cipher_encrypt"]

  const OUT_BUF_SIZE = 1048576

  type
    CipherObj = object
      stage: CipherStage
      ctr: ptr DeoxyEncrypt
      outBuf: ptr UncheckedArray[byte]
      encBuf: ptr UncheckedArray[byte]

    Cipher* = ptr CipherObj


  proc cipherCreate*(): Cipher {.exportc: "cipher_create".} =
    result = cast[Cipher](allocShared0(sizeof(CipherObj)))
    result.ctr = deoxy.create()
    result.outBuf = cast[ptr UncheckedArray[byte]](allocShared0(OUT_BUF_SIZE))
    result.encBuf = cast[ptr UncheckedArray[byte]](allocShared0(OUT_BUF_SIZE))

  proc cipherFree*(cipher: Cipher) {.exportc: "cipher_free".} =
    cipher.encBuf.deallocShared()
    cipher.outBuf.deallocShared()
    deoxy.free(cipher.ctr)
    cipher.deallocShared()

  proc cipherProcess*(cipher: Cipher; indata: ptr UncheckedArray[byte]; insize: cint;
                      outdata: ptr ptr UncheckedArray[byte]; outsize: ptr cint): cint {.exportc: "cipher_process".} =
    if cipher.stage == CipherStage.Ready:
      var decLen = cipher.ctr.dec(indata, insize.uint, cipher.outBuf, OUT_BUF_SIZE.uint)
      outdata[] = cipher.outBuf
      outsize[] = decLen.cint
      return CipherProcessMode.Recv.cint

    elif cipher.stage == CipherStage.None:
      if insize == 64:
        var kpSeed: Ed25519Seed
        if cryptSeed(kpSeed) != 0:
          raise newException(CipherError, "seed failed")

        var pub: Ed25519PublicKey
        var prv: Ed25519PrivateKey
        ed25519.createKeypair(pub, prv, kpSeed)

        var salt: DeoxySalt
        if cryptSeed(salt) != 0:
          raise newException(CipherError, "seed failed")

        var pub_srv: Ed25519PublicKey = cast[ptr Ed25519PublicKey](addr indata[0])[]
        var salt_srv: DeoxySalt = cast[ptr DeoxySalt](addr indata[32])[]

        var shared: Ed25519SharedSecret
        ed25519.keyExchange(shared, pub_srv, prv)
        cipher.ctr.setKey(shared, salt, salt_srv)

        var pubsalt = (pub, salt).toBytes
        if pubsalt.len <= OUT_BUF_SIZE:
          copyMem(cipher.outBuf, addr pubsalt[0], pubsalt.len)
          outdata[] = cipher.outBuf
          outsize[] = pubsalt.len.cint
          cipher.stage = CipherStage.Negotiate
          return CipherProcessMode.SendPub.cint

    elif cipher.stage == CipherStage.Negotiate:
      var decLen = cipher.ctr.dec(indata, insize.uint, cipher.outBuf, OUT_BUF_SIZE.uint)
      var msg = cipher.outBuf.toBytes(decLen)
      decLen = cipher.ctr.enc(cast[ptr UncheckedArray[byte]](addr msg[0]), msg.len.uint, cipher.outBuf, OUT_BUF_SIZE.uint)
      outdata[] = cipher.outBuf
      outsize[] = decLen.cint
      cipher.stage = CipherStage.Ready
      return CipherProcessMode.SendReady.cint

    outdata[] = nil
    outsize[] = 0.cint
    return CipherProcessMode.Error.cint

  proc cipherEncrypt*(cipher: Cipher; indata: ptr UncheckedArray[byte]; insize: cint;
                      outdata: ptr ptr UncheckedArray[byte]; outsize: ptr cint): bool {.discardable, exportc: "cipher_encrypt".} =
    var lz4size = LZ4_COMPRESSBOUND(insize)
    if lz4size.int <= OUT_BUF_SIZE:
      var encLen = cipher.ctr.enc(indata, insize.uint, cipher.encBuf, lz4size.uint)
      if encLen > 0:
        outdata[] = cipher.encBuf
        outsize[] = encLen.cint
        return true

    outdata[] = nil
    outsize[] = 0.cint
    return false
