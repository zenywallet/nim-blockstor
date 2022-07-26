when defined(emscripten):
  proc crypt_seed*(seed: pointer, size: int): int {.exportc.} =
    {.emit:"""
#include <emscripten.h>

int ret = EM_ASM_INT(
try {
  if(crypto && crypto.getRandomValues) {
    var seed = new Uint8Array($1);
    crypto.getRandomValues(seed);
    HEAPU8.set(seed, $0);
    return 0;
  }
} catch(e) {}
try {
  if(!global.crypto) {
    global.crypto = require('crypto');
  }
  var seed = crypto.randomBytes($1);
  HEAPU8.set(seed, $0);
  return 0;
} catch(e) {
  return 1;
}
, seed, size);
return ret;
""".}
else:
  {.emit: """
#ifdef _WIN32
#include <windows.h>
#include <wincrypt.h>
#else
#include <stdio.h>
#endif

int crypt_seed(unsigned char *seed, int size) {
#ifdef _WIN32
  HCRYPTPROV prov;

  if (!CryptAcquireContext(&prov, NULL, NULL, PROV_RSA_FULL, CRYPT_VERIFYCONTEXT))  {
    return 1;
  }

  if (!CryptGenRandom(prov, size, seed))  {
    CryptReleaseContext(prov, 0);
    return 1;
  }

  CryptReleaseContext(prov, 0);
#else
  FILE *f = fopen("/dev/urandom", "rb");

  if (f == NULL) {
    return 1;
  }

  fread(seed, 1, size, f);
  fclose(f);
#endif

  return 0;
}
"""}
