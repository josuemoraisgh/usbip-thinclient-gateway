#define UNICODE
#define _UNICODE
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cctype>
#include <cstdio>
#include <fstream>
#include <map>
#include <mutex>
#include <regex>
#include <set>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#pragma comment(lib, "Advapi32.lib")
#pragma comment(lib, "Ws2_32.lib")

namespace {

constexpr wchar_t kServiceName[] = L"UsbipBrokerCpp";
constexpr wchar_t kDisplayName[] = L"USB/IP Broker C++";

struct DeviceRule {
    std::string vid;
    std::string pid;
};

struct RemoteDevice {
    std::string host;
    std::string busid;
    std::string vid;
    std::string pid;
    std::string description;
};

struct PnpDevice {
    std::string className;
    std::string friendlyName;
    std::string instanceId;
    std::string status;
};

struct WinUsbRule {
    std::string name;
    std::string description;
    std::string pattern;
    std::wstring driverInf;
};

struct Config {
    std::wstring usbipPath = L"C:\\usbip\\usbip.exe";
    std::wstring logPath = L"C:\\ProgramData\\UsbipBrokerCpp\\logs\\broker.log";
    std::wstring statePath = L"C:\\ProgramData\\UsbipBrokerCpp\\state.txt";
    std::wstring auditLogPath = L"C:\\ProgramData\\UsbipBrokerCpp\\logs\\audit.csv";
    std::vector<std::string> thinClients;
    std::vector<DeviceRule> allowedDevices;
    std::vector<DeviceRule> blockedDevices;
    std::string attachPolicy = "allowlist";
    int pollIntervalSeconds = 5;
    int commandTimeoutSeconds = 25;
    int attachRetryCount = 3;
    int attachRetryDelaySeconds = 2;
    bool eventListenerEnabled = true;
    int eventPort = 12000;
    bool winUsbEnabled = false;
    std::wstring winUsbDefaultDriverInf;
    int winUsbSettleSeconds = 3;
    int winUsbRetryCount = 2;
    std::vector<WinUsbRule> winUsbRules;
    // Mapa IP -> nome da estacao (ex: "192.168.100.31" -> "Estacao-01")
    std::map<std::string, std::string> stationNames;
};

SERVICE_STATUS_HANDLE g_statusHandle = nullptr;
SERVICE_STATUS g_status = {};
std::atomic<bool> g_stopRequested(false);
std::mutex g_logMutex;
std::mutex g_winUsbMutex;
std::set<std::string> g_winUsbApplied;
std::set<std::string> g_auditWritten;

std::wstring GetExecutableDirectory() {
    wchar_t buffer[MAX_PATH] = {};
    GetModuleFileNameW(nullptr, buffer, MAX_PATH);
    std::wstring path(buffer);
    size_t slash = path.find_last_of(L"\\/");
    if (slash == std::wstring::npos) {
        return L".";
    }
    return path.substr(0, slash);
}

std::wstring DefaultConfigPath() {
    return L"C:\\ProgramData\\UsbipBrokerCpp\\config.ini";
}

void EnsureDirectoryForFile(const std::wstring& path) {
    size_t slash = path.find_last_of(L"\\/");
    if (slash == std::wstring::npos) {
        return;
    }
    std::wstring directory = path.substr(0, slash);
    std::wstring current;
    for (wchar_t ch : directory) {
        current.push_back(ch);
        if (ch == L'\\' || ch == L'/') {
            if (current.size() > 3) {
                CreateDirectoryW(current.c_str(), nullptr);
            }
        }
    }
    CreateDirectoryW(directory.c_str(), nullptr);
}

bool FileExists(const std::wstring& path) {
    DWORD attributes = GetFileAttributesW(path.c_str());
    return attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

std::string WideToUtf8(const std::wstring& value) {
    if (value.empty()) {
        return {};
    }
    int size = WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, nullptr, 0, nullptr, nullptr);
    if (size <= 0) {
        return {};
    }
    std::string result(static_cast<size_t>(size - 1), '\0');
    WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, &result[0], size, nullptr, nullptr);
    return result;
}

std::wstring Utf8ToWide(const std::string& value) {
    if (value.empty()) {
        return {};
    }
    int size = MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1, nullptr, 0);
    if (size <= 0) {
        size = MultiByteToWideChar(CP_ACP, 0, value.c_str(), -1, nullptr, 0);
        std::wstring result(static_cast<size_t>(size - 1), L'\0');
        MultiByteToWideChar(CP_ACP, 0, value.c_str(), -1, &result[0], size);
        return result;
    }
    std::wstring result(static_cast<size_t>(size - 1), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1, &result[0], size);
    return result;
}

std::wstring ExpandEnvironmentPath(const std::wstring& value) {
    if (value.empty()) {
        return {};
    }
    DWORD needed = ExpandEnvironmentStringsW(value.c_str(), nullptr, 0);
    if (needed == 0) {
        return value;
    }
    std::wstring expanded(static_cast<size_t>(needed), L'\0');
    DWORD written = ExpandEnvironmentStringsW(value.c_str(), &expanded[0], needed);
    if (written == 0 || written > needed) {
        return value;
    }
    if (!expanded.empty() && expanded.back() == L'\0') {
        expanded.pop_back();
    }
    return expanded;
}

std::string Trim(const std::string& value) {
    const char* spaces = " \t\r\n";
    size_t begin = value.find_first_not_of(spaces);
    if (begin == std::string::npos) {
        return {};
    }
    size_t end = value.find_last_not_of(spaces);
    return value.substr(begin, end - begin + 1);
}

std::wstring TrimWide(const std::wstring& value) {
    const wchar_t* spaces = L" \t\r\n";
    size_t begin = value.find_first_not_of(spaces);
    if (begin == std::wstring::npos) {
        return {};
    }
    size_t end = value.find_last_not_of(spaces);
    return value.substr(begin, end - begin + 1);
}

