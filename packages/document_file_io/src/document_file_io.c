#ifndef _WIN32
#if defined(__linux__)
#define _GNU_SOURCE
#endif
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE
#endif
#define _POSIX_C_SOURCE 200809L
#else
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0602
#endif
#endif
/* Narrow ABI: the OS supplies identity and bytes from the same open object.
 * Status: 0 success, 1 missing, 2 IO failure, 3 changed, 4 unsupported object.
 * Every allocation is owned by cap_snapshot_free. Never follow a final link.
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <wchar.h>
#include <errno.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#define CAP_EXPORT __declspec(dllexport)
#else
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <sys/stdio.h>
#endif
#if defined(__linux__)
#include <sys/syscall.h>
#include <linux/fs.h>
#endif
#define CAP_EXPORT __attribute__((visibility("default")))
#endif

typedef struct {
  uint64_t volume, id_low, id_high, size;
  uint8_t *bytes;
  int32_t status, error;
} cap_snapshot;

#ifdef _WIN32
static wchar_t *wide_path(const char *path) {
  int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, NULL, 0);
  if (!size) return NULL;
  wchar_t *wide = calloc((size_t)size, sizeof(wchar_t));
  if (!wide) return NULL;
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide, size);
  for (wchar_t *p = wide; *p; ++p) if (*p == L'/') *p = L'\\';
  /* Already extended, including UNC. Do not normalize this namespace again. */
  if (wcsncmp(wide, L"\\\\?\\", 4) == 0) return wide;
  DWORD length = GetFullPathNameW(wide, 0, NULL, NULL);
  if (!length) { free(wide); return NULL; }
  wchar_t *absolute = calloc((size_t)length, sizeof(wchar_t));
  if (!absolute) { free(wide); return NULL; }
  DWORD copied = GetFullPathNameW(wide, length, absolute, NULL);
  free(wide);
  if (!copied || copied >= length) { free(absolute); return NULL; }
  int unc = wcsncmp(absolute, L"\\\\", 2) == 0;
  const wchar_t *prefix = unc ? L"\\\\?\\UNC\\" : L"\\\\?\\";
  wchar_t *out = calloc(wcslen(absolute) + 9, sizeof(wchar_t));
  if (out) {
    wcscpy(out, prefix);
    wcscat(out, absolute + (unc ? 2 : 0));
  }
  free(absolute);
  return out;
}
static HANDLE open_read(const wchar_t *path) {
  return CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
    NULL, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_SEQUENTIAL_SCAN |
    FILE_FLAG_BACKUP_SEMANTICS, NULL);
}
#endif

/* Publish a staged file, preserving the existing Windows ACL and metadata.
 * Never delete the destination first or fall back to a lossy copy. Sharing
 * violations are retried by the Dart caller without blocking its isolate. */
CAP_EXPORT int32_t cap_replace_file(const char *source, const char *destination,
                                  const char *recovery) {
#ifdef _WIN32
  wchar_t *from = wide_path(source), *to = wide_path(destination), *backup = wide_path(recovery);
  if (!from || !to || !backup) {
    free(from); free(to); free(backup); return ERROR_INVALID_NAME;
  }
  if (GetFileAttributesW(backup) != INVALID_FILE_ATTRIBUTES) {
    free(from); free(to); free(backup); return ERROR_FILE_EXISTS;
  }
  int32_t error;
  if (ReplaceFileW(to, from, backup, 0, NULL, NULL)) {
    error = 0;
    /* Cleanup must not turn a committed save into a reported failure. */
    DeleteFileW(backup);
  } else {
    error = GetLastError();
    /* Unlike a backup-less replacement, a failed namespace move retains
     * the old bytes. Restore exclusively; if this fails, leave the recovery
     * copy and staged bytes for recovery rather than destroying either. */
    if (error == ERROR_UNABLE_TO_MOVE_REPLACEMENT_2) {
      MoveFileExW(backup, to, MOVEFILE_WRITE_THROUGH);
    }
    /* ReplaceFile requires an existing destination. A new name is claimed
     * exclusively, so an external creator racing this check is not erased. */
    if (error == ERROR_FILE_NOT_FOUND &&
        GetFileAttributesW(to) == INVALID_FILE_ATTRIBUTES &&
        GetLastError() == ERROR_FILE_NOT_FOUND) {
      error = MoveFileExW(from, to, MOVEFILE_WRITE_THROUGH) ? 0 : GetLastError();
    }
  }
  free(from); free(to); free(backup); return error;
#else
  (void)recovery;
  return rename(source, destination) == 0 ? 0 : errno;
#endif
}

/* Flush the staged bytes before publishing the name. macOS fsync alone does
 * not request a drive-cache flush; F_FULLFSYNC supplies that stronger step. */
