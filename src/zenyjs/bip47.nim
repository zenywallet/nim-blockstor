# Copyright (c) 2021 zenywallet

import bip32, bytes, base58
import ../secp256k1
import ../secp256k1_ecdh
import sequtils
import eckey
import arraylib

proc paymentCode*(node: HDNode): string =
  var d = (0x47'u8, 0x01'u8, 0x00'u8, node.publicKey, node.chainCode, Pad(13)).toBytes.addCheck
  base58.enc(d)

var ecdhFunc: secp256k1_ecdh_hash_function = proc (output: ptr uint8;
                                                  x32: ptr uint8; y32: ptr uint8;
                                                  data: pointer): cint {.cdecl.} =
  copyMem(output, x32, 32)
  result = 1.cint

proc ecdh*(prv: PrivateKey, pub: PublicKeyObj): Array[byte] =
  if prv.len != 32 or pub.len != 64:
    raise newException(EcError, "ecdh parameters")
  var output = newArray[byte](32)
  let prvSeq = prv.toBytes
  let pubSeq = pub.toBytes
  if secp256k1_ecdh(ctx(), cast[ptr uint8](addr output[0]),
                    cast[ptr secp256k1_pubkey](unsafeAddr pubSeq[0]),
                    cast[ptr uint8](unsafeAddr prvSeq[0]), ecdhFunc, nil) == 0:
    raise newException(EcError, "secp256k1_ecdh")
  result = output


when isMainModule:
  import utils
  import address
  import script
  import nimcrypto
  import tx
  import ../opcodes
  import custom

  echo "###Alice's wallet:"
  var seed_alice = "64dca76abc9c6f0cf3d212d248c380c4622c8f93b2c425ec6a5567fd5db57e10d3e6f94a2f6af4ac2edb8998072aad92098db73558c323777abf5bd1082d970a".Hex.toBytes
  var m_alice = bip32.master(seed_alice)

  echo "Payment code: (M/47'/0'/0')"
  var m_alice_47h_0h_0h = m_alice.hardened(47).hardened(0).hardened(0)
  var paymentCodeAlice = paymentCode(m_alice_47h_0h_0h)
  echo paymentCodeAlice

  echo "ECDH parameters: (M/47'/0'/0'/0)"
  var m_alice_47h_0h_0h_0 = m_alice_47h_0h_0h.derive(0)
  echo "a0: ", m_alice_47h_0h_0h_0.privateKey
  echo "A0: ", m_alice_47h_0h_0h_0.publicKey

  echo "###Bob's wallet:"
  var seed_bob = "87eaaac5a539ab028df44d9110defbef3797ddb805ca309f61a69ff96dbaa7ab5b24038cf029edec5235d933110f0aea8aeecf939ed14fc20730bba71e4b1110".Hex.toBytes
  var m_bob = bip32.master(seed_bob)

  echo "Payment code: (M/47'/0'/0')"
  var m_bob_47h_0h_0h = m_bob.hardened(47).hardened(0).hardened(0)
  echo paymentCode(m_bob_47h_0h_0h)

  echo "ECDH parameters: (M/47'/0'/0'/0 - M/47'/0'/0'/9)"
  for i in 0..9:
    var m_bob_47h_0h_0h_i = m_bob_47h_0h_0h.derive(i.uint32)
    echo "b", i, ": ", m_bob_47h_0h_0h_i.privateKey
    echo "B", i, ": ", m_bob_47h_0h_0h_i.publicKey

  echo "###Shared secrets:"
  for i in 0..9:
    var m_bob_47h_0h_0h_i = m_bob_47h_0h_0h.derive(i.uint32)
    var aB = m_alice_47h_0h_0h_0.privateKey.ecdh(m_bob_47h_0h_0h_i.publicKey.pubObj)
    var bA = m_bob_47h_0h_0h_i.privateKey.ecdh(m_alice_47h_0h_0h_0.publicKey.pubObj)
    assert aB == bA
    var s = PrivateKey(bA)
    echo "S", i, ": ", s

  echo  "###The first 10 addresses used by Alice for sending to Bob are:"
  var bitcoin: Network
  bitcoin.pubKeyPrefix = 0'u8
  bitcoin.scriptPrefix = 5'u8
  bitcoin.wif = 128'u8
  bitcoin.bech32 = "bc"

  for i in 0..9:
    var m_bob_47h_0h_0h_i = m_bob_47h_0h_0h.derive(i.uint32)
    var aB = m_alice_47h_0h_0h_0.privateKey.ecdh(m_bob_47h_0h_0h_i.publicKey.pubObj)
    var S = PrivateKey(aB)
    var s = sha256s(S).toBytes
    var B_prime = tweakAdd(m_bob_47h_0h_0h_i.publicKey.pubObj, s)
    echo bitcoin.getAddress(B_prime.pub)

  echo "###Alice's notification transaction to Bob:"
  echo "Alice's notification address: ", bitcoin.getAddress(m_alice_47h_0h_0h_0.publicKey)

  var wifAlice = "Kx983SRhAZpAhj7Aac1wUXMJ6XZeyJKqCxJJ49dxEbYCT4a1ozRD"
  echo "private key of input unassociated with Alice's payment code: ", wifAlice

  var pcAlice = base58.dec(paymentCode(m_alice_47h_0h_0h))
  var pcAlicePayload = pcAlice[1..^5]
  echo "Alice's payment code payload:"
  echo pcAlicePayload

  var m_bob_47h_0h_0h_0 = m_bob_47h_0h_0h.derive(0)
  var bobNotificationAddress = bitcoin.getAddress(m_bob_47h_0h_0h_0.publicKey)
  echo "Bob's notification address: ", bobNotificationAddress
  echo "Bob's notification address public key: ", m_bob_47h_0h_0h_0.publicKey

  var outputAlice = "86f411ab1c8e70ae8a0795ab7a6757aea6e4d5ae1826fc7b8f00c597d500609c01000000".Hex.toBytes
  echo "Outpoint of first UTXO in Alice's notification transaction to Bob:"
  echo outputAlice

  var alicePrv = "1b7a10f45118e2519a8dd46ef81591c1ae501d082b6610fdda3de7a3c932880d".Hex.toBytes.PrivateKey
  var s = alicePrv.ecdh(m_bob_47h_0h_0h_0.publicKey.pubObj)
  echo "Shared secret: ", s

  var I = sha512.hmac(outputAlice.toSeq, s.toSeq).data # opposite? s = HMAC-SHA512(x, o)
  var mask = I.toSeq
  echo "Blinding mask:"
  echo mask

  for i in 0..63:
    pcAlicePayload[i+3] = pcAlicePayload[i+3] xor mask[i]
  echo "Alice's payment code payload after blinding:"
  echo pcAlicePayload

  var alicePub = alicePrv.pub
  var tx1 = newTx()
  tx1.ver = 1'i32
  tx1.ins.add((tx: outputAlice[0..31].Hash, n: outputAlice[32..^1].toUint32,
               sig: bitcoin.getScript(bitcoin.getAddress(alicePub)).Sig, sequence: 0xffffffff'u32))
  tx1.outs.add((10000'u64, p2pkh_script(bobNotificationAddress).Script))
  tx1.outs.add((10000'u64, (OP_RETURN, PushData(pcAlicePayload)).toBytes.Script))
  var sigHashType: uint32 = SIGHASH_ALL
  var txSign = (tx1, sigHashType).toBytes
  var txSignHash = sha256d(txSign).toBytes
  var signDer = alicePrv.sign(txSignHash, grind = false) # grind false is only used to match test vectors
  assert alicePub.verify(txSignHash, signDer) == true
  var sig0 = (PushData((signDer, sigHashType.uint8).toBytes), PushData(alicePub)).toBytes
  tx1.ins[0].sig = sig0.Sig
  echo "Notification transaction to be pushed:"
  echo tx1.toBytes

  echo "Notification transaction hash: ", tx1.hash
