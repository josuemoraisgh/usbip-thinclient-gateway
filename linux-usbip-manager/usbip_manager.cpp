#include <arpa/inet.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <signal.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <limits.h>
#include <fstream>
#include <iostream>
#include <map>
#include <regex>
#include <set>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

namespace {

volatile sig_atomic_t g_stop = 0;

struct Rule {
    std::string vid = "*";
    std::string pid = "*";
    std::string busid = "*";
    std::string name;
};

struct Device {
    std::string busid;
    std::string vid;
    std::string pid;
    std::string manufacturer;
    std::string product;
    std::string serial;
    std::string deviceClass;
    std::string speed;
    std::string driver;
    std::vector<std::string> interfaceDrivers;

    std::string name() const {
        std::string value;
        if (!manufacturer.empty()) {
            value += manufacturer;
        }
        if (!product.empty()) {
            if (!value.empty()) {
                value += " ";
            }
            value += product;
        }
        if (value.empty()) {
            value = vid + ":" + pid;
        }
        return value;
    }

    bool exported() const {
        if (driver == "usbip-host") {
            return true;
        }
        return std::find(interfaceDrivers.begin(), interfaceDrivers.end(), "usbip-host") != interfaceDrivers.end();
    }
};

struct Config {
    std::string bindPolicy = "allow_all";
    std::vector<Rule> allowedDevices = {
        {"303a", "1001", "*", "Espressif ESP32-S3 USB Serial/JTAG"},
        {"303a", "*", "*", "Espressif devices"},
        {"10c4", "ea60", "*", "Silicon Labs CP210x"},
        {"1a86", "7523", "*", "WCH CH340/CH341"},
        {"0403", "6010", "*", "ESP-PROG / FTDI FT2232H"},
        {"0403", "6001", "*", "FTDI FT232"},
    };
    std::vector<Rule> blockedDevices = {
        {"1d6b", "*", "*", "Linux USB root hubs"},
    };
    bool blockUsbHubs = true;
    double settleSeconds = 2.0;
    int retryCount = 6;
    double retryDelaySeconds = 1.5;
    double reconcileIntervalSeconds = 5.0;
    double commandTimeoutSeconds = 15.0;
    std::string statePath = "/run/usbip-manager/state.json";
    int usbipTcpPort = 3240;
    bool notifyEnabled = false;
    std::string notifyHost;
    int notifyPort = 12000;
    double notifyTimeoutSeconds = 2.0;
    std::string sharedSecret;
    std::string usbip = "usbip";
    std::string modprobe = "modprobe";
    std::string udevadm = "udevadm";
};

struct CommandResult {
    int exitCode = 127;
    std::string output;
};

std::string trim(const std::string& value) {
    const char* spaces = " \t\r\n";
    size_t begin = value.find_first_not_of(spaces);
    if (begin == std::string::npos) {
        return "";
    }
    size_t end = value.find_last_not_of(spaces);
    return value.substr(begin, end - begin + 1);
}

std::string lower(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    return value;
}

std::string normalizeHex(std::string value) {
    value = lower(trim(value));
    if (value.rfind("0x", 0) == 0) {
        value = value.substr(2);
    }
    if (value.empty() || value == "*") {
        return value.empty() ? "" : "*";
    }
    while (value.size() < 4) {
        value = "0" + value;
    }
    return value;
}

std::string readText(const std::string& path) {
    std::ifstream file(path);
    if (!file) {
        return "";
    }
    std::stringstream buffer;
    buffer << file.rdbuf();
    return trim(buffer.str());
}

bool isExecutable(const std::string& path) {
    return access(path.c_str(), X_OK) == 0;
}

std::string dirnameOf(const std::string& path) {
    size_t slash = path.find_last_of('/');
    if (slash == std::string::npos) {
        return ".";
    }
    if (slash == 0) {
        return "/";
    }
    return path.substr(0, slash);
}

void mkdirs(const std::string& path) {
    if (path.empty() || path == "/") {
        return;
    }
    std::string current;
    for (char ch : path) {
        current.push_back(ch);
        if (ch == '/' && current.size() > 1) {
            mkdir(current.c_str(), 0755);
        }
    }
    mkdir(path.c_str(), 0755);
}

std::string basenameOf(const std::string& path) {
    size_t slash = path.find_last_of('/');
    if (slash == std::string::npos) {
        return path;
    }
    return path.substr(slash + 1);
}

std::string symlinkTargetBase(const std::string& path) {
    char buffer[PATH_MAX] = {};
    ssize_t size = readlink(path.c_str(), buffer, sizeof(buffer) - 1);
    if (size <= 0) {
        return "";
    }
    buffer[size] = '\0';
    return basenameOf(buffer);
}

std::vector<std::string> listDirNames(const std::string& path) {
    std::vector<std::string> names;
    DIR* dir = opendir(path.c_str());
    if (!dir) {
        return names;
    }
    while (dirent* entry = readdir(dir)) {
        std::string name = entry->d_name;
        if (name != "." && name != "..") {
            names.push_back(name);
        }
    }
    closedir(dir);
    std::sort(names.begin(), names.end());
    return names;
}

std::string shellQuote(const std::string& value) {
    std::string result = "'";
    for (char ch : value) {
        if (ch == '\'') {
            result += "'\\''";
        } else {
            result.push_back(ch);
        }
    }
    result += "'";
    return result;
}

CommandResult runCommand(const std::vector<std::string>& args) {
    CommandResult result;
    if (args.empty()) {
        return result;
    }
    std::string command;
    for (const std::string& arg : args) {
        if (!command.empty()) {
            command += " ";
        }
        command += shellQuote(arg);
    }
    command += " 2>&1";

    FILE* pipe = popen(command.c_str(), "r");
    if (!pipe) {
        result.output = std::string("popen failed: ") + strerror(errno);
        return result;
    }
    char buffer[4096];
    while (fgets(buffer, sizeof(buffer), pipe)) {
        result.output += buffer;
    }
    int status = pclose(pipe);
    if (WIFEXITED(status)) {
        result.exitCode = WEXITSTATUS(status);
    } else {
        result.exitCode = 1;
    }
    return result;
}

std::string findTool(const std::string& configured, const std::string& name) {
    if (!configured.empty() && isExecutable(configured)) {
        return configured;
    }
    const char* paths[] = {"/usr/sbin", "/usr/bin", "/sbin", "/bin"};
    for (const char* dir : paths) {
        std::string candidate = std::string(dir) + "/" + name;
        if (isExecutable(candidate)) {
            return candidate;
        }
    }
    std::string toolsRoot = "/usr/lib/linux-tools";
    std::vector<std::string> versions = listDirNames(toolsRoot);
    for (auto it = versions.rbegin(); it != versions.rend(); ++it) {
        std::string candidate = toolsRoot + "/" + *it + "/" + name;
        if (isExecutable(candidate)) {
            return candidate;
        }
    }
    return name;
}

bool wildcardMatch(const std::string& text, const std::string& pattern) {
    std::string rx;
    for (char ch : pattern) {
        switch (ch) {
        case '*':
            rx += ".*";
            break;
        case '?':
            rx += ".";
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
            rx.push_back('\\');
            rx.push_back(ch);
            break;
        default:
            rx.push_back(ch);
            break;
        }
    }
    try {
        return std::regex_match(text, std::regex(rx, std::regex::icase));
    } catch (...) {
        return text == pattern;
    }
}

std::string jsonString(const std::string& value) {
    std::string out = "\"";
    for (char ch : value) {
        switch (ch) {
        case '\\':
            out += "\\\\";
            break;
        case '"':
            out += "\\\"";
            break;
        case '\n':
            out += "\\n";
            break;
        case '\r':
            out += "\\r";
            break;
        case '\t':
            out += "\\t";
            break;
        default:
            out.push_back(ch);
            break;
        }
    }
    out += "\"";
    return out;
}

std::string extractString(const std::string& json, const std::string& key, const std::string& fallback) {
    try {
        std::regex pattern("\"" + key + "\"\\s*:\\s*\"([^\"]*)\"");
        std::smatch match;
        if (std::regex_search(json, match, pattern)) {
            return match[1].str();
        }
    } catch (...) {
    }
    return fallback;
}

int extractInt(const std::string& json, const std::string& key, int fallback) {
    try {
        std::regex pattern("\"" + key + "\"\\s*:\\s*([0-9]+)");
        std::smatch match;
        if (std::regex_search(json, match, pattern)) {
            return std::stoi(match[1].str());
        }
    } catch (...) {
    }
    return fallback;
}

double extractDouble(const std::string& json, const std::string& key, double fallback) {
    try {
        std::regex pattern("\"" + key + "\"\\s*:\\s*([0-9]+(?:\\.[0-9]+)?)");
        std::smatch match;
        if (std::regex_search(json, match, pattern)) {
            return std::stod(match[1].str());
        }
    } catch (...) {
    }
    return fallback;
}

bool extractBool(const std::string& json, const std::string& key, bool fallback) {
    try {
        std::regex pattern("\"" + key + "\"\\s*:\\s*(true|false|1|0)", std::regex::icase);
        std::smatch match;
        if (std::regex_search(json, match, pattern)) {
            std::string value = lower(match[1].str());
            return value == "true" || value == "1";
        }
    } catch (...) {
    }
    return fallback;
}

std::string extractObject(const std::string& json, const std::string& key) {
    size_t keyPos = json.find("\"" + key + "\"");
    if (keyPos == std::string::npos) {
        return "";
    }
    size_t begin = json.find('{', keyPos);
    if (begin == std::string::npos) {
        return "";
    }
    int depth = 0;
    bool inString = false;
    bool escape = false;
    for (size_t i = begin; i < json.size(); ++i) {
        char ch = json[i];
        if (escape) {
            escape = false;
            continue;
        }
        if (ch == '\\' && inString) {
            escape = true;
            continue;
        }
        if (ch == '"') {
            inString = !inString;
            continue;
        }
        if (inString) {
            continue;
        }
        if (ch == '{') {
            ++depth;
        } else if (ch == '}') {
            --depth;
            if (depth == 0) {
                return json.substr(begin, i - begin + 1);
            }
        }
    }
    return "";
}

std::string extractArray(const std::string& json, const std::string& key) {
    size_t keyPos = json.find("\"" + key + "\"");
    if (keyPos == std::string::npos) {
        return "";
    }
    size_t begin = json.find('[', keyPos);
    if (begin == std::string::npos) {
        return "";
    }
    int depth = 0;
    bool inString = false;
    bool escape = false;
    for (size_t i = begin; i < json.size(); ++i) {
        char ch = json[i];
        if (escape) {
            escape = false;
            continue;
        }
        if (ch == '\\' && inString) {
            escape = true;
            continue;
        }
        if (ch == '"') {
            inString = !inString;
            continue;
        }
        if (inString) {
            continue;
        }
        if (ch == '[') {
            ++depth;
        } else if (ch == ']') {
            --depth;
            if (depth == 0) {
                return json.substr(begin, i - begin + 1);
            }
        }
    }
    return "";
}

std::vector<Rule> parseRules(const std::string& arrayText, const std::vector<Rule>& fallback) {
    if (arrayText.empty()) {
        return fallback;
    }
    std::vector<Rule> rules;
    std::regex objectPattern("\\{[^\\}]*\\}");
    auto begin = std::sregex_iterator(arrayText.begin(), arrayText.end(), objectPattern);
    auto end = std::sregex_iterator();
    for (auto it = begin; it != end; ++it) {
        std::string object = it->str();
        Rule rule;
        rule.vid = normalizeHex(extractString(object, "vid", "*"));
        rule.pid = normalizeHex(extractString(object, "pid", "*"));
        rule.busid = extractString(object, "busid", "*");
        rule.name = extractString(object, "name", "");
        rules.push_back(rule);
    }
    return rules.empty() ? fallback : rules;
}

Config loadConfig(const std::string& path) {
    Config config;
    std::string json = readText(path);
    if (json.empty()) {
        config.usbip = findTool("", "usbip");
        config.modprobe = findTool("", "modprobe");
        config.udevadm = findTool("", "udevadm");
        return config;
    }

    config.bindPolicy = extractString(json, "bind_policy", config.bindPolicy);
    config.blockUsbHubs = extractBool(json, "block_usb_hubs", config.blockUsbHubs);
    config.settleSeconds = extractDouble(json, "settle_seconds", config.settleSeconds);
    config.retryCount = extractInt(json, "retry_count", config.retryCount);
    config.retryDelaySeconds = extractDouble(json, "retry_delay_seconds", config.retryDelaySeconds);
    config.reconcileIntervalSeconds = extractDouble(json, "reconcile_interval_seconds", config.reconcileIntervalSeconds);
    config.commandTimeoutSeconds = extractDouble(json, "command_timeout_seconds", config.commandTimeoutSeconds);
    config.statePath = extractString(json, "state_path", config.statePath);
    config.usbipTcpPort = extractInt(json, "usbip_tcp_port", config.usbipTcpPort);
    config.allowedDevices = parseRules(extractArray(json, "allowed_devices"), config.allowedDevices);
    config.blockedDevices = parseRules(extractArray(json, "blocked_devices"), config.blockedDevices);

    std::string notify = extractObject(json, "notify");
    config.notifyEnabled = extractBool(notify, "enabled", config.notifyEnabled);
    config.notifyHost = extractString(notify, "host", config.notifyHost);
    config.notifyPort = extractInt(notify, "port", config.notifyPort);
    config.notifyTimeoutSeconds = extractDouble(notify, "timeout_seconds", config.notifyTimeoutSeconds);
    config.sharedSecret = extractString(notify, "shared_secret", config.sharedSecret);

    std::string commands = extractObject(json, "commands");
    config.usbip = findTool(extractString(commands, "usbip", ""), "usbip");
    config.modprobe = findTool(extractString(commands, "modprobe", ""), "modprobe");
    config.udevadm = findTool(extractString(commands, "udevadm", ""), "udevadm");
    return config;
}

std::set<std::string> exportedBusids(const Config& config) {
    std::set<std::string> exported;
    CommandResult result = runCommand({config.usbip, "list", "-l"});
    if (result.exitCode != 0) {
        return exported;
    }
    std::string current;
    std::stringstream stream(result.output);
    std::string line;
    while (std::getline(stream, line)) {
        line = trim(line);
        if (line.rfind("- busid ", 0) == 0) {
            std::stringstream parts(line);
            std::string dash;
            std::string label;
            parts >> dash >> label >> current;
        } else if (!current.empty() && line.find("usbip-host") != std::string::npos) {
            exported.insert(current);
        }
    }
    return exported;
}

std::vector<Device> listDevices(const Config& config) {
    const std::string base = "/sys/bus/usb/devices";
    std::vector<Device> devices;
    std::set<std::string> exported = exportedBusids(config);
    for (const std::string& name : listDirNames(base)) {
        if (name.find(':') != std::string::npos || name.rfind("usb", 0) == 0) {
            continue;
        }
        std::string dir = base + "/" + name;
        std::string vid = normalizeHex(readText(dir + "/idVendor"));
        std::string pid = normalizeHex(readText(dir + "/idProduct"));
        if (vid.empty() || pid.empty()) {
            continue;
        }
        Device device;
        device.busid = name;
        device.vid = vid;
        device.pid = pid;
        device.manufacturer = readText(dir + "/manufacturer");
        device.product = readText(dir + "/product");
        device.serial = readText(dir + "/serial");
        std::string cls = normalizeHex(readText(dir + "/bDeviceClass"));
        device.deviceClass = cls.size() >= 2 ? cls.substr(cls.size() - 2) : cls;
        device.speed = readText(dir + "/speed");
        device.driver = symlinkTargetBase(dir + "/driver");
        for (const std::string& child : listDirNames(base)) {
            if (child.rfind(name + ":", 0) == 0) {
                std::string driver = symlinkTargetBase(base + "/" + child + "/driver");
                if (!driver.empty()) {
                    device.interfaceDrivers.push_back(driver);
                }
            }
        }
        if (exported.find(name) != exported.end() &&
            std::find(device.interfaceDrivers.begin(), device.interfaceDrivers.end(), "usbip-host") == device.interfaceDrivers.end()) {
            device.interfaceDrivers.push_back("usbip-host");
        }
        devices.push_back(device);
    }
    return devices;
}

bool matchesRule(const Device& device, const Rule& rule) {
    return wildcardMatch(device.vid, normalizeHex(rule.vid)) &&
           wildcardMatch(device.pid, normalizeHex(rule.pid)) &&
           (rule.busid == "*" || wildcardMatch(device.busid, rule.busid));
}

bool isAllowed(const Config& config, const Device& device) {
    if (config.blockUsbHubs && device.deviceClass == "09") {
        return false;
    }
    for (const Rule& rule : config.blockedDevices) {
        if (matchesRule(device, rule)) {
            return false;
        }
    }
    if (config.bindPolicy == "disabled") {
        return false;
    }
    if (config.bindPolicy == "allow_all") {
        return true;
    }
    if (config.bindPolicy == "allowlist") {
        for (const Rule& rule : config.allowedDevices) {
            if (matchesRule(device, rule)) {
                return true;
            }
        }
        return false;
    }
    std::cerr << "Unknown bind_policy: " << config.bindPolicy << "\n";
    return false;
}

Device* findDevice(std::vector<Device>& devices, const std::string& busid) {
    for (Device& device : devices) {
        if (device.busid == busid) {
            return &device;
        }
    }
    return nullptr;
}

std::string deviceJson(const Device& device) {
    std::ostringstream json;
    json << "{"
         << "\"busid\":" << jsonString(device.busid)
         << ",\"vid\":" << jsonString(device.vid)
         << ",\"pid\":" << jsonString(device.pid)
         << ",\"manufacturer\":" << jsonString(device.manufacturer)
         << ",\"product\":" << jsonString(device.product)
         << ",\"serial\":" << jsonString(device.serial)
         << ",\"device_class\":" << jsonString(device.deviceClass)
         << ",\"speed\":" << jsonString(device.speed)
         << ",\"driver\":" << jsonString(device.driver)
         << ",\"name\":" << jsonString(device.name())
         << ",\"is_exported\":" << (device.exported() ? "true" : "false")
         << "}";
    return json.str();
}

void writeState(const Config& config, const std::string& status, const Device& device, const std::string& error = "") {
    mkdirs(dirnameOf(config.statePath));
    std::string tmp = config.statePath + ".tmp";
    std::ofstream file(tmp);
    if (!file) {
        return;
    }
    file << "{\n  \"devices\": {\n    " << jsonString(device.busid) << ": {\n"
         << "      \"status\": " << jsonString(status) << ",\n"
         << "      \"last_seen\": " << std::time(nullptr) << ",\n"
         << "      \"device\": " << deviceJson(device);
    if (!error.empty()) {
        file << ",\n      \"last_error\": " << jsonString(error);
    }
    file << "\n    }\n  }\n}\n";
    file.close();
    rename(tmp.c_str(), config.statePath.c_str());
}

void notifyWindows(const Config& config, const std::string& event, const Device* device, const std::string& busid, const std::string& error = "") {
    if (!config.notifyEnabled || config.notifyHost.empty()) {
        return;
    }
    addrinfo hints {};
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_family = AF_UNSPEC;
    addrinfo* info = nullptr;
    std::string port = std::to_string(config.notifyPort);
    if (getaddrinfo(config.notifyHost.c_str(), port.c_str(), &hints, &info) != 0) {
        std::cerr << "Could not resolve notify host " << config.notifyHost << "\n";
        return;
    }

    int sock = -1;
    for (addrinfo* rp = info; rp != nullptr; rp = rp->ai_next) {
        sock = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
        if (sock < 0) {
            continue;
        }
        if (connect(sock, rp->ai_addr, rp->ai_addrlen) == 0) {
            break;
        }
        close(sock);
        sock = -1;
    }
    freeaddrinfo(info);
    if (sock < 0) {
        std::cerr << "Could not connect to notify host " << config.notifyHost << ":" << config.notifyPort << "\n";
        return;
    }

    char hostname[256] = {};
    gethostname(hostname, sizeof(hostname) - 1);
    std::ostringstream payload;
    payload << "{"
            << "\"event\":" << jsonString(event)
            << ",\"thinclient\":" << jsonString(hostname)
            << ",\"usbip_port\":" << config.usbipTcpPort
            << ",\"timestamp\":" << std::time(nullptr)
            << ",\"busid\":" << jsonString(busid);
    if (device) {
        payload << ",\"device\":" << deviceJson(*device);
    }
    if (!error.empty()) {
        payload << ",\"error\":" << jsonString(error);
    }
    if (!config.sharedSecret.empty()) {
        payload << ",\"shared_secret\":" << jsonString(config.sharedSecret);
    }
    payload << "}\n";
    std::string data = payload.str();
    send(sock, data.data(), data.size(), 0);
    close(sock);
}

void loadModules(const Config& config) {
    CommandResult result = runCommand({config.modprobe, "-a", "usbip-core", "usbip-host"});
    if (result.exitCode != 0) {
        std::cerr << "Could not load USB/IP modules: " << trim(result.output) << "\n";
    }
}

void settleUdev(const Config& config) {
    if (isExecutable(config.udevadm)) {
        runCommand({config.udevadm, "settle"});
    }
}

bool bindDevice(const Config& config, Device device) {
    if (!isAllowed(config, device)) {
        return false;
    }
    if (device.exported()) {
        writeState(config, "already_exported", device);
        return true;
    }
    std::string lastError;
    for (int attempt = 1; attempt <= config.retryCount && !g_stop; ++attempt) {
        std::cout << "Exporting USB " << device.busid << " " << device.vid << ":" << device.pid
                  << " " << device.name() << " attempt " << attempt << "/" << config.retryCount << "\n";
        CommandResult result = runCommand({config.usbip, "bind", "-b", device.busid});
        lastError = trim(result.output);
        if (result.exitCode == 0 || lower(lastError).find("already") != std::string::npos) {
            writeState(config, "exported", device);
            notifyWindows(config, "exported", &device, device.busid);
            return true;
        }
        std::cerr << "usbip bind failed for " << device.busid << ": " << lastError << "\n";
        std::this_thread::sleep_for(std::chrono::milliseconds(static_cast<int>(config.retryDelaySeconds * 1000)));
        std::vector<Device> refreshed = listDevices(config);
        Device* current = findDevice(refreshed, device.busid);
        if (current) {
            device = *current;
            if (device.exported()) {
                writeState(config, "exported", device);
                notifyWindows(config, "exported", &device, device.busid);
                return true;
            }
        }
    }
    writeState(config, "failed", device, lastError);
    notifyWindows(config, "failed", &device, device.busid, lastError);
    return false;
}

int reconcile(const Config& config, const std::string& targetBusid = "") {
    loadModules(config);
    settleUdev(config);
    std::vector<Device> devices = listDevices(config);
    int count = 0;
    for (const Device& device : devices) {
        if (!targetBusid.empty() && device.busid != targetBusid) {
            continue;
        }
        if (bindDevice(config, device)) {
            ++count;
        }
    }
    return count;
}

void printScan(const Config& config) {
    std::vector<Device> devices = listDevices(config);
    std::cout << "[";
    for (size_t i = 0; i < devices.size(); ++i) {
        if (i > 0) {
            std::cout << ",";
        }
        std::cout << deviceJson(devices[i]);
    }
    std::cout << "]\n";
}

void signalHandler(int) {
    g_stop = 1;
}

void usage() {
    std::cout << "Usage: usbip_manager [--config PATH] [--verbose] <monitor|scan|status|event|bind|unbind> [--busid BUSID]\n";
}

} // namespace

