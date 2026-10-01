// Minimális Arduino String pótlék, hogy az obd_parse.h PC-n is lefordítható és tesztelhető legyen.
#pragma once
#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>

class String {
  std::string s;
 public:
  String() {}
  String(const char* c) : s(c ? c : "") {}
  String(const std::string& v) : s(v) {}
  String(char c) : s(1, c) {}

  size_t length() const { return s.size(); }
  const char* c_str() const { return s.c_str(); }
  char operator[](size_t i) const { return i < s.size() ? s[i] : 0; }

  void trim() {
    size_t a = 0, b = s.size();
    while (a < b && isspace((unsigned char)s[a])) a++;
    while (b > a && isspace((unsigned char)s[b - 1])) b--;
    s = s.substr(a, b - a);
  }
  void toUpperCase() { for (auto& c : s) c = (char)toupper((unsigned char)c); }
  bool startsWith(const String& p) const { return s.compare(0, p.s.size(), p.s) == 0 && s.size() >= p.s.size(); }
  int indexOf(const String& p) const {
    size_t i = s.find(p.s);
    return i == std::string::npos ? -1 : (int)i;
  }
  String substring(size_t from, size_t to) const {
    if (from > s.size()) from = s.size();
    if (to > s.size()) to = s.size();
    if (to < from) to = from;
    return String(s.substr(from, to - from));
  }
  String substring(size_t from) const { return substring(from, s.size()); }
  float toFloat() const { return (float)atof(s.c_str()); }

  String& operator+=(char c) { s += c; return *this; }
  String& operator+=(const String& o) { s += o.s; return *this; }
  friend String operator+(const String& a, const String& b) { return String(a.s + b.s); }
  bool operator==(const String& o) const { return s == o.s; }
  bool operator==(const char* o) const { return s == o; }
  bool operator!=(const char* o) const { return s != o; }
};
