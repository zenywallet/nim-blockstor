// Copyright (c) 2021 zenywallet

#include "imgui.h"
#include "imgui_impl_sdl2.h"
#include "imgui_impl_opengl3.h"
#include <stdio.h>
#include <emscripten.h>
#include <SDL.h>
#include <SDL_opengles2.h>
#include <nlohmann/json.hpp>
#include <iostream>
#include <sstream>
#include <string>
#include <ctime>
#include <iomanip>
#include "../deps/zbar/include/zbar.h"
#include "ui.h"

using json = nlohmann::json;
using namespace zbar;

SDL_Window*     g_Window = NULL;
SDL_GLContext   g_GLContext = NULL;
ImFont* mainFont = NULL;
ImFont* monoFont = NULL;
ImFont* iconFont = NULL;
#define TI_WAND "\xee\x98\x80"
#define TI_FILES "\xee\x9a\xa3"
#define TI_CLIPBOARD "\xee\x9a\xb4"
#define TI_ERASER "\xee\x9a\xa5"

json noraList;
json nodeStatus;
json winBip44;
json winAddress;
json addrInfos;
json winTools;
json winBlock;
json blkInfos;
json winTx;
json txInfos;
json heightInfos;
json winTotp;
json winQrreader;
json winMining;
json miningInfos;

bool dirtySettingsFlag = false;
float dirtySettingsTimer = 0.0f;
float settingSsavingRate = 5.0f;
bool loadSettingsFlag = true;

void MarkSettingsDirty()
{
    if (dirtySettingsTimer <= 0.0f) {
        dirtySettingsTimer = settingSsavingRate;
    }
}

bool CheckSettingsDirty(ImGuiIO& io)
{
    if (dirtySettingsTimer > 0.0f)
    {
        dirtySettingsTimer -= io.DeltaTime;
        if (dirtySettingsTimer <= 0.0f)
        {
            dirtySettingsFlag = true;
            dirtySettingsTimer = 0.0f;
        }
    }
    return dirtySettingsFlag;
}

static void main_loop(void *arg);

extern "C" bool streamActive;

extern "C" void* stream;

extern "C" void uiError(const char* msg);

extern "C" bool streamSend(const char* data, int size);

extern "C" void streamRecv(char* data, int size) {
    std::string s(data, size);
    auto j = json::parse(s);
    if (j["type"] == "noralist") {
        noraList = j["data"];
    } else if(j["type"] == "status") {
        auto data = j["data"];
        int nid = data["nid"].get<int>();
        std::string nid_s = std::to_string(nid);
        bool prev_synced = false;
        if (!nodeStatus[nid_s].empty()) {
            prev_synced = nodeStatus[nid_s]["synced"].get<bool>();
        }
        nodeStatus[nid_s] = data;
        int nodeHeight = nodeStatus[nid_s]["height"].get<int>();
        int nodeLastHeight = nodeStatus[nid_s]["lastHeight"].get<int>();
        bool synced = (nodeHeight == nodeLastHeight);
        nodeStatus[nid_s]["synced"] = synced;
        if (!prev_synced && synced) {
            for (auto& el : winTx["windows"].items()) {
                int height = winTx["windows"][el.key()]["height"].get<int>();
                if (winTx["windows"][el.key()]["nid"].get<int>() == nid &&
                    winTx["windows"][el.key()]["valid_tx"].get<bool>()) {
                    winTx["windows"][el.key()]["update"] = true;
                }
            }
        } else {
            for (auto& el : winTx["windows"].items()) {
                int height = winTx["windows"][el.key()]["height"].get<int>();
                if (winTx["windows"][el.key()]["nid"].get<int>() == nid &&
                    (height < 0 || nodeHeight == height) &&
                    winTx["windows"][el.key()]["valid_tx"].get<bool>()) {
                    winTx["windows"][el.key()]["update"] = true;
                }
            }
        }
    } else if(j["type"] == "addr") {
        addrInfos["pending"].push_back(j["data"]);
    } else if(j["type"] == "utxo") {
        addrInfos["utxo_pending"].push_back(j["data"]);
    } else if(j["type"] == "addrlog") {
        addrInfos["addrlog_pending"].push_back(j["data"]);
    } else if(j["type"] == "tx") {
        txInfos["pending"].push_back(j);
    } else if(j["type"] == "block") {
        blkInfos["pending"].push_back(j);
    } else if(j["type"] == "height") {
        heightInfos["pending"].push_back(j["data"]);
    } else if(j["type"] == "mining") {
        miningInfos["pending"].push_back(j["data"]);
    }

    if (EM_ASM_INT(return document.hidden)) {
        main_loop(nullptr);
    }
}

#define HDNodeHandle void*
enum AddressType {
    Unknown,
    P2PKH,
    P2SH,
    P2SH_P2WPKH,
    P2WPKH
};
extern "C" {
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

    int crypt_seed(unsigned char *seed, int size);

    char* base58_enc(char* buf, int size);
    char* base58_enc_from_hex(char* hex);
    int base58_dec(char* s, char* buf, int size);
    char* base58_dec_to_hex(char* s);

    void address_init();
    char* get_address(int nid, char* hash160, int size, uint8_t address_type);
    char* get_address_from_hex(int nid, char* hash160_hex, uint8_t address_type);
    bool* check_address(char* address);
    char* get_hash160_hex(int nid, char* address);

    char *call_totp(char* key, uint64_t sec, int digit, int timestep, int algo);
}

std::string getTime(int64_t tval)
{
    std::time_t tt = tval;
    std::tm* t = std::gmtime(&tt);
    std::stringstream ss;
    ss << std::put_time(t, "%Y-%m-%d %X");
    return ss.str();
}

std::string getLocalTime(int64_t tval)
{
    std::time_t tt = tval;
    std::tm* t = std::localtime(&tt);
    std::stringstream ss;
    ss << std::put_time(t, "%Y-%m-%d %X");
    return ss.str();
}

constexpr char hexmap[] = {'0', '1', '2', '3', '4', '5', '6', '7',
                           '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'};

std::string hexStr(unsigned char *data, int len)
{
  std::string s(len * 2, ' ');
  for (int i = 0; i < len; ++i) {
    s[2 * i]     = hexmap[(data[i] & 0xF0) >> 4];
    s[2 * i + 1] = hexmap[data[i] & 0x0F];
  }
  return s;
}

std::string trimQuote(std::string s)
{
    if (s[0] == '\"' && s[s.length() - 1] == '\"') {
        return s.substr(1, s.length() - 2);
    }
    return s;
}

uint64_t jvalToUint64(json jval)
{
    uint64_t val;
    if (jval.type() == json::value_t::string) {
        val = std::stoull(jval.get<std::string>());
    } else {
        val = jval.get<uint64_t>();
    }
    return val;
}

std::string jvalToStr(json jval)
{
    std::string valstr;
    if (jval.type() == json::value_t::string) {
        valstr = jval.get<std::string>();
    } else {
        valstr = std::to_string(jval.get<uint64_t>());
    }
    return valstr;
}

json uint64ToJson(uint64_t val)
{
    if (val > 9007199254740991) {
        return std::to_string(val);
    }
    return val;
}

std::string convCoin(std::string valstr)
{
    int len = valstr.length();
    if (len <= 0) {
        return "";
    } else if (len > 8) {
        return valstr.substr(0, len - 8) + "." + valstr.substr(len - 8, 8);
    } else if (len < 8) {
        valstr.insert(0, 8 - len, '0');
    }
    return "0." + valstr;
}

std::string convCoin(json jval)
{
    return convCoin(jvalToStr(jval));
}

static ImGuiWindowFlags PrepareOverlay()
{
    const float PAD = 10.0f;
    static int corner = 3;

    ImGuiIO& io = ImGui::GetIO();
    ImGuiWindowFlags window_flags = ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_AlwaysAutoResize |
        ImGuiWindowFlags_NoSavedSettings | ImGuiWindowFlags_NoFocusOnAppearing | ImGuiWindowFlags_NoNav;
    const ImGuiViewport* viewport = ImGui::GetMainViewport();
    ImVec2 work_pos = viewport->WorkPos;
    ImVec2 work_size = viewport->WorkSize;
    ImVec2 window_pos, window_pos_pivot;
    window_pos.x = (corner & 1) ? (work_pos.x + work_size.x - PAD) : (work_pos.x + PAD);
    window_pos.y = (corner & 2) ? (work_pos.y + work_size.y - PAD) : (work_pos.y + PAD);
    window_pos_pivot.x = (corner & 1) ? 1.0f : 0.0f;
    window_pos_pivot.y = (corner & 2) ? 1.0f : 0.0f;
    ImGui::SetNextWindowPos(window_pos, ImGuiCond_Always, window_pos_pivot);
    window_flags |= ImGuiWindowFlags_NoMove;
    ImGui::SetNextWindowBgAlpha(0.35f);
    return window_flags;
}

static void ShowConnectStatusOverlay(bool* p_open)
{
    ImGuiWindowFlags window_flags = PrepareOverlay();
    if (ImGui::Begin("Status Overlay", p_open, window_flags))
    {
        if (streamActive) {
            ImGui::Text("Connected");
        } else {
            ImGui::Text("Disconnected");
        }
    }
    ImGui::End();
}

static void ShowFramerateOverlay(bool* p_open)
{
    ImGuiWindowFlags window_flags = PrepareOverlay();
    if (ImGui::Begin("Status Overlay", p_open, window_flags))
    {
        ImGuiIO& io = ImGui::GetIO();
        auto framerate = io.Framerate;
        ImGui::Text("%.3f ms / %.1f FPS", 1000.0f / framerate, framerate);
    }
    ImGui::End();
}

static void copyString(const std::string& input, char *dst, size_t dst_size)
{
    strncpy(dst, input.c_str(), dst_size - 1);
    dst[dst_size - 1] = '\0';
}