std::string Lower(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    return value;
}

std::string NormalizePnpPattern(std::string value) {
    value = Lower(Trim(value));
    std::replace(value.begin(), value.end(), '/', '\\');
    return value;
}

std::string NormalizeHex(std::string value) {
    value = Lower(Trim(value));
    if (value.rfind("0x", 0) == 0) {
        value = value.substr(2);
    }
    if (value == "*" || value.empty()) {
        return value;
    }
    while (value.size() < 4) {
        value = "0" + value;
    }
    return value;
}

std::vector<std::string> Split(const std::string& value, char delimiter) {
    std::vector<std::string> parts;
    std::stringstream stream(value);
    std::string item;
    while (std::getline(stream, item, delimiter)) {
        item = Trim(item);
        if (!item.empty()) {
            parts.push_back(item);
        }
    }
    return parts;
}

bool WildcardMatch(const std::string& text, const std::string& pattern) {
    std::string regexText;
    regexText.reserve(pattern.size() * 2);
    for (char ch : pattern) {
        switch (ch) {
        case '*':
            regexText += ".*";
            break;
        case '?':
            regexText += ".";
            break;
        case '.':
        case '\\':
        case '+':
        case '^':
        case '$':
        case '(':
        case ')':
        case '[':
        case ']':
        case '{':
        case '}':
        case '|':
            regexText.push_back('\\');
            regexText.push_back(ch);
            break;
        default:
            regexText.push_back(ch);
            break;
        }
    }
    return std::regex_match(text, std::regex(regexText, std::regex::icase));
}

void LogLine(const std::wstring& logPath, const std::string& level, const std::string& message) {
    std::lock_guard<std::mutex> lock(g_logMutex);
    EnsureDirectoryForFile(logPath);
    SYSTEMTIME now = {};
    GetLocalTime(&now);
    std::ofstream log(WideToUtf8(logPath), std::ios::app | std::ios::binary);
    if (!log) {
        return;
    }
    char timestamp[64] = {};
    std::snprintf(timestamp, sizeof(timestamp), "%04u-%02u-%02u %02u:%02u:%02u",
                  now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute, now.wSecond);
    log << timestamp << " " << level << " " << message << "\r\n";
}

// Retorna o conjunto de nomes de COM ports presentes no registro do Windows.
// Consulta HKLM\HARDWARE\DEVICEMAP\SERIALCOMM onde cada valor contem o nome
// da porta (ex: "COM5"). Usado para detectar novos COM ports apos um attach.
std::set<std::string> GetComPorts() {
    std::set<std::string> ports;
    HKEY hKey = nullptr;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"HARDWARE\\DEVICEMAP\\SERIALCOMM",
                      0, KEY_READ, &hKey) != ERROR_SUCCESS) {
        return ports;
    }
    DWORD index = 0;
    wchar_t valueName[256] = {};
    wchar_t valueData[256] = {};
    while (true) {
        DWORD nameLen = static_cast<DWORD>(std::size(valueName));
        DWORD dataLen = static_cast<DWORD>(sizeof(valueData));
        DWORD type = 0;
        LONG res = RegEnumValueW(hKey, index++, valueName, &nameLen,
                                 nullptr, &type,
                                 reinterpret_cast<LPBYTE>(valueData), &dataLen);
        if (res == ERROR_NO_MORE_ITEMS) {
            break;
        }
        if (res != ERROR_SUCCESS) {
            break;
        }
        if (type == REG_SZ && dataLen >= sizeof(wchar_t)) {
            DWORD charCount = dataLen / sizeof(wchar_t);
            while (charCount > 0 && valueData[charCount - 1] == L'\0') {
                --charCount;
            }
            if (charCount > 0) {
                ports.insert(WideToUtf8(std::wstring(valueData, charCount)));
            }
        }
    }
    RegCloseKey(hKey);
    return ports;
}

// Retorna a primeira porta presente em 'after' que nao existia em 'before',
// ou string vazia se nenhuma porta nova foi detectada.
std::string FindNewComPort(const std::set<std::string>& before,
                           const std::set<std::string>& after) {
    for (const auto& port : after) {
        if (before.find(port) == before.end()) {
            return port;
        }
    }
    return {};
}

std::string ExtractComPort(const std::string& text) {
    std::smatch match;
    if (std::regex_search(text, match, std::regex("(COM[0-9]+)", std::regex::icase))) {
        std::string port = match[1].str();
        std::transform(port.begin(), port.end(), port.begin(), [](unsigned char ch) {
            return static_cast<char>(std::toupper(ch));
        });
        return port;
    }
    return {};
}

// Grava uma linha no audit log CSV com a rastreabilidade COM x estacao.
// Cria o cabecalho na primeira vez que o arquivo e criado.
void WriteAuditEntry(const std::wstring& auditPath,
                     const std::string& stationName,
                     const std::string& host,
                     const std::string& busid,
                     const std::string& vid,
                     const std::string& pid,
                     const std::string& description,
                     const std::string& comPort) {
    std::lock_guard<std::mutex> lock(g_logMutex);
    EnsureDirectoryForFile(auditPath);
    bool fileExists = false;
    {
        std::ifstream check(WideToUtf8(auditPath));
        fileExists = check.good();
    }
    std::ofstream file(WideToUtf8(auditPath), std::ios::app | std::ios::binary);
    if (!file) {
        return;
    }
    if (!fileExists) {
        file << "timestamp,station,host_ip,busid,vid,pid,description,com_port\r\n";
    }
    SYSTEMTIME now = {};
    GetLocalTime(&now);
    char timestamp[64] = {};
    std::snprintf(timestamp, sizeof(timestamp), "%04u-%02u-%02u %02u:%02u:%02u",
                  now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute, now.wSecond);
    // Escapa a descricao para CSV (aspas duplas se houver virgula ou aspas)
    std::string desc = description;
    if (desc.find(',') != std::string::npos || desc.find('"') != std::string::npos) {
        std::string escaped;
        escaped.reserve(desc.size() + 2);
        for (char ch : desc) {
            if (ch == '"') {
                escaped += "\"\"";
            } else {
                escaped += ch;
            }
        }
        desc = "\"" + escaped + "\"";
    }
    file << timestamp << ","
         << stationName << ","
         << host << ","
         << busid << ","
         << vid << ","
         << pid << ","
         << desc << ","
         << (comPort.empty() ? "?" : comPort) << "\r\n";
}

