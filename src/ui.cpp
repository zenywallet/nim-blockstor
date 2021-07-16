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
        ImGui::Checkbox("Connection status", &show_connect_status_overlay);
        ImGui::Checkbox("Frame rate", &show_framerate_overlay);
        ImGui::Separator();
        ImGui::Checkbox("ImGui Demo", &show_demo_window);
        toolSize = ImGui::GetWindowSize();
        toolPos = ImGui::GetWindowPos();
        ImGui::End();
    }

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