static int charVal(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

static bool checkHexStr(std::string& s)
{
    int len = s.length();
    if(len <= 0 || len % 2 != 0) {
        return false;
    }
    for (int i = 0; i < len; i++) {
        if (charVal(s[i]) < 0) {
            return false;
        }
    }
    return true;
}

EM_JS(void, db_set, (const char* tag, const char* data), {
    localStorage[UTF8ToString(tag)] = UTF8ToString(data);
});

EM_JS(char*, db_get, (const char* tag), {
    var data = localStorage[UTF8ToString(tag)];
    if(!data) {
        return null;
    }
    var len = lengthBytesUTF8(data) + 1;
    var p = _malloc(len);
    stringToUTF8(data, p, len);
    return p;
});

EM_JS(void, db_del, (const char* tag), {
    localStorage.removeItem(UTF8ToString(tag));
});

EM_JS(void, db_clear, (), {
    localStorage.clear();
});

std::string db_get_string(const char* tag) {
    char* str = db_get(tag);
    if (str != nullptr) {
        std::string ret_string(str);
        free(str);
        return ret_string;
    }
    return "";
}

json db_get_json(const char* tag) {
    std::string ret_string = db_get_string(tag);
    if (!ret_string.empty()) {
        return json::parse(ret_string);
    }
    return json{};
}

static void HelpMarker(const char* desc)
{
    ImGui::TextDisabled("(?)");
    if (ImGui::IsItemHovered())
    {
        ImGui::BeginTooltip();
        ImGui::PushTextWrapPos(ImGui::GetFontSize() * 35.0f);
        ImGui::TextUnformatted(desc);
        ImGui::PopTextWrapPos();
        ImGui::EndTooltip();
    }
}

static void ShowBip44Window(bool* p_open, int wid)
{
    ImGuiIO& io = ImGui::GetIO();
    ImGuiPlatformIO& platform_io = ImGui::GetPlatformIO();
    json& param = winBip44["windows"][std::to_string(wid)];

    std::string title(std::string("BIP44 - " + std::to_string(wid) + "##" + std::to_string(wid)).c_str());
    if (ImGui::Begin(title.c_str(), p_open)) {
        std::string seed_hex = param["seed"].get<std::string>();
        bool seed_animate = param["animate"].get<bool>();
        int seedbit = param["seedbit"].get<int>();
        int seed_len = seed_hex.length();
        bool seed_valid = param["seedvalid"].get<bool>();
        bool seederr = param["seederr"].get<bool>();

        if (seed_len > 256) {
            seed_hex = seed_hex.substr(0, 256);
            seed_len = 256;
        }

        if (seed_animate) {
            unsigned char buf[257];
            std::memset(buf, 0, sizeof(buf));
            seed_valid = checkHexStr(seed_hex);
            if (seed_valid) {
                int j = 0;
                for (unsigned int i = 0; i < seed_len; i += 2) {
                    std::string s = seed_hex.substr(i, 2);
                    buf[j] = (char)strtol(s.c_str(), NULL, 16);
                    j++;
                }
            }

            float progress = param["progress"].get<float>();
            progress += 0.4f * io.DeltaTime;
            int keylen;
            if (seedbit == 0) {
                keylen = 32;
            } else if (seedbit == 1) {
                keylen = 64;
            } else if (seedbit == 2) {
                keylen = 128;
            }
            int pos = int(keylen * progress - 32.0f);
            if(keylen > pos) {
                if (pos < 0) {
                    pos = 0;
                }
                if(crypt_seed(&buf[pos], keylen - pos) == 0) {
                    seed_hex = hexStr(buf, keylen);
                } else {
                    param["animate"] = false;
                    param["seedvalid"] = false;
                    seed_hex = "";
                    progress = 0.0f;
                    seederr = true;
                    param["seederr"] = true;
                }
            } else {
                param["animate"] = false;
                progress = 0.0f;
                param["seedvalid"] = seed_valid;
                if (seed_valid) {
                    param["bip44update"] = true;
                }
            }
            param["seed"] = seed_hex;
            param["progress"] = progress;
        }

        ImGui::SetNextItemOpen(true, ImGuiCond_Once);
        if (ImGui::CollapsingHeader("Master Seed")) {
            static float seedBitWidth[3] = {650.0, 1290.0, 2570.0};
            ImGui::SetNextItemOpen(true, ImGuiCond_Once);
            if (ImGui::TreeNode("Seed hex")) {
                char seed_str[257];
                copyString(seed_hex, seed_str, sizeof(seed_str));

                if (seedbit >= 0 && seedbit <= 3) {
                    ImGui::PushFont(monoFont);
                    ImGui::PushItemWidth(seedBitWidth[seedbit]);
                    if (ImGui::InputText("##shex", seed_str, IM_ARRAYSIZE(seed_str))) {
                        seed_hex = std::string(seed_str);
                        seed_len = seed_hex.length();
                        seed_valid = checkHexStr(seed_hex);
                        param["seed"] = seed_hex;
                        param["bip44update"] = true;
                        param["animate"] = false;
                        param["progress"] = 0.0f;
                        param["seedvalid"] = seed_valid;
                    }
                    ImGui::PopItemWidth();
                    ImGui::PopFont();
                    if (ImGui::Button(std::string(TI_FILES " Copy##sbtn").c_str())) {
                        platform_io.Platform_SetClipboardTextFn(NULL, seed_str);
                    }
                    ImGui::SameLine();
                    ImGui::Text("Paste ctrl+v");
                }
                if (seederr) {
                    ImGui::TextColored(ImVec4(1.0f, 1.0f, 0.0f, 1.0f), "Critical: Seed generator is failed");
                }
                ImGui::TreePop();
                ImGui::Separator();
            }

            ImGui::SetNextItemOpen(true, ImGuiCond_Once);
            if (ImGui::TreeNode("Seed base58")) {
                ImGui::PushFont(monoFont);
                ImGui::PushItemWidth(seedBitWidth[seedbit]);
                char base58char[257];
                if (seed_valid && seedbit >= 0 && seedbit <= 3) {
                    strncpy(base58char, base58_enc_from_hex((char*)seed_hex.c_str()), sizeof(base58char));
                    base58char[256] = '\0';
                } else {
                    base58char[0] = '\0';
                }
                if (ImGui::InputText("##s58", base58char, IM_ARRAYSIZE(base58char))) {
                    seed_hex = base58_dec_to_hex(base58char);
                    seed_len = seed_hex.length();
                    seed_valid = checkHexStr(seed_hex);
                    param["seed"] = seed_hex;
                    param["bip44update"] = true;
                    param["animate"] = false;
                    param["progress"] = 0.0f;
                    param["seedvalid"] = seed_valid;
                }
                ImGui::PopItemWidth();
                ImGui::PopFont();
                if (ImGui::Button(std::string(TI_FILES " Copy##s58btn").c_str())) {
                    platform_io.Platform_SetClipboardTextFn(NULL, base58char);
                }
                ImGui::SameLine();
                ImGui::Text("Paste ctrl+v");
                ImGui::TreePop();
                ImGui::Separator();
            }

            ImGui::RadioButton("256bit", &seedbit, 0); ImGui::SameLine();
            ImGui::RadioButton("512bit", &seedbit, 1); ImGui::SameLine();
            ImGui::RadioButton("1024bit", &seedbit, 2); ImGui::SameLine();
            param["seedbit"] = seedbit;

            if (ImGui::Button((std::string(TI_WAND) + " Generate Seed").c_str())) {
                param["animate"] = true;
                param["seed"] = "";
                param["progress"] = 0.0f;
                param["seederr"] = false;
            }
            ImGui::SameLine();
            if (ImGui::Button((std::string(TI_ERASER) + " Clear##s58cbtn").c_str())) {
                seed_hex = "";
                seed_len = 0;
                seed_valid = false;
                param["seed"] = seed_hex;
                param["animate"] = false;
                param["progress"] = 0.0f;
                param["seedvalid"] = seed_valid;
                param["bip44update"] = false;
            }
        }

        int network_idx = param["nid"].get<int>();
        bool testnet = param["testnet"].get<bool>();
        ImGui::SetNextItemOpen(true, ImGuiCond_Once);
        if (ImGui::CollapsingHeader("Master Key")) {
            std::string xprv;
            std::string xpub;
            if(!seed_valid) {
                if (seed_len == 0) {
                    xprv = "";
                    xpub = "";
                } else {
                    xprv = "invalid seed";
                    xpub = "invalid seed";
                }
            } else if (seed_hex.compare(param["prev_seed"].get<std::string>()) != 0 || testnet != param["prev_testnet"].get<bool>()) {
                param["prev_seed"] = seed_hex;
                param["prev_testnet"] = testnet;
                HDNodeHandle m = bip32_master_from_hex((char*)seed_hex.c_str(), testnet);
                xprv = std::string(bip32_xprv(m));
                xpub = std::string(bip32_xpub(m));
                param["xprv"] = xprv;
                param["xpub"] = xpub;
                bip32_free_all();
            } else {
                xprv = param["xprv"].get<std::string>();
                xpub = param["xpub"].get<std::string>();
            }
            ImGui::SetNextItemOpen(true, ImGuiCond_Once);
            if (ImGui::TreeNode("Private key")) {
                ImGui::PushFont(monoFont);
                ImGui::Text(xprv.c_str());
                ImGui::PopFont();
                if (seed_valid && xprv.length() > 0 && ImGui::Button(std::string(TI_FILES " Copy##mprv").c_str())) {
                    platform_io.Platform_SetClipboardTextFn(NULL, xprv.c_str());
                }
                ImGui::TreePop();
                ImGui::Separator();
            }
            ImGui::SetNextItemOpen(true, ImGuiCond_Once);
            if (ImGui::TreeNode("Public key")) {
                ImGui::PushFont(monoFont);
                ImGui::Text(xpub.c_str());
                ImGui::PopFont();
                if (seed_valid && xpub.length() > 0 && ImGui::Button(std::string(TI_FILES " Copy##mpub").c_str())) {
                    platform_io.Platform_SetClipboardTextFn(NULL, xpub.c_str());
                }
                ImGui::TreePop();
                ImGui::Separator();
            }
        }

        int lp = param["b44p"].get<int>();
        int lc = param["b44c"].get<int>();
        int la = param["b44a"].get<int>();
        int idx0 = param["bip44_idx0"].get<int>();
        int idx1 = param["bip44_idx1"].get<int>();
        std::string bip44xprv;
        std::string bip44xpub;
        int flag_derivation = false;
        ImGui::SetNextItemOpen(true, ImGuiCond_Once);
        if (ImGui::CollapsingHeader("Derivation")) {
            int plp = lp;
            int plc = lc;
            int pla = la;
            ImGui::AlignTextToFramePadding();
            ImGui::Text("m /"); ImGui::SameLine();
            ImGui::PushItemWidth(140);
            if (ImGui::InputInt("purpose'", &lp)) {
                if (lp < 0) lp = 0;
                if (lp > 65535) lp = 65535;
            }
            ImGui::SameLine();
            ImGui::PopItemWidth();
            ImGui::Text("/"); ImGui::SameLine();
            ImGui::PushItemWidth(140);
            if (ImGui::InputInt("coin_type'", &lc)) {
                if (lc < 0) lc = 0;
                if (lc > 65535) lc = 65535;
            }
            ImGui::SameLine();
            ImGui::PopItemWidth();
            ImGui::Text("/"); ImGui::SameLine();
            ImGui::PushItemWidth(140);
            if (ImGui::InputInt("account' / change / address_index", &la)) {
                if (la < 0) la = 0;
                if (la > 65535) la = 65535;
            }
            ImGui::PopItemWidth();

            if (lp != plp || lc != plc || la != pla) {
                param["b44p"] = lp;
                param["b44c"] = lc;
                param["b44a"] = la;
                if (seed_valid && !param["animate"].get<bool>()) {
                    param["bip44update"] = true;
                }
            }
            flag_derivation = true;
        }
        if (!seed_valid) {
            if (seed_len == 0) {
                bip44xprv = "";
                bip44xpub = "";
                param["bip44xprv"] = bip44xprv;
                param["bip44xpub"] = bip44xpub;
            } else {
                bip44xprv = "invalid seed";
                bip44xpub = "invalid seed";
            }
            param["bip44_0"].clear();
            param["bip44_1"].clear();
        } else {
            bip44xprv = param["bip44xprv"].get<std::string>();
            bip44xpub = param["bip44xpub"].get<std::string>();
            if (param["bip44update"].get<bool>()) {
                param["bip44update"] = false;
                HDNodeHandle m = bip32_master_from_hex((char*)seed_hex.c_str(), testnet);
                HDNodeHandle p = bip32_hardened(m, lp);
                HDNodeHandle c = bip32_hardened(p, lc);
                HDNodeHandle a = bip32_hardened(c, la);
                bip44xprv = bip32_xprv(a);
                bip44xpub = bip32_xpub(a);
                param["bip44xprv"] = bip44xprv;
                param["bip44xpub"] = bip44xpub;
                param["bip44_0"].clear();
                param["bip44_1"].clear();
                for (int i = idx0; i < idx0 + 20; i++) {
                    HDNodeHandle c0 = bip32_derive(a, 0);
                    HDNodeHandle t0 = bip32_derive(c0, i);
                    param["bip44_0"].push_back(bip32_address(t0, network_idx));
                }
                for (int i = idx1; i < idx1 + 20; i++) {
                    HDNodeHandle c1 = bip32_derive(a, 1);
                    HDNodeHandle t1 = bip32_derive(c1, i);
                    param["bip44_1"].push_back(bip32_address(t1, network_idx));
                }
                bip32_free_all();
            }
        }
        if (flag_derivation) {
            ImGui::SetNextItemOpen(true, ImGuiCond_Once);
            if (ImGui::TreeNode(std::string("Private key (m/" + std::to_string(lp) + "'/" + std::to_string(lc) + "'/" + std::to_string(la) + "')").c_str())) {
                ImGui::PushFont(monoFont);
                ImGui::Text(bip44xprv.c_str());
                ImGui::PopFont();
                if (seed_valid && bip44xprv.length() > 0 && ImGui::Button(std::string(TI_FILES " Copy##m44prv").c_str())) {
                    platform_io.Platform_SetClipboardTextFn(NULL, bip44xprv.c_str());
                }
                ImGui::TreePop();
                ImGui::Separator();
            }
            ImGui::SetNextItemOpen(true, ImGuiCond_Once);
            if (ImGui::TreeNode(std::string("Public key (m/" + std::to_string(lp) + "'/" + std::to_string(lc) + "'/" + std::to_string(la) + "')").c_str())) {
                ImGui::PushFont(monoFont);
                ImGui::Text(bip44xpub.c_str());
                ImGui::PopFont();
                if (seed_valid && bip44xpub.length() > 0 && ImGui::Button(std::string(TI_FILES " Copy##m44pub").c_str())) {
                    platform_io.Platform_SetClipboardTextFn(NULL, bip44xpub.c_str());
                }
                ImGui::TreePop();
                ImGui::Separator();
            }
        }

        ImGui::SetNextItemOpen(true, ImGuiCond_Once);
        if (ImGui::CollapsingHeader("Addresses")) {
            ImGuiComboFlags comb_flags = 0;
            const bool items_testnet[] = {false, true};
            const char* combo_preview_value = NetworkIds[network_idx];
            ImGui::PushItemWidth(350);
            if (ImGui::BeginCombo("Network", combo_preview_value, comb_flags)) {
                for (int n = 0; n < IM_ARRAYSIZE(NetworkIds); n++) {
                    const bool is_selected = (network_idx == n);
                    if (ImGui::Selectable(NetworkIds[n], is_selected)) {
                        network_idx = n;
                        param["bip44update"] = true;
                        param["nid"] = network_idx;
                        param["testnet"] = items_testnet[n];
                    }
                    if (is_selected) {
                        ImGui::SetItemDefaultFocus();
                    }
                }
                ImGui::EndCombo();
            }
            ImGui::PopItemWidth();

            static const int maxIdx = 0x7fffffff - 20;
            ImGuiTabBarFlags tab_bar_flags = ImGuiTabBarFlags_None;
            if (ImGui::BeginTabBar("MyTabBar", tab_bar_flags))
            {
                if (ImGui::BeginTabItem("External (change 0)"))
                {
                    ImGui::AlignTextToFramePadding();
                    ImGui::Text("start: "); ImGui::SameLine();
                    ImGui::PushItemWidth(180);
                    if (ImGui::InputInt("address_index##idx0", &idx0)) {
                        if (idx0 < 0) idx0 = 0;
                        if (idx0 > maxIdx) idx0 = maxIdx;
                        param["bip44_idx0"] = idx0;
                        if (seed_valid) {
                            param["bip44update"] = true;
                        }
                    }
                    ImGui::PopItemWidth();

                    ImGui::PushFont(monoFont);
                    if (param["bip44_0"].size() > 0) {
                        int start = idx0;
                        std::string path_base("m/" + std::to_string(lp) + "'/" + std::to_string(lc) + "'/" + std::to_string(la) + "'/0/");
                        for (auto& el : param["bip44_0"]) {
                            std::string address = el.get<std::string>();
                            ImGui::AlignTextToFramePadding();
                            ImGui::Text((path_base + std::to_string(start) + ": " + address).c_str()); ImGui::SameLine();
                            ImGui::PushFont(mainFont);
                            if (ImGui::Button((std::string(TI_FILES "##0-") + std::to_string(start)).c_str())) {
                                platform_io.Platform_SetClipboardTextFn(NULL, address.c_str());
                            }
                            ImGui::PopFont();
                            start++;
                        }
                    } else {
                        for(int i = 0; i < 5; i++) {
                            ImGui::Text("");
                        }
                    }
                    ImGui::PopFont();
                    ImGui::EndTabItem();
                }
                if (ImGui::BeginTabItem("Internal (change 1)"))
                {
                    ImGui::AlignTextToFramePadding();
                    ImGui::Text("start: "); ImGui::SameLine();
                    ImGui::PushItemWidth(180);
                    if (ImGui::InputInt("address_index##idx1", &idx1)) {
                        if (idx1 < 0) idx1 = 0;
                        if (idx1 > maxIdx) idx1 = maxIdx;
                        param["bip44_idx1"] = idx1;
                        if (seed_valid) {
                            param["bip44update"] = true;
                        }
                    }
                    ImGui::PopItemWidth();

                    ImGui::PushFont(monoFont);
                    if (param["bip44_1"].size() > 0) {
                        int start = idx1;
                        std::string path_base("m/" + std::to_string(lp) + "'/" + std::to_string(lc) + "'/" + std::to_string(la) + "'/1/");
                        for (auto& el : param["bip44_1"]) {
                            std::string address = el.get<std::string>();
                            ImGui::AlignTextToFramePadding();
                            ImGui::Text((path_base + std::to_string(start) + ": " + address).c_str());; ImGui::SameLine();
                            ImGui::PushFont(mainFont);
                            if (ImGui::Button((std::string(TI_FILES "##1-") + std::to_string(start)).c_str())) {
                                platform_io.Platform_SetClipboardTextFn(NULL, address.c_str());
                            }
                            ImGui::PopFont();
                            start++;
                        }
                    } else {
                        for(int i = 0; i < 5; i++) {
                            ImGui::Text("");
                        }
                    }
                    ImGui::PopFont();
                }
                ImGui::EndTabBar();
            }
            ImGui::Separator();
        }
    }
    ImGui::End();
}

static void ShowAddressWindow(bool* p_open, int wid)
{
    ImGuiIO& io = ImGui::GetIO();
    std::string wid_s = std::to_string(wid);
    json& param = winAddress["windows"][wid_s];
    std::string address = param["address"].get<std::string>();
    std::string address_hex = param["address_hex"].get<std::string>();
    bool valid = param["valid"].get<bool>();
    int network_idx = param["nid"].get<int>();
    std::string nid_s = std::to_string(network_idx);
    std::string addr1 = param["addr1"].get<std::string>();
    std::string addr3 = param["addr3"].get<std::string>();
    std::string addr4 = param["addr4"].get<std::string>();
    bool update = false;
    if (param["update"].get<bool>() && streamActive) {
        update = true;
        param["update"] = false;
    }
    std::string title;
    if (winAddress["samewin"].get<bool>()) {
        title = "Addresses";
    } else {
        title = "Address - " + wid_s + "##ta" + wid_s;
    }
    ImGui::SetNextWindowSize(ImVec2(820, 700), ImGuiCond_FirstUseEver);
    if (ImGui::Begin(title.c_str(), p_open)) {
        std::string header;
        std::string amount;
        if (address.length() > 0) {
            if (addrInfos.find(nid_s) != addrInfos.end() &&
                addrInfos[nid_s].find(address) != addrInfos[nid_s].end() &&
                addrInfos[nid_s][address].find("val") != addrInfos[nid_s][address].end() &&
                addrInfos[nid_s][address]["unused"].get<int>() == 0) {
                amount = convCoin(addrInfos[nid_s][address]["val"]);
                header = address + " " + amount + "##ha" + wid_s;
            } else {
                header = address + "##ha" + wid_s;
            }
        } else {
            header = "Address##ha" + wid_s;
        }
        if (address.length() > 0) {
            ImGui::PushFont(monoFont);
        } else {
            ImGui::PushFont(mainFont);
        }
        ImGui::SetNextItemOpen(param["addropen"].get<bool>());
        if (ImGui::CollapsingHeader(header.c_str())) {
            param["addropen"] = true;
            ImGui::PopFont();
            ImGuiComboFlags comb_flags = 0;
            const char* combo_value = NetworkIds[network_idx];
            ImGui::PushItemWidth(350);
            if (ImGui::BeginCombo(("Network##na" + wid_s).c_str(), combo_value, comb_flags)) {
                for (int n = 0; n < IM_ARRAYSIZE(NetworkIds); n++) {
                    const bool is_selected = (network_idx == n);
                    if (ImGui::Selectable(NetworkIds[n], is_selected)) {
                        network_idx = n;
                        param["nid"] = network_idx;
                        nid_s = std::to_string(network_idx);
                        if (streamActive) {
                            update = true;
                        } else {
                            param["update"] = true;
                        }
                        MarkSettingsDirty();
                    }
                    if (is_selected) {
                        ImGui::SetItemDefaultFocus();
                    }
                }
                ImGui::EndCombo();
            }
            ImGui::PopItemWidth();

            char address_str[257];
            copyString(address, address_str, sizeof(address_str));
            ImGui::PushItemWidth(466.0f);
            ImGui::PushFont(monoFont);
            if (ImGui::InputText(("Address  ##ia" + wid_s).c_str(), address_str, IM_ARRAYSIZE(address_str))) {
                address = std::string(address_str);
                address_hex = get_hash160_hex(network_idx, address_str);
                param["address"] = address;
                param["address_hex"] = address_hex;
                if (address_hex.length() > 0) {
                    valid = true;
                } else {
                    valid = false;
                }
                param["valid"] = valid;
                if (streamActive) {
                    update = true;
                } else {
                    param["update"] = true;
                }
                MarkSettingsDirty();
            }
            ImGui::PopFont();
            ImGui::PopItemWidth();

            ImGui::Separator();

            if (addrInfos.find(nid_s) != addrInfos.end() &&
                addrInfos[nid_s].find(address) != addrInfos[nid_s].end()) {
                int unused = addrInfos[nid_s][address]["unused"].get<int>();
                if (unused == 0) {
                    ImGui::Text("status:"); ImGui::SameLine();
                    ImGui::Text("used");
                    ImGui::Text("amount:"); ImGui::SameLine();
                    ImGui::PushFont(monoFont);
                    ImGui::Text(amount.c_str());
                    ImGui::PopFont();
                    ImGui::Text("utxo count:"); ImGui::SameLine();
                    ImGui::PushFont(monoFont);
                    ImGui::Text(std::to_string(addrInfos[nid_s][address]["utxo_count"].get<uint32_t>()).c_str());
                    ImGui::PopFont();
                } else if (unused == 1) {
                    ImGui::Text("status:"); ImGui::SameLine();
                    ImGui::Text("unused");
                    ImGui::Text("amount:");
                    ImGui::Text("utxo count:");
                }
            } else {
                ImGui::Text("status:");
                ImGui::Text("amount:");
                ImGui::Text("utxo count:");
            }

            if (ImGui::TreeNode(("Related addresses##ra" + wid_s).c_str())) {
                ImGui::Text("p2pkh:"); ImGui::SameLine();
                ImGui::PushFont(monoFont);
                ImGui::Text(addr1.c_str());
                ImGui::PopFont();
                ImGui::Text("p2sh-p2wpkh:"); ImGui::SameLine();
                ImGui::PushFont(monoFont);
                ImGui::Text(addr3.c_str());
                ImGui::PopFont();
                ImGui::Text("p2wpkh:"); ImGui::SameLine();
                ImGui::PushFont(monoFont);
                ImGui::Text(addr4.c_str());
                ImGui::PopFont();
                ImGui::TreePop();
            }

            ImGui::SetNextItemOpen(true, ImGuiCond_Once);
            if (ImGui::TreeNode(("UTXO (Unspent Transaction Output)##utxo" + wid_s).c_str())) {
                if (addrInfos.find(nid_s) != addrInfos.end() &&
                    addrInfos[nid_s].find(address) != addrInfos[nid_s].end()) {
                    json& utxos = addrInfos[nid_s][address]["utxos"];
                    json& utxostbl = addrInfos[nid_s][address]["utxostbl"];
                    int load_count = utxos.size();
                    int table_count = utxostbl.size();
                    const float TEXT_BASE_HEIGHT = ImGui::GetTextLineHeightWithSpacing();
                    ImGui::PushFont(monoFont);
                    static ImGuiTableFlags flags = ImGuiTableFlags_SizingFixedFit | ImGuiTableFlags_RowBg |
                                            ImGuiTableFlags_Borders | ImGuiTableFlags_Resizable |
                                            ImGuiTableFlags_Reorderable | ImGuiTableFlags_Hideable |
                                            ImGuiTableFlags_ScrollY;
                    ImVec2 outer_size = ImVec2(0.0f, TEXT_BASE_HEIGHT * 8);
                    if (ImGui::BeginTable("utxos", 4, flags, outer_size))
                    {
                        ImGui::TableSetupScrollFreeze(0, 1);
                        ImGui::TableSetupColumn("id", ImGuiTableColumnFlags_WidthFixed, 11 * 10.0f);
                        ImGui::TableSetupColumn("txid", ImGuiTableColumnFlags_WidthFixed, 65 * 10.0f);
                        ImGui::TableSetupColumn("n", ImGuiTableColumnFlags_WidthFixed, 6 * 10.0f);
                        ImGui::TableSetupColumn("value", ImGuiTableColumnFlags_WidthStretch, 30 * 10.0f);
                        ImGui::TableHeadersRow();

                        if (table_count > 0) {
                            ImGuiListClipper clipper;
                            clipper.Begin(table_count);
                            while (clipper.Step()) {
                                for (int row_n = clipper.DisplayStart; row_n < clipper.DisplayEnd; row_n++) {
                                    json el = utxostbl[row_n];
                                    ImGui::TableNextRow();
                                    ImGui::TableSetColumnIndex(0);
                                    ImGui::Text(std::to_string(el["id"].get<uint64_t>()).c_str());
                                    ImGui::TableSetColumnIndex(1);
                                    ImGui::Text(el["tx"].get<std::string>().c_str());
                                    ImGui::TableSetColumnIndex(2);
                                    ImGui::Text(std::to_string(el["n"].get<int>()).c_str());
                                    ImGui::TableSetColumnIndex(3);
                                    ImGui::Text(convCoin(el["val"]).c_str());
                                }
                            }
                        }
                        ImGui::EndTable();
                    }
                    ImGui::PopFont();
                    if (addrInfos[nid_s][address]["utxoload"].get<bool>()) {
                        if (ImGui::Button("Stop")) {
                            addrInfos[nid_s][address]["utxoload"] = false;
                        }
                        ImGui::SameLine();
                        ImGui::PushFont(monoFont);
                        ImGui::Text(("downloading... " + std::to_string(load_count)).c_str());
                        ImGui::PopFont();
                    } else {
                        if (ImGui::Button("Update")) {
                            utxos.clear();
                            std::string network_idx_s = std::to_string(network_idx);
                            std::string cmd_utxo = "{\"cmd\":\"utxo\",\"data\":{\"nid\":" +
                                            network_idx_s + ",\"addr\":\"" + address + "\",\"rev\":1}}";
                            streamSend(cmd_utxo.c_str(), cmd_utxo.length());
                        }
                        if (!addrInfos[nid_s][address]["utxonext"].empty()) {
                            ImGui::SameLine();
                            if (ImGui::Button("More")) {
                                std::string network_idx_s = std::to_string(network_idx);
                                std::string cmd_utxo = "{\"cmd\":\"utxo\",\"data\":{\"nid\":" +
                                                network_idx_s + ",\"addr\":\"" + address +
                                                "\",\"rev\":1,\"lte\":" + addrInfos[nid_s][address]["utxonext"].dump() + "}}";
                                streamSend(cmd_utxo.c_str(), cmd_utxo.length());
                                addrInfos[nid_s][address].erase("utxonext");
                            }
                            ImGui::SameLine();
                            if (ImGui::Button("All")) {
                                addrInfos[nid_s][address]["utxoload"] = true;
                                std::string network_idx_s = std::to_string(network_idx);
                                std::string cmd_utxo = "{\"cmd\":\"utxo\",\"data\":{\"nid\":" +
                                                network_idx_s + ",\"addr\":\"" + address +
                                                "\",\"rev\":1,\"lte\":" + addrInfos[nid_s][address]["utxonext"].dump() + "}}";
                                streamSend(cmd_utxo.c_str(), cmd_utxo.length());
                                addrInfos[nid_s][address].erase("utxonext");
                            }
                        }
                    }
                }
                ImGui::TreePop();
            }

            ImGui::SetNextItemOpen(true, ImGuiCond_Once);
            if (ImGui::TreeNode(("Transaction Logs##addrlog" + wid_s).c_str())) {
                if (addrInfos.find(nid_s) != addrInfos.end() &&
                    addrInfos[nid_s].find(address) != addrInfos[nid_s].end()) {
                    json& addrlogs = addrInfos[nid_s][address]["addrlogs"];
                    json& addrlogstbl = addrInfos[nid_s][address]["addrlogstbl"];
                    int load_count = addrlogs.size();
                    int table_count = addrlogstbl.size();
                    const float TEXT_BASE_HEIGHT = ImGui::GetTextLineHeightWithSpacing();
                    ImGui::PushFont(monoFont);
                    static ImGuiTableFlags flags = ImGuiTableFlags_SizingFixedFit | ImGuiTableFlags_RowBg |
                                            ImGuiTableFlags_Borders | ImGuiTableFlags_Resizable |
                                            ImGuiTableFlags_Reorderable | ImGuiTableFlags_Hideable |
                                            ImGuiTableFlags_ScrollX | ImGuiTableFlags_ScrollY;
                    ImVec2 outer_size = ImVec2(0.0f, TEXT_BASE_HEIGHT * 8);
                    if (ImGui::BeginTable("addrlogs", 7, flags, outer_size))
                    {
                        ImGui::TableSetupScrollFreeze(0, 1);
                        ImGui::TableSetupColumn("id", ImGuiTableColumnFlags_WidthFixed, 11 * 10.0f);
                        ImGui::TableSetupColumn("txid", ImGuiTableColumnFlags_WidthFixed, 65 * 10.0f);
                        ImGui::TableSetupColumn("trans", ImGuiTableColumnFlags_WidthFixed, 6 * 10.0f);
                        ImGui::TableSetupColumn("value", ImGuiTableColumnFlags_WidthFixed, 30 * 10.0f);
                        ImGui::TableSetupColumn("height", ImGuiTableColumnFlags_WidthFixed, 9 * 10.0f);
                        ImGui::TableSetupColumn("blktime", ImGuiTableColumnFlags_WidthFixed, 20 * 10.0f);
                        ImGui::TableSetupColumn("mined", ImGuiTableColumnFlags_WidthFixed, 6 * 10.0f);
                        ImGui::TableHeadersRow();

                        if (table_count > 0) {
                            ImGuiListClipper clipper;
                            clipper.Begin(table_count);
                            while (clipper.Step()) {
                                for (int row_n = clipper.DisplayStart; row_n < clipper.DisplayEnd; row_n++) {
                                    json el = addrlogstbl[row_n];
                                    ImGui::TableNextRow();
                                    ImGui::TableSetColumnIndex(0);
                                    ImGui::Text(std::to_string(el["id"].get<uint64_t>()).c_str());
                                    ImGui::TableSetColumnIndex(1);
                                    ImGui::Text(el["tx"].get<std::string>().c_str());
                                    ImGui::TableSetColumnIndex(2);
                                    int trans = el["trans"].get<int>();
                                    if (trans == 0) {
                                        ImGui::Text("out");
                                    } else {
                                        ImGui::Text("in");
                                    }
                                    ImGui::TableSetColumnIndex(3);
                                    ImGui::Text(convCoin(el["val"]).c_str());
                                    ImGui::TableSetColumnIndex(4);
                                    ImGui::Text(std::to_string(el["height"].get<int>()).c_str());
                                    ImGui::TableSetColumnIndex(5);
                                    ImGui::Text(getLocalTime(el["blktime"].get<int64_t>()).c_str());
                                    ImGui::TableSetColumnIndex(6);
                                    ImGui::Text(std::to_string(el["mined"].get<int>()).c_str());
                                }
                            }
                        }
                        ImGui::EndTable();
                    }
                    ImGui::PopFont();
                    if (addrInfos[nid_s][address]["addrlogload"].get<bool>()) {
                        if (ImGui::Button("Stop")) {
                            addrInfos[nid_s][address]["addrlogload"] = false;
                        }
                        ImGui::SameLine();
                        ImGui::PushFont(monoFont);
                        ImGui::Text(("downloading... " + std::to_string(load_count)).c_str());
                        ImGui::PopFont();
                    } else {
                        if (!addrInfos[nid_s][address]["addrlognext"].empty()) {
                            if (ImGui::Button("More")) {
                                std::string network_idx_s = std::to_string(network_idx);
                                std::string cmd_addrlog = "{\"cmd\":\"addrlog\",\"data\":{\"nid\":" +
                                                network_idx_s + ",\"addr\":\"" + address +
                                                "\",\"rev\":1,\"lte\":" + addrInfos[nid_s][address]["addrlognext"].dump() + "}}";
                                streamSend(cmd_addrlog.c_str(), cmd_addrlog.length());
                                addrInfos[nid_s][address].erase("addrlognext");
                            }
                            ImGui::SameLine();
                            if (ImGui::Button("All")) {
                                addrInfos[nid_s][address]["addrlogload"] = true;
                                std::string network_idx_s = std::to_string(network_idx);
                                std::string cmd_addrlog = "{\"cmd\":\"addrlog\",\"data\":{\"nid\":" +
                                                network_idx_s + ",\"addr\":\"" + address +
                                                "\",\"rev\":1,\"lte\":" + addrInfos[nid_s][address]["addrlognext"].dump() + "}}";
                                streamSend(cmd_addrlog.c_str(), cmd_addrlog.length());
                                addrInfos[nid_s][address].erase("addrlognext");
                            }
                        }
                    }
                }
                ImGui::TreePop();
            }
        } else {
            param["addropen"] = false;
            ImGui::PopFont();
        }
    }

    if (update) {
        update = false;
        std::string prev_address = param["prev_address"].get<std::string>();
        int prev_nid = param["prev_nid"].get<int>();
        std::string prev_nid_s = std::to_string(prev_nid);
        if (prev_address.length() > 0 && addrInfos.find(prev_nid_s) != addrInfos.end() &&
            addrInfos[prev_nid_s].find(prev_address) != addrInfos[prev_nid_s].end()) {
            if (addrInfos[prev_nid_s][prev_address]["ref_count"].get<int>() > 1) {
                addrInfos[prev_nid_s][prev_address]["ref_count"] = addrInfos[prev_nid_s][prev_address]["ref_count"].get<int>() - 1;
            } else {
                addrInfos[prev_nid_s].erase(prev_address);
                std::string s = "{\"cmd\":\"addr-off\",\"data\":{\"nid\":" +
                                std::to_string(prev_nid) + ",\"addr\":\"" + prev_address + "\"}}";
                streamSend(s.c_str(), s.length());
            }
            param["prev_address"] = "";
        }
        if (valid) {
            if (addrInfos.find(nid_s) == addrInfos.end()) {
                addrInfos[nid_s] = R"({})"_json;
            }
            if (addrInfos[nid_s].find(address) == addrInfos[nid_s].end()) {
                addrInfos[nid_s][address] =  R"({"sid": -1, "unused": -1, "val": 0, "utxo_count": 0, "addrlogs": {}, "addrlogstbl": [], "addrlogload": false, "utxos": {}, "utxostbl": [], "utxoload": false, "ref_count": 1})"_json;
                std::string s = "{\"cmd\":\"addr-on\",\"data\":{\"nid\":" +
                                nid_s + ",\"addr\":\"" + address + "\"}}";
                streamSend(s.c_str(), s.length());
                std::string cmd_utxo = "{\"cmd\":\"utxo\",\"data\":{\"nid\":" +
                                nid_s + ",\"addr\":\"" + address + "\",\"rev\":1}}";
                streamSend(cmd_utxo.c_str(), cmd_utxo.length());
            } else {
                addrInfos[nid_s][address]["ref_count"] = addrInfos[nid_s][address]["ref_count"].get<int>() + 1;
            }
            param["prev_address"] = address;
            param["prev_nid"] = network_idx;

            addr1 = get_address_from_hex(network_idx, (char*)address_hex.c_str(), P2PKH);
            addr3 = get_address_from_hex(network_idx, (char*)address_hex.c_str(), P2SH_P2WPKH);
            addr4 = get_address_from_hex(network_idx, (char*)address_hex.c_str(), P2WPKH);
            param["addr1"] = addr1;
            param["addr3"] = addr3;
            param["addr4"] = addr4;
        } else {
            param["addr1"] = "";
            param["addr3"] = "";
            param["addr4"] = "";
        }
    }

    while (!addrInfos["pending"].empty()) {
        auto ainfo = addrInfos["pending"].at(0);
        std::string addr = ainfo["addr"].get<std::string>();
        std::string ainfo_nid_s = std::to_string(ainfo["nid"].get<int>());
        if (addrInfos[ainfo_nid_s].find(addr) != addrInfos[ainfo_nid_s].end()) {
            if (ainfo.find("val") == ainfo.end()) {
                addrInfos[ainfo_nid_s][addr]["unused"] = 1;
            } else {
                addrInfos[ainfo_nid_s][addr]["unused"] = 0;
                addrInfos[ainfo_nid_s][addr]["val"] = ainfo["val"];
                addrInfos[ainfo_nid_s][addr]["utxo_count"] = ainfo["utxo_count"];

                if (addrInfos[ainfo_nid_s][addr].find("nextid") != addrInfos[ainfo_nid_s][addr].end()) {
                    uint64_t nextid = addrInfos[ainfo_nid_s][addr]["nextid"].get<uint64_t>();
                    std::string cmd_addrlog = "{\"cmd\":\"addrlog\",\"data\":{\"nid\":" +
                                    ainfo_nid_s + ",\"addr\":\"" + addr + "\",\"gte\":" + std::to_string(nextid) + "}}";
                    streamSend(cmd_addrlog.c_str(), cmd_addrlog.length());
                } else {
                    std::string cmd_addrlog = "{\"cmd\":\"addrlog\",\"data\":{\"nid\":" +
                                    ainfo_nid_s + ",\"addr\":\"" + addr + "\",\"rev\":1}}";
                    streamSend(cmd_addrlog.c_str(), cmd_addrlog.length());
                }
            }
        }
        addrInfos["pending"].erase(0);
    }

    bool utxo_update = true;
    if (!addrInfos["utxo_delta"].empty()) {
        float delta = addrInfos["utxo_delta"].get<float>();
        if (delta > 0.0) {
            addrInfos["utxo_delta"] = delta - io.DeltaTime;
            utxo_update = false;
        }
    }
    if (utxo_update) {
        addrInfos["utxo_delta"] = 0.3f;
        if (!addrInfos["utxo_pending"].empty()) {
            auto ainfo = addrInfos["utxo_pending"].at(0);
            std::string addr = ainfo["addr"].get<std::string>();
            std::string ainfo_nid_s = std::to_string(ainfo["nid"].get<int>());
            if (addrInfos[ainfo_nid_s].find(addr) != addrInfos[ainfo_nid_s].end()) {
                json& utxos = addrInfos[ainfo_nid_s][addr]["utxos"];
                for (auto& el : ainfo["utxos"]) {
                    utxos[std::to_string(el["id"].get<uint64_t>())] = el;
                }

                bool tableupdate = false;
                if (ainfo.find("next") != ainfo.end()) {
                    if (addrInfos[ainfo_nid_s][addr]["utxoload"]) {
                        std::string cmd_utxo = "{\"cmd\":\"utxo\",\"data\":{\"nid\":" +
                                        ainfo_nid_s + ",\"addr\":\"" + addr +
                                        "\",\"rev\":1,\"lte\":" + ainfo["next"].dump() + "}}";
                        streamSend(cmd_utxo.c_str(), cmd_utxo.length());
                        if (utxos.size() <= 1000) {
                            tableupdate = true;
                        }
                    } else {
                        addrInfos[ainfo_nid_s][addr]["utxonext"] = ainfo["next"];
                        tableupdate = true;
                    }
                } else {
                    tableupdate = true;
                    addrInfos[ainfo_nid_s][addr]["utxoload"] = false;
                }
                if (tableupdate) {
                    auto& table = addrInfos[ainfo_nid_s][addr]["utxostbl"];
                    table.clear();
                    for (auto& el : utxos.items()) {
                        table.push_back(el.value());
                    }
                    std::sort(table.begin(), table.end(), [](auto const& p1, auto const& p2) {
                        return p1["id"] > p2["id"];
                    });
                }
            }
            addrInfos["utxo_pending"].erase(0);
        }
    }

    bool addrlog_update = true;
    if (!addrInfos["addrlog_delta"].empty()) {
        float delta = addrInfos["addrlog_delta"].get<float>();
        if (delta > 0.0) {
            addrInfos["addrlog_delta"] = delta - io.DeltaTime;
            addrlog_update = false;
        }
    }
    if (addrlog_update) {
        addrInfos["addrlog_delta"] = 0.3f;
        if (!addrInfos["addrlog_pending"].empty()) {
            auto ainfo = addrInfos["addrlog_pending"].at(0);
            std::string addr = ainfo["addr"].get<std::string>();
            std::string ainfo_nid_s = std::to_string(ainfo["nid"].get<int>());
            if (addrInfos[ainfo_nid_s].find(addr) != addrInfos[ainfo_nid_s].end()) {
                json& addrlogs = addrInfos[ainfo_nid_s][addr]["addrlogs"];
                uint64_t latest_id = 0;
                for (auto& el : ainfo["addrlogs"]) {
                    uint64_t id = el["id"].get<uint64_t>();
                    addrlogs[std::to_string(id)] = el;
                    if (id > latest_id) {
                        latest_id = id;
                    }
                }
                if (latest_id == 0) {
                    addrInfos[ainfo_nid_s][addr]["nextid"] = 0;
                } else {
                    addrInfos[ainfo_nid_s][addr]["nextid"] = latest_id + 1;
                }

                bool tableupdate = false;
                if (ainfo.find("next") != ainfo.end()) {
                    if (addrInfos[ainfo_nid_s][addr]["addrlogload"]) {
                        std::string cmd_addrlog = "{\"cmd\":\"addrlog\",\"data\":{\"nid\":" +
                                        ainfo_nid_s + ",\"addr\":\"" + addr +
                                        "\",\"rev\":1,\"lte\":" + ainfo["next"].dump() + "}}";
                        streamSend(cmd_addrlog.c_str(), cmd_addrlog.length());
                        if (addrlogs.size() <= 1000) {
                            tableupdate = true;
                        }
                    } else {
                        addrInfos[ainfo_nid_s][addr]["addrlognext"] = ainfo["next"];
                        tableupdate = true;
                    }
                } else {
                    tableupdate = true;
                    addrInfos[ainfo_nid_s][addr]["addrlogload"] = false;
                }
                if (tableupdate) {
                    auto& table = addrInfos[ainfo_nid_s][addr]["addrlogstbl"];
                    table.clear();
                    for (auto& el : addrlogs.items()) {
                        table.push_back(el.value());
                    }
                    std::sort(table.begin(), table.end(), [](auto const& p1, auto const& p2) {
                        return p1["id"] > p2["id"];
                    });
                }
            }
            addrInfos["addrlog_pending"].erase(0);
        }
    }
    ImGui::End();
}

static void ShowTxWindow(bool* p_open, int wid)
{
    ImGuiIO& io = ImGui::GetIO();
    std::string wid_s = std::to_string(wid);
    json& param = winTx["windows"][wid_s];
    int network_idx = param["nid"].get<int>();
    std::string tx = param["tx"].get<std::string>();
    bool valid_tx = param["valid_tx"].get<bool>();
    std::string hash = param["tx"].get<std::string>();
    bool update = false;
    if (param["update"].get<bool>() && streamActive) {
        update = true;
        param["update"] = false;
    }
    std::string title;
    if (winTx["samewin"].get<bool>()) {
        title = "Transactions";
    } else {
        title = "Transaction - " + wid_s + "##tx" + wid_s;
    }
    ImGui::SetNextWindowSize(ImVec2(1167, 700), ImGuiCond_FirstUseEver);
    if (ImGui::Begin(title.c_str(), p_open)) {
        std::string header;
        if (hash.length() > 0) {
            header = hash + "##txh" + wid_s;
        } else {
            header = "Transaction##txh" + wid_s;
        }
        ImGui::PushFont(monoFont);
        ImGui::SetNextItemOpen(param["txopen"].get<bool>());
        if (ImGui::CollapsingHeader(header.c_str())) {
            param["txopen"] = true;
            ImGuiComboFlags comb_flags = 0;
            const char* combo_preview_value = NetworkIds[network_idx];
            ImGui::PushItemWidth(350);
            if (ImGui::BeginCombo("Network", combo_preview_value, comb_flags)) {
                for (int n = 0; n < IM_ARRAYSIZE(NetworkIds); n++) {
                    const bool is_selected = (network_idx == n);
                    if (ImGui::Selectable(NetworkIds[n], is_selected)) {
                        network_idx = n;
                        param["nid"] = network_idx;
                        param["prev_tx"] = "";
                        txInfos[wid_s].clear();
                        bool validhex = checkHexStr(hash);
                        if (validhex && hash.length() == 64) {
                            valid_tx = true;
                            if (streamActive) {
                                update = true;
                            } else {
                                param["update"] = true;
                            }
                        } else {
                            valid_tx = false;
                        }
                        param["valid_tx"] = valid_tx;
                    }
                    if (is_selected) {
                        ImGui::SetItemDefaultFocus();
                    }
                }
                ImGui::EndCombo();
            }
            ImGui::PopItemWidth();

            char tx_hash[134];
            copyString(hash, tx_hash, sizeof(tx_hash));
            ImGui::PushItemWidth(820.0f);
            if (ImGui::InputText(("Transaction ID (txid)##txid" + wid_s).c_str(), tx_hash, IM_ARRAYSIZE(tx_hash))) {
                std::string tx_str = std::string(tx_hash);
                hash = tx_str;
                param["tx"] = tx_str;
                bool validhex = checkHexStr(tx_str);
                if (validhex && tx_str.length() == 64) {
                    valid_tx = true;
                    txInfos[wid_s].clear();
                    if (streamActive) {
                        update = true;
                    } else {
                        param["update"] = true;
                    }
                } else {
                    valid_tx = false;
                }
                param["valid_tx"] = valid_tx;
            }
            ImGui::PopItemWidth();

            if (!valid_tx) {
                if (hash.length() > 0) {
                    ImGui::Text(("invalid txid \"" + hash + "\"").c_str());
                }
            } else if (!txInfos[wid_s].empty()) {
                int err = txInfos[wid_s]["err"].get<int>();
                if (err == 0) {
                    auto res = txInfos[wid_s]["res"];
                    ImGui::SetNextItemOpen(true, ImGuiCond_Once);
                    if (ImGui::TreeNode(("inputs##ins" + wid_s).c_str())) {
                        if (res["ins"].size() > 0) {
                            for (auto& el : res["ins"]) {
                                int count = el["count"].get<int>();
                                if (count > 1) {
                                    ImGui::Text((el["addr"].get<std::string>() + "(" + std::to_string(count) + ") " +
                                                convCoin(el["val"])).c_str());
                                } else {
                                    ImGui::Text((el["addr"].get<std::string>() + " " +
                                                convCoin(el["val"])).c_str());
                                }
                            }
                        } else {
                            ImGui::Text("coinbase");
                        }
                        ImGui::TreePop();
                    }
                    ImGui::SetNextItemOpen(true, ImGuiCond_Once);
                    if (ImGui::TreeNode(("outputs##outs" + wid_s).c_str())) {
                        if (res["outs"].size() > 0) {
                            for (auto& el : res["outs"]) {
                                int count = el["count"].get<int>();
                                if (count > 1) {
                                    ImGui::Text((el["addr"].get<std::string>() + "(" + std::to_string(count) + ") " +
                                                convCoin(el["val"])).c_str());
                                } else {
                                    ImGui::Text((el["addr"].get<std::string>() + " " +
                                                convCoin(el["val"])).c_str());
                                }
                            }
                        } else {
                            ImGui::Text("none");
                        }
                        ImGui::TreePop();
                    }
                    ImGui::Text(("fee: " + convCoin(res["fee"])).c_str());
                    if (!res["height"].empty()) {
                        int height = res["height"].get<int>();
                        ImGui::Text(("height: " + std::to_string(height)).c_str());
                        ImGui::Text(("time: " + getLocalTime(res["time"].get<int64_t>())).c_str());
                        ImGui::Text(("sequence id: " + std::to_string(res["id"].get<uint64_t>())).c_str());
                        param["height"] = height;
                    } else {
                        ImGui::Text("This transaction is not yet in the block");
                        param["height"] = -1;
                    }
                } else if (err = 2) {
                    ImGui::Text("txid is not found");
                } else {
                    ImGui::Text("error");
                }
            }
        } else {
            param["txopen"] = false;
        }
        ImGui::PopFont();
    }
    if (update && valid_tx) {
        std::string s = "{\"cmd\":\"tx\",\"data\":{\"nid\":" + std::to_string(network_idx) +
                        ",\"txid\":\"" + hash + "\"},\"ref\":\"" + wid_s + "\"}";
        streamSend(s.c_str(), s.length());
    }
    while (!txInfos["pending"].empty()) {
        auto tx = txInfos["pending"].at(0);
        txInfos[tx["ref"].get<std::string>()] = tx["data"];
        txInfos["pending"].erase(0);
    }
    ImGui::End();
}

static void ShowBlockWindow(bool* p_open, int wid)
{
    ImGuiIO& io = ImGui::GetIO();
    std::string wid_s = std::to_string(wid);
    json& param = winBlock["windows"][wid_s];
    int network_idx = param["nid"].get<int>();
    std::string network_idx_s = std::to_string(network_idx);
    if (nodeStatus[network_idx_s].empty() || nodeStatus[network_idx_s]["height"].empty()) {
        return;
    }
    int height = param["height"].get<int>();
    int max_height = nodeStatus[network_idx_s]["height"].get<int>();
    std::string title = "Block - " + wid_s + "##blk" + wid_s;
    ImGui::SetNextWindowSize(ImVec2(1167, 700), ImGuiCond_FirstUseEver);
    if (ImGui::Begin(title.c_str(), p_open)) {
        if (height > max_height) {
            height = max_height;
            param["height"] = height;
        }
        int org_height = height;
        int height_gap = param["height_gap"].get<int>();
        ImGuiComboFlags comb_flags = 0;
        const char* combo_preview_value = NetworkIds[network_idx];
        ImGui::PushFont(monoFont);
        ImGui::PushItemWidth(350);
        if (ImGui::BeginCombo("Network", combo_preview_value, comb_flags)) {
            for (int n = 0; n < IM_ARRAYSIZE(NetworkIds); n++) {
                const bool is_selected = (network_idx == n);
                if (ImGui::Selectable(NetworkIds[n], is_selected)) {
                    network_idx = n;
                    param["nid"] = network_idx;
                    param["prev_height"] = -1;
                }
                if (is_selected) {
                    ImGui::SetItemDefaultFocus();
                }
            }
            ImGui::EndCombo();
        }
        ImGui::PopItemWidth();
        ImGui::DragInt("Height", &height, 0.5f, 0, max_height, "%d", ImGuiSliderFlags_None);
        ImGui::SameLine(); HelpMarker("Drag to move left or right or double-click to input the value directly.");
        ImGui::SliderInt("##blkslider", &height, 0, max_height, "%d", ImGuiSliderFlags_None);
        param["height"] = height;
        if (org_height != height && height_gap != 0) {
            height_gap = 0;
            param["height_gap"] = 0;
        }
        char blk_hash[257];
        std::string hash = param["hash"].get<std::string>();
        copyString(hash, blk_hash, sizeof(blk_hash));
        ImGui::InputText("Block Hash##blkh", blk_hash, IM_ARRAYSIZE(blk_hash), ImGuiInputTextFlags_ReadOnly);

        //ImGui::SameLine(); ImGui::LabelText("##labelbh", "Block Hash");
        //ImGui::PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0.0f);
        bool height_update = param["prev_height"].get<int>() != height;
        static ImGuiTableFlags flags = ImGuiTableFlags_SizingFixedFit | ImGuiTableFlags_RowBg |
                                        ImGuiTableFlags_Borders | ImGuiTableFlags_Resizable |
                                        ImGuiTableFlags_Reorderable | ImGuiTableFlags_Hideable;
        if (ImGui::BeginTable("blocks", 3, flags))
        {
            ImGui::TableSetupColumn("Height", ImGuiTableColumnFlags_WidthFixed, 9 * 10.0f);
            ImGui::TableSetupColumn("Block Hash", ImGuiTableColumnFlags_WidthFixed, 65 * 10.0f);
            ImGui::TableSetupColumn("Time", ImGuiTableColumnFlags_WidthStretch, 20 * 10.0f);
            ImGui::TableHeadersRow();

            if (!blkInfos[wid_s].empty()) {
                param["hash"] = "";
                int pos = 0;
                for (auto& el : blkInfos[wid_s]["blocks"]) {
                    ImGui::TableNextRow();
                    ImGui::TableSetColumnIndex(0);
                    std::string hash_str = trimQuote(el["hash"].dump());
                    int cur_height = el["height"].get<int>();
                    bool item_is_selected;
                    if (height_gap == 0 && height + 10 < max_height) {
                        if (pos == 10) {
                            item_is_selected = true;
                            param["hash"] = hash_str;
                        } else {
                            item_is_selected = false;
                        }
                        pos++;
                    } else {
                        if (height == cur_height) {
                            item_is_selected = true;
                            param["hash"] = hash_str;
                        } else {
                            item_is_selected = false;
                        }
                    }

                    ImGuiSelectableFlags selectable_flags = ImGuiSelectableFlags_SpanAllColumns | ImGuiSelectableFlags_AllowItemOverlap;
                    if (ImGui::Selectable(std::to_string(cur_height).c_str(), item_is_selected, selectable_flags, ImVec2(0, 0.0f))) {
                        height_gap = height_gap + height - cur_height;
                        param["height_gap"] = height_gap;
                        param["height"] = cur_height;
                    }
                    ImGui::TableSetColumnIndex(1);
                    ImGui::Text(trimQuote(el["hash"].dump()).c_str());
                    ImGui::TableSetColumnIndex(2);
                    ImGui::Text(getLocalTime(el["time"].get<int64_t>()).c_str());
                }
            }
            ImGui::EndTable();
        }
        ImGui::PopFont();

        if (height_update) {
            float delta = param["delta"].get<float>();
            if (delta <= 0.0) {
                param["prev_height"] = height;
                param["delta"] = 0.06f;
                std::string s = "{\"cmd\":\"block\",\"data\":{\"nid\":" + network_idx_s + ", \"height\":" +
                                std::to_string(height + 10 + height_gap) + ",  \"limit\":21}, \"ref\":\"" + wid_s + "\"}";
                streamSend(s.c_str(), s.length());
            } else {
                param["delta"] = delta - io.DeltaTime;
            }
        }
    }
    while (!blkInfos["pending"].empty()) {
        auto blk = blkInfos["pending"].at(0);
        blkInfos[blk["ref"].get<std::string>()] = blk["data"];
        blkInfos["pending"].erase(0);
    }
    ImGui::End();
}

static void CheckHeightAndRollback()
{
    while (!heightInfos["pending"].empty()) {
        auto hinfo = heightInfos["pending"].at(0);
        int nid = hinfo["nid"].get<int>();
        std::string nid_s = std::to_string(nid);
        if (heightInfos.find(nid_s) != heightInfos.end()) {
            int64_t prev_height = heightInfos[nid_s]["height"];
            int64_t height = hinfo["height"].get<int64_t>();
            if (height <= prev_height) {
                std::cout << "rollback prev=" << std::to_string(prev_height) << " " << hinfo.dump() << std::endl;
                uint64_t sid = hinfo["sid"].get<uint64_t>();
                if (addrInfos.find(nid_s) != addrInfos.end()) {
                    for (auto& el : addrInfos[nid_s].items()) {
                        std::cout << el.key() << std::endl;
                        auto& ainfo = addrInfos[nid_s][el.key()];
                        if (ainfo.find("addrlogs") != ainfo.end()) {
                            ainfo["addrlogsdel"] = R"([])"_json;
                            for (auto& el : ainfo["addrlogs"]) {
                                if (el["id"].get<uint64_t>() >= sid) {
                                    ainfo["addrlogsdel"].push_back(std::to_string(el["id"].get<uint64_t>()));
                                }
                            }
                            for (auto& el : ainfo["addrlogsdel"]) {
                                ainfo["addrlogs"].erase(el.get<std::string>());
                            }
                            ainfo.erase("addrlogsdel");
                        }

                        while (!ainfo["addrlogstbl"].empty()) {
                            auto& table = ainfo["addrlogstbl"].at(0);
                            if (table["id"].get<uint64_t>() >= sid) {
                                ainfo["addrlogstbl"].erase(0);
                                continue;
                            }
                            break;
                        }
                        ainfo["nextid"] = sid;
                    }
                    std::cout << addrInfos.dump() << std::endl;
                }

            }
        }
        heightInfos[nid_s] = hinfo;
        heightInfos["pending"].erase(0);
    }
}

static void ShowTotpWindow(bool* p_open)
{
    static int digit = 6;
    static int timestep = 30;
    static int algo = 0;
    static std::string key_s = "";
    static std::string totp_s = "";
    static uint64_t epochTime;
    static float delta = 0;

    ImGui::SetNextWindowSize(ImVec2(820, 220), ImGuiCond_FirstUseEver);
    if (ImGui::Begin("TOTP", p_open)) {
        bool update = false;
        if (ImGui::SliderInt("Digits", &digit, 1, 8)) {
            if (digit < 1) {
                digit = 1;
            } else if (digit > 8) {
                digit = 8;
            }
            update = true;
        }
        ImGui::SameLine(); HelpMarker("CTRL+click to input value.");
        if (ImGui::InputInt("Time step (sec)", &timestep)) {
            update = true;
        }
        if (ImGui::Combo("Algorithm", &algo, "SHA1\0SHA256\0SHA512\0\0")) {
            update = true;
        }
        char key_str[257];
        copyString(key_s, key_str, sizeof(key_str));
        if (ImGui::InputText("Key (base32)", key_str, IM_ARRAYSIZE(key_str))) {
            key_s = std::string(key_str);
            update = true;
        }
        if ((update || delta <= 0) && key_s.length() > 0) {
            epochTime = (uint64_t)EM_ASM_INT({
                return Math.floor((new Date).getTime() / 1000);
            });
            totp_s = std::string(call_totp(key_str, epochTime, digit, timestep, algo));
            delta = 1.0f;
        } else {
            ImGuiIO& io = ImGui::GetIO();
            delta = delta - io.DeltaTime;
        }
        ImGui::Text("TOTP:");
        if (key_s.length() > 0) {
            ImGui::SameLine();
            ImGui::Text(totp_s.c_str());
            ImGui::Text("Expire:");
            ImGui::SameLine();
            ImGui::Text(std::to_string(timestep - epochTime % timestep).c_str());
        }
    }
    ImGui::End();
}

static void ShowQrreaderWindow(bool* p_open, bool reset = false)
{
    static zbar_image_scanner_t *scanner = nullptr;
    static zbar_image_t *image = nullptr;
    static int prev_width = -1;
    static int prev_height = -1;
    static std::string qr_results = "";

    if (reset) {
        if (image == nullptr) {
            zbar_image_destroy(image);
        }
        if (scanner == nullptr) {
            zbar_image_scanner_destroy(scanner);
        }
        prev_width = -1;
        prev_height = -1;
        qr_results = "";
        return;
    }

    ImGui::SetNextWindowSize(ImVec2(820, 760), ImGuiCond_FirstUseEver);
    if (ImGui::Begin("QR Reader", p_open)) {
        if (ImGui::Button("Change Camera")) {
            EM_ASM({ deoxy.next(); });
        }

        void* videodata = nullptr;
        videodata = (char*)EM_ASM_INT({
            var video = deoxy.qrvideo;
            if (video) {
                var canvas = deoxy.qrcanvas;
                var ctx = canvas.getContext('2d');
                if(video.readyState === video.HAVE_ENOUGH_DATA) {
                    canvas.height = video.videoHeight;
                    canvas.width = video.videoWidth;
                    ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
                    var image = ctx.getImageData(0, 0, canvas.width, canvas.height);
                    var grayData = [];
                    var d = image.data;
                    for(var i = 0, j = 0; i < d.length; i += 4, j++) {
                      grayData[j] = (d[i] * 66 + d[i + 1] * 129 + d[i + 2] * 25 + 4096) >> 8;
                    }
                    var rect8 = new Uint8Array((new Uint32Array([image.width, image.height])).buffer);
                    var imagedata = new Uint8Array(rect8.length + image.width * image.height * 4 + image.width * image.height);
                    imagedata.set(rect8);
                    imagedata.set(image.data, rect8.length);
                    imagedata.set(grayData, rect8.length + image.width * image.height * 4);
                    var buf = deoxy.malloc(imagedata.length);
                    HEAPU8.set(imagedata, buf);
                    return buf;
                } else{
                    return 0;
                }
            } else {
                return 0;
            }
        });
        if (videodata != nullptr) {
            static GLuint image_texture;
            static bool initTexture = false;
            if (!initTexture) {
                glGenTextures(1, &image_texture); // WARNING: Do not call every time
                glBindTexture(GL_TEXTURE_2D, image_texture);
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
#if defined(GL_UNPACK_ROW_LENGTH) && !defined(__EMSCRIPTEN__)
                glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
#endif
                initTexture = true;
            }
            int width = *(uint32_t *)videodata;
            int height = *((uint32_t *)videodata + 1);
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, (uint8_t *)videodata + 8);
            uint8_t *raw = (uint8_t *)videodata + 8 + width * height * 4;

            if (scanner == nullptr) {
                scanner = zbar_image_scanner_create();
                zbar_image_scanner_set_config(scanner, (zbar_symbol_type_t)0, ZBAR_CFG_X_DENSITY, 1);
                zbar_image_scanner_set_config(scanner, (zbar_symbol_type_t)0, ZBAR_CFG_Y_DENSITY, 1);
            }
            if (prev_width != width || prev_height != height) {
                if (image != nullptr) {
                    zbar_image_destroy(image);
                }
                image = zbar_image_create();
                zbar_image_set_format(image, zbar_fourcc('Y', '8', '0', '0'));
                zbar_image_set_size(image, width, height);
                prev_width = width;
                prev_height = height;
            }
            zbar_image_set_data(image, raw, width * height, nullptr);
            int n = zbar_scan_image(scanner, image);

            const zbar_symbol_t *symbol = zbar_image_first_symbol(image);
            for(; symbol; symbol = zbar_symbol_next(symbol)) {
                zbar_symbol_type_t typ = zbar_symbol_get_type(symbol);
                const char *data = zbar_symbol_get_data(symbol);
                unsigned poly_size = zbar_symbol_get_loc_size(symbol);
                int poly[poly_size * 2];
                unsigned u = 0;
                for(unsigned p = 0; p < poly_size; p++) {
                    poly[u] = zbar_symbol_get_loc_x(symbol, p);
                    poly[u + 1] = zbar_symbol_get_loc_y(symbol, p);
                    u += 2;
                }

                qr_results = std::string(data) + "\n" + qr_results;
                if (qr_results.length() >= 512 * 8) {
                    qr_results = qr_results.substr(0, 512 * 8 - 1);
                    qr_results = qr_results.substr(0, qr_results.find_last_of("\n"));
                }
            }

            ImGui::Image((ImTextureID)(intptr_t)image_texture, ImVec2(640, 480));
            free(videodata);

            char qr_str[512 * 8];
            copyString(qr_results, qr_str, sizeof(qr_str));
            ImGui::InputTextMultiline("##qrresult", qr_str, IM_ARRAYSIZE(qr_str),
                ImVec2(-FLT_MIN, ImGui::GetTextLineHeight() * 8),
                ImGuiInputTextFlags_ReadOnly | ImGuiInputTextFlags_AllowTabInput);

        }
    }
    ImGui::End();
}

