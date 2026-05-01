#define UNICODE
#define _UNICODE
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX

#include <windows.h>
#include <objidl.h>
#include <propidl.h>
#include <shellapi.h>
#include <gdiplus.h>

#include <cwchar>
#include <iterator>
#include <string>

#pragma comment(lib, "Gdiplus.lib")
#pragma comment(lib, "Shell32.lib")
#pragma comment(lib, "User32.lib")

namespace {

constexpr wchar_t kWindowClass[] = L"UsbipTrayLauncherWindow";
constexpr wchar_t kMutexName[] = L"Local\\UsbipTrayLauncher";
constexpr wchar_t kMonitorExe[] = L"usbip_monitor.exe";
constexpr wchar_t kTooltip[] = L"USB/IP Monitor";
constexpr UINT kTrayId = 1;
constexpr UINT kTrayCallback = WM_APP + 1;
constexpr UINT kMenuOpen = 1001;
constexpr UINT kMenuExit = 1002;

UINT g_taskbarCreated = 0;
HICON g_icon = nullptr;
ULONG_PTR g_gdiplusToken = 0;
NOTIFYICONDATAW g_nid = {};

std::wstring ExeDirectory() {
    wchar_t path[MAX_PATH] = {};
    GetModuleFileNameW(nullptr, path, MAX_PATH);
    std::wstring value(path);
    size_t slash = value.find_last_of(L"\\/");
    if (slash == std::wstring::npos) {
        return L".";
    }
    return value.substr(0, slash);
}

std::wstring MonitorPath() {
    return ExeDirectory() + L"\\" + kMonitorExe;
}

HICON CreateUsbIcon() {
    using namespace Gdiplus;

    Bitmap bitmap(32, 32, PixelFormat32bppARGB);
    Graphics graphics(&bitmap);
    graphics.SetSmoothingMode(SmoothingModeAntiAlias);
    graphics.Clear(Color(0, 0, 0, 0));

    SolidBrush background(Color(255, 21, 101, 192));
    graphics.FillRectangle(&background, 0, 0, 32, 32);

    Pen white(Color(255, 255, 255, 255), 2.2f);
    white.SetStartCap(LineCapRound);
    white.SetEndCap(LineCapRound);

    graphics.DrawLine(&white, 16, 5, 16, 20);
    graphics.DrawLine(&white, 10, 13, 22, 13);
    graphics.DrawLine(&white, 10, 13, 10, 19);
    graphics.DrawLine(&white, 22, 13, 22, 19);

    SolidBrush dot(Color(255, 255, 255, 255));
    graphics.FillEllipse(&dot, 13, 2, 6, 6);
    graphics.FillEllipse(&dot, 7, 18, 6, 6);
    graphics.FillEllipse(&dot, 19, 18, 6, 6);

    HICON icon = nullptr;
    bitmap.GetHICON(&icon);
    return icon;
}

BOOL CALLBACK FindMonitorWindowProc(HWND hwnd, LPARAM lParam) {
    if (!IsWindowVisible(hwnd)) {
        return TRUE;
    }

    DWORD processId = 0;
    GetWindowThreadProcessId(hwnd, &processId);
    if (processId == 0) {
        return TRUE;
    }

    wchar_t title[256] = {};
    GetWindowTextW(hwnd, title, static_cast<int>(std::size(title)));
    if (wcsstr(title, L"USB/IP Monitor") == nullptr) {
        return TRUE;
    }

    *reinterpret_cast<HWND*>(lParam) = hwnd;
    return FALSE;
}

HWND FindMonitorWindow() {
    HWND found = nullptr;
    EnumWindows(FindMonitorWindowProc, reinterpret_cast<LPARAM>(&found));
    return found;
}

void FocusMonitorWindow(HWND hwnd) {
    if (!hwnd) {
        return;
    }
    ShowWindow(hwnd, SW_RESTORE);
    SetForegroundWindow(hwnd);
}

void OpenMonitor() {
    HWND existing = FindMonitorWindow();
    if (existing) {
        FocusMonitorWindow(existing);
        return;
    }

    std::wstring exe = MonitorPath();
    std::wstring directory = ExeDirectory();
    STARTUPINFOW startup = {};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION process = {};

    std::wstring commandLine = L"\"" + exe + L"\"";
    if (CreateProcessW(exe.c_str(), commandLine.data(), nullptr, nullptr, FALSE, 0,
                       nullptr, directory.c_str(), &startup, &process)) {
        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
    }
}

void AddTrayIcon(HWND hwnd) {
    if (!g_icon) {
        g_icon = CreateUsbIcon();
    }

    ZeroMemory(&g_nid, sizeof(g_nid));
    g_nid.cbSize = sizeof(g_nid);
    g_nid.hWnd = hwnd;
    g_nid.uID = kTrayId;
    g_nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    g_nid.uCallbackMessage = kTrayCallback;
    g_nid.hIcon = g_icon;
    wcscpy_s(g_nid.szTip, kTooltip);

    Shell_NotifyIconW(NIM_ADD, &g_nid);
    g_nid.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIconW(NIM_SETVERSION, &g_nid);
}

void RemoveTrayIcon() {
    if (g_nid.hWnd) {
        Shell_NotifyIconW(NIM_DELETE, &g_nid);
        ZeroMemory(&g_nid, sizeof(g_nid));
    }
}

void ShowContextMenu(HWND hwnd) {
    HMENU menu = CreatePopupMenu();
    AppendMenuW(menu, MF_STRING, kMenuOpen, L"Abrir monitor");
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING, kMenuExit, L"Sair do icone");

