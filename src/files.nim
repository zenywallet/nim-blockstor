# Copyright (c) 2021 zenywallet
# nim c -r --forceBuild src/files.nim

import os, macros, strutils, tables, mimetypes
import nimcrypto, md5, base64
import zip/zlib
import bytes

const srcDir = currentSourcePath().parentDir()
const publicDir = srcDir / "../public"

macro constFilesTable: untyped =
  var filesTable: seq[tuple[key: string, val: tuple[content: string, deflate: string,
                                                    mime: string,
                                                    sha256: string, md5: string]]]
  let plen = publicDir.len
  let mimes = newMimetypes()
  echo staticExec("nim c -d:release " & (srcDir / "deflate.nim"))
  for f in walkDirRec(publicDir):
    echo "const file: ", f
    let filename = f[plen..^1]
    let fileSplit = splitFile(filename)
    let data = readFile(f)
    var ext = ""
    if fileSplit.ext.len > 1:
      ext = fileSplit.ext[1..^1]
    let mime = mimes.getMimeType(ext)
    let hash = base64.encode(sha256.digest(data).data)
    let md5 = base64.encode(data.getMD5().toBytesFromHex)
    discard staticExec((srcDir / "deflate") & " " & f & " " & (srcDir / "deflate_tmp"))
    let deflate = readFile(srcDir / "deflate_tmp")
    discard staticExec("rm " & (srcDir / "deflate_tmp"))
    filesTable.add((filename, (data, deflate, mime, hash, md5)))

  newConstStmt(
    newIdentNode("filesTable"),
    newCall("toTable",
      newLit(filesTable)
    )
  )

constFilesTable()

proc getConstFile*(file: string): tuple[content: string, deflate: string,
                                        mime: string,
                                        sha256: string, md5: string] =
  try:
    if file.endsWith("/"):
      result = filesTable[file & "index.html"]
    else:
      result = filesTable[file]
  except KeyError:
    discard

var currentPublicDir {.threadvar.}: string
var mimes {.threadvar.}: MimeDB

proc initDynamicFile*() =
  currentPublicDir = getCurrentDir() / "public"
  mimes = newMimetypes()

proc getDynamicFile*(file: string): tuple[content: string, deflate: string,
                                          mime: string,
                                          sha256: string, md5: string] =
  var requestDir = currentPublicDir / file
  if requestDir.startsWith(currentPublicDir):
    var ext = ""
    if file.endsWith("/"):
      requestDir = requestDir & "index.html"
      ext = "html"
    else:
      let fileSplit = splitFile(file)
      if fileSplit.ext.len > 1:
        ext = fileSplit.ext[1..^1]
    try:
      let data = readFile(requestDir)
      let mime = mimes.getMimeType(ext)
      let hash = base64.encode(sha256.digest(data).data)
      let md5 = base64.encode(data.toMD5())
      let deflate = compress(data, stream = RAW_DEFLATE)
      result = (data, deflate, mime, hash, md5)
    except:
      discard


when isMainModule:
  echo getConstFile("/")
  echo getConstFile("/index.html")
  echo getConstFile("/index")

  initDynamicFile()
  echo getDynamicFile("/")
  echo getDynamicFile("/index.html")
  echo getDynamicFile("/index")
