# SPDX-License-Identifier: BSD-3-Clause
#
# Pulled into the unit-test configure by build.sh (CMAKE_PROJECT_INCLUDE, deferred to the end of the root
# directory): adds the eq_iir libFuzzer target next to the cmocka tests, reusing their scaffold.
set(_hd ${CMAKE_CURRENT_LIST_DIR})
# Imported targets and the cmocka subdirectory's variables are directory-scoped; rebuild what is needed.
set(_lds ${PROJECT_BINARY_DIR}/test/cmocka/memory_mock.x)
set(_lsan ${LSAN_OFF_SRC})
set(_standalone_main $ENV{STANDALONE_FUZZ_MAIN})
foreach(_t fuzz_eq_iir fuzz_eq_iir-standalone)
	add_executable(${_t} ${_hd}/fuzz_eq_iir.c ${_lsan})
	add_dependencies(${_t} ld_script_memory_mock)
	target_include_directories(${_t} PRIVATE
		${PROJECT_SOURCE_DIR}/test/cmocka/include
		${PROJECT_SOURCE_DIR}/test/cmocka/src
		${PROJECT_SOURCE_DIR}/src/audio
		${CMOCKA_DIRECTORY}/include)
	target_link_libraries(${_t} PRIVATE "-T${_lds}" audio_for_eq_iir sof_options common_mock ${CMOCKA_DIRECTORY}/lib/libcmocka-static.a m)
	target_compile_definitions(${_t} PRIVATE -DUNIT_TEST -D_UINTPTR_T_DEFINED
		-DCONFIG_NUMBERS_NORM -DCONFIG_NUMBERS_VECTOR_FIND)
	sof_append_relative_path_definitions(${_t})
endforeach()
target_link_options(fuzz_eq_iir PRIVATE -fsanitize=fuzzer)
# Run-once reproducer: LLVM's file-input main() instead of the libFuzzer runtime.
target_sources(fuzz_eq_iir-standalone PRIVATE ${_standalone_main})