int main(int argc, char** argv) {
    signal(SIGTERM, signalHandler);
    signal(SIGINT, signalHandler);

    std::string configPath = "/etc/usbip-manager/config.json";
    std::string command;
    std::string busid;
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--config" && i + 1 < argc) {
            configPath = argv[++i];
        } else if (arg == "--busid" && i + 1 < argc) {
            busid = argv[++i];
        } else if (arg == "--verbose") {
            // stdout/stderr are captured by systemd; no separate verbosity needed.
        } else if (command.empty()) {
            command = arg;
        } else {
            usage();
            return 2;
        }
    }
    if (command.empty()) {
        usage();
        return 2;
    }

    Config config = loadConfig(configPath);
    if (command == "monitor") {
        std::cout << "USB/IP native manager started; policy=" << config.bindPolicy
                  << ", interval=" << config.reconcileIntervalSeconds << "s\n";
        while (!g_stop) {
            reconcile(config);
            for (int i = 0; i < static_cast<int>(config.reconcileIntervalSeconds * 10) && !g_stop; ++i) {
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
            }
            config = loadConfig(configPath);
        }
        return 0;
    }
    if (command == "event") {
        if (busid.empty()) {
            std::cerr << "event requires --busid\n";
            return 2;
        }
        if (config.settleSeconds > 0) {
            std::this_thread::sleep_for(std::chrono::milliseconds(static_cast<int>(config.settleSeconds * 1000)));
        }
        reconcile(config, busid);
        return 0;
    }
    if (command == "scan" || command == "status") {
        printScan(config);
        return 0;
    }
    if (command == "bind") {
        if (busid.empty()) {
            std::cerr << "bind requires --busid\n";
            return 2;
        }
        std::vector<Device> devices = listDevices(config);
        Device* device = findDevice(devices, busid);
        if (!device) {
            std::cerr << "USB device " << busid << " not found\n";
            return 2;
        }
        return bindDevice(config, *device) ? 0 : 1;
    }
    if (command == "unbind") {
        if (busid.empty()) {
            std::cerr << "unbind requires --busid\n";
            return 2;
        }
        CommandResult result = runCommand({config.usbip, "unbind", "-b", busid});
        std::cout << result.output;
        return result.exitCode;
    }

    usage();
    return 2;
}
