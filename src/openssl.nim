# Copyright (c) 2021 zenywallet

import os

const USE_LIBRESSL = false

when USE_LIBRESSL:
  const libresslPath = currentSourcePath.parentDir() / "../deps/libressl"
  {.passL: libresslPath / "ssl/.libs/libssl.a".}
  {.passL: libresslPath / "crypto/.libs/libcrypto.a".}
else:
  const opensslPath = currentSourcePath.parentDir() / "../deps/openssl"
  {.passL: opensslPath / "libssl.a".}
  {.passL: opensslPath / "libcrypto.a".}

type
  # include/internal/conf.h
  ossl_init_settings_st = ptr object

  # ssl/ssl_local.h
  ssl_st = ptr object
  ssl_ctx_st = ptr object
  ssl_method_st = ptr object

  # include/openssl/types.h
  OPENSSL_INIT_SETTINGS* = ossl_init_settings_st
  SSL* = ssl_st
  SSL_CTX* = ssl_ctx_st
  SSL_METHOD* = ssl_method_st

# include/openssl/x509.h
const X509_FILETYPE_PEM* = 1

# include/openssl/ssl.h
const OPENSSL_INIT_NO_LOAD_SSL_STRINGS* = 0x00100000'u64
const OPENSSL_INIT_LOAD_SSL_STRINGS* = 0x00200000'u64

const SSL_FILETYPE_PEM* = X509_FILETYPE_PEM

const SSL_OP_NO_SSLv3* = 0x02000000'u32
const SSL_OP_NO_TLSv1* = 0x04000000'u32
const SSL_OP_NO_TLSv1_2* = 0x08000000'u32
const SSL_OP_NO_TLSv1_1* = 0x10000000'u32
const SSL_OP_NO_TLSv1_3* = 0x20000000'u32

# Removed from OpenSSL 1.1.0. Was 0x01000000L
const SSL_OP_NO_SSLv2* = 0x0'u32

const SSL_MODE_ENABLE_PARTIAL_WRITE* = 0x00000001'u64
const SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER* = 0x00000002'u64
const SSL_MODE_AUTO_RETRY* = 0x00000004'u64
const SSL_MODE_RELEASE_BUFFERS* = 0x00000010'u64
const SSL_MODE_SEND_CLIENTHELLO_TIME* = 0x00000020'u64
const SSL_MODE_SEND_SERVERHELLO_TIME* = 0x00000040'u64
const SSL_MODE_SEND_FALLBACK_SCSV* = 0x00000080'u64
const SSL_CTRL_MODE* = 33

# include/openssl/crypto.h
const OPENSSL_VERSION_0* = 0
const OPENSSL_CFLAGS* = 1
const OPENSSL_BUILT_ON* = 2
const OPENSSL_PLATFORM* = 3
const OPENSSL_DIR* = 4
const OPENSSL_ENGINES_DIR* = 5
const OPENSSL_VERSION_STRING* = 6
const OPENSSL_FULL_VERSION_STRING* = 7
const OPENSSL_MODULES_DIR* = 8
const OPENSSL_CPU_INFO* = 9

const OPENSSL_INIT_NO_LOAD_CRYPTO_STRINGS* = 0x00000001'u64
const OPENSSL_INIT_LOAD_CRYPTO_STRINGS* = 0x00000002'u64
const OPENSSL_INIT_ADD_ALL_CIPHERS* = 0x00000004'u64
const OPENSSL_INIT_ADD_ALL_DIGESTS* = 0x00000008'u64

# include/openssl/ssl.h
proc TLS_server_method*(): SSL_METHOD {.importc.}
proc SSLv23_server_method*(): SSL_METHOD {.inline.} = TLS_server_method()
proc SSL_CTX_new*(meth: SSL_METHOD): SSL_CTX {.importc.}
proc SSL_CTX_free*(ctx: SSL_CTX) {.importc.}
proc SSL_new*(ctx: SSL_CTX): SSL {.importc.}

