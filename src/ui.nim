# Copyright (c) 2021 zenywallet

import bytes
import deoxy
import ed25519
import lz4
import os
import system
import strutils
import seed
import bip32c
import base58c
import address_c
import otp_c

const srcPath = currentSourcePath().parentDir()
const imguiPath = srcPath / "../deps/imgui"
const jsonPath = srcPath / "../deps/json"
const preloadPath = srcPath / "../preload_tmp"

{.passC: "-I" & imguiPath & " -I" & imguiPath / "backends" &
  " -I" & jsonPath / "include" & " -DCIMGUI_DEFINE_ENUMS_AND_STRUCTS".}
{.passL: "--preload-file " & preloadPath & "@/ --extern-pre-js " & srcPath / "ui_loader.js".}

{.compile: srcPath / "ui.cpp".}
{.compile: imguiPath / "imgui.cpp".}
{.compile: imguiPath / "imgui_demo.cpp".}
{.compile: imguiPath / "imgui_draw.cpp".}
{.compile: imguiPath / "imgui_tables.cpp".}
{.compile: imguiPath / "imgui_widgets.cpp".}
{.compile: imguiPath / "backends/imgui_impl_sdl.cpp".}
{.compile: imguiPath / "backends/imgui_impl_opengl3.cpp".}

{.emit: """
#include <emscripten.h>
""".}

const DECODE_BUF_SIZE = 1048576

type
  StreamStage {.pure.} = enum
    None
    Negotiate
    Ready

  StreamObj = object
    stage: StreamStage
    ctr: ptr DeoxyEncrypt
    decBuf: array[DECODE_BUF_SIZE, byte]

  Stream* = ptr StreamObj

  StreamError* = object of CatchableError

var streamActive* {.exportc.}: bool = false
var stream* {.exportc.}: Stream

template debug(x: varargs[string, `$`]) {.used.} = echo join(x)
template info(x: varargs[string, `$`]) {.used.} = echo join(x)
template error(x: varargs[string, `$`]) {.used.} = echo join(x)

proc unsecureSend*(stream: Stream, data: ptr UncheckedArray[byte], size: cint): bool {.discardable.} =
  {.emit: """
    return EM_ASM_INT({
      var d = new Uint8Array(Module.HEAPU8.buffer, $1, $2).slice();
      return deoxy.send($0, d);
    }, `stream`, data, size);
  """.}

proc send*(stream: Stream, data: ptr UncheckedArray[byte], size: cint): bool {.discardable.} =
  var outdata = newSeq[byte](LZ4_COMPRESSBOUND(size))
  var outsize: uint = outdata.len.uint
  var encLen = stream.ctr.enc(data, size.uint, cast[ptr UncheckedArray[byte]](addr outdata[0]), outsize)
  if encLen > 0:
    var d = outdata[0..<encLen]
    return stream.unsecureSend(cast[ptr UncheckedArray[byte]](addr d[0]), encLen.cint)
  return false

proc streamSend*(data: ptr UncheckedArray[byte], size: cint): bool {.discardable, exportc.} =
  stream.send(data, size)

proc onOpen*(stream: Stream) {.exportc.} =
  debug "onOpen"
  stream.ctr = deoxy.create()

proc onClose*(stream: Stream) {.exportc.} =
  streamActive = false
  debug "onClose"
  stream.ctr.free()
  deallocShared(stream)

proc streamRecv(data: ptr UncheckedArray[byte], size: cint) {.importc.}

proc onMessage*(stream: Stream, data: ptr UncheckedArray[byte], size: cint) {.exportc.} =
  debug "onMessage stage=", stream.stage, " data=", data.toBytes(size)

  if stream.stage == StreamStage.Ready:
    when declared(streamRecv):
      var indata = data.toBytes(size)
      let inbuf = cast[ptr UncheckedArray[byte]](addr indata[0])
      let outbuf = cast[ptr UncheckedArray[byte]](addr stream.decBuf[0])
      var decLen = stream.ctr.dec(inbuf, indata.len.uint, outbuf, stream.decBuf.len.uint)
      streamRecv(outbuf, decLen.cint)
    else:
      discard

  elif stream.stage == StreamStage.None:
    if size == 64:
      block negotiate:
        var kpSeed: Ed25519Seed
        if cryptSeed(kpSeed) != 0:
          raise newException(StreamError, "seed failed")

        var pub: Ed25519PublicKey
        var prv: Ed25519PrivateKey
        ed25519.createKeypair(pub, prv, kpSeed)

        var salt: DeoxySalt
        if cryptSeed(salt) != 0:
          raise newException(StreamError, "seed failed")

        var pub_srv: Ed25519PublicKey = cast[ptr Ed25519PublicKey](addr data[0])[]
        var salt_srv: DeoxySalt = cast[ptr DeoxySalt](addr data[32])[]

        var shared: Ed25519SharedSecret
        ed25519.keyExchange(shared, pub_srv, prv)
        stream.ctr.setKey(shared, salt, salt_srv)

        var pubsalt = (pub, salt).toBytes
        let retSend = stream.unsecureSend(cast[ptr UncheckedArray[byte]](addr pubsalt[0]), pubsalt.len.cint)
        debug "retSend=", retSend

      stream.stage = StreamStage.Negotiate

  elif stream.stage == StreamStage.Negotiate:
    var indata = data.toBytes(size)
    let inbuf = cast[ptr UncheckedArray[byte]](addr indata[0])
    let outbuf = cast[ptr UncheckedArray[byte]](addr stream.decBuf[0])
    var decLen = stream.ctr.dec(inbuf, indata.len.uint, outbuf, stream.decBuf.len.uint)
    var r = outbuf.toString(decLen)
    debug "decLen=", decLen, " data=", r
    let retsend = stream.send(cast[ptr UncheckedArray[byte]](addr r[0]), r.len.cint)
    debug "retSend=", retSend
    stream.stage = StreamStage.Ready
    streamActive = true

proc streamConnect*(url, protocol: string): Stream {.discardable.} =
  var stream = cast[Stream](allocShared0(sizeof(StreamObj)))
  stream.stage = StreamStage.None

  let url = url.cstring
  let protocol = protocol.cstring

  {.emit: """
    EM_ASM({
      deoxy.connect($0, UTF8ToString($1), UTF8ToString($2));
    }, `stream`, `url`, `protocol`);
  """.}

  result = stream

proc close*(stream: Stream) =
  {.emit: """
    EM_ASM({
      deoxy.close($0);
    }, `stream`);
  """.}

proc uiError*(msg: cstring) {.exportc.} =
  {.emit: """
    EM_ASM({
      deoxy.error(UTF8ToString($0));
    }, `msg`);
  """.}

proc uiError*(msg: string) {.inline.} = uiError(msg.cstring)

when not compileOption("gc", "arc") and not compileOption("gc", "orc") :
  {.warning: "requires --gc:arc or --gc:orc option. Use NimMain is only for debugging.".}
  proc NimMain() {.importc.}

proc guimain(): int {.importc, discardable, used.}

proc uiMain() {.exportc.} =
  when not compileOption("gc", "arc") and not compileOption("gc", "orc"):
    NimMain()

  {.emit: """
    EM_ASM({
      try {
        var ret = Module.ccall('guimain', 'number', []);
        console.log('guimain ret=', ret);
      } catch(e) {
        if(e == 'unwind') {
          console.log('unwind simulate_infinite_loop is true')
        } else {
          console.error('except:', e);
        }
      }
    });
  """.}

  stream = streamConnect("ws://localhost:8000/ws", "deoxy-0.1")