EM_JS(void, set_mining_data, (const char* data), {
    var workers = deoxy.miningWorkers;
    if(workers) {
        var miningData = JSON.parse(UTF8ToString(data));
        var nonce = Math.floor(Math.random() * 4294967296);
        var step = Math.round(4294967296 / workers.length);
        for(var i = 0; i < workers.length; i++) {
            var worker = workers[i];
            miningData.nonce = nonce;
            worker.postMessage(miningData);
            nonce += step;
        }
    }
});

EM_JS(void, set_worker, (void* stream), {
    deoxy.miningWorkers = deoxy.miningWorkers || [];
    deoxy.miningStatus = deoxy.miningStatus || {};
    var workers = deoxy.miningWorkers;
    var cpuCount = navigator.hardwareConcurrency || 2;
    if(workers.length == 0) {
        for(var i = 0; i < cpuCount; i++) {
            var worker = new Worker("miner.js");
            workers.push(worker);
        }
        var i = 0;
        for(let worker of workers) {
            worker.id = i;
            i++;
            worker.onmessage = function(e) {
                if(e.data["cmd"] == "find") {
                    deoxy.cmdSend(stream, e.data);
                } else if(e.data["cmd"] == "status") {
                    deoxy.miningStatus[worker.id] = e.data["data"];
                }
            };
        }
    }
});

