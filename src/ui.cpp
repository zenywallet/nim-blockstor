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

using json = nlohmann::json;

SDL_Window*     g_Window = NULL;
SDL_GLContext   g_GLContext = NULL;
ImFont* mainFont = NULL;
ImFont* monoFont = NULL;

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

static void ShowConnectStatusOverlay(bool* p_open)
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
    if (ImGui::Begin("Connect status", p_open, window_flags))
    {
        if (streamActive) {
            ImGui::Text("Connected");

        } else {
            ImGui::Text("Disconnected");
        }

    }
    auto framerate = ImGui::GetIO().Framerate;
    ImGui::Text("%.3f ms / %.1f FPS", 1000.0f / framerate, framerate);
    ImGui::End();
}

static void main_loop(void *arg)
{
    IM_UNUSED(arg);
    ImGuiIO& io = ImGui::GetIO();

    static bool show_demo_window = true;
    static bool show_connect_status_overlay = true;
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

        ImGui::SetNextWindowSize(ImVec2(400, 500), ImGuiCond_FirstUseEver);
        ImGui::Begin("Nora Servers");
        ImGui::PushFont(monoFont);
        if (noraList.size() > 0) {
            for (auto& node : noraList) {
                std::string node_s = node.get<std::string>();
                ImGui::SetNextItemOpen(true, ImGuiCond_Once);
                if (ImGui::CollapsingHeader(node_s.c_str())) {
                    auto status = nodeStatus[node_s];
                    if (!status.empty()) {
                        for (auto& el : status.items()) {
                            std::string s = el.key() + ": " + el.value().dump();
                            ImGui::Text(s.c_str());
                        }
                    }
                }
            }
        }
        ImGui::PopFont();
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

    ImGui::StyleColorsDark();

    ImGui_ImplSDL2_InitForOpenGL(g_Window, g_GLContext);
    const char* glsl_version = "#version 100";
    ImGui_ImplOpenGL3_Init(glsl_version);

    mainFont = io.Fonts->AddFontFromFileTTF("Play-Regular.ttf", 20.0f);
    monoFont = io.Fonts->AddFontFromFileTTF("ShareTechMono-Regular.ttf", 20.0f);

    emscripten_set_main_loop_arg(main_loop, NULL, 0, true);
    return 0;
}