CAP_EXPORT int32_t cap_sync_file(const char *path) {
#ifdef _WIN32
  wchar_t *wide = wide_path(path);
  if (!wide) return ERROR_INVALID_NAME;
  HANDLE fd = CreateFileW(wide, GENERIC_WRITE, FILE_SHARE_READ, NULL,
    OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, NULL);
  free(wide);
  if (fd == INVALID_HANDLE_VALUE) return GetLastError();
  int32_t error = FlushFileBuffers(fd) ? 0 : GetLastError();
  CloseHandle(fd); return error;
#else
  int fd = open(path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW);
  if (fd < 0) return errno;
  int result;
#if defined(__APPLE__)
  do { result = fcntl(fd, F_FULLFSYNC); } while (result < 0 && errno == EINTR);
#else
  do { result = fsync(fd); } while (result < 0 && errno == EINTR);
#endif
  int error = result < 0 ? errno : 0;
  close(fd); return error;
#endif
}

CAP_EXPORT cap_snapshot *cap_snapshot_read(const char *path) {
  cap_snapshot *out = calloc(1, sizeof(cap_snapshot));
  if (!out) return NULL;
  out->status = 2;
#ifdef _WIN32
  wchar_t *wide = wide_path(path);
  if (!wide) { out->error = ERROR_INVALID_NAME; return out; }
  HANDLE fd = open_read(wide);
  if (fd == INVALID_HANDLE_VALUE) {
    out->error = GetLastError();
    if (out->error == ERROR_FILE_NOT_FOUND || out->error == ERROR_PATH_NOT_FOUND) out->status = 1;
    free(wide); return out;
  }
  FILE_ID_INFO first_id, last_id, path_id;
  BY_HANDLE_FILE_INFORMATION first, last;
  if (!GetFileInformationByHandleEx(fd, FileIdInfo, &first_id, sizeof(first_id)) ||
      !GetFileInformationByHandle(fd, &first)) { out->error = GetLastError(); goto done; }
  if (first.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT) || first.nNumberOfLinks != 1) {
    out->status = 4; goto done;
  }
  out->size = ((uint64_t)first.nFileSizeHigh << 32) | first.nFileSizeLow;
  out->volume = first_id.VolumeSerialNumber;
  memcpy(&out->id_low, first_id.FileId.Identifier, 8);
  memcpy(&out->id_high, first_id.FileId.Identifier + 8, 8);
#else
  int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
  if (fd < 0) {
    out->error = errno;
    if (errno == ENOENT || errno == ENOTDIR) out->status = 1;
    if (errno == ELOOP) out->status = 4;
    return out;
  }
  struct stat first, last, binding;
  if (fstat(fd, &first)) { out->error = errno; goto done; }
  if (!S_ISREG(first.st_mode) || first.st_nlink != 1) { out->status = 4; goto done; }
  out->size = (uint64_t)first.st_size;
  out->volume = (uint64_t)first.st_dev;
  out->id_low = (uint64_t)first.st_ino;
#endif
  /* Bound allocation even for virtual files and changing remote placeholders. */
  if (out->size > 512ULL * 1024 * 1024) { out->status = 4; goto done; }
  out->bytes = malloc(out->size ? (size_t)out->size : 1);
  if (!out->bytes) { out->error = ENOMEM; goto done; }
  uint64_t offset = 0;
  while (offset < out->size) {
    uint32_t count = (uint32_t)((out->size - offset) > 1048576 ? 1048576 : (out->size - offset));
#ifdef _WIN32
    DWORD read_count = 0;
    if (!ReadFile(fd, out->bytes + offset, count, &read_count, NULL)) { out->error = GetLastError(); goto done; }
    if (!read_count) { out->status = 3; goto done; }
#else
    ssize_t read_count = read(fd, out->bytes + offset, count);
    if (read_count < 0 && errno == EINTR) continue;
    if (read_count < 0) { out->error = errno; goto done; }
    if (!read_count) { out->status = 3; goto done; }
#endif
    offset += (uint64_t)read_count;
  }
#ifdef _WIN32
  if (!GetFileInformationByHandleEx(fd, FileIdInfo, &last_id, sizeof(last_id)) ||
      !GetFileInformationByHandle(fd, &last)) { out->error = GetLastError(); goto done; }
  if (memcmp(&first_id, &last_id, sizeof(first_id)) || first.nNumberOfLinks != last.nNumberOfLinks ||
      first.nFileSizeHigh != last.nFileSizeHigh || first.nFileSizeLow != last.nFileSizeLow ||
      CompareFileTime(&first.ftLastWriteTime, &last.ftLastWriteTime)) { out->status = 3; goto done; }
  HANDLE named = open_read(wide);
  if (named == INVALID_HANDLE_VALUE) { out->status = 3; goto done; }
  int same = GetFileInformationByHandleEx(named, FileIdInfo, &path_id, sizeof(path_id)) &&
             !memcmp(&first_id, &path_id, sizeof(first_id));
  CloseHandle(named);
  if (!same) { out->status = 3; goto done; }
#else
  if (fstat(fd, &last)) { out->error = errno; goto done; }
#if defined(__APPLE__)
#define MTIME st_mtimespec
#define CTIME st_ctimespec
#else
#define MTIME st_mtim
#define CTIME st_ctim
#endif
  if (first.st_size != last.st_size || first.st_nlink != last.st_nlink ||
      first.MTIME.tv_sec != last.MTIME.tv_sec || first.MTIME.tv_nsec != last.MTIME.tv_nsec ||
      first.CTIME.tv_sec != last.CTIME.tv_sec || first.CTIME.tv_nsec != last.CTIME.tv_nsec ||
      lstat(path, &binding) || !S_ISREG(binding.st_mode) ||
      binding.st_dev != first.st_dev || binding.st_ino != first.st_ino) { out->status = 3; goto done; }
