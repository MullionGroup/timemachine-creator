
#ifdef _WIN32
  #define _CRT_SECURE_NO_WARNINGS 1
#endif

#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <algorithm>
#include <stdexcept>
#include <vector>
#include <sys/stat.h>

#ifdef _WIN32
  #include <process.h>
  #include <Windows.h>
  #include <Userenv.h>
  #pragma comment(lib, "userenv.lib")
  #pragma comment(lib, "Advapi32.lib")
#else
  #include <strings.h>
  #include <sys/utsname.h>
  #include <sys/time.h>
  #include <sys/resource.h>
  #include <unistd.h>
#endif

#include "cpp_utils.h"

// From Randy Sargent's public domain library, 2001-2012

#ifdef _WIN32
  // Windows
  #define ALLOWABLE_DIRECTORY_DELIMITERS "/\\"
  #define DIRECTORY_DELIMITER '\\'
  #define DIRECTORY_DELIMITER_STRING "\\"
#else
  // UNIX
  #define ALLOWABLE_DIRECTORY_DELIMITERS "/"
  #define DIRECTORY_DELIMITER '/'
  #define DIRECTORY_DELIMITER_STRING "/"
#endif

std::string filename_sans_directory(const std::string &filename)
{
  size_t lastDirDelim = filename.find_last_of(ALLOWABLE_DIRECTORY_DELIMITERS);
  // No directory delimiter, so return filename
  if (lastDirDelim == std::string::npos) return filename;
  // Return everything after the delimiter
  return filename.substr(lastDirDelim+1);
}

std::string filename_directory(const std::string &filename)
{
  size_t lastDirDelim = filename.find_last_of(ALLOWABLE_DIRECTORY_DELIMITERS);
  // No directory delimiter, so return nothing
  if (lastDirDelim == std::string::npos) return "";
  // Return everything up to just before the last delimiter
  return filename.substr(0, lastDirDelim);
}

std::string filename_sans_suffix(const std::string &filename)
{
  // Find the last '.'
  size_t lastDot = filename.find_last_of(".");
  if (lastDot == std::string::npos) return filename;

  // Find the last directory delimiter
  size_t lastDirDelim = filename.find_last_of(ALLOWABLE_DIRECTORY_DELIMITERS);

  if (lastDirDelim != std::string::npos &&
      lastDot < lastDirDelim) {
    // The last dot was inside the directory name, so return as is
    return filename;
  }

  // Return everything up to the last dot
  return filename.substr(0, lastDot);
}

std::string filename_suffix(const std::string &filename)
{
  // Find the last '.'
  size_t lastDot = filename.find_last_of(".");
  if (lastDot == std::string::npos) return "";

  // Find the last directory delimiter
  size_t lastDirDelim = filename.find_last_of(ALLOWABLE_DIRECTORY_DELIMITERS);

  if (lastDirDelim != std::string::npos &&
      lastDot < lastDirDelim) {
    // The last dot was inside the directory name, so no suffix
    return "";
  }

  // Return everything after the last dot
  return filename.substr(lastDot+1);
}

std::string filename_suffix_with_dot(const std::string &filename)
{
  // Find the last '.'
  size_t lastDot = filename.find_last_of(".");
  if (lastDot == std::string::npos) return "";

  // Find the last directory delimiter
  size_t lastDirDelim = filename.find_last_of(ALLOWABLE_DIRECTORY_DELIMITERS);

  if (lastDirDelim != std::string::npos &&
      lastDot < lastDirDelim) {
    // The last dot was inside the directory name, so no suffix
    return "";
  }

  // Return everything starting with last dot
  return filename.substr(lastDot);
}

std::string string_vprintf(const char *fmt, va_list args) {
  size_t size = 500;
  char *buf = (char *)malloc(size);
  // grow the buffer size until the output is no longer truncated
  while (1) {
    va_list args_copy;
#if defined(_WIN32)
    args_copy = args;
    size_t nwritten = _vsnprintf(buf, size-1, fmt, args_copy);
#else
    va_copy(args_copy, args);
    size_t nwritten = vsnprintf(buf, size-1, fmt, args_copy);
#endif
    // Some c libraries return -1 for overflow, some return a number larger than size-1
    if (nwritten < size-2) {
      buf[nwritten+1] = 0;
      std::string ret(buf);
      free(buf);
      return ret;
    }
    size *= 2;
    buf = (char *)realloc(buf, size);
  }
}

std::string string_printf(const char *fmt, ...) {
  va_list args;
  va_start(args, fmt);
  std::string ret = string_vprintf(fmt, args);
  va_end(args);
  return ret;
}

#ifndef CPP_UTILS_OMIT_FILESYSTEM

void make_directory(const std::string &dirname) {
#ifdef _WIN32
  _wmkdir(Unicode(dirname).path());
#else
  mkdir(Unicode(dirname).path(), 0777);
#endif
}

