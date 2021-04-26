# Copyright (c) 2020 zenywallet

import os
import seed as seedNative
export cryptSeed

const ed25519Path = currentSourcePath().parentDir()  / "../deps/ed25519"

{.passC: "-I\"" / ed25519Path / "src\"" & " -DED25519_NO_SEED".}

{.compile: ed25519Path / "src/add_scalar.c".}
{.compile: ed25519Path / "src/fe.c".}
{.compile: ed25519Path / "src/ge.c".}
{.compile: ed25519Path / "src/key_exchange.c".}
{.compile: ed25519Path / "src/keypair.c".}
{.compile: ed25519Path / "src/sc.c".}
#{.compile: ed25519Path / "src/seed.c".}
{.compile: ed25519Path / "src/sha512.c".}
{.compile: ed25519Path / "src/sign.c".}
{.compile: ed25519Path / "src/verify.c".}

{.emit: """
#include "ge.h"

void ed25519_get_publickey(unsigned char *private_key, unsigned char *public_key) {
    ge_p3 A;

    private_key[0] &= 248;
    private_key[31] &= 63;
    private_key[31] |= 64;

    ge_scalarmult_base(&A, private_key);
    ge_p3_tobytes(public_key, &A);
}
""".}

type
  Ed25519Seed* = array[32, byte]
  Ed25519PublicKey* = array[32, byte]
  Ed25519PrivateKey* = array[64, byte]
  Ed25519Signature* = array[64, byte]
  Ed25519Scalar* = array[32, byte]
  Ed25519SharedSecret* = array[32, byte]


proc createKeypair*(publicKey: var Ed25519PublicKey; privateKey: var Ed25519PrivateKey;
                            seed: Ed25519Seed) {.importc: "ed25519_create_keypair".}
proc sign*(signature: var Ed25519Signature; message: cstring; messageLen: uint;
                  publicKey: Ed25519PublicKey; privateKey: Ed25519PrivateKey) {.importc: "ed25519_sign".}
proc verify*(signature: Ed25519Signature; message: cstring; messageLen: uint;
                    publicKey: Ed25519PublicKey): int {.importc: "ed25519_verify".}
proc addScalar*(publicKey: Ed25519PublicKey; privateKey: Ed25519PrivateKey;
                        scalar: var Ed25519Scalar) {.importc: "ed25519_add_scalar".}
proc keyExchange*(sharedSecret: var Ed25519SharedSecret; publicKey: Ed25519PublicKey;
                          privateKey: Ed25519PrivateKey) {.importc: "ed25519_key_exchange".}

proc getPublickey*(privateKey: Ed25519PrivateKey; publicKey: var Ed25519PublicKey) {.importc: "ed25519_get_publickey".}


when(isMainModule):
  type
    Ed25519SeedError* = object of CatchableError

  var seed: Ed25519Seed
  if cryptSeed(seed) != 0:
    raise newException(Ed25519SeedError, "seed failed")

  var pub: Ed25519PublicKey
  var priv: Ed25519PrivateKey
  createKeypair(pub, priv, seed)
  echo pub
  echo priv