#endif
  out->status = 0;
done:
#ifdef _WIN32
  CloseHandle(fd); free(wide);
#else
  close(fd);
#endif
  return out;
}

CAP_EXPORT void cap_snapshot_free(cap_snapshot *value) {
  if (value) { free(value->bytes); free(value); }
}

/* A directory move preserves native identity. Do not infer completion from a
 * path existing: a different directory may have appeared after interruption. */
CAP_EXPORT cap_snapshot *cap_directory_identity(const char *path) {
  cap_snapshot *out = calloc(1, sizeof(cap_snapshot));
  if (!out) return NULL;
  out->status = 2;
#ifdef _WIN32
  wchar_t *wide = wide_path(path);
  if (!wide) { out->error = ERROR_INVALID_NAME; return out; }
  HANDLE fd = CreateFileW(wide, FILE_READ_ATTRIBUTES,
    FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING,
    FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, NULL);
  free(wide);
  if (fd == INVALID_HANDLE_VALUE) {
    out->error = GetLastError();
    if (out->error == ERROR_FILE_NOT_FOUND || out->error == ERROR_PATH_NOT_FOUND) out->status = 1;
    return out;
  }
  FILE_ID_INFO identity;
  BY_HANDLE_FILE_INFORMATION info;
  if (!GetFileInformationByHandleEx(fd, FileIdInfo, &identity, sizeof(identity)) ||
      !GetFileInformationByHandle(fd, &info)) out->error = GetLastError();
  else if (!(info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ||
           (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) out->status = 4;
  else {
    out->volume = identity.VolumeSerialNumber;
    memcpy(&out->id_low, identity.FileId.Identifier, 8);
    memcpy(&out->id_high, identity.FileId.Identifier + 8, 8);
    out->status = 0;
  }
  CloseHandle(fd);
#else
  int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY);
  if (fd < 0) {
    out->error = errno;
    if (errno == ENOENT) out->status = 1;
    if (errno == ELOOP || errno == ENOTDIR) out->status = 4;
    return out;
  }
  struct stat identity, binding;
  if (fstat(fd, &identity)) out->error = errno;
  else if (lstat(path, &binding) || !S_ISDIR(binding.st_mode) ||
           binding.st_dev != identity.st_dev || binding.st_ino != identity.st_ino) out->status = 3;
  else {
    out->volume = (uint64_t)identity.st_dev;
    out->id_low = (uint64_t)identity.st_ino;
    out->status = 0;
  }
  close(fd);
#endif
  return out;
}

/* Publish an already flushed same-directory temporary file without replacing
 * an existing name. link/unlink makes the POSIX name claim exclusive even
 * against non-cooperating creators. Returns the OS error, zero on success.
 */
CAP_EXPORT int32_t cap_install_new(const char *source, const char *destination) {
#ifdef _WIN32
  wchar_t *from = wide_path(source), *to = wide_path(destination);
  if (!from || !to) { free(from); free(to); return ERROR_INVALID_NAME; }
  int32_t error = MoveFileExW(from, to, MOVEFILE_WRITE_THROUGH) ? 0 : GetLastError();
  free(from); free(to); return error;
#else
  if (link(source, destination)) return errno;
  /* Destination is installed even when source cleanup fails. The Dart caller
   * owns the temporary artifact and verifies the installed identity. */
  unlink(source);
  return 0;
#endif
}

CAP_EXPORT int32_t cap_sync_directory(const char *path) {
#ifdef _WIN32
  /* There is no equivalent namespace durability promise for this adapter. */
  return ERROR_NOT_SUPPORTED;
#else
  int fd = open(path, O_RDONLY | O_CLOEXEC | O_DIRECTORY);
  if (fd < 0) return errno;
  int result;
  do { result = fsync(fd); } while (result < 0 && errno == EINTR);
  int error = result < 0 ? errno : 0;
  close(fd);
  return error;
#endif
}

/* Exclusive namespace move; unsupported filesystems fail without a replacing
 * fallback. Native-host validation is still required on macOS and Windows. */
CAP_EXPORT int32_t cap_move_directory_new(const char *source, const char *destination) {
#if defined(__linux__)
  return syscall(SYS_renameat2, AT_FDCWD, source, AT_FDCWD, destination,
                 RENAME_NOREPLACE) == 0 ? 0 : errno;
#elif defined(__APPLE__)
  return renamex_np(source, destination, RENAME_EXCL) == 0 ? 0 : errno;
#elif defined(_WIN32)
  wchar_t *from = wide_path(source), *to = wide_path(destination);
  if (!from || !to) { free(from); free(to); return ERROR_INVALID_NAME; }
  int32_t error = MoveFileExW(from, to, MOVEFILE_WRITE_THROUGH) ? 0 : GetLastError();
  free(from); free(to); return error;
#else
  return ENOTSUP;
#endif
}
