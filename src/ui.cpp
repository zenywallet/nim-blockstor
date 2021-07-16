// Copyright (c) 2021 zenywallet

#include "imgui.h"
#include "imgui_impl_sdl.h"
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

using json = nlohmann::json;

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

extern "C" bool streamActive;

extern "C" void uiError(const char* msg);

extern "C" bool streamSend(const char* data, int size);

extern "C" void streamRecv(char* data, int size) {
    EM_ASM({
        var d = new Uint8Array(Module.HEAPU8.buffer, $0, $1).slice();
    }, data, size);

    std::string s(data, size);
    auto j = json::parse(s);
    if (j["type"] == "noralist") {
        noraList = j["data"];
    } else if(j["type"] == "status") {
        auto data = j["data"];
        nodeStatus[data["network"].get<std::string>()] = data;
    }
}

#define HDNodeHandle void*
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

static void ShowBip44Window(bool* p_open, int wid)
{
    ImGuiIO& io = ImGui::GetIO();
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
            static float seedBitWidth[3] = {622.0, 1236.0, 2462.0};
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
                        io.SetClipboardTextFn(NULL, seed_str);
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
                    io.SetClipboardTextFn(NULL, base58char);
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
                    io.SetClipboardTextFn(NULL, xprv.c_str());
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
                    io.SetClipboardTextFn(NULL, xpub.c_str());
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
            ImGui::PushItemWidth(120);
            if (ImGui::InputInt("purpose'", &lp)) {
                if (lp < 0) lp = 0;
                if (lp > 65535) lp = 65535;
            }
            ImGui::SameLine();
            ImGui::PopItemWidth();
            ImGui::Text("/"); ImGui::SameLine();
            ImGui::PushItemWidth(120);
            if (ImGui::InputInt("coin_type'", &lc)) {
                if (lc < 0) lc = 0;
                if (lc > 65535) lc = 65535;
            }
            ImGui::SameLine();
            ImGui::PopItemWidth();
            ImGui::Text("/"); ImGui::SameLine();
            ImGui::PushItemWidth(120);
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
                    io.SetClipboardTextFn(NULL, bip44xprv.c_str());
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
                    io.SetClipboardTextFn(NULL, bip44xpub.c_str());
                }
                ImGui::TreePop();
                ImGui::Separator();
            }
        }

        ImGui::SetNextItemOpen(true, ImGuiCond_Once);
        if (ImGui::CollapsingHeader("Addresses")) {
            ImGuiComboFlags comb_flags = 0;
            const char* items[] = {"BitZeny_mainnet", "BitZeny_testnet"};
            const bool items_testnet[] = {false, true};
            const char* combo_preview_value = items[network_idx];
            ImGui::PushItemWidth(300);
            if (ImGui::BeginCombo("Network", combo_preview_value, comb_flags)) {
                for (int n = 0; n < IM_ARRAYSIZE(items); n++) {
                    const bool is_selected = (network_idx == n);
                    if (ImGui::Selectable(items[n], is_selected)) {
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
                                io.SetClipboardTextFn(NULL, address.c_str());
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
                                io.SetClipboardTextFn(NULL, address.c_str());
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

static void main_loop(void *arg)
{
    IM_UNUSED(arg);
    ImGuiIO& io = ImGui::GetIO();

    static bool show_demo_window = false;
    static bool show_connect_status_overlay = true;
    static bool show_framerate_overlay = true;
    static bool show_nora_servers_window = false;
    static ImVec4 clear_color = ImVec4(0.45f, 0.55f, 0.60f, 1.00f);

    SDL_Event event;
    while (SDL_PollEvent(&event))
    {
        ImGui_ImplSDL2_ProcessEvent(&event);
    }

    ImGui_ImplOpenGL3_NewFrame();
    ImGui_ImplSDL2_NewFrame(g_Window);
    ImGui::NewFrame();

    if(show_demo_window) {
        ImGui::ShowDemoWindow(&show_demo_window);
    }
    if (show_connect_status_overlay) {
        ShowConnectStatusOverlay(&show_connect_status_overlay);
    }
    if (show_framerate_overlay) {
        ShowFramerateOverlay(&show_framerate_overlay);
    }


    {
        static bool noralistRequested = false;
        static bool statusOnRequested = false;
        static bool statusRequested = false;

        if (streamActive) {
            if (!noralistRequested) {
                std::string s = "{\"cmd\": \"noralist\"}";
                streamSend(s.c_str(), s.length());
                noralistRequested = true;
            }
            if (!statusOnRequested) {
                std::string s = "{\"cmd\": \"status-on\"}";
                streamSend(s.c_str(), s.length());
                statusOnRequested = true;
            }
            if (!statusRequested) {
                std::string s = "{\"cmd\": \"status\"}";
                streamSend(s.c_str(), s.length());
                statusRequested = true;
            }
        }
    }

    ImVec2 toolPos;
    ImVec2 toolSize;
    ImGui::SetNextWindowPos(ImVec2(0, 0), ImGuiCond_Once);
    if (ImGui::Begin("Tools", nullptr, ImGuiWindowFlags_NoResize)) {
        ImGui::Checkbox("Nora Servers", &show_nora_servers_window);
        if (ImGui::Button("BIP44")) {
            if (winBip44["wid"].empty()) {
                winBip44 = R"({"wid": 0, "windows": {}, "del": []})"_json;
            }
            int wid = winBip44["wid"].get<int>() + 1;
            winBip44["wid"] = wid;
            winBip44["windows"][std::to_string(wid)] = R"({"nid": 0, "testnet": false, "prev_testnet": false, "seed": "", "prev_seed": "", "xprv": "", "xpub": "", "animate": false, "progress": 0, "b44p": 44, "b44c": 123, "b44a": 0, "bip44update": false, "bip44_0": [], "bip44_1": [], "bip44xprv": "", "bip44xpub": "", "bip44_idx0": 0, "bip44_idx1": 0, "seedbit": 1, "seedvalid": false, "seederr": false})"_json;
        }
        ImGui::Separator();
        ImGui::Checkbox("Connection status", &show_connect_status_overlay);
        ImGui::Checkbox("Frame rate", &show_framerate_overlay);
        ImGui::Separator();
        ImGui::Checkbox("ImGui Demo", &show_demo_window);
        toolSize = ImGui::GetWindowSize();
        toolPos = ImGui::GetWindowPos();
    }
    ImGui::End();

    if (show_nora_servers_window) {
        ImGui::SetNextWindowPos(ImVec2(toolPos.x + toolSize.x, toolPos.y), ImGuiCond_Once);
        ImGui::SetNextWindowSize(ImVec2(700, 350), ImGuiCond_FirstUseEver);
        if (ImGui::Begin("Nora Servers", &show_nora_servers_window)) {
            ImGui::PushFont(monoFont);
            if (noraList.size() > 0) {
                for (auto& node : noraList) {
                    std::string node_s = node.get<std::string>();
                    ImGui::SetNextItemOpen(true, ImGuiCond_Once);
                    if (ImGui::CollapsingHeader(node_s.c_str())) {
                        auto status = nodeStatus[node_s];
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
                }
            }
            ImGui::PopFont();
        }
        ImGui::End();
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

    ImGui::Render();
    SDL_GL_MakeCurrent(g_Window, g_GLContext);
    glViewport(0, 0, (int)io.DisplaySize.x, (int)io.DisplaySize.y);
    glClearColor(clear_color.x * clear_color.w, clear_color.y * clear_color.w, clear_color.z * clear_color.w, clear_color.w);
    glClear(GL_COLOR_BUFFER_BIT);
    ImGui_ImplOpenGL3_RenderDrawData(ImGui::GetDrawData());
    SDL_GL_SwapWindow(g_Window);
}

static const char* GetClipboardTextFn_Impl(void* user_data)
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

static void SetClipboardTextFn_Impl(void* user_data, const char* text)
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
    SDL_GL_SetSwapInterval(1);

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
    ImFontConfig icons_config;
    icons_config.MergeMode = true;
    mainFont = io.Fonts->AddFontFromFileTTF("Play-Regular.ttf", 20.0f);
    iconFont = io.Fonts->AddFontFromFileTTF("themify.ttf", 16.0f, &icons_config, icons_ranges);
    monoFont = io.Fonts->AddFontFromFileTTF("ShareTechMono-Regular.ttf", 20.0f);
    io.GetClipboardTextFn = GetClipboardTextFn_Impl;
    io.SetClipboardTextFn = SetClipboardTextFn_Impl;

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
    });

    emscripten_set_main_loop_arg(main_loop, NULL, 0, true);

    return 0;
}