void make_directory_and_parents(const std::string &dirname) {
  if (dirname == "") return;
  make_directory_and_parents(filename_directory(dirname));
  make_directory(dirname);
}

bool filename_exists(const std::string &filename) {
#ifdef _WIN32
  struct _stat64i32 s;
  return (0 == _wstat(Unicode(filename).path(), &s));
#else
  struct stat s;
  return (0 == stat(Unicode(filename).path(), &s));
#endif
}

void rename_file(const std::string &src, const std::string &dest) {
#ifdef _WIN32
  if (!MoveFileExW(Unicode(src).path(), Unicode(dest).path(), MOVEFILE_REPLACE_EXISTING)) {
    throw_error("Can't rename %s to %s", src.c_str(), dest.c_str());
  }
#else
  if (rename(src.c_str(), dest.c_str())) {
    throw_error("Can't rename %s to %s", src.c_str(), dest.c_str());
  }
#endif
}

bool delete_file(const std::string &src) {
#ifdef _WIN32
  return 0 == _wunlink(Unicode(src).path());
#else
  return 0 == unlink(Unicode(src).path());
#endif
}

// Returns -1 if error
long long file_size(const std::string &src) {
  struct stat stat_buf;
  if (stat(src.c_str(), &stat_buf)) return -1;
  return stat_buf.st_size;
}

std::string read_file(const std::string &filename) {
  FILE *in = fopen_utf8(filename, "rb");
  if (!in) return "";
  std::vector<char> buf(1024*1024);
  std::string ret;
  while (1) {
    size_t nread = fread(&buf[0], 1, sizeof(buf), in);
    if (nread <= 0) break;
    ret.append(&buf[0], nread);
  }
  fclose(in);
  return ret;
}

#endif /* #ifndef CPP_UTILS_OMIT_FILESYSTEM */

FILE *fopen_utf8(const std::string &filename, const char *mode) {
#ifdef _WIN32
  return _wfopen(Unicode(filename).path(), Unicode(mode).path());
#else
  return fopen(filename.c_str(), mode);
#endif
}

static std::string remove_b(const char *str) {
  std::string ret(str);
  // Remove instances of 'b'
  ret.erase(std::remove(ret.begin(), ret.end(), 'b'));
  return ret;
}

int system_utf8(const std::string &cmdline) {
#ifdef _WIN32
  // Add quotes around entire commandline per http://msdn.microsoft.com/en-us/library/96ayss4b.aspx
  return _wsystem(Unicode("\"" + cmdline + "\"").path());
#else
  return system(cmdline.c_str());
#endif
}

FILE *popen_utf8(const std::string &cmdline, const char *mode) {
#ifdef _WIN32
  // Add quotes around entire commandline per http://msdn.microsoft.com/en-us/library/96ayss4b.aspx
  return _wpopen(Unicode("\"" + cmdline + "\"").path(), Unicode(mode).path());
#else
  return popen(cmdline.c_str(), remove_b(mode).c_str());
#endif
}

#ifdef _WIN32
int pclose(FILE *p) {
  return _pclose(p);
}
#endif

bool iequals(const std::string &a, const std::string &b)
{
#ifdef _WIN32
  return !_stricmp(a.c_str(), b.c_str());
#else
  return !strcasecmp(a.c_str(), b.c_str());
#endif
}

std::string temporary_path(const std::string &path)
{
  // TODO(RS): make this thread-safe if we someday use threads
  static unsigned int counter = 0;
  static std::string cached_hostname;
  if (!counter) cached_hostname = hostname();
#ifdef _WIN32
        int pid = _getpid();
#else
        int pid = getpid();
#endif
  return string_printf("%s_%s_%d_%d_%d%s",
                       filename_sans_suffix(path).c_str(),
                       cached_hostname.c_str(),
                       (int) time(0),
                       pid,
                       counter++,
                       filename_suffix_with_dot(path).c_str());
}

#ifdef _WIN32
std::string hostname()
{
  char buf[1000];
  DWORD bufsize = sizeof(buf);
  GetComputerNameExA(ComputerNameDnsHostname, buf, &bufsize);
  return std::string(buf, bufsize);
}
#else
std::string hostname()
{
  struct utsname u;
  if (uname(&u)) {
    perror("uname");
    exit(1);
  }
  return u.nodename;
}
#endif

void throw_error(const char *fmt, ...) {
  va_list args;
  va_start(args, fmt);
  std::string msg = string_vprintf(fmt, args);
  va_end(args);
  throw std::runtime_error(msg);
}

std::string executable_suffix() {
#ifdef _WIN32
  return ".exe";
#else
  return "";
#endif
}


///// executable_path

// From http://stackoverflow.com/questions/1023306/finding-current-executables-path-without-proc-self-exe
// Mac OS X: _NSGetExecutablePath() (man 3 dyld)
// Linux: readlink /proc/self/exe
// Solaris: getexecname()
// FreeBSD: sysctl CTL_KERN KERN_PROC KERN_PROC_PATHNAME -1
// BSD with procfs: readlink /proc/curproc/file
// Windows: GetModuleFileName() with hModule = NULL