std::string ReadIniString(const std::wstring& path, const wchar_t* section, const wchar_t* key, const wchar_t* fallback) {
    wchar_t buffer[8192] = {};
    GetPrivateProfileStringW(section, key, fallback, buffer, static_cast<DWORD>(std::size(buffer)), path.c_str());
    return WideToUtf8(buffer);
}

std::wstring ReadIniWideString(const std::wstring& path, const wchar_t* section, const wchar_t* key, const wchar_t* fallback) {
    wchar_t buffer[8192] = {};
    GetPrivateProfileStringW(section, key, fallback, buffer, static_cast<DWORD>(std::size(buffer)), path.c_str());
    return buffer;
}

int ReadIniInt(const std::wstring& path, const wchar_t* section, const wchar_t* key, int fallback) {
    return static_cast<int>(GetPrivateProfileIntW(section, key, fallback, path.c_str()));
}

bool ReadIniBool(const std::wstring& path, const wchar_t* section, const wchar_t* key, bool fallback) {
    int value = ReadIniInt(path, section, key, fallback ? 1 : 0);
    return value != 0;
}

std::vector<DeviceRule> ParseRules(const std::string& value) {
    std::vector<DeviceRule> rules;
    for (const std::string& item : Split(value, ',')) {
        size_t colon = item.find(':');
        if (colon == std::string::npos) {
            continue;
        }
        rules.push_back({NormalizeHex(item.substr(0, colon)), NormalizeHex(item.substr(colon + 1))});
    }
    return rules;
}

Config LoadConfig(const std::wstring& configPath) {
    Config config;
    config.usbipPath = Utf8ToWide(ReadIniString(configPath, L"Broker", L"UsbipPath", L"C:\\usbip\\usbip.exe"));
    config.logPath = Utf8ToWide(ReadIniString(configPath, L"Broker", L"LogPath", L"C:\\ProgramData\\UsbipBrokerCpp\\logs\\broker.log"));
    config.statePath = Utf8ToWide(ReadIniString(configPath, L"Broker", L"StatePath", L"C:\\ProgramData\\UsbipBrokerCpp\\state.txt"));
    config.auditLogPath = Utf8ToWide(ReadIniString(configPath, L"Broker", L"AuditLogPath", L"C:\\ProgramData\\UsbipBrokerCpp\\logs\\audit.csv"));
    config.attachPolicy = Lower(ReadIniString(configPath, L"Broker", L"AttachPolicy", L"allowlist"));
    config.pollIntervalSeconds = std::max(1, ReadIniInt(configPath, L"Broker", L"PollIntervalSeconds", 5));
    config.commandTimeoutSeconds = std::max(5, ReadIniInt(configPath, L"Broker", L"CommandTimeoutSeconds", 25));
    config.attachRetryCount = std::max(1, ReadIniInt(configPath, L"Broker", L"AttachRetryCount", 3));
    config.attachRetryDelaySeconds = std::max(1, ReadIniInt(configPath, L"Broker", L"AttachRetryDelaySeconds", 2));
    config.thinClients = Split(ReadIniString(configPath, L"Broker", L"ThinClients", L""), ',');
    config.allowedDevices = ParseRules(ReadIniString(configPath, L"Broker", L"AllowedDevices", L"303a:1001,303a:*,10c4:ea60,1a86:7523,0403:6010,0403:6001"));
    config.blockedDevices = ParseRules(ReadIniString(configPath, L"Broker", L"BlockedDevices", L"1d6b:*,2a7a:9a18,10c4:8105"));
    config.eventListenerEnabled = ReadIniBool(configPath, L"Events", L"Enabled", true);
    config.eventPort = std::max(1, ReadIniInt(configPath, L"Events", L"Port", 12000));

    std::wstring defaultWinUsbInf = GetExecutableDirectory() + L"\\drivers\\usbip-winusb.inf";
    config.winUsbEnabled = ReadIniBool(configPath, L"WinUSB", L"Enabled", false);
    config.winUsbDefaultDriverInf = ExpandEnvironmentPath(TrimWide(ReadIniWideString(configPath, L"WinUSB", L"DefaultDriverInf", defaultWinUsbInf.c_str())));
    config.winUsbSettleSeconds = std::max(0, ReadIniInt(configPath, L"WinUSB", L"SettleSeconds", 3));
    config.winUsbRetryCount = std::max(1, ReadIniInt(configPath, L"WinUSB", L"RetryCount", 2));
    for (const std::string& ruleName : Split(ReadIniString(configPath, L"WinUSB", L"Rules", L"ESP32S3_NATIVE_JTAG,ESP_PROG_FT2232_JTAG"), ',')) {
        std::wstring section = L"WinUSB." + Utf8ToWide(ruleName);
        WinUsbRule rule;
        rule.name = ruleName;
        rule.description = ReadIniString(configPath, section.c_str(), L"Description", L"");
        rule.pattern = NormalizePnpPattern(ReadIniString(configPath, section.c_str(), L"Pattern", L""));
        rule.driverInf = ExpandEnvironmentPath(TrimWide(ReadIniWideString(configPath, section.c_str(), L"DriverInf", L"")));
        if (!rule.name.empty() && !rule.pattern.empty()) {
            config.winUsbRules.push_back(rule);
        }
    }

    // Carrega mapeamento IP -> nome de estacao da secao [Stations]
    // Formato: 192.168.100.31=Estacao-01
    wchar_t stationsBuffer[8192] = {};
    GetPrivateProfileSectionW(L"Stations", stationsBuffer,
                              static_cast<DWORD>(std::size(stationsBuffer)),
                              configPath.c_str());
    const wchar_t* ptr = stationsBuffer;
    while (*ptr) {
        std::wstring entry(ptr);
        size_t eq = entry.find(L'=');
        if (eq != std::wstring::npos) {
            std::string ip = Trim(WideToUtf8(entry.substr(0, eq)));
            std::string name = Trim(WideToUtf8(entry.substr(eq + 1)));
            if (!ip.empty() && !name.empty()) {
                config.stationNames[ip] = name;
            }
        }
        ptr += entry.size() + 1;
    }

    return config;
}