EM_JS(void, remove_worker, (), {
    deoxy.miningWorkers = deoxy.miningWorkers || [];
    var workers = deoxy.miningWorkers;
    for(let worker of workers) {
        worker.terminate();
    }
    deoxy.miningWorkers = [];
    deoxy.miningStatus = {};
});

EM_JS(int, get_miners_num, (), {
    if(deoxy.miningWorkers) {
        return deoxy.miningWorkers.length;
    }
    return 0;
});

EM_JS(int, get_miners_hashrate, (), {
    if(deoxy.miningStatus) {
        var count = 0;
        for(i in deoxy.miningStatus) {
            count += deoxy.miningStatus[i];
        }
        return Math.round(count);
    } else {
        return 0;
    }
});

static void ShowMiningWindow(bool* p_open)
{
    static bool mining_start = false;
    static int mining_nid = -1;

    json& param = winMining;
    std::string address = param["address"].get<std::string>();
    std::string address_hex = param["address_hex"].get<std::string>();
    bool valid = param["valid"].get<bool>();
    int network_idx = param["nid"].get<int>();

    ImGui::SetNextWindowSize(ImVec2(820, 220), ImGuiCond_FirstUseEver);
    if (ImGui::Begin("Mining", p_open)) {
        ImGuiComboFlags comb_flags = 0;
        const char* combo_value = NetworkIds[network_idx];
        ImGui::PushItemWidth(350);
        if (ImGui::BeginCombo("Network##m", combo_value, comb_flags)) {
            for (int n = 0; n < IM_ARRAYSIZE(NetworkIds); n++) {
                const bool is_selected = (network_idx == n);
                if (ImGui::Selectable(NetworkIds[n], is_selected)) {
                    network_idx = n;
                    param["nid"] = network_idx;
                    MarkSettingsDirty();
                }
                if (is_selected) {
                    ImGui::SetItemDefaultFocus();
                }
            }
            ImGui::EndCombo();
        }
        ImGui::PopItemWidth();

        char address_str[257];
        copyString(address, address_str, sizeof(address_str));
        ImGui::PushItemWidth(544.0f);
        ImGui::PushFont(monoFont);
        if (ImGui::InputText("Address##m", address_str, IM_ARRAYSIZE(address_str))) {
            address = std::string(address_str);
            address_hex = get_hash160_hex(network_idx, address_str);
            param["address"] = address;
            param["address_hex"] = address_hex;
            if (address_hex.length() > 0) {
                valid = true;
            } else {
                valid = false;
            }
            param["valid"] = valid;
            MarkSettingsDirty();
        }
        ImGui::PopFont();
        ImGui::PopItemWidth();

        if (ImGui::Button("Start")) {
            if (valid) {
                if (mining_start) {
                    std::string mining_nid_s = std::to_string(mining_nid);
                    std::string s = "{\"cmd\":\"mining-off\",\"data\":{\"nid\":" + mining_nid_s + "}}";
                    streamSend(s.c_str(), s.length());
                } else {
                    mining_start = true;
                }
                mining_nid = network_idx;
                set_worker(stream);
                std::string network_idx_s = std::to_string(network_idx);
                std::string s = "{\"cmd\":\"mining-on\",\"data\":{\"nid\":" + network_idx_s + ",\"addr\":\"" + address + "\"}}";
                streamSend(s.c_str(), s.length());

            }
        }
        ImGui::SameLine();
        if (ImGui::Button("Stop")) {
            if (mining_start) {
                mining_start = false;
                std::string mining_nid_s = std::to_string(mining_nid);
                std::string s = "{\"cmd\":\"mining-off\",\"data\":{\"nid\":" + mining_nid_s + "}}";
                streamSend(s.c_str(), s.length());
                remove_worker();
            }
        }

        static float miner_status_delta = 3.0f;
        static int miners_num = 0;
        static int miners_hashrate = 0;
        if (miner_status_delta > 0.0) {
            ImGuiIO& io = ImGui::GetIO();
            miner_status_delta -= io.DeltaTime;
        } else {
            miners_num = get_miners_num();
            miners_hashrate = get_miners_hashrate();
            miner_status_delta = 3.0f;
        }
        ImGui::Text("Workers:");
        ImGui::SameLine();
        ImGui::Text(std::to_string(miners_num).c_str());
        ImGui::Text("Hashrate:");
        ImGui::SameLine();
        ImGui::Text(std::to_string(miners_hashrate).c_str());
        ImGui::SameLine();
        ImGui::Text("H/s");
    }
    while (!miningInfos["pending"].empty()) {
        auto miningData = miningInfos["pending"].at(0);
        miningInfos["pending"].erase(0);
        std::string data = miningData.dump();
        set_mining_data(data.c_str());
    }
    ImGui::End();
}

