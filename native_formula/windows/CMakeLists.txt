cmake_minimum_required(VERSION 3.14)
project(quelyt_formula_native LANGUAGES CXX)
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" quelyt_formula)
set(quelyt_formula_native_bundled_libraries
    "$<TARGET_FILE:quelyt_formula>" PARENT_SCOPE)