std::wstring QuoteArg(const std::wstring& value) {
    std::wstring result = L"\"";
    for (wchar_t ch : value) {
        if (ch == L'"') {
            result += L"\\\"";
        } else {
            result.push_back(ch);
        }
    }
    result += L"\"";
    return result;
}

struct CommandResult {
    DWORD exitCode = 1;
    std::string output;
};

CommandResult RunExecutable(const Config& config,
                            const std::wstring& executable,
                            const std::vector<std::wstring>& args,
                            int timeoutSeconds = 0) {
    CommandResult result;
    SECURITY_ATTRIBUTES security = {};
    security.nLength = sizeof(security);
    security.bInheritHandle = TRUE;

    HANDLE readPipe = nullptr;
    HANDLE writePipe = nullptr;
    if (!CreatePipe(&readPipe, &writePipe, &security, 0)) {
        return result;
    }
    SetHandleInformation(readPipe, HANDLE_FLAG_INHERIT, 0);

    std::wstring commandLine = QuoteArg(executable);
    for (const std::wstring& arg : args) {
        commandLine += L" ";
        commandLine += QuoteArg(arg);
    }

    STARTUPINFOW startup = {};
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESTDHANDLES;
    startup.hStdOutput = writePipe;
    startup.hStdError = writePipe;
    startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);

    PROCESS_INFORMATION process = {};
    std::vector<wchar_t> mutableCommand(commandLine.begin(), commandLine.end());
    mutableCommand.push_back(L'\0');

    BOOL created = CreateProcessW(nullptr, mutableCommand.data(), nullptr, nullptr, TRUE, CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process);
    CloseHandle(writePipe);
    if (!created) {
        CloseHandle(readPipe);
        result.output = "CreateProcess failed for " + WideToUtf8(commandLine);
        return result;
    }

    std::string output;
    DWORD wait = WAIT_TIMEOUT;
    int effectiveTimeout = timeoutSeconds > 0 ? timeoutSeconds : config.commandTimeoutSeconds;
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(std::max(1, effectiveTimeout));
    char buffer[4096] = {};
    while (std::chrono::steady_clock::now() < deadline) {
        DWORD available = 0;
        if (PeekNamedPipe(readPipe, nullptr, 0, nullptr, &available, nullptr) && available > 0) {
            DWORD read = 0;
            if (ReadFile(readPipe, buffer, static_cast<DWORD>(sizeof(buffer)), &read, nullptr) && read > 0) {
                output.append(buffer, buffer + read);
            }
        }
        wait = WaitForSingleObject(process.hProcess, 100);
        if (wait == WAIT_OBJECT_0) {
            break;
        }
    }

    if (wait != WAIT_OBJECT_0) {
        TerminateProcess(process.hProcess, 1460);
        WaitForSingleObject(process.hProcess, 5000);
    }

    DWORD read = 0;
    while (ReadFile(readPipe, buffer, static_cast<DWORD>(sizeof(buffer)), &read, nullptr) && read > 0) {
        output.append(buffer, buffer + read);
    }

    DWORD exitCode = 1;
    GetExitCodeProcess(process.hProcess, &exitCode);
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    CloseHandle(readPipe);

    result.exitCode = exitCode;
    result.output = output;
    return result;
}

CommandResult RunCommand(const Config& config, const std::vector<std::wstring>& args) {
    return RunExecutable(config, config.usbipPath, args, config.commandTimeoutSeconds);
}

std::vector<std::string> ParseCsvLine(const std::string& line) {
    std::vector<std::string> fields;
    std::string current;
    bool inQuotes = false;
    for (size_t i = 0; i < line.size(); ++i) {
        char ch = line[i];
        if (inQuotes) {
            if (ch == '"') {
                if (i + 1 < line.size() && line[i + 1] == '"') {
                    current.push_back('"');
                    ++i;
                } else {
                    inQuotes = false;
                }
            } else {
                current.push_back(ch);
            }
        } else if (ch == ',') {
            fields.push_back(current);
            current.clear();
        } else if (ch == '"') {
            inQuotes = true;
        } else {
            current.push_back(ch);
        }
    }
    fields.push_back(current);
    return fields;
}

