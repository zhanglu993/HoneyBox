#pragma once

#include <cstdio>

namespace honey::test {

inline int failures = 0;

using TestFunction = void (*)();

struct TestCase {
    const char *name;
    TestFunction function;
    TestCase *next;
};

inline TestCase *&registered_tests()
{
    static TestCase *head = nullptr;
    return head;
}

class Registration {
public:
    Registration(const char *name, TestFunction function)
        : test_case_{name, function, registered_tests()}
    {
        registered_tests() = &test_case_;
    }

private:
    TestCase test_case_;
};

inline void expect(bool condition, const char *expression, const char *file, int line)
{
    if (!condition) {
        std::fprintf(stderr, "%s:%d: expectation failed: %s\n", file, line, expression);
        ++failures;
    }
}

inline int run_all_tests()
{
    failures = 0;

    for (TestCase *test = registered_tests(); test != nullptr; test = test->next) {
        const int failures_before = failures;
        std::printf("[ RUN      ] %s\n", test->name);
        test->function();
        std::printf(failures == failures_before ? "[       OK ] %s\n" : "[  FAILED  ] %s\n", test->name);
    }

    return failures == 0 ? 0 : 1;
}

} // namespace honey::test

#define HMC_TEST(name) \
    static void name(); \
    static ::honey::test::Registration name##_registration(#name, &name); \
    static void name()

#define HMC_EXPECT(expression) \
    ::honey::test::expect((expression), #expression, __FILE__, __LINE__)
