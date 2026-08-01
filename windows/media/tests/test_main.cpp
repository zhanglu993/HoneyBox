#include "test_support.h"

int main(int argc, char* argv[]) {
  return hmw::test::RunAllTests(argc > 1 ? argv[1] : "");
}