std::vector<PnpDevice> ListPresentPnpDevices(const Config& config) {
    std::vector<PnpDevice> devices;
    const std::wstring command =
        L"Get-PnpDevice -PresentOnly | "
        L"Select-Object Class,FriendlyName,InstanceId,Status | "
        L"ConvertTo-Csv -NoTypeInformation";
    CommandResult result = RunExecutable(
        config,
        L"powershell.exe",
        {L"-NoProfile", L"-ExecutionPolicy", L"Bypass", L"-Command", command},
        std::max(15, config.commandTimeoutSeconds));
    if (result.exitCode != 0) {
        LogLine(config.logPath, "WARN", "Get-PnpDevice failed: " + Trim(result.output));
        return devices;
    }

    std::stringstream stream(result.output);
    std::string line;
    bool firstLine = true;
    while (std::getline(stream, line)) {
        line = Trim(line);
        if (line.empty()) {
            continue;
        }
        if (line.rfind("\xEF\xBB\xBF", 0) == 0) {
            line = line.substr(3);
        }
        if (firstLine) {
            firstLine = false;
            if (line.find("InstanceId") != std::string::npos) {
                continue;
            }
        }
        std::vector<std::string> fields = ParseCsvLine(line);
        if (fields.size() < 4) {
            continue;
        }
        PnpDevice device;
        device.className = Trim(fields[0]);
        device.friendlyName = Trim(fields[1]);
        device.instanceId = Trim(fields[2]);
        device.status = Trim(fields[3]);
        if (!device.instanceId.empty()) {
            devices.push_back(device);
        }
    }
    return devices;
}

std::string FindPresentComPortForVidPid(const Config& config,
                                        const std::string& vid,
                                        const std::string& pid) {
    std::string needleA = "vid_" + Lower(vid) + "&pid_" + Lower(pid);
    std::string needleB = "vid_" + Lower(vid) + "+pid_" + Lower(pid);
    for (const PnpDevice& device : ListPresentPnpDevices(config)) {
        if (Lower(device.className) != "ports") {
            continue;
        }
        std::string instanceId = Lower(device.instanceId);
        if (instanceId.find(needleA) == std::string::npos &&
            instanceId.find(needleB) == std::string::npos) {
            continue;
        }
        std::string port = ExtractComPort(device.friendlyName);
        if (!port.empty()) {
            return port;
        }
    }
    return {};
}

std::string ResolveStationName(const Config& config, const std::string& host) {
    auto it = config.stationNames.find(host);
    if (it != config.stationNames.end()) {
        return it->second;
    }
    return host;
}

void AuditDeviceOnce(const Config& config,
                     const RemoteDevice& device,
                     const std::string& comPort) {
    std::string key = Lower(device.host) + "/" + device.busid + "/" + Lower(device.vid) + ":" + Lower(device.pid);
    {
        std::lock_guard<std::mutex> lock(g_logMutex);
        if (g_auditWritten.find(key) != g_auditWritten.end()) {
            return;
        }
        g_auditWritten.insert(key);
    }
    std::string stationName = ResolveStationName(config, device.host);
    std::ostringstream auditMsg;
    auditMsg << "COM port assigned: " << (comPort.empty() ? "?" : comPort)
             << " station=" << stationName
             << " " << device.host << "/" << device.busid
             << " " << device.vid << ":" << device.pid
             << " (" << device.description << ")";
    LogLine(config.logPath, "INFO", auditMsg.str());
    WriteAuditEntry(config.auditLogPath, stationName, device.host, device.busid,
                    device.vid, device.pid, device.description, comPort);
}

std::wstring ResolveWinUsbInf(const Config& config, const WinUsbRule& rule) {
    if (!rule.driverInf.empty()) {
        return rule.driverInf;
    }
    return config.winUsbDefaultDriverInf;
}

bool WinUsbRuleMatches(const WinUsbRule& rule, const PnpDevice& device) {
    std::string instanceId = NormalizePnpPattern(device.instanceId);
    std::string combined = NormalizePnpPattern(device.className + " " + device.friendlyName + " " + device.instanceId + " " + device.status);
    return WildcardMatch(instanceId, rule.pattern) || WildcardMatch(combined, rule.pattern);
}

void ApplyWinUsbRules(const Config& config, bool waitForSettle) {
    if (!config.winUsbEnabled || config.winUsbRules.empty()) {
        return;
    }
    std::unique_lock<std::mutex> lock(g_winUsbMutex, std::try_to_lock);
    if (!lock.owns_lock()) {
        return;
    }
    if (waitForSettle && config.winUsbSettleSeconds > 0) {
        for (int i = 0; i < config.winUsbSettleSeconds * 10 && !g_stopRequested.load(); ++i) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
    }
    if (g_stopRequested.load()) {
        return;
    }

    std::vector<PnpDevice> devices = ListPresentPnpDevices(config);
    for (const PnpDevice& device : devices) {
        for (const WinUsbRule& rule : config.winUsbRules) {
            if (!WinUsbRuleMatches(rule, device)) {
                continue;
            }
            std::wstring driverInf = ResolveWinUsbInf(config, rule);
            std::string instanceId = NormalizePnpPattern(device.instanceId);
            std::string cacheKey = Lower(rule.name) + "|" + instanceId + "|" + Lower(WideToUtf8(driverInf));
            if (g_winUsbApplied.find(cacheKey) != g_winUsbApplied.end()) {
                continue;
            }
            if (driverInf.empty()) {
                LogLine(config.logPath, "ERROR", "WinUSB rule " + rule.name + " matched " + device.instanceId + " but DriverInf is empty");
                continue;
            }
            if (!FileExists(driverInf)) {
                LogLine(config.logPath, "ERROR", "WinUSB rule " + rule.name + " matched " + device.instanceId +
                        " but INF was not found: " + WideToUtf8(driverInf));
                continue;
            }

            LogLine(config.logPath, "INFO", "WinUSB rule " + rule.name + " matched " + device.instanceId +
                    ". Installing " + WideToUtf8(driverInf));
            bool installed = false;
            for (int attempt = 1; attempt <= config.winUsbRetryCount && !g_stopRequested.load(); ++attempt) {
                CommandResult result = RunExecutable(
                    config,
                    L"pnputil.exe",
                    {L"/add-driver", driverInf, L"/install"},
                    std::max(30, config.commandTimeoutSeconds));
                if (result.exitCode == 0) {
                    installed = true;
                    LogLine(config.logPath, "INFO", "WinUSB driver install OK for rule " + rule.name +
                            " instance=" + device.instanceId);
                    break;
                }
                LogLine(config.logPath, "WARN", "WinUSB driver install failed for rule " + rule.name +
                        " attempt " + std::to_string(attempt) + "/" + std::to_string(config.winUsbRetryCount) +
                        ": " + Trim(result.output));
                std::this_thread::sleep_for(std::chrono::seconds(2));
            }
            if (installed) {
                g_winUsbApplied.insert(cacheKey);
            }
        }
    }
}

