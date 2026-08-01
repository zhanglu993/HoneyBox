#pragma once

#include <cstdint>
#include <cstdio>
#include <string_view>

namespace hmw::test {

inline int failures = 0;

using TestFunction = void (*)();

struct TestCase {
  const char* name;
  TestFunction function;
  TestCase* next;
};

inline TestCase*& RegisteredTests() {
  static TestCase* head = nullptr;
  return head;
}

class Registration {
 public:
  Registration(const char* name, TestFunction function)
      : test_case_{name, function, RegisteredTests()} {
    RegisteredTests() = &test_case_;
  }

 private:
  TestCase test_case_;
};

inline void Expect(bool condition, const char* expression, const char* file,
                   int line) {
  if (!condition) {
    std::fprintf(stderr, "%s:%d: expectation failed: %s\n", file, line,
                 expression);
    ++failures;
  }
}

inline int RunAllTests(std::string_view filter = {}) {
  failures = 0;
  for (TestCase* test = RegisteredTests(); test != nullptr; test = test->next) {
    if (!filter.empty() &&
        std::string_view(test->name).find(filter) == std::string_view::npos) {
      continue;
    }
    const int failures_before = failures;
    std::printf("[ RUN      ] %s\n", test->name);
    test->function();
    std::printf(failures == failures_before ? "[       OK ] %s\n"
                                            : "[  FAILED  ] %s\n",
                test->name);
  }
  return failures == 0 ? 0 : 1;
}

}  // namespace hmw::test

inline void IgnoreProgress(uint32_t, uint32_t) {}
inline bool NeverCancel() { return false; }

#define HMW_TEST(name) \
  static void name(); \
  static ::hmw::test::Registration name##_registration(#name, &name); \
  static void name()

#define HMW_EXPECT(...) \
  ::hmw::test::Expect((__VA_ARGS__), #__VA_ARGS__, __FILE__, __LINE__)