static void main_loop(void *arg)
{
    IM_UNUSED(arg);
    static bool main_called = false;
    if (main_called) {
        return;
    }
    main_called = true;
    ImGuiIO& io = ImGui::GetIO();

    static bool show_demo_window = false;
    static bool show_connect_status_overlay = true;
    static bool show_framerate_overlay = false;
    static bool show_nora_servers_window = false;
    static bool show_same_address_window = false;
    static bool show_same_transaction_window = false;
    static bool show_totp_window = false;
    static bool show_qrreader_window = false;
    static bool show_mining_window = false;
    static ImVec4 clear_color = ImVec4(0.45f, 0.55f, 0.60f, 1.00f);

    SDL_Event event;
    while (SDL_PollEvent(&event))
    {
        ImGui_ImplSDL2_ProcessEvent(&event);
    }

    if (loadSettingsFlag) {
        loadSettingsFlag = false;
        winBip44 = db_get_json("winBip44");
        winAddress = db_get_json("winAddress");
        winTools = db_get_json("winTools");
        winTx = db_get_json("winTx");
        winBlock = db_get_json("winBlock");
        winTotp = db_get_json("winTotp");
        winQrreader = db_get_json("winQrreader");
        winMining = db_get_json("winMining");
        std::string settings = db_get_string("settings");
        ImGui::LoadIniSettingsFromMemory(settings.c_str(), settings.length());
        if (winTools.find("nora_chk") != winTools.end()) {
            show_nora_servers_window = winTools["nora_chk"].get<bool>();
        }
        if (winTools.find("connect_chk") != winTools.end()) {
            show_connect_status_overlay = winTools["connect_chk"].get<bool>();
        }
        if (winTools.find("frate_chk") != winTools.end()) {
            show_framerate_overlay = winTools["frate_chk"].get<bool>();
        }
        if (winTools.find("demo_chk") != winTools.end()) {
            show_demo_window = winTools["demo_chk"].get<bool>();
        }
        if (winTotp.find("totp_chk") != winTotp.end()) {
            show_totp_window = winTotp["totp_chk"].get<bool>();
        }
        if (winQrreader.find("qrreader_chk") != winQrreader.end()) {
            show_qrreader_window = winQrreader["qrreader_chk"].get<bool>();
        }
        if (winMining.find("mining_chk") != winMining.end()) {
            show_mining_window = winMining["mining_chk"].get<bool>();
        } else {

        }
        if (winAddress.find("samewin") != winAddress.end()) {
            show_same_address_window = winAddress["samewin"].get<bool>();
        }
        if (winTx.find("samewin") != winTx.end()) {
            show_same_transaction_window = winTx["samewin"].get<bool>();
        }
        for (auto& el : winAddress["windows"].items()) {
            winAddress["windows"][el.key()]["update"] = true;
        }
        for (auto& el : winTx["windows"].items()) {
            winTx["windows"][el.key()]["update"] = true;
        }
        for (auto& el : winBlock["windows"].items()) {
            winBlock["windows"][el.key()]["prev_height"] = -1;
        }
    }
    if (CheckSettingsDirty(io) || io.WantSaveIniSettings) {
        std::cout << "save" << std::endl;
        dirtySettingsFlag = false;
        io.WantSaveIniSettings = false;
        db_set("winBip44", winBip44.dump().c_str());
        db_set("winAddress", winAddress.dump().c_str());
        db_set("winTools", winTools.dump().c_str());
        db_set("winTx", winTx.dump().c_str());
        db_set("winBlock", winBlock.dump().c_str());
        db_set("winTotp", winTotp.dump().c_str());
        db_set("winQrreader", winQrreader.dump().c_str());
        db_set("winMining", winMining.dump().c_str());
        size_t out_size;
        const char* s = ImGui::SaveIniSettingsToMemory(&out_size);
        std::string settings(s, out_size);
        db_set("settings", settings.c_str());
    }

    ImGui_ImplOpenGL3_NewFrame();
    ImGui_ImplSDL2_NewFrame();
    ImGui::NewFrame();

    if(show_demo_window) {
        ImGui::ShowDemoWindow(&show_demo_window);
        winTools["demo_chk"] = show_demo_window;
    }
    if (show_connect_status_overlay) {
        ShowConnectStatusOverlay(&show_connect_status_overlay);
    }
    if (show_framerate_overlay) {
        ShowFramerateOverlay(&show_framerate_overlay);
    }

    {
        static bool firstCommandRequested = false;
        if (streamActive) {
            if (!firstCommandRequested) {
                {
                    std::string s = "{\"cmd\": \"noralist\"}";
                    streamSend(s.c_str(), s.length());
                }
                {
                    std::string s = "{\"cmd\": \"status-on\"}";
                    streamSend(s.c_str(), s.length());
                }
                {
                    std::string s = "{\"cmd\": \"height-on\"}";
                    streamSend(s.c_str(), s.length());
                }
                firstCommandRequested = true;
            }
        }
    }

    CheckHeightAndRollback();

    ImVec2 toolPos;
    ImVec2 toolSize;
    ImGui::SetNextWindowPos(ImVec2(0, 0), ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowSize(ImVec2(260, 520), ImGuiCond_FirstUseEver);
    if (ImGui::Begin("Tools", nullptr)) {
        if (ImGui::Checkbox("Nora Servers", &show_nora_servers_window)) {
            winTools["nora_chk"] = show_nora_servers_window;
            MarkSettingsDirty();
        }
        if (ImGui::Button("Address")) {
            if (winAddress["wid"].empty()) {
                winAddress = R"({"wid": 0, "windows": {}, "del": [], "samewin": false})"_json;
            }
            int wid = winAddress["wid"].get<int>() + 1;
            winAddress["wid"] = wid;
            winAddress["windows"][std::to_string(wid)] = R"({"nid": 0, "prev_nid": 0, "address": "", "prev_address": "", "address_hex": "", "valid": false, "addr1": "", "addr3": "", "addr4": "", "addropen": true, "update": false})"_json;
        }
        ImGui::SameLine();
        if (ImGui::Button("Transaction")) {
            if (winTx["wid"].empty()) {
                winTx = R"({"wid": 0, "windows": {}, "del": [], "samewin": false})"_json;
            }
            int wid = winTx["wid"].get<int>() + 1;
            winTx["wid"] = wid;
            winTx["windows"][std::to_string(wid)] = R"({"nid": 0, "tx": "", "prev_tx": "", "valid_tx": false, "update": false, "txopen": true, "height": -1})"_json;
        }
        if (ImGui::Button("Block")) {
            if (winBlock["wid"].empty()) {
                winBlock = R"({"wid": 0, "windows": {}, "del": []})"_json;
            }
            int wid = winBlock["wid"].get<int>() + 1;
            winBlock["wid"] = wid;
            winBlock["windows"][std::to_string(wid)] = R"({"nid": 0, "height": 0, "prev_height": -1, "delta": 0, "height_gap": 0, "hash": ""})"_json;
            if (!nodeStatus["0"].empty() && !nodeStatus["0"]["height"].empty()) {
                winBlock["windows"][std::to_string(wid)]["height"] = nodeStatus["0"]["height"];
            }
        }
        ImGui::SameLine();
        if (ImGui::Button("BIP44")) {
            if (winBip44["wid"].empty()) {
                winBip44 = R"({"wid": 0, "windows": {}, "del": []})"_json;
            }
            int wid = winBip44["wid"].get<int>() + 1;
            winBip44["wid"] = wid;
            winBip44["windows"][std::to_string(wid)] = R"({"nid": 0, "testnet": false, "prev_testnet": false, "seed": "", "prev_seed": "", "xprv": "", "xpub": "", "animate": false, "progress": 0, "b44p": 44, "b44c": 123, "b44a": 0, "bip44update": false, "bip44_0": [], "bip44_1": [], "bip44xprv": "", "bip44xpub": "", "bip44_idx0": 0, "bip44_idx1": 0, "seedbit": 1, "seedvalid": false, "seederr": false})"_json;
        }
        ImGui::Separator();
        ImGui::SetNextItemOpen(true, ImGuiCond_Once);
        if (ImGui::TreeNode("Extra apps")) {
            if (ImGui::Checkbox("Mining", &show_mining_window)) {
                if (winMining.empty()) {
                    winMining = R"({"nid": 0, "address": "", "address_hex": "", "valid": false, "mining_chk": false})"_json;
                }
                winMining["mining_chk"] = show_mining_window;
                MarkSettingsDirty();
            }
            if (ImGui::Checkbox("TOTP", &show_totp_window)) {
                winTotp["totp_chk"] = show_totp_window;
                MarkSettingsDirty();
            }
            if (ImGui::Checkbox("QR Reader", &show_qrreader_window)) {
                winQrreader["qrreader_chk"] = show_qrreader_window;
                MarkSettingsDirty();
            }
            ImGui::TreePop();
        }
        ImGui::Separator();
        ImGui::SetNextItemOpen(true, ImGuiCond_Once);
        if (ImGui::TreeNode("Window positions")) {
            if (ImGui::Button("Save")) {
                dirtySettingsFlag = true;
            }
            ImGui::SameLine();
            if (ImGui::Button("Reset")) {
                db_clear();
                EM_ASM({
                    location.reload();
                });
            }
            ImGui::TreePop();
        }
        ImGui::Separator();
        ImGui::SetNextItemOpen(true, ImGuiCond_Once);
        if (ImGui::TreeNode("Combine windows")) {
            if (ImGui::Checkbox("Address", &show_same_address_window)) {
                winAddress["samewin"] = show_same_address_window;
                MarkSettingsDirty();
            }
            if (ImGui::Checkbox("Transaction", &show_same_transaction_window)) {
                winTx["samewin"] = show_same_transaction_window;
                MarkSettingsDirty();
            }
            ImGui::TreePop();
        }
        ImGui::Separator();
        ImGui::SetNextItemOpen(true, ImGuiCond_Once);
        if (ImGui::TreeNode("Test")) {
            if (ImGui::Checkbox("Connection status", &show_connect_status_overlay)) {
                winTools["connect_chk"] = show_connect_status_overlay;
                MarkSettingsDirty();
            }
            if (ImGui::Checkbox("Frame rate", &show_framerate_overlay)) {
                winTools["frate_chk"] = show_framerate_overlay;
                MarkSettingsDirty();
            }
            if (ImGui::Checkbox("ImGui Demo", &show_demo_window)) {
                winTools["demo_chk"] = show_demo_window;
                MarkSettingsDirty();
            }
            ImGui::TreePop();
        }
        toolSize = ImGui::GetWindowSize();
        toolPos = ImGui::GetWindowPos();
    }
    ImGui::End();

    if (show_nora_servers_window) {
        ImGui::SetNextWindowPos(ImVec2(toolPos.x + toolSize.x, toolPos.y), ImGuiCond_FirstUseEver);
        ImGui::SetNextWindowSize(ImVec2(820, 350), ImGuiCond_FirstUseEver);
        if (ImGui::Begin("Nora Servers", &show_nora_servers_window)) {
            ImGui::PushFont(monoFont);
            if (noraList.size() > 0) {
                int node_id = 0;
                for (auto& node : noraList) {
                    std::string node_s = node.get<std::string>();
                    ImGui::SetNextItemOpen(true, ImGuiCond_Once);
                    if (ImGui::CollapsingHeader(node_s.c_str())) {
                        auto status = nodeStatus[std::to_string(node_id)];
                        if (!status.empty()) {
                            if (!status["blkTime"].empty()) {
                                int64_t tval = status["blkTime"].get<int64_t>();
                                std::string blkTimeStr = "Block Time: " + getLocalTime(tval);
                                ImGui::Text(blkTimeStr.c_str());
                            }
                            if (!status["hash"].empty()) {
                                std::string hashStr = "Hash: " + status["hash"].get<std::string>();
                                ImGui::Text(hashStr.c_str());
                            }
                            if (!status["height"].empty()) {
                                if (!status["lastHeight"].empty()) {
                                    int64_t height = status["height"].get<int64_t>();
                                    int64_t last_height = status["lastHeight"].get<int64_t>();
                                    std::string heightStr = "Height: " +
                                        std::to_string(height) + " / " +
                                        std::to_string(last_height);
                                    ImGui::Text(heightStr.c_str());
                                    if (last_height > 0) {
                                        float progress = static_cast<double>(height) / static_cast<double>(last_height);
                                        if (height < last_height && progress > 0.994f) {
                                            progress = 0.994f;
                                        }
                                        ImGui::ProgressBar(progress, ImVec2(0.0f, 0.0f));
                                        ImGui::SameLine(0.0f, ImGui::GetStyle().ItemInnerSpacing.x);
                                        if (height == last_height) {
                                            ImGui::Text("Synced");
                                        } else {
                                            ImGui::Text("Syncing");
                                        }
                                    } else {
                                        ImGui::ProgressBar(0.0f, ImVec2(0.0f, 0.0f));
                                        ImGui::SameLine(0.0f, ImGui::GetStyle().ItemInnerSpacing.x);
                                        ImGui::Text("Not syncing");
                                    }
                                } else {
                                    std::string heightStr = "Height: " +
                                        std::to_string(status["height"].get<int64_t>());
                                    ImGui::Text(heightStr.c_str());
                                }

                            }
                        }
                    }
                    node_id++;
                }
            }
            ImGui::PopFont();
        }
        winTools["nora_chk"] = show_nora_servers_window;
        ImGui::End();
    }

    if(show_mining_window) {
        ShowMiningWindow(&show_mining_window);
        winMining["mining_chk"] = show_mining_window;
    }

    if(show_totp_window) {
        ShowTotpWindow(&show_totp_window);
        winTotp["totp_chk"] = show_totp_window;
    }

    static bool prev_qrreader_show = false;
    if(show_qrreader_window) {
        if (!prev_qrreader_show) {
            EM_ASM({
                deoxy.qrstart();
            });
            prev_qrreader_show = show_qrreader_window;
        }
        ShowQrreaderWindow(&show_qrreader_window);
        winQrreader["qrreader_chk"] = show_qrreader_window;
    } else {
        if (prev_qrreader_show) {
            ShowQrreaderWindow(&show_qrreader_window, true);
            EM_ASM({
                deoxy.qrstop();
            });
            prev_qrreader_show = show_qrreader_window;
        }
    }

    for (auto& el : winBip44["windows"].items()) {
        int wid = std::stoi(el.key());
        bool flag = true;
        ShowBip44Window(&flag, wid);
        if (!flag) {
            winBip44["del"].push_back(el.key());
        }
    }
    for (auto& el : winBip44["del"]) {
        winBip44["windows"].erase(el.get<std::string>());
    }
    winBip44["del"].clear();

    for (auto& el : winAddress["windows"].items()) {
        int wid = std::stoi(el.key());
        bool flag = true;
        ShowAddressWindow(&flag, wid);
        if (!flag) {
            winAddress["del"].push_back(el.key());
        }
    }
    for (auto& el : winAddress["del"]) {
        std::string key = el.get<std::string>();
        json& param = winAddress["windows"][el.get<std::string>()];
        std::string prev_address = param["prev_address"].get<std::string>();
        std::string prev_nid_s = std::to_string(param["prev_nid"].get<int>());
        if (prev_address.length() > 0 && addrInfos.find(prev_nid_s) != addrInfos.end() &&
            addrInfos[prev_nid_s].find(prev_address) != addrInfos[prev_nid_s].end()) {
            if (addrInfos[prev_nid_s][prev_address]["ref_count"].get<int>() > 1) {
                addrInfos[prev_nid_s][prev_address]["ref_count"] = addrInfos[prev_nid_s][prev_address]["ref_count"].get<int>() - 1;
            } else {
                addrInfos[prev_nid_s].erase(prev_address);
                std::string s = "{\"cmd\":\"addr-off\",\"data\":{\"nid\":" + prev_nid_s +
                                ",\"addr\":\"" + prev_address + "\"}}";
                streamSend(s.c_str(), s.length());
            }
            param["prev_address"] = "";
        }
        winAddress["windows"].erase(key);
    }
    winAddress["del"].clear();

    for (auto& el : winTx["windows"].items()) {
        int wid = std::stoi(el.key());
        bool flag = true;
        ShowTxWindow(&flag, wid);
        if (!flag) {
            winTx["del"].push_back(el.key());
        }
    }
    for (auto& el : winTx["del"]) {
        winTx["windows"].erase(el.get<std::string>());
    }
    winTx["del"].clear();

    for (auto& el : winBlock["windows"].items()) {
        int wid = std::stoi(el.key());
        bool flag = true;
        ShowBlockWindow(&flag, wid);
        if (!flag) {
            winBlock["del"].push_back(el.key());
        }
    }
    for (auto& el : winBlock["del"]) {
        winBlock["windows"].erase(el.get<std::string>());
    }
    winBlock["del"].clear();

    ImGui::Render();
    SDL_GL_MakeCurrent(g_Window, g_GLContext);
    glViewport(0, 0, (int)io.DisplaySize.x, (int)io.DisplaySize.y);
    glClearColor(clear_color.x * clear_color.w, clear_color.y * clear_color.w, clear_color.z * clear_color.w, clear_color.w);
    glClear(GL_COLOR_BUFFER_BIT);
    ImGui_ImplOpenGL3_RenderDrawData(ImGui::GetDrawData());
    SDL_GL_SwapWindow(g_Window);
    main_called = false;
}

static const char* GetClipboardTextFn_Impl(ImGuiContext*)
{
    static std::string cliptext;

    char* clipchar = NULL;
    clipchar = (char*)EM_ASM_INT({
        var clipboard = deoxy.clipboard;
        clipboard.focus();
        clipboard.select();
        document.execCommand('paste');
        var s = clipboard.value.slice();
        var len = lengthBytesUTF8(s) + 1;
        var buf = _malloc(len);
        stringToUTF8(s, buf, len);
        return buf;
    });
    if (clipchar != NULL) {
        cliptext = std::string(clipchar);
        free(clipchar);

        return cliptext.c_str();
    }

    return NULL;
}

static void SetClipboardTextFn_Impl(ImGuiContext*, const char* text)
{
    EM_ASM({
        var clipboard = deoxy.clipboard;
        clipboard.value = UTF8ToString($0);
        clipboard.focus();
        clipboard.select();
        document.execCommand('copy');
    }, text);
}

extern "C" int guimain()
{
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_TIMER | SDL_INIT_GAMECONTROLLER) != 0)
    {
        std::string err = "Error: " + std::string(SDL_GetError());
        uiError(err.c_str());
        return -1;
    }

    SDL_GL_SetAttribute(SDL_GL_CONTEXT_FLAGS, 0);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_ES);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 2);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 0);
    SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
    SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 24);
    SDL_GL_SetAttribute(SDL_GL_STENCIL_SIZE, 8);
    SDL_DisplayMode current;
    SDL_GetCurrentDisplayMode(0, &current);
    SDL_WindowFlags window_flags = (SDL_WindowFlags)(SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI);
    g_Window = SDL_CreateWindow("blockstor - a block explorer for wallet", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, 1280, 720, window_flags);
    g_GLContext = SDL_GL_CreateContext(g_Window);
    if (!g_GLContext)
    {
        uiError("Failed to initialize WebGL context");
        return -1;
    }
    //SDL_GL_SetSwapInterval(1);

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO(); (void)io;

    io.IniFilename = NULL;
    io.ConfigInputTextCursorBlink = true;
    io.ConfigWindowsResizeFromEdges = true;
    io.ConfigFlags |= ImGuiConfigFlags_DockingEnable;

    ImGui::StyleColorsDark();

    ImGui_ImplSDL2_InitForOpenGL(g_Window, g_GLContext);
    const char* glsl_version = "#version 100";
    ImGui_ImplOpenGL3_Init(glsl_version);

    static const ImWchar icons_ranges[] = { 0xe600, 0xe75f, 0 };
    ImFontConfig font_config;
    font_config.MergeMode = true;
    mainFont = io.Fonts->AddFontFromFileTTF("spleen-32x64.otf", 20.0f);
    io.Fonts->AddFontFromFileTTF("Corporate-Logo-Medium-ver3.otf", 20.0f, &font_config, io.Fonts->GetGlyphRangesJapanese());
    io.Fonts->AddFontFromFileTTF("themify.ttf", 16.0f, &font_config, icons_ranges);
    iconFont = mainFont;
    monoFont = mainFont;

    ImGuiPlatformIO& platform_io = ImGui::GetPlatformIO();
    platform_io.Platform_GetClipboardTextFn = GetClipboardTextFn_Impl;
    platform_io.Platform_SetClipboardTextFn = SetClipboardTextFn_Impl;

    EM_ASM({
        var clipboard = document.getElementById('clipboard');
        if(!clipboard) {
            clipboard = document.createElement('textarea');
            clipboard.setAttribute('id', 'clipboard');
            clipboard.setAttribute('raws', 1);
            clipboard.setAttribute('tabindex', -1);
            clipboard.setAttribute('spellcheck', false);
            clipboard.setAttribute('readyOnly', '');
            document.body.appendChild(clipboard);
        }
        clipboard.focus();
        document.execCommand('paste');  // workaround first take
        deoxy.clipboard = clipboard;

        document.addEventListener("paste", function(e) {
          if(e.clipboardData) {
            clipboard.value = e.clipboardData.getData("text");
          }
        });

        var camDevice = (function() {
          var cam_ids = [];
          var sel_cam = null;
          var sel_cam_index = 0;
          if(navigator.mediaDevices) {
            navigator.mediaDevices.enumerateDevices().then(function(devices) {
              devices.forEach(function(device) {
                if(device.kind == 'videoinput') {
                  cam_ids.push(device);
                }
              });
            });
          }
          return {
            set_current: function(deviceId) {
              var new_cam_index = 0;
              for(var i in cam_ids) {
                if(deviceId == cam_ids[i].deviceId) {
                  new_cam_index = i;
                  break;
                }
              }
              sel_cam_index = new_cam_index;
              sel_cam = cam_ids[sel_cam_index].deviceId;
            },
            next: function() {
              if(cam_ids.length > 0) {
                if(sel_cam == null) {
                  sel_cam_index = cam_ids.length - 1;
                  sel_cam = cam_ids[sel_cam_index].deviceId;
                } else {
                  sel_cam_index++;
                  if(sel_cam_index >= cam_ids.length) {
                    sel_cam_index = 0;
                  }
                  sel_cam = cam_ids[sel_cam_index].deviceId;
                }
              }
              return sel_cam;
            },
            count: function() {
              return cam_ids.length;
            }
          };
        })();

        var current_deviceId = null;
        deoxy.qrstart = function() {
            deoxy.qrvideo = document.createElement("video");
            deoxy.qrcanvas = document.createElement("canvas");
            var constraints;
            if(!current_deviceId) {
                constraints = {video: {facingMode: "environment"}};
            } else {
                constraints = {video: {deviceId: current_deviceId}};
            }
            navigator.mediaDevices.getUserMedia(constraints).then((stream) => {
                if(!current_deviceId) {
                    var envcam;
                    stream.getTracks().forEach(function(track) {
                        envcam = track.getSettings().deviceId;
                        return true;
                    });
                    if(envcam) {
                        camDevice.set_current(envcam);
                    }
                }
                deoxy.qrvideo.srcObject = stream;
                deoxy.qrvideo.setAttribute("playsinline", true);
                deoxy.qrvideo.play();
            }).catch((e) => {
                throw e;
            });
        };

        deoxy.qrstop = function() {
            deoxy.qrvideo.pause();
            if(deoxy.qrvideo.srcObject) {
                deoxy.qrvideo.srcObject.getTracks().forEach(function(track) {
                    track.stop();
                });
            }
            deoxy.qrvideo.removeAttribute('src');
            deoxy.qrvideo.load();
        };

        deoxy.next = function() {
            deoxy.qrstop();
            current_deviceId = camDevice.next();
            deoxy.qrstart();
        };
    });

    bip32_init();
    address_init();
    emscripten_set_main_loop_arg(main_loop, NULL, 0, true);

    return 0;
}
