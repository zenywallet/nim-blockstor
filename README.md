# nim-blockstor
Block Explorer API for Wallet Service

### Features

- Block explorer can handle multiple bitcoin-like cores forked from the bitcoin core in a single process
- Includes the original front-end web server specialized for real-time message exchange
    - Multi-threaded server processing
    - [WebSocket](https://datatracker.ietf.org/doc/html/rfc6455) support
    - [TLS/SSL](https://en.wikipedia.org/wiki/Transport_Layer_Security) support
    - [OpenSSL](https://www.openssl.org/), [LibreSSL](https://www.libressl.org/), or [BoringSSL](https://boringssl.googlesource.com/boringssl/) can be selected depending on the future security situation
    - Renew SSL certificates without application restart
    - Support for automatic renewal of [Let's Encrypt](https://letsencrypt.org/) certificates
    - Ability to limit the number of client connections and requests to prevent high server loads
    - Up to 30k simultaneous connections, a single server could support approximately 1 million user wallets
    - Redirect http requests to https
    - Web proxy functionality implemented for internal connections, no SSL
    - Web pages are in-memory static files at compile time, dynamic file loading is also available for development
    - Careful handling of connection-related errors
    - Only the minimum necessary functions are implemented, so code is short and simple for easy review

    **Note:** The related files for this web server have been copied to [Caprese](https://github.com/zenywallet/caprese) and development continues.

- Encrypted stream communication framework between client and server in WebSocket
    - [Ed25519](https://github.com/orlp/ed25519) [ECDH](https://en.wikipedia.org/wiki/Elliptic-curve_Diffie%E2%80%93Hellman) key exchange
    - [Serpent](https://www.cl.cam.ac.uk/~rja14/serpent.html) encryption with [CTR](https://en.wikipedia.org/wiki/Block_cipher_mode_of_operation#Counter_(CTR)) mode
    - [LZ4](https://github.com/lz4/lz4) extremely fast compression

    *Encryption Flow:*  
    compress => encryption => SSL send --- (internet) ---> SSL receive => decryption => decompress  
    Basically the same algorithm as used in [Pastel Wallet](https://github.com/zenywallet/pastel-wallet), except that uses [Deflate](https://en.wikipedia.org/wiki/Deflate) compression

- Messaging functionality to send data from the server to clients individually or in groups
- Easy altcoin support, no need to implement proprietary hash algorithms per core
- Support for coin amounts up to 64 bits in Satoshi units
- Keep track of the number of UTXOs per addresses
- Dependency-free executables for easy server deployment
- Selectable KVS (Key-Value Store) [Sophia](https://github.com/pmwkaa/sophia) and [RocksDB](https://github.com/facebook/rocksdb)
- Fast and comfortable web-based UI created with [ImGui](https://github.com/ocornut/imgui) for developers, PC browsers only
- Web mining, [yespower](https://www.openwall.com/yespower/) only
- [TOTP](https://en.wikipedia.org/wiki/Time-based_one-time_password) (Time-Based One-Time Password), [RFC 6238](https://datatracker.ietf.org/doc/html/rfc6238), Compatible with [Google Authenticator](https://en.wikipedia.org/wiki/Google_Authenticator)
- Web-based QR code and barcode reader using [ZBar](https://github.com/mchehab/zbar)
- Includes [zenyjs](https://github.com/zenywallet/nim-blockstor/tree/master/src/zenyjs), a wallet library written in [Nim](https://nim-lang.org/) that can be converted to javascript with WASM as the backend

### Requirements

- Linux, recommended Debian or Ubuntu  
  BSD, Windows will be supported

### Install Dependencies

    sudo apt install build-essential automake libtool autopoint

### Install Nim

See [Nim](https://nim-lang.org/) for installation details.

### Download Emscripten and install

    git clone https://github.com/emscripten-core/emsdk.git
    cd emsdk
    git pull
    ./emsdk install latest
    ./emsdk activate latest
    source ./emsdk_env.sh

See [Emscripten](https://emscripten.org/) for installation details. *emsdk_env.sh* must be run before nimble building.

### Download nim-blockstor

    git clone https://github.com/zenywallet/nim-blockstor
    cd nim-blockstor
    git submodule update --init

**Note:** *--recursive* option is unnecessary and should not be added.

### Closure Compiler Setup

Use closure-compiler to minify javascript. The closure-compiler beautifully optimizes the somewhat wasteful javascript generated by nim.
Download [*closure-compiler.jar*](https://developers.google.com/closure/compiler) and copy to *nim-blockstor/closure-compiler-vyyyyMMdd.jar*. The version date in the filename does not need to be changed. The build script will take care of it. If you use jar, you need to install java.

    sudo apt install openjdk-17-jre

An alternative is to install [google-closure-compiler](https://www.npmjs.com/package/google-closure-compiler) from npm without using the jar. In this case, nodejs is required. Emscripten SDK environment has nodejs, so use that or install nodejs separately. [nvm](https://github.com/nvm-sh/nvm) is recommended to install nodejs.

    npm i google-closure-compiler

### Build Dependencies

    nimble depsAll

It takes quite a while, so edit the blockstor configuration file in the meantime.

### Blockstor Configuration

    cp src/config_default.nim src/config.nim

edit src/config.nim

### Install Dependent Packages

    nimble install -d

### Release Build

    nimble ui
    nimble webminer
    nimble webmining
    nimble build -d:release -d:ENABLE_SSL

Non-root users cannot use privileged ports such as 80 or 443 by default, so capabilities must be added after each build.

    sudo setcap cap_net_bind_service=+ep ./blockstor

Check that the capabilities are added

    getcap ./blockstor

### Launch

    ./blockstor

### Miscellaneous Build Options

    nimble uidebug
    nimble build -d:release -d:DYNAMIC_FILES
    nimble build -d:release -d:DB_ROCKSDB
    nimble build -d:release --opt:speed -d:DB_ROCKSDB -d:ENABLE_SSL --verbose

    cd src/zenyjs
    nim c -r zenyjs_build.nim
    ./zenyjs_build mining.nim
    cp zenyjs.wasm mining.js mining.html ../../public

### License

MIT
