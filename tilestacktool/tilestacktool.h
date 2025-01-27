#ifndef TILESTACKTOOL_H
#define TILESTACKTOOL_H

#include <cstdlib>
#include <fstream>
#include <list>
#include <memory>
#include <streambuf>
#include <string>

#include "JSON.h"
#include "xmlreader.h"

#include "simple_shared_ptr.h"
#include "Tilestack.h"

void usage(const char *fmt, ...);

class Arglist : public std::list<std::string> {
public:
  Arglist(char **begin, char **end) {
    for (char **arg = begin; arg < end; arg++) push_back(std::string(*arg));
  }
  std::string shift() {
    if (empty()) usage("Missing argument");
    std::string ret = front();
    pop_front();
    return ret;
  }
  double shift_double() {
    std::string arg = shift();
    char *end;
    double ret = strtod(arg.c_str(), &end);
    if (end != arg.c_str() + arg.length()) {
      usage("Can't parse '%s' as floating point value", arg.c_str());
    }
    return ret;
  }
  int shift_int() {
    std::string arg = shift();
    char *end;
    int ret = strtol(arg.c_str(), &end, 0);
    if (end != arg.c_str() + arg.length()) {
      usage("Can't parse '%s' as integer", arg.c_str());
    }
    return ret;
  }
  JSON shift_json() {
    std::string arg = shift();
    if (arg.size() > 0 && arg[0] == '@') {
      return JSON::fromFile(arg.c_str() + 1);
    } else {
      return JSON(arg);
    }
  }
  bool next_is_non_flag() const {
    if (empty()) return false;
    if (front().length() > 0 && front()[0] == '-') return false;
    return true;
  }
};

template <typename T>
class AutoPtrStack {
  std::list<simple_shared_ptr<T> > stack;
public:
  void push(simple_shared_ptr<T> &t) {
    stack.push_back(t);
  }
  simple_shared_ptr<T> pop() {
    assert(!stack.empty());
    simple_shared_ptr<T> ret = stack.back();
    stack.pop_back();
    return ret;
  }
  simple_shared_ptr<T> top() {
    assert(!stack.empty());
    return stack.back();
  }
  int size() { 
    return stack.size(); 
  }
};

extern AutoPtrStack<Tilestack> tilestackstack;

typedef bool (*Command)(const std::string &flag, Arglist &arglist);
bool register_command(Command cmd);

#endif
