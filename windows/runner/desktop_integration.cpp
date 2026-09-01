#include "desktop_integration.h"

#include <shlobj.h>

#include <string>

namespace {

// Where the answer lives. Shared with the installer (installer.iss), which
// writes "yes" or "no" according to its "Open .pgn files" checkbox.
constexpr wchar_t kChoiceKey[] = L"Software\\ChessAutoPrep";
constexpr wchar_t kChoiceValue[] = L"FileAssociationChoice";

constexpr wchar_t kProgId[] = L"ChessAutoPrep.pgn";
constexpr wchar_t kProgIdKey[] = L"Software\\Classes\\ChessAutoPrep.pgn";
constexpr wchar_t kExtensionKey[] = L"Software\\Classes\\.pgn";
constexpr wchar_t kApplicationKey[] =
    L"Software\\Classes\\Applications\\chess_auto_prep.exe";

void SetString(const std::wstring& subkey, const wchar_t* value_name,
               const std::wstring& data) {
  ::RegSetKeyValueW(HKEY_CURRENT_USER, subkey.c_str(), value_name, REG_SZ,
                    data.c_str(),
                    static_cast<DWORD>((data.size() + 1) * sizeof(wchar_t)));
}

std::wstring ReadChoice() {
  wchar_t buffer[16] = {};
  DWORD size = sizeof(buffer);
  LSTATUS status =
      ::RegGetValueW(HKEY_CURRENT_USER, kChoiceKey, kChoiceValue,
                     RRF_RT_REG_SZ, nullptr, buffer, &size);
  return status == ERROR_SUCCESS ? std::wstring(buffer) : std::wstring();
}

void WriteChoice(const wchar_t* choice) {
  SetString(kChoiceKey, kChoiceValue, choice);
}

// True when no application (per-user or machine-wide) claims .pgn.
bool PgnIsUnclaimed() {
  wchar_t buffer[256] = {};
  DWORD size = sizeof(buffer);
  LSTATUS status = ::RegGetValueW(HKEY_CLASSES_ROOT, L".pgn", nullptr,
                                  RRF_RT_REG_SZ, nullptr, buffer, &size);
  return status != ERROR_SUCCESS || buffer[0] == L'\0';
}

// Registers this executable as a .pgn handler under the user's hive: a
// ProgID for the type, a place in the "Open with" list, and — when nothing
// else owns .pgn — the default. Windows keeps a default the user picked
// themselves (UserChoice) ahead of all of this, as it should.
void RegisterPgnAssociation() {
  wchar_t exe_buffer[MAX_PATH] = {};
  if (::GetModuleFileNameW(nullptr, exe_buffer, MAX_PATH) == 0) return;
  const std::wstring exe(exe_buffer);
  const std::wstring open_command = L"\"" + exe + L"\" \"%1\"";

  SetString(kProgIdKey, nullptr, L"PGN chess games");
  SetString(std::wstring(kProgIdKey) + L"\\DefaultIcon", nullptr,
            L"\"" + exe + L"\",0");
  SetString(std::wstring(kProgIdKey) + L"\\shell\\open\\command", nullptr,
            open_command);

  SetString(std::wstring(kExtensionKey) + L"\\OpenWithProgids", kProgId, L"");
  if (PgnIsUnclaimed()) SetString(kExtensionKey, nullptr, kProgId);

  SetString(kApplicationKey, L"FriendlyAppName", L"Chess Auto Prep");
  SetString(std::wstring(kApplicationKey) + L"\\shell\\open\\command", nullptr,
            open_command);
  SetString(std::wstring(kApplicationKey) + L"\\SupportedTypes", L".pgn",
            L"");

  ::SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, nullptr, nullptr);
}

}  // namespace

void DesktopIntegrationMaybeSetup(HWND parent_window) {
  const std::wstring choice = ReadChoice();
  if (choice == L"yes") {
    // Refreshed every launch so the registration survives moving the
    // unzipped folder.
    RegisterPgnAssociation();
    return;
  }
  if (choice == L"no") return;

  const int answer = ::MessageBoxW(
      parent_window,
      L"Make Chess Auto Prep the app Windows suggests for .pgn files?\n\n"
      L"This only changes settings for your account. You can change it later "
      L"in Settings > Apps > Default apps.",
      L"Open .pgn files with Chess Auto Prep?",
      MB_YESNO | MB_ICONQUESTION | MB_DEFBUTTON1);
  if (answer == IDYES) {
    WriteChoice(L"yes");
    RegisterPgnAssociation();
  } else if (answer == IDNO) {
    WriteChoice(L"no");
  }
}
