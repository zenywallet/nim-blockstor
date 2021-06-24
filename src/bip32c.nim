# Copyright (c) 2021 zenywallet

import bytes
import address
import bip32
import tables

{.used.}

type
  HDNodeHandle* = pointer


var hdNodes {.threadvar.}: Table[HDNodeHandle, HDNode]
var stringRefs {.threadvar.}: Table[pointer, ref string]

proc bip32_init*() {.exportc.} =
  hdNodes = initTable[HDNodeHandle, HDNode]()
  stringRefs = initTable[pointer, ref string]()

proc bip32_free_all*() {.exportc.} =
  hdNodes.clear()
  stringRefs.clear()

proc bip32_hdnode_free*(h: HDNodeHandle) {.exportc.} =
  hdNodes.del(h)

proc bip32_string_free*(s: cstring) {.exportc.} =
  stringRefs.del(cast[pointer](s))

proc bip32_master*(seed: ptr UncheckedArray[byte], size: cint, testnet: bool = false): HDNodeHandle {.exportc.} =
  let n = master(seed.toBytes(size), testnet)
  result = cast[HDNodeHandle](n)
  hdNodes[result] = n

proc bip32_master_from_hex*(seed_hex: cstring, testnet: bool = false): HDNodeHandle {.exportc.} =
  var seed = Hex($seed_hex).toBytes
  let n = master(seed, testnet)
  result = cast[HDNodeHandle](n)
  hdNodes[result] = n

proc checkLen(x: cstring): bool =
  result = false
  for i in 0..255:
    if x[i] == cast[char](nil):
      result = true
      break

proc bip32_node*(x: cstring, testnet: bool = false): HDNodeHandle {.exportc.} =
  if checkLen(x) == false:
    raise newException(HdError, "node string too long")
  let n = node($x, testnet)
  result = cast[HDNodeHandle](n)
  hdNodes[result] = n

proc bip32_hardened*(h: HDNodeHandle, index: uint32): HDNodeHandle {.exportc.} =
  let n = hardened(hdNodes[h], index)
  result = cast[HDNodeHandle](n)
  hdNodes[result] = n

proc bip32_derive*(h: HDNodeHandle, index: uint32): HDNodeHandle {.exportc.} =
  let n = derive(hdNodes[h], index)
  result = cast[HDNodeHandle](n)
  hdNodes[result] = n

proc bip32_address*(h: HDNodeHandle, networkId: cint): cstring {.exportc.} =
  var s = new string
  s[] = hdNodes[h].address(getNetwork(networkId.NetworkId)) & "\0"
  result = s[].cstring
  stringRefs[cast[pointer](result)] = s

proc bip32_segwit_address*(h: HDNodeHandle, networkId: cint): cstring {.exportc.} =
  var s = new string
  s[] = hdNodes[h].segwitAddress(getNetwork(networkId.NetworkId)) & "\0"
  result = s[].cstring
  stringRefs[cast[pointer](result)] = s

proc bip32_xprv*(h: HDNodeHandle): cstring {.exportc.} =
  var s = new string
  s[] = hdNodes[h].xprv & "\0"
  result = s[].cstring
  stringRefs[cast[pointer](result)] = s

proc bip32_xpub*(h: HDNodeHandle): cstring {.exportc.} =
  var s = new string
  s[] = hdNodes[h].xpub & "\0"
  result = s[].cstring
  stringRefs[cast[pointer](result)] = s

when isMainModule:
  {.emit: """
#define HDNodeHandle void*

/*
void bip32_init();
void bip32_free_all();
void bip32_hdnode_free(HDNodeHandle h);
void bip32_string_free(char* s);
HDNodeHandle bip32_master(char* seed, int size, bool testnet);
HDNodeHandle bip32_master_from_hex(char *seed_hex, bool testnet);
HDNodeHandle bip32_node(char* x, bool testnet);
HDNodeHandle bip32_hardened(HDNodeHandle h, int index);
HDNodeHandle bip32_derive(HDNodeHandle h, int index);
char* bip32_address(HDNodeHandle h, int network_id);
char* bip32_segwit_address(HDNodeHandle h, int network_id);
char* bip32_xprv(HDNodeHandle h);
char* bip32_xpub(HDNodeHandle h);
*/

void test1() {
  bip32_init();

  printf("--- Test vector 1\n");
  char* seed_hex = "000102030405060708090a0b0c0d0e0f";
  HDNodeHandle m = bip32_master_from_hex(seed_hex, false);
  printf("Seed: %s\n", seed_hex);
  printf("Chain m\n");
  printf("ext pub: %s\n", bip32_xpub(m));
  printf("ext prv: %s\n", bip32_xprv(m));

  printf("Chain m/0'\n");
  HDNodeHandle m_0h = bip32_hardened(m, 0);
  printf("ext pub: %s\n", bip32_xpub(m_0h));
  printf("ext prv: %s\n", bip32_xprv(m_0h));

  printf("Chain m/0'/1\n");
  HDNodeHandle m_0h_1 = bip32_derive(m_0h, 1);
  printf("ext pub: %s\n", bip32_xpub(m_0h_1));
  printf("ext prv: %s\n", bip32_xprv(m_0h_1));

  printf("Chain m/0'/1/2'\n");
  HDNodeHandle m_0h_1_2h = bip32_hardened(m_0h_1, 2);
  printf("ext pub: %s\n", bip32_xpub(m_0h_1_2h));
  printf("ext prv: %s\n", bip32_xprv(m_0h_1_2h));

  printf("Chain m/0'/1/2'/2\n");
  HDNodeHandle m_0h_1_2h_2 = bip32_derive(m_0h_1_2h, 2);
  printf("ext pub: %s\n", bip32_xpub(m_0h_1_2h_2));
  printf("ext prv: %s\n", bip32_xprv(m_0h_1_2h_2));

  printf("Chain m/0'/1/2'/2/1000000000\n");
  HDNodeHandle m_0h_1_2h_2_1000000000 = bip32_derive(m_0h_1_2h_2, 1000000000);
  printf("ext pub: %s\n", bip32_xpub(m_0h_1_2h_2_1000000000));
  printf("ext prv: %s\n", bip32_xprv(m_0h_1_2h_2_1000000000));

  bip32_free_all();
}
""".}

  proc test1() {.importc.}

  test1()