#if defined(_WIN32)
std::string executable_path() {
  wchar_t buf[10000];
  DWORD bufsize = sizeof(buf);
  GetModuleFileNameW(NULL, buf, bufsize);
  return Unicode(buf).utf8();
}

#elif defined(__APPLE__)
#include <mach-o/dyld.h>
std::string executable_path() {
  uint32_t len = 0;
  int ret = _NSGetExecutablePath(NULL, &len);
  assert(ret == -1);
  std::vector<char> buf(len);
  ret = _NSGetExecutablePath(&buf[0], &len);
  return std::string(&buf[0]);
}
#else
// Linux
std::string executable_path() {
  std::vector<char> buf(1000);
  while (1) {
    int ret = readlink("/proc/self/exe", &buf[0], buf.size());
    assert(ret > 0);
    if (ret < (int)buf.size()) return std::string(&buf[0], ret);
    buf.resize(buf.size()*2);
  }
}
#endif

///// home_directory

#ifdef _WIN32
std::string home_directory() {
  TCHAR buf[10000]={0};
  DWORD bufsize = sizeof(buf);
  HANDLE token = 0;
  OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token);
  GetUserProfileDirectory(token, buf, &bufsize);
  CloseHandle(token);
  return Unicode(buf).utf8();
}

#else

// Linux or OS X
#include <unistd.h>
#include <sys/types.h>
#include <pwd.h>

std::string home_directory() {
  struct passwd pwd, *pwdptr = NULL;
  char buf[10000];
  getpwuid_r(getuid(), &pwd, buf, sizeof(buf), &pwdptr);
  return pwdptr ? pwdptr->pw_dir : "";
}
#endif

///// application_user_state_directory

#if defined(_WIN32)
std::string application_user_state_directory(const std::string &application_name) {
  return home_directory() + "/Application Data/" + application_name;
}
#elif defined(__APPLE__)
std::string application_user_state_directory(const std::string &application_name) {
  return home_directory() + "/Library/Application Support/" + application_name;
}
#else
std::string application_user_state_directory(const std::string &application_name) {
  return home_directory() + "/usr/local" + application_name;
}
#endif

///// Unicode paths

Unicode::Unicode(const std::string &utf8) : m_utf8(utf8) {
        init_from_utf8();
}
Unicode::Unicode(const char *utf8) : m_utf8(utf8) {
        init_from_utf8();
}
const char *Unicode::utf8() { return m_utf8.c_str(); }
#ifdef _WIN32
Unicode::Unicode(const wchar_t *utf16) : m_utf16(utf16, utf16+wcslen(utf16)+1) {
  std::vector<char> tmp(m_utf16.size() * 4);
  // TODO(PD) or TODO(RS): patch from Paul Heckbert's code
  wcstombs(&tmp[0], utf16, tmp.size());
  m_utf8 = std::string(&tmp[0]);
}
const wchar_t *Unicode::utf16() { return &m_utf16[0]; }
void Unicode::init_from_utf8() {
  // calculate size of output buffer (this includes terminating NULL)
  int nchars = MultiByteToWideChar(CP_UTF8, 0, m_utf8.c_str(), -1, NULL, 0);
  assert(nchars>0);
  m_utf16.resize(nchars);
  // see http://msdn.microsoft.com/en-us/library/windows/desktop/dd319072%28v=vs.85%29.aspx
  // this time, do the conversion and write to m_utf16
  int nchars_written = MultiByteToWideChar(CP_UTF8, 0, m_utf8.c_str(), -1, &m_utf16[0], nchars);
  assert(nchars_written == nchars);
}
const wchar_t *Unicode::path() { return utf16(); }
#else
void Unicode::init_from_utf8() {}
const char *Unicode::path() { return utf8(); }
#endif

#if defined(__APPLE__)
std::string os() { return "osx"; }
#elif defined(_WIN32)
std::string os() { return "windows"; }
#else
std::string os() { return "linux"; }
#endif

#if defined(_WIN32)

double filetime_to_double(struct _FILETIME &ft) {
  unsigned long long t = ft.dwLowDateTime + ((unsigned long long)ft.dwHighDateTime << 32);
  return t / 1e7;
}

void get_cpu_usage(double &user, double &system) {
  struct _FILETIME creation_time, exit_time, kernel_time, user_time;
  GetProcessTimes(GetCurrentProcess(), &creation_time, &exit_time, &kernel_time, &user_time);
  user = filetime_to_double(user_time);
  system = filetime_to_double(kernel_time);
}

#else

double tv_to_double(struct timeval &tv) {
  return tv.tv_sec + tv.tv_usec / 1e6;
}
void get_cpu_usage(double &user, double &system) {
  struct rusage usage;
  getrusage(RUSAGE_SELF, &usage);
  user = tv_to_double(usage.ru_utime);
  system = tv_to_double(usage.ru_stime);
}

#endif