std::vector<RemoteDevice> ParseUsbipList(const std::string& text, const std::string& host) {
    std::vector<RemoteDevice> devices;
    std::regex busLine(R"(^\s*(?:-\s*)?([0-9]+(?:-[0-9.]+)+)\s*:\s*(.*?)(?:\(([0-9a-fA-F]{4}):([0-9a-fA-F]{4})\))?\s*$)");
    std::regex vidPid(R"(\(([0-9a-fA-F]{4}):([0-9a-fA-F]{4})\))");
    std::stringstream stream(text);
    std::string line;
    while (std::getline(stream, line)) {
        std::smatch match;
        if (std::regex_match(line, match, busLine)) {
            RemoteDevice device;
            device.host = host;
            device.busid = match[1].str();
            device.description = Trim(match[2].str());
            if (match.size() >= 5) {
                device.vid = NormalizeHex(match[3].str());
                device.pid = NormalizeHex(match[4].str());
            }
            devices.push_back(device);
        } else if (!devices.empty() && std::regex_search(line, match, vidPid)) {
            devices.back().vid = NormalizeHex(match[1].str());
            devices.back().pid = NormalizeHex(match[2].str());
        }
    }
    return devices;
}

std::set<std::string> ParseUsbipPortKeys(const std::string& text) {
    std::set<std::string> keys;
    std::regex remote(R"(usbip://([^/:]+)(?::[0-9]+)?/(\S+))", std::regex::icase);
    std::stringstream stream(text);
    std::string line;
    while (std::getline(stream, line)) {
        std::smatch match;
        if (std::regex_search(line, match, remote)) {
            keys.insert(Lower(match[1].str()) + "/" + match[2].str());
        }
    }
    return keys;
}

std::vector<RemoteDevice> ParseUsbipPortDevices(const std::string& text) {
    std::vector<RemoteDevice> devices;
    std::regex descLine(R"(^\s*(.+?)\s+\(([0-9a-fA-F]{4}):([0-9a-fA-F]{4})\)\s*$)");
    std::regex remote(R"(usbip://([^/:]+)(?::[0-9]+)?/(\S+))", std::regex::icase);
    std::stringstream stream(text);
    std::string line;
    RemoteDevice current;
    bool haveDescription = false;
    while (std::getline(stream, line)) {
        std::smatch match;
        if (std::regex_match(line, match, descLine)) {
            current = RemoteDevice{};
            current.description = Trim(match[1].str());
            current.vid = NormalizeHex(match[2].str());
            current.pid = NormalizeHex(match[3].str());
            haveDescription = true;
            continue;
        }
        if (haveDescription && std::regex_search(line, match, remote)) {
            current.host = match[1].str();
            current.busid = match[2].str();
            devices.push_back(current);
            haveDescription = false;
        }
    }
    return devices;
}

std::vector<RemoteDevice> AttachedDevices(const Config& config) {
    CommandResult result = RunCommand(config, {L"port"});
    if (result.exitCode != 0) {
        return {};
    }
    return ParseUsbipPortDevices(result.output);
}

bool MatchesRule(const RemoteDevice& device, const DeviceRule& rule) {
    return WildcardMatch(device.vid, rule.vid) && WildcardMatch(device.pid, rule.pid);
}

bool IsAllowed(const Config& config, const RemoteDevice& device) {
    for (const auto& rule : config.blockedDevices) {
        if (MatchesRule(device, rule)) {
            return false;
        }
    }
    if (config.attachPolicy == "disabled") {
        return false;
    }
    if (config.attachPolicy == "allow_all") {
        return true;
    }
    for (const auto& rule : config.allowedDevices) {
        if (MatchesRule(device, rule)) {
            return true;
        }
    }
    return false;
}

std::vector<RemoteDevice> ListRemote(const Config& config, const std::string& host) {
    CommandResult result = RunCommand(config, {L"list", L"-r", Utf8ToWide(host)});
    if (result.exitCode != 0) {
        LogLine(config.logPath, "WARN", "usbip list failed for " + host + ": " + Trim(result.output));
        return {};
    }
    return ParseUsbipList(result.output, host);
}

std::set<std::string> AttachedKeys(const Config& config) {
    CommandResult result = RunCommand(config, {L"port"});
    if (result.exitCode != 0) {
        return {};
    }
    return ParseUsbipPortKeys(result.output);
}

bool AttachDevice(const Config& config, const RemoteDevice& device) {
    if (!IsAllowed(config, device)) {
        return false;
    }
    // Snapshot dos COM ports antes do attach para detectar qual porta sera criada
    std::set<std::string> portsBefore = GetComPorts();

    for (int attempt = 1; attempt <= config.attachRetryCount && !g_stopRequested.load(); ++attempt) {
        std::ostringstream message;
        message << "Attaching " << device.host << "/" << device.busid << " " << device.vid << ":" << device.pid
                << " attempt " << attempt << "/" << config.attachRetryCount;
        LogLine(config.logPath, "INFO", message.str());
        CommandResult result = RunCommand(config, {L"attach", L"-r", Utf8ToWide(device.host), L"-b", Utf8ToWide(device.busid)});
        std::string output = Lower(result.output);
        if (result.exitCode == 0 || output.find("already") != std::string::npos || output.find("busy") != std::string::npos) {
            ApplyWinUsbRules(config, true);
            // Aguarda o driver carregar e o COM port aparecer no registro (ate 6 segundos)
            std::string newPort;
            for (int settle = 0; settle < 6 && !g_stopRequested.load(); ++settle) {
                std::this_thread::sleep_for(std::chrono::seconds(1));
                std::set<std::string> portsAfter = GetComPorts();
                newPort = FindNewComPort(portsBefore, portsAfter);
                if (!newPort.empty()) {
                    break;
                }
            }
            AuditDeviceOnce(config, device, newPort);
            return true;
        }
        LogLine(config.logPath, "WARN", "usbip attach failed: " + Trim(result.output));
        std::this_thread::sleep_for(std::chrono::seconds(config.attachRetryDelaySeconds));
    }
    return false;
}