proc OPENSSL_init_ssl*(opts: uint64, settings: OPENSSL_INIT_SETTINGS): cint {.importc.}
proc SSL_library_init*(): cint {.inline, discardable.} = OPENSSL_init_ssl(0'u64, nil)
proc SSL_load_error_strings*(): cint {.inline, discardable.} =
  OPENSSL_init_ssl(OPENSSL_INIT_LOAD_SSL_STRINGS or OPENSSL_INIT_LOAD_CRYPTO_STRINGS, nil)

proc SSL_CTX_use_PrivateKey_file*(ctx: SSL_CTX, file: cstring, fileType: cint): cint {.importc.}
proc SSL_CTX_use_certificate_file*(ctx: SSL_CTX, file: cstring, fileType: cint): cint {.importc.}
proc SSL_CTX_use_certificate_chain_file*(ctx: SSL_CTX, file: cstring): cint {.importc.}

proc SSL_set_fd*(s: SSL, fd: cint): cint {.importc.}
proc SSL_free*(ssl: SSL) {.importc.}
proc SSL_accept*(ssl: SSL): cint {.importc.}
proc SSL_stateless*(s: SSL): cint {.importc.}
proc SSL_connect*(ssl: SSL): cint {.importc.}
proc SSL_read*(ssl: SSL, buf: pointer, num: cint): cint {.importc.}
proc SSL_read_ex*(ssl: SSL, buf: pointer, num: csize_t, readbytes: csize_t): cint {.importc.}

proc SSL_write*(ssl: SSL, buf: pointer, num: cint): cint {.importc.}
proc SSL_write*(ssl: SSL, buf: cstring, num: int): cint {.importc.}
proc SSL_write_ex*(s: SSL, buf: pointer, num: csize_t, written: csize_t): cint {.importc.}
proc SSL_write_early_data*(s: SSL, buf: pointer, num: csize_t, written: csize_t): cint {.importc.}

proc SSL_ctrl*(ssl: SSL, cmd: cint, larg: clong, parg: pointer): clong {.importc, discardable.}
proc SSL_CTX_ctrl*(ctx: SSL_CTX, cmd: cint, larg: clong, parg: pointer): clong {.importc, discardable.}

when USE_LIBRESSL:
  const SSL_CTRL_OPTIONS* = 32
  template SSL_CTX_set_options*(ctx, op: untyped): untyped =
    SSL_CTX_ctrl((ctx), SSL_CTRL_OPTIONS, (op), nil)
else:
  proc SSL_CTX_set_options*(ctx: SSL_CTX, op: clong): clong {.importc, discardable.}

proc SSL_CTX_set_mode*(ctx: SSL_CTX, mode: clong): clong {.inline, discardable.} =
  SSL_CTX_ctrl(ctx, SSL_CTRL_MODE, mode, nil)

proc SSL_set_mode*(ssl: SSL, mode: clong): clong {.inline, discardable.} =
  SSL_ctrl(ssl, SSL_CTRL_MODE, mode, nil)

proc SSL_get_error*(s: SSL, ret_code: cint): cint {.importc.}
proc SSL_get_version*(s: SSL): cstring {.importc.}

# include/openssl/crypto.h
proc OpenSSL_version*(t: int): cstring {.importc.}
proc OPENSSL_init_crypto*(opts: uint64, settings: OPENSSL_INIT_SETTINGS): cint {.importc.}

# include/openssl/evp.h
proc OPENSSL_add_all_algorithms_noconf*(): cint {.inline.} =
  OPENSSL_init_crypto(OPENSSL_INIT_ADD_ALL_CIPHERS or OPENSSL_INIT_ADD_ALL_DIGESTS, nil)
proc OpenSSL_add_all_algorithms*(): cint {.inline, discardable.} = OPENSSL_add_all_algorithms_noconf()

# include/openssl/err.h
proc ERR_get_error*(): culong {.importc.}


when isMainModule:
  echo SSL_load_error_strings()
  echo SSL_library_init()
  echo OpenSSL_add_all_algorithms()

  var ctx = SSL_CTX_new(TLS_server_method())
  echo repr ctx
  var ssl = SSL_new(ctx)
  echo repr ssl
  echo SSL_CTX_set_options(ctx, (SSL_OP_NO_SSLv2 or SSL_OP_NO_SSLv3 or
                      SSL_OP_NO_TLSv1 or SSL_OP_NO_TLSv1_1 or SSL_OP_NO_TLSv1_2).clong)
  echo SSL_get_version(ssl)
  for i in 0..9:
    echo OpenSSL_version(i)
