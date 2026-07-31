#pragma once

#include <cstdio>
#include <cstring>

namespace ebadge::test {

inline int failures = 0;

inline void expect(bool condition, const char *expression, const char *file, int line)
{
    if (!condition) {
        std::fprintf(stderr, "%s:%d: expectation failed: %s\n", file, line, expression);
        ++failures;
    }
}

} // namespace ebadge::test

#define EB_EXPECT(expression) \
    ::ebadge::test::expect((expression), #expression, __FILE__, __LINE__)