int ScanOnce(const Config& config, const std::string& targetHost = "", const std::string& targetBusid = "") {
    std::set<std::string> attached = AttachedKeys(config);
    int attachedCount = 0;
    for (const RemoteDevice& device : AttachedDevices(config)) {
        if ((!targetHost.empty() && Lower(device.host) != Lower(targetHost)) ||
            (!targetBusid.empty() && device.busid != targetBusid)) {
            continue;
        }
        AuditDeviceOnce(config, device, FindPresentComPortForVidPid(config, device.vid, device.pid));
    }
    std::vector<std::string> hosts = config.thinClients;
    if (!targetHost.empty() && std::find(hosts.begin(), hosts.end(), targetHost) == hosts.end()) {
        hosts.push_back(targetHost);
    }
    for (const std::string& host : hosts) {
        if (g_stopRequested.load()) {
            break;
        }
        if (!targetHost.empty() && Lower(host) != Lower(targetHost)) {
            continue;
        }
        std::vector<RemoteDevice> devices = ListRemote(config, host);
        for (const RemoteDevice& device : devices) {
            if (!targetBusid.empty() && device.busid != targetBusid) {
                continue;
            }
            std::string key = Lower(host) + "/" + device.busid;
            if (attached.find(key) != attached.end()) {
                AuditDeviceOnce(config, device, FindPresentComPortForVidPid(config, device.vid, device.pid));
                continue;
            }
            if (AttachDevice(config, device)) {
                ++attachedCount;
                attached.insert(key);
            }
        }
    }
    return attachedCount;
}

std::string JsonValue(const std::string& text, const std::string& key) {
    std::regex pattern("\\\"" + key + "\\\"\\s*:\\s*\\\"([^\\\"]*)\\\"", std::regex::icase);
    std::smatch match;
    if (std::regex_search(text, match, pattern)) {
        return match[1].str();
    }
    return {};
}

void EventListener(const Config& config) {
    if (!config.eventListenerEnabled) {
        return;
    }
    WSADATA data = {};
    if (WSAStartup(MAKEWORD(2, 2), &data) != 0) {
        LogLine(config.logPath, "ERROR", "WSAStartup failed");
        return;
    }
    SOCKET server = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (server == INVALID_SOCKET) {
        WSACleanup();
        return;
    }
    BOOL reuse = TRUE;
    setsockopt(server, SOL_SOCKET, SO_REUSEADDR, reinterpret_cast<const char*>(&reuse), sizeof(reuse));

    sockaddr_in address = {};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_ANY);
    address.sin_port = htons(static_cast<u_short>(config.eventPort));
    if (bind(server, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == SOCKET_ERROR ||
        listen(server, SOMAXCONN) == SOCKET_ERROR) {
        LogLine(config.logPath, "ERROR", "Could not listen on TCP " + std::to_string(config.eventPort));
        closesocket(server);
        WSACleanup();
        return;
    }

    LogLine(config.logPath, "INFO", "Listening for Linux events on TCP " + std::to_string(config.eventPort));
    u_long nonBlocking = 1;
    ioctlsocket(server, FIONBIO, &nonBlocking);
    while (!g_stopRequested.load()) {
        sockaddr_in peer = {};
        int peerLength = sizeof(peer);
        SOCKET client = accept(server, reinterpret_cast<sockaddr*>(&peer), &peerLength);
        if (client == INVALID_SOCKET) {
            std::this_thread::sleep_for(std::chrono::milliseconds(250));
            continue;
        }
        char peerHost[INET_ADDRSTRLEN] = {};
        const char* peerText = inet_ntoa(peer.sin_addr);
        if (peerText) {
            std::snprintf(peerHost, sizeof(peerHost), "%s", peerText);
        }
        char buffer[16384] = {};
        int received = recv(client, buffer, static_cast<int>(sizeof(buffer) - 1), 0);
        closesocket(client);
        if (received <= 0) {
            continue;
        }
        std::string payload(buffer, buffer + received);
        std::string event = JsonValue(payload, "event");
        if (event != "exported" && event != "already_exported") {
            continue;
        }
        std::string busid = JsonValue(payload, "busid");
        LogLine(config.logPath, "INFO", std::string("Event from ") + peerHost + " busid=" + busid);
        ScanOnce(config, peerHost, busid);
    }
    closesocket(server);
    WSACleanup();
}

void BrokerLoop(const std::wstring& configPath) {
    Config config = LoadConfig(configPath);
    LogLine(config.logPath, "INFO", "USB/IP Broker C++ starting. Config=" + WideToUtf8(configPath));
    std::thread listener(EventListener, config);
    auto lastWinUsbSweep = std::chrono::steady_clock::time_point{};
    while (!g_stopRequested.load()) {
        Config current = LoadConfig(configPath);
        try {
            int count = ScanOnce(current);
            if (count > 0) {
                LogLine(current.logPath, "INFO", "Attached " + std::to_string(count) + " device(s)");
            }
            auto now = std::chrono::steady_clock::now();
            bool dueForWinUsbSweep =
                current.winUsbEnabled &&
                !current.winUsbRules.empty() &&
                (lastWinUsbSweep.time_since_epoch().count() == 0 ||
                 count > 0 ||
                 now - lastWinUsbSweep >= std::chrono::seconds(60));
            if (dueForWinUsbSweep) {
                ApplyWinUsbRules(current, false);
                lastWinUsbSweep = now;
            }
        } catch (const std::exception& ex) {
            LogLine(current.logPath, "ERROR", ex.what());
        }
        for (int i = 0; i < current.pollIntervalSeconds * 10 && !g_stopRequested.load(); ++i) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
    }
    if (listener.joinable()) {
        listener.join();
    }
    Config finalConfig = LoadConfig(configPath);
    LogLine(finalConfig.logPath, "INFO", "USB/IP Broker C++ stopped");
}