    POINT cursor = {};
    GetCursorPos(&cursor);
    SetForegroundWindow(hwnd);
    TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_BOTTOMALIGN | TPM_LEFTALIGN,
                   cursor.x, cursor.y, 0, hwnd, nullptr);
    DestroyMenu(menu);
}

LRESULT CALLBACK WndProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
    if (message == g_taskbarCreated) {
        AddTrayIcon(hwnd);
        return 0;
    }

    switch (message) {
    case WM_CREATE:
        AddTrayIcon(hwnd);
        return 0;

    case kTrayCallback:
        if (LOWORD(lParam) == WM_LBUTTONUP || LOWORD(lParam) == WM_LBUTTONDBLCLK) {
            OpenMonitor();
        } else if (LOWORD(lParam) == WM_RBUTTONUP || LOWORD(lParam) == WM_CONTEXTMENU) {
            ShowContextMenu(hwnd);
        }
        return 0;

    case WM_COMMAND:
        if (LOWORD(wParam) == kMenuOpen) {
            OpenMonitor();
        } else if (LOWORD(wParam) == kMenuExit) {
            DestroyWindow(hwnd);
        }
        return 0;

    case WM_DESTROY:
        RemoveTrayIcon();
        PostQuitMessage(0);
        return 0;

    default:
        return DefWindowProcW(hwnd, message, wParam, lParam);
    }
}

} // namespace

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int) {
    HANDLE mutex = CreateMutexW(nullptr, FALSE, kMutexName);
    if (!mutex || GetLastError() == ERROR_ALREADY_EXISTS) {
        return 0;
    }

    Gdiplus::GdiplusStartupInput gdiplusInput;
    if (Gdiplus::GdiplusStartup(&g_gdiplusToken, &gdiplusInput, nullptr) != Gdiplus::Ok) {
        return 1;
    }

    g_taskbarCreated = RegisterWindowMessageW(L"TaskbarCreated");

    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = WndProc;
    wc.hInstance = instance;
    wc.lpszClassName = kWindowClass;
    RegisterClassExW(&wc);

    HWND hwnd = CreateWindowExW(0, kWindowClass, L"USB/IP Tray Launcher",
                               0, 0, 0, 0, 0, nullptr,
                               nullptr, instance, nullptr);
    if (!hwnd) {
        Gdiplus::GdiplusShutdown(g_gdiplusToken);
        return 1;
    }

    MSG msg = {};
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    if (g_icon) {
        DestroyIcon(g_icon);
    }
    Gdiplus::GdiplusShutdown(g_gdiplusToken);
    if (mutex) {
        CloseHandle(mutex);
    }
    return 0;
}
