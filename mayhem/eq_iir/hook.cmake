# SPDX-License-Identifier: BSD-3-Clause
cmake_language(EVAL CODE "cmake_language(DEFER DIRECTORY \"${CMAKE_SOURCE_DIR}\" CALL include \"${CMAKE_CURRENT_LIST_DIR}/fuzz.cmake\")")