void SetServiceStatusState(DWORD state, DWORD exitCode = NO_ERROR, DWORD waitHint = 0) {
    g_status.dwCurrentState = state;
    g_status.dwWin32ExitCode = exitCode;
    g_status.dwWaitHint = waitHint;
    if (state == SERVICE_START_PENDING) {
        g_status.dwControlsAccepted = 0;
    } else {
        g_status.dwControlsAccepted = SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN;
    }
    SetServiceStatus(g_statusHandle, &g_status);
}

DWORD WINAPI ServiceControlHandler(DWORD control, DWORD, LPVOID, LPVOID) {
    switch (control) {
    case SERVICE_CONTROL_STOP:
    case SERVICE_CONTROL_SHUTDOWN:
        SetServiceStatusState(SERVICE_STOP_PENDING, NO_ERROR, 30000);
        g_stopRequested.store(true);
        return NO_ERROR;
    default:
        return NO_ERROR;
    }
}

void WINAPI ServiceMain(DWORD argc, LPWSTR* argv) {
    g_statusHandle = RegisterServiceCtrlHandlerExW(kServiceName, ServiceControlHandler, nullptr);
    if (!g_statusHandle) {
        return;
    }
    g_status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
    SetServiceStatusState(SERVICE_START_PENDING, NO_ERROR, 30000);

    std::wstring configPath = DefaultConfigPath();
    if (argc >= 2 && argv[1] && wcslen(argv[1]) > 0) {
        configPath = argv[1];
    }

    SetServiceStatusState(SERVICE_RUNNING);
    BrokerLoop(configPath);
    SetServiceStatusState(SERVICE_STOPPED);
}

int RunConsole(const std::wstring& configPath) {
    g_stopRequested.store(false);
    BrokerLoop(configPath);
    return 0;
}

int InstallService(const std::wstring& exePath, const std::wstring& configPath) {
    SC_HANDLE manager = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CREATE_SERVICE);
    if (!manager) {
        return 1;
    }
    std::wstring binary = QuoteArg(exePath) + L" " + QuoteArg(configPath);
    SC_HANDLE service = CreateServiceW(
        manager, kServiceName, kDisplayName,
        SERVICE_ALL_ACCESS, SERVICE_WIN32_OWN_PROCESS, SERVICE_AUTO_START,
        SERVICE_ERROR_NORMAL, binary.c_str(), nullptr, nullptr, nullptr, nullptr, nullptr);
    if (!service) {
        service = OpenServiceW(manager, kServiceName, SERVICE_ALL_ACCESS);
        if (!service) {
            CloseServiceHandle(manager);
            return 2;
        }
        ChangeServiceConfigW(service, SERVICE_WIN32_OWN_PROCESS, SERVICE_AUTO_START, SERVICE_ERROR_NORMAL,
                             binary.c_str(), nullptr, nullptr, nullptr, nullptr, nullptr, kDisplayName);
    }
    SERVICE_FAILURE_ACTIONSW actions = {};
    SC_ACTION restart[3] = {};
    restart[0].Type = SC_ACTION_RESTART;
    restart[0].Delay = 5000;
    restart[1].Type = SC_ACTION_RESTART;
    restart[1].Delay = 5000;
    restart[2].Type = SC_ACTION_RESTART;
    restart[2].Delay = 30000;
    actions.dwResetPeriod = 60;
    actions.cActions = 3;
    actions.lpsaActions = restart;
    ChangeServiceConfig2W(service, SERVICE_CONFIG_FAILURE_ACTIONS, &actions);
    CloseServiceHandle(service);
    CloseServiceHandle(manager);
    return 0;
}

int UninstallService() {
    SC_HANDLE manager = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
    if (!manager) {
        return 1;
    }
    SC_HANDLE service = OpenServiceW(manager, kServiceName, SERVICE_STOP | DELETE | SERVICE_QUERY_STATUS);
    if (!service) {
        CloseServiceHandle(manager);
        return 0;
    }
    SERVICE_STATUS status = {};
    ControlService(service, SERVICE_CONTROL_STOP, &status);
    DeleteService(service);
    CloseServiceHandle(service);
    CloseServiceHandle(manager);
    return 0;
}

} // namespace

int wmain(int argc, wchar_t** argv) {
    std::wstring configPath = DefaultConfigPath();
    for (int i = 1; i < argc; ++i) {
        std::wstring arg = argv[i];
        if ((arg == L"--config" || arg == L"/config") && i + 1 < argc) {
            configPath = argv[++i];
        } else if (arg == L"--console") {
            return RunConsole(configPath);
        } else if (arg == L"--install") {
            wchar_t exePath[MAX_PATH] = {};
            GetModuleFileNameW(nullptr, exePath, MAX_PATH);
            return InstallService(exePath, configPath);
        } else if (arg == L"--uninstall") {
            return UninstallService();
        }
    }

    SERVICE_TABLE_ENTRYW serviceTable[] = {
        {const_cast<LPWSTR>(kServiceName), ServiceMain},
        {nullptr, nullptr}
    };
    if (!StartServiceCtrlDispatcherW(serviceTable)) {
        return RunConsole(configPath);
    }
    return 0;
}
