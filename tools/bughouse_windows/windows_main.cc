// Preserve Unicode command-line paths without depending on Windows' ACP.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <clocale>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

int hivemind_main(int argc, char* argv[]);

int wmain(int argc, wchar_t* argv[]) {
    try {
        // Path conversions use UTF-8. Keep the numeric locale at C for UCI.
        if (!std::setlocale(LC_CTYPE, ".UTF8")) {
            throw std::runtime_error("The Windows C runtime cannot enable UTF-8 paths");
        }
        std::vector<std::string> storage;
        storage.reserve(argc);
        for (int i = 0; i < argc; ++i) {
            const int length = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                argv[i], -1, nullptr, 0, nullptr, nullptr);
            if (!length) throw std::runtime_error("Invalid Unicode command-line argument");
            std::string value(length, '\0');
            if (!WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, argv[i], -1,
                                     value.data(), length, nullptr, nullptr)) {
                throw std::runtime_error("Could not convert Unicode command-line argument");
            }
            value.pop_back();
            storage.push_back(std::move(value));
        }
        std::vector<char*> arguments;
        for (auto& value : storage) arguments.push_back(value.data());
        arguments.push_back(nullptr);
        return hivemind_main(argc, arguments.data());
    } catch (const std::exception& error) {
        std::cerr << "Hivemind startup failed: " << error.what() << std::endl;
        return 1;
    }
}
