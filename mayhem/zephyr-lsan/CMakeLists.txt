# Link the LeakSanitizer-off hook into the native_sim runner, where the ASan runtime looks it up.
target_sources(native_simulator INTERFACE ${CMAKE_CURRENT_LIST_DIR}/lsan_off.c)
