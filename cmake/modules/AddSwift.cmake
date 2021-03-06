include(macCatalystUtils)
include(SwiftList)
include(SwiftXcodeSupport)
include(SwiftWindowsSupport)
include(SwiftAndroidSupport)

function(_swift_gyb_target_sources target scope)
  foreach(source ${ARGN})
    get_filename_component(generated ${source} NAME_WLE)
    get_filename_component(absolute ${source} REALPATH)

    add_custom_command(OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/${generated}
      COMMAND
        $<TARGET_FILE:Python2::Interpreter> ${SWIFT_SOURCE_DIR}/utils/gyb -D CMAKE_SIZEOF_VOID_P=${CMAKE_SIZEOF_VOID_P} ${SWIFT_GYB_FLAGS} -o ${CMAKE_CURRENT_BINARY_DIR}/${generated}.tmp ${absolute}
      COMMAND
        ${CMAKE_COMMAND} -E copy_if_different ${CMAKE_CURRENT_BINARY_DIR}/${generated}.tmp ${CMAKE_CURRENT_BINARY_DIR}/${generated}
      COMMAND
        ${CMAKE_COMMAND} -E remove ${CMAKE_CURRENT_BINARY_DIR}/${generated}.tmp
      DEPENDS
        ${absolute})
    set_source_files_properties(${CMAKE_CURRENT_BINARY_DIR}/${generated} PROPERTIES
      GENERATED TRUE)
    target_sources(${target} ${scope}
      ${CMAKE_CURRENT_BINARY_DIR}/${generated})
  endforeach()
endfunction()

# SWIFTLIB_DIR is the directory in the build tree where Swift resource files
# should be placed.  Note that $CMAKE_CFG_INTDIR expands to "." for
# single-configuration builds.
set(SWIFTLIB_DIR
    "${CMAKE_BINARY_DIR}/${CMAKE_CFG_INTDIR}/lib/swift")
set(SWIFTSTATICLIB_DIR
    "${CMAKE_BINARY_DIR}/${CMAKE_CFG_INTDIR}/lib/swift_static")

function(_compute_lto_flag option out_var)
  string(TOLOWER "${option}" lowercase_option)
  if (lowercase_option STREQUAL "full")
    set(${out_var} "-flto=full" PARENT_SCOPE)
  elseif (lowercase_option STREQUAL "thin")
    set(${out_var} "-flto=thin" PARENT_SCOPE)
  endif()
endfunction()

function(_set_target_prefix_and_suffix target kind sdk)
  precondition(target MESSAGE "target is required")
  precondition(kind MESSAGE "kind is required")
  precondition(sdk MESSAGE "sdk is required")

  if(${sdk} STREQUAL ANDROID)
    if(${kind} STREQUAL STATIC)
      set_target_properties(${target} PROPERTIES PREFIX "lib" SUFFIX ".a")
    elseif(${kind} STREQUAL SHARED)
      set_target_properties(${target} PROPERTIES PREFIX "lib" SUFFIX ".so")
    endif()
  elseif(${sdk} STREQUAL WINDOWS)
    if(${kind} STREQUAL STATIC)
      set_target_properties(${target} PROPERTIES PREFIX "" SUFFIX ".lib")
    elseif(${kind} STREQUAL SHARED)
      set_target_properties(${target} PROPERTIES PREFIX "" SUFFIX ".dll")
    endif()
  endif()
endfunction()

function(is_darwin_based_sdk sdk_name out_var)
  if ("${sdk_name}" STREQUAL "OSX" OR
      "${sdk_name}" STREQUAL "IOS" OR
      "${sdk_name}" STREQUAL "IOS_SIMULATOR" OR
      "${sdk_name}" STREQUAL "TVOS" OR
      "${sdk_name}" STREQUAL "TVOS_SIMULATOR" OR
      "${sdk_name}" STREQUAL "WATCHOS" OR
      "${sdk_name}" STREQUAL "WATCHOS_SIMULATOR")
    set(${out_var} TRUE PARENT_SCOPE)
  else()
    set(${out_var} FALSE PARENT_SCOPE)
  endif()
endfunction()

# Usage:
# _add_host_variant_c_compile_link_flags(
#   ANALYZE_CODE_COVERAGE analyze_code_coverage
#   RESULT_VAR_NAME result_var_name
# )
function(_add_host_variant_c_compile_link_flags)
  set(oneValueArgs RESULT_VAR_NAME ANALYZE_CODE_COVERAGE)
  cmake_parse_arguments(CFLAGS
    ""
    "${oneValueArgs}"
    ""
    ${ARGN})

  set(result ${${CFLAGS_RESULT_VAR_NAME}})

  is_darwin_based_sdk("${SWIFT_HOST_VARIANT_SDK}" IS_DARWIN)
  if(IS_DARWIN)
    set(DEPLOYMENT_VERSION "${SWIFT_SDK_${SWIFT_HOST_VARIANT_SDK}_DEPLOYMENT_VERSION}")
  endif()

  # MSVC, clang-cl, gcc don't understand -target.
  if(CMAKE_C_COMPILER_ID MATCHES "Clang" AND NOT SWIFT_COMPILER_IS_MSVC_LIKE)
    get_target_triple(target target_variant "${SWIFT_HOST_VARIANT_SDK}" "${SWIFT_HOST_VARIANT_ARCH}"
      MACCATALYST_BUILD_FLAVOR ""
      DEPLOYMENT_VERSION "${DEPLOYMENT_VERSION}")
    list(APPEND result "-target" "${target}")
  endif()

  set(_sysroot
    "${SWIFT_SDK_${SWIFT_HOST_VARIANT_SDK}_ARCH_${SWIFT_HOST_VARIANT_ARCH}_PATH}")
  if(IS_DARWIN)
    list(APPEND result "-isysroot" "${_sysroot}")
  elseif(NOT SWIFT_COMPILER_IS_MSVC_LIKE AND NOT "${_sysroot}" STREQUAL "/")
    list(APPEND result "--sysroot=${_sysroot}")
  endif()

  if(SWIFT_HOST_VARIANT_SDK STREQUAL ANDROID)
    # lld can handle targeting the android build.  However, if lld is not
    # enabled, then fallback to the linker included in the android NDK.
    if(NOT SWIFT_ENABLE_LLD_LINKER)
      swift_android_tools_path(${SWIFT_HOST_VARIANT_ARCH} tools_path)
      list(APPEND result "-B" "${tools_path}")
    endif()
  endif()

  if(IS_DARWIN)
    # We collate -F with the framework path to avoid unwanted deduplication
    # of options by target_compile_options -- this way no undesired
    # side effects are introduced should a new search path be added.
    list(APPEND result
      "-arch" "${SWIFT_HOST_VARIANT_ARCH}"
      "-F${SWIFT_SDK_${SWIFT_HOST_VARIANT_ARCH}_PATH}/../../../Developer/Library/Frameworks"
      "-m${SWIFT_SDK_${SWIFT_HOST_VARIANT_SDK}_VERSION_MIN_NAME}-version-min=${DEPLOYMENT_VERSION}")
  endif()

  if(CFLAGS_ANALYZE_CODE_COVERAGE)
    list(APPEND result "-fprofile-instr-generate"
                       "-fcoverage-mapping")
  endif()

  _compute_lto_flag("${SWIFT_TOOLS_ENABLE_LTO}" _lto_flag_out)
  if (_lto_flag_out)
    list(APPEND result "${_lto_flag_out}")
  endif()

  set("${CFLAGS_RESULT_VAR_NAME}" "${result}" PARENT_SCOPE)
endfunction()


function(_add_host_variant_c_compile_flags target)
  _add_host_variant_c_compile_link_flags(
    ANALYZE_CODE_COVERAGE FALSE
    RESULT_VAR_NAME result)
  target_compile_options(${target} PRIVATE
    ${result})

  is_build_type_optimized("${CMAKE_BUILD_TYPE}" optimized)
  if(optimized)
    target_compile_options(${target} PRIVATE -O2)

    # Omit leaf frame pointers on x86 production builds (optimized, no debug
    # info, and no asserts).
    is_build_type_with_debuginfo("${CMAKE_BUILD_TYPE}" debug)
    if(NOT debug AND NOT LLVM_ENABLE_ASSERTIONS)
      if(SWIFT_HOST_VARIANT_ARCH MATCHES "i?86")
        if(NOT SWIFT_COMPILER_IS_MSVC_LIKE)
          target_compile_options(${target} PRIVATE -momit-leaf-frame-pointer)
        else()
          target_compile_options(${target} PRIVATE /Oy)
        endif()
      endif()
    endif()
  else()
    if(NOT SWIFT_COMPILER_IS_MSVC_LIKE)
      target_compile_options(${target} PRIVATE -O0)
    else()
      target_compile_options(${target} PRIVATE /Od)
    endif()
  endif()

  # CMake automatically adds the flags for debug info if we use MSVC/clang-cl.
  if(NOT SWIFT_COMPILER_IS_MSVC_LIKE)
    is_build_type_with_debuginfo("${CMAKE_BUILD_TYPE}" debuginfo)
    if(debuginfo)
      _compute_lto_flag("${SWIFT_TOOLS_ENABLE_LTO}" _lto_flag_out)
      if(_lto_flag_out)
        target_compile_options(${target} PRIVATE -gline-tables-only)
      else()
        target_compile_options(${target} PRIVATE -g)
      endif()
    else()
      target_compile_options(${target} PRIVATE -g0)
    endif()
  endif()

  if(SWIFT_HOST_VARIANT_SDK STREQUAL WINDOWS)
    # MSVC/clang-cl don't support -fno-pic or -fms-compatibility-version.
    if(NOT SWIFT_COMPILER_IS_MSVC_LIKE)
      target_compile_options(${target} PRIVATE
        -fms-compatibility-version=1900
        -fno-pic)
    endif()

    target_compile_definitions(${target} PRIVATE
      LLVM_ON_WIN32
      _CRT_SECURE_NO_WARNINGS
      _CRT_NONSTDC_NO_WARNINGS)
    if(NOT "${CMAKE_C_COMPILER_ID}" STREQUAL "MSVC")
      target_compile_definitions(${target} PRIVATE
        _CRT_USE_BUILTIN_OFFSETOF)
    endif()
    # TODO(compnerd) permit building for different families
    target_compile_definitions(${target} PRIVATE
      _CRT_USE_WINAPI_FAMILY_DESKTOP_APP)
    if(SWIFT_HOST_VARIANT_ARCH MATCHES arm)
      target_compile_definitions(${target} PRIVATE
        _ARM_WINAPI_PARTITION_DESKTOP_SDK_AVAILABLE)
    endif()
    target_compile_definitions(${target} PRIVATE
      # TODO(compnerd) handle /MT
      _MD
      _DLL
      # NOTE: We assume that we are using VS 2015 U2+
      _ENABLE_ATOMIC_ALIGNMENT_FIX
      # NOTE: We use over-aligned values for the RefCount side-table
      # (see revision d913eefcc93f8c80d6d1a6de4ea898a2838d8b6f)
      # This is required to build with VS2017 15.8+
      _ENABLE_EXTENDED_ALIGNED_STORAGE=1)

    # msvcprt's std::function requires RTTI, but we do not want RTTI data.
    # Emulate /GR-.
    # TODO(compnerd) when moving up to VS 2017 15.3 and newer, we can disable
    # RTTI again
    if(SWIFT_COMPILER_IS_MSVC_LIKE)
      target_compile_options(${target} PRIVATE /GR-)
    else()
      target_compile_options(${target} PRIVATE
        -frtti
        "SHELL:-Xclang -fno-rtti-data")
    endif()

    # NOTE: VS 2017 15.3 introduced this to disable the static components of
    # RTTI as well.  This requires a newer SDK though and we do not have
    # guarantees on the SDK version currently.
    target_compile_definitions(${target} PRIVATE
      _HAS_STATIC_RTTI=0)

    # NOTE(compnerd) workaround LLVM invoking `add_definitions(-D_DEBUG)` which
    # causes failures for the runtime library when cross-compiling due to
    # undefined symbols from the standard library.
    if(NOT CMAKE_BUILD_TYPE STREQUAL Debug)
      target_compile_options(${target} PRIVATE
        -U_DEBUG)
    endif()
  endif()

  if(SWIFT_HOST_VARIANT_SDK STREQUAL ANDROID)
    if(SWIFT_HOST_VARIANT_ARCH STREQUAL x86_64)
      # NOTE(compnerd) Android NDK 21 or lower will generate library calls to
      # `__sync_val_compare_and_swap_16` rather than lowering to the CPU's
      # `cmpxchg16b` instruction as the `cx16` feature is disabled due to a bug
      # in Clang.  This is being fixed in the current master Clang and will
      # hopefully make it into Clang 9.0.  In the mean time, workaround this in
      # the build.
      if(CMAKE_C_COMPILER_ID MATCHES Clang AND CMAKE_C_COMPILER_VERSION
          VERSION_LESS 9.0.0)
        target_compile_options(${target} PRIVATE -mcx16)
      endif()
    endif()
  endif()

  if(LLVM_ENABLE_ASSERTIONS)
    target_compile_options(${target} PRIVATE -UNDEBUG)
  else()
    target_compile_definitions(${target} PRIVATE -DNDEBUG)
  endif()

  if(SWIFT_ENABLE_RUNTIME_FUNCTION_COUNTERS)
    target_compile_definitions(${target} PRIVATE
      SWIFT_ENABLE_RUNTIME_FUNCTION_COUNTERS)
  endif()

  if(SWIFT_ANALYZE_CODE_COVERAGE)
    target_compile_options(${target} PRIVATE
      -fprofile-instr-generate
      -fcoverage-mapping)
  endif()

  if((SWIFT_HOST_VARIANT_ARCH STREQUAL armv7 OR
      SWIFT_HOST_VARIANT_ARCH STREQUAL aarch64) AND
     (SWIFT_HOST_VARIANT_SDK STREQUAL LINUX OR
      SWIFT_HOST_VARIANT_SDK STREQUAL ANDROID))
    target_compile_options(${target} PRIVATE -funwind-tables)
  endif()

  if(SWIFT_HOST_VARIANT_SDK STREQUAL ANDROID)
    target_compile_options(${target} PRIVATE -nostdinc++)
    swift_android_libcxx_include_paths(CFLAGS_CXX_INCLUDES)
    swift_android_include_for_arch("${SWIFT_HOST_VARIANT_ARCH}"
      "${SWIFT_HOST_VARIANT_ARCH}_INCLUDE")
    target_include_directories(${target} SYSTEM PRIVATE
      ${CFLAGS_CXX_INCLUDES}
      ${${SWIFT_HOST_VARIANT_ARCH}_INCLUDE})
    target_compile_definitions(${target} PRIVATE
      __ANDROID_API__=${SWIFT_ANDROID_API_LEVEL})
  endif()

  if(SWIFT_HOST_VARIANT_SDK STREQUAL "LINUX")
    if(SWIFT_HOST_VARIANT_ARCH STREQUAL x86_64)
      # this is the minimum architecture that supports 16 byte CAS, which is
      # necessary to avoid a dependency to libatomic
      target_compile_options(${target} PRIVATE -march=core2)
    endif()
  endif()
endfunction()

function(_add_host_variant_link_flags target)
  _add_host_variant_c_compile_link_flags(
    ANALYZE_CODE_COVERAGE ${SWIFT_ANALYZE_CODE_COVERAGE}
    RESULT_VAR_NAME result)
  target_link_options(${target} PRIVATE
    ${result})

  if(SWIFT_HOST_VARIANT_SDK STREQUAL LINUX)
    target_link_libraries(${target} PRIVATE
      pthread
      dl)
  elseif(SWIFT_HOST_VARIANT_SDK STREQUAL FREEBSD)
    target_link_libraries(${target} PRIVATE
      pthread)
  elseif(SWIFT_HOST_VARIANT_SDK STREQUAL CYGWIN)
    # No extra libraries required.
  elseif(SWIFT_HOST_VARIANT_SDK STREQUAL WINDOWS)
    # We don't need to add -nostdlib using MSVC or clang-cl, as MSVC and
    # clang-cl rely on auto-linking entirely.
    if(NOT SWIFT_COMPILER_IS_MSVC_LIKE)
      # NOTE: we do not use "/MD" or "/MDd" and select the runtime via linker
      # options. This causes conflicts.
      target_link_options(${target} PRIVATE
        -nostdlib)
    endif()
    swift_windows_lib_for_arch(${SWIFT_HOST_VARIANT_ARCH}
      ${SWIFT_HOST_VARIANT_ARCH}_LIB)
    target_link_directories(${target} PRIVATE
      ${${SWIFT_HOST_VARIANT_ARCH}_LIB})

    # NOTE(compnerd) workaround incorrectly extensioned import libraries from
    # the Windows SDK on case sensitive file systems.
    target_link_directories(${target} PRIVATE
      ${CMAKE_BINARY_DIR}/winsdk_lib_${SWIFT_HOST_VARIANT_ARCH}_symlinks)
  elseif(SWIFT_HOST_VARIANT_SDK STREQUAL HAIKU)
    target_link_libraries(${target} PRIVATE
      bsd)
    target_link_options(${target} PRIVATE
      "SHELL:-Xlinker -Bsymbolic")
  elseif(SWIFT_HOST_VARIANT_SDK STREQUAL ANDROID)
    target_link_libraries(${target} PRIVATE
      dl
      log
      # We need to add the math library, which is linked implicitly by libc++
      m)

    # link against the custom C++ library
    swift_android_cxx_libraries_for_arch(${SWIFT_HOST_VARIANT_ARCH}
      cxx_link_libraries)
    target_link_libraries(${target} PRIVATE
      ${cxx_link_libraries})

    swift_android_lib_for_arch(${SWIFT_HOST_VARIANT_ARCH}
      ${SWIFT_HOST_VARIANT_ARCH}_LIB)
    target_link_directories(${target} PRIVATE
      ${${SWIFT_HOST_VARIANT_ARCH}_LIB})
  else()
    # If lto is enabled, we need to add the object path flag so that the LTO code
    # generator leaves the intermediate object file in a place where it will not
    # be touched. The reason why this must be done is that on OS X, debug info is
    # left in object files. So if the object file is removed when we go to
    # generate a dsym, the debug info is gone.
    if (SWIFT_TOOLS_ENABLE_LTO)
      target_link_options(${target} PRIVATE
        "SHELL:-Xlinker -object_path_lto"
        "SHELL:-Xlinker ${CMAKE_CURRENT_BINARY_DIR}/${CMAKE_CFG_INTDIR}/${target}-${SWIFT_HOST_VARIANT_SDK}-${SWIFT_HOST_VARIANT_ARCH}-lto${CMAKE_C_OUTPUT_EXTENSION}")
    endif()
  endif()

  if(NOT SWIFT_COMPILER_IS_MSVC_LIKE)
    # FIXME: On Apple platforms, find_program needs to look for "ld64.lld"
    find_program(LDLLD_PATH "ld.lld")
    if((SWIFT_ENABLE_LLD_LINKER AND LDLLD_PATH AND NOT APPLE) OR
       (SWIFT_HOST_VARIANT_SDK STREQUAL WINDOWS AND NOT CMAKE_SYSTEM_NAME STREQUAL WINDOWS))
      target_link_options(${target} PRIVATE -fuse-ld=lld)
    elseif(SWIFT_ENABLE_GOLD_LINKER AND
           "${SWIFT_SDK_${SWIFT_HOST_VARIANT_SDK}_OBJECT_FORMAT}" STREQUAL "ELF")
      if(CMAKE_HOST_SYSTEM_NAME STREQUAL Windows)
        target_link_options(${target} PRIVATE -fuse-ld=gold.exe)
      else()
        target_link_options(${target} PRIVATE -fuse-ld=gold)
      endif()
    endif()
  endif()

  # Enable dead stripping. Portions of this logic were copied from llvm's
  # `add_link_opts` function (which, perhaps, should have been used here in the
  # first place, but at this point it's hard to say whether that's feasible).
  #
  # TODO: Evaluate/enable -f{function,data}-sections --gc-sections for bfd,
  # gold, and lld.
  if(NOT CMAKE_BUILD_TYPE STREQUAL Debug)
    if(CMAKE_SYSTEM_NAME MATCHES Darwin)
      # See rdar://48283130: This gives 6MB+ size reductions for swift and
      # SourceKitService, and much larger size reductions for sil-opt etc.
      target_link_options(${target} PRIVATE
        "SHELL:-Xlinker -dead_strip")
    endif()
  endif()
endfunction()

# Add a single variant of a new Swift library.
#
# Usage:
#   _add_swift_host_library_single(
#     target
#     [SHARED]
#     [STATIC]
#     [LLVM_LINK_COMPONENTS comp1 ...]
#     source1 [source2 source3 ...])
#
# target
#   Name of the library (e.g., swiftParse).
#
# SHARED
#   Build a shared library.
#
# STATIC
#   Build a static library.
#
# LLVM_LINK_COMPONENTS
#   LLVM components this library depends on.
#
# source1 ...
#   Sources to add into this library
function(_add_swift_host_library_single target)
  set(options
        SHARED
        STATIC)
  set(single_parameter_options)
  set(multiple_parameter_options
        LLVM_LINK_COMPONENTS)

  cmake_parse_arguments(ASHLS
                        "${options}"
                        "${single_parameter_options}"
                        "${multiple_parameter_options}"
                        ${ARGN})
  set(ASHLS_SOURCES ${ASHLS_UNPARSED_ARGUMENTS})

  translate_flags(ASHLS "${options}")

  if(NOT ASHLS_SHARED AND NOT ASHLS_STATIC)
    message(FATAL_ERROR "Either SHARED or STATIC must be specified")
  endif()

  # Include LLVM Bitcode slices for iOS, Watch OS, and Apple TV OS device libraries.
  set(embed_bitcode_arg)
  if(SWIFT_EMBED_BITCODE_SECTION)
    if(SWIFT_HOST_VARIANT_SDK MATCHES "(I|TV|WATCH)OS")
      list(APPEND ASHLS_C_COMPILE_FLAGS "-fembed-bitcode")
      set(embed_bitcode_arg EMBED_BITCODE)
    endif()
  endif()

  if(XCODE)
    string(REGEX MATCHALL "/[^/]+" split_path ${CMAKE_CURRENT_SOURCE_DIR})
    list(GET split_path -1 dir)
    file(GLOB_RECURSE ASHLS_HEADERS
      ${SWIFT_SOURCE_DIR}/include/swift${dir}/*.h
      ${SWIFT_SOURCE_DIR}/include/swift${dir}/*.def
      ${CMAKE_CURRENT_SOURCE_DIR}/*.def)

    file(GLOB_RECURSE ASHLS_TDS
      ${SWIFT_SOURCE_DIR}/include/swift${dir}/*.td)

    set_source_files_properties(${ASHLS_HEADERS} ${ASHLS_TDS}
      PROPERTIES
      HEADER_FILE_ONLY true)
    source_group("TableGen descriptions" FILES ${ASHLS_TDS})

    set(ASHLS_SOURCES ${ASHLS_SOURCES} ${ASHLS_HEADERS} ${ASHLS_TDS})
  endif()

  if(ASHLS_SHARED)
    set(libkind SHARED)
  elseif(ASHLS_STATIC)
    set(libkind STATIC)
  endif()

  add_library("${target}" ${libkind} ${ASHLS_SOURCES})
  _set_target_prefix_and_suffix("${target}" "${libkind}" "${SWIFT_HOST_VARIANT_SDK}")
  add_dependencies(${target} ${LLVM_COMMON_DEPENDS})

  if(SWIFT_HOST_VARIANT_SDK STREQUAL WINDOWS)
    swift_windows_include_for_arch(${SWIFT_HOST_VARIANT_ARCH} SWIFTLIB_INCLUDE)
    target_include_directories("${target}" SYSTEM PRIVATE ${SWIFTLIB_INCLUDE})
    set_target_properties(${target}
                          PROPERTIES
                            CXX_STANDARD 14)
  endif()

  if(SWIFT_HOST_VARIANT_SDK STREQUAL WINDOWS)
    set_property(TARGET "${target}" PROPERTY NO_SONAME ON)
  endif()

  llvm_update_compile_flags(${target})

  set_output_directory(${target}
      BINARY_DIR ${SWIFT_RUNTIME_OUTPUT_INTDIR}
      LIBRARY_DIR ${SWIFT_LIBRARY_OUTPUT_INTDIR})

  if(SWIFT_HOST_VARIANT_SDK IN_LIST SWIFT_APPLE_PLATFORMS)
    set_target_properties("${target}"
      PROPERTIES
      INSTALL_NAME_DIR "@rpath")
  elseif(SWIFT_HOST_VARIANT_SDK STREQUAL LINUX)
    set_target_properties("${target}"
      PROPERTIES
      INSTALL_RPATH "$ORIGIN:/usr/lib/swift/linux")
  elseif(SWIFT_HOST_VARIANT_SDK STREQUAL CYGWIN)
    set_target_properties("${target}"
      PROPERTIES
      INSTALL_RPATH "$ORIGIN:/usr/lib/swift/cygwin")
  elseif(SWIFT_HOST_VARIANT_SDK STREQUAL "ANDROID")
    set_target_properties("${target}"
      PROPERTIES
      INSTALL_RPATH "$ORIGIN")
  endif()

  set_target_properties("${target}" PROPERTIES BUILD_WITH_INSTALL_RPATH YES)
  set_target_properties("${target}" PROPERTIES FOLDER "Swift libraries")

  # Call llvm_config() only for libraries that are part of the compiler.
  swift_common_llvm_config("${target}" ${ASHLS_LLVM_LINK_COMPONENTS})

  target_compile_options(${target} PRIVATE
    ${ASHLS_C_COMPILE_FLAGS})
  if(SWIFT_HOST_VARIANT_SDK STREQUAL WINDOWS)
    if(libkind STREQUAL SHARED)
      target_compile_definitions(${target} PRIVATE
        _WINDLL)
    endif()
  endif()

  _add_host_variant_c_compile_flags(${target})
  _add_host_variant_link_flags(${target})

  # Set compilation and link flags.
  if(SWIFT_HOST_VARIANT_SDK STREQUAL WINDOWS)
    swift_windows_include_for_arch(${SWIFT_HOST_VARIANT_ARCH}
      ${SWIFT_HOST_VARIANT_ARCH}_INCLUDE)
    target_include_directories(${target} SYSTEM PRIVATE
      ${${SWIFT_HOST_VARIANT_ARCH}_INCLUDE})

    if(NOT ${CMAKE_C_COMPILER_ID} STREQUAL MSVC)
      swift_windows_get_sdk_vfs_overlay(ASHLS_VFS_OVERLAY)
      target_compile_options(${target} PRIVATE
        "SHELL:-Xclang -ivfsoverlay -Xclang ${ASHLS_VFS_OVERLAY}")

      # MSVC doesn't support -Xclang. We don't need to manually specify
      # the dependent libraries as `cl` does so.
      target_compile_options(${target} PRIVATE
        "SHELL:-Xclang --dependent-lib=oldnames"
        # TODO(compnerd) handle /MT, /MTd
        "SHELL:-Xclang --dependent-lib=msvcrt$<$<CONFIG:Debug>:d>")
    endif()
  endif()

  if(${SWIFT_HOST_VARIANT_SDK} IN_LIST SWIFT_APPLE_PLATFORMS)
    target_link_options(${target} PRIVATE
      "LINKER:-compatibility_version,1")
    if(SWIFT_COMPILER_VERSION)
      target_link_options(${target} PRIVATE
        "LINKER:-current_version,${SWIFT_COMPILER_VERSION}")
    endif()
    # Include LLVM Bitcode slices for iOS, Watch OS, and Apple TV OS device libraries.
    if(SWIFT_EMBED_BITCODE_SECTION)
      if(${SWIFT_HOST_VARIANT_SDK} MATCHES "(I|TV|WATCH)OS")
        target_link_options(${target} PRIVATE
          "LINKER:-bitcode_bundle"
          "LINKER:-lto_library,${LLVM_LIBRARY_DIR}/libLTO.dylib")

        # Please note that using a generator expression to fit
        # this in a single target_link_options does not work
        # (at least in CMake 3.15 and 3.16),
        # since that seems not to allow the LINKER: prefix to be
        # evaluated (i.e. it will be added as-is to the linker parameters)
        if(SWIFT_EMBED_BITCODE_SECTION_HIDE_SYMBOLS)
          target_link_options(${target} PRIVATE
            "LINKER:-bitcode_hide_symbols")
        endif()
      endif()
    endif()
  endif()

  # Do not add code here.
endfunction()

# Add a new Swift host library.
#
# Usage:
#   add_swift_host_library(name
#     [SHARED]
#     [STATIC]
#     [LLVM_LINK_COMPONENTS comp1 ...]
#     source1 [source2 source3 ...])
#
# name
#   Name of the library (e.g., swiftParse).
#
# SHARED
#   Build a shared library.
#
# STATIC
#   Build a static library.
#
# LLVM_LINK_COMPONENTS
#   LLVM components this library depends on.
#
# source1 ...
#   Sources to add into this library.
function(add_swift_host_library name)
  set(options
        SHARED
        STATIC)
  set(single_parameter_options)
  set(multiple_parameter_options
        LLVM_LINK_COMPONENTS)

  cmake_parse_arguments(ASHL
                        "${options}"
                        "${single_parameter_options}"
                        "${multiple_parameter_options}"
                        ${ARGN})
  set(ASHL_SOURCES ${ASHL_UNPARSED_ARGUMENTS})

  translate_flags(ASHL "${options}")

  if(NOT ASHL_SHARED AND NOT ASHL_STATIC)
    message(FATAL_ERROR "Either SHARED or STATIC must be specified")
  endif()

  _add_swift_host_library_single(
    ${name}
    ${ASHL_SHARED_keyword}
    ${ASHL_STATIC_keyword}
    ${ASHL_SOURCES}
    LLVM_LINK_COMPONENTS ${ASHL_LLVM_LINK_COMPONENTS}
    )

  add_dependencies(dev ${name})
  if(NOT LLVM_INSTALL_TOOLCHAIN_ONLY)
    swift_install_in_component(TARGETS ${name}
      ARCHIVE DESTINATION lib${LLVM_LIBDIR_SUFFIX} COMPONENT dev
      LIBRARY DESTINATION lib${LLVM_LIBDIR_SUFFIX} COMPONENT dev
      RUNTIME DESTINATION bin COMPONENT dev)
  endif()

  swift_is_installing_component(dev is_installing)
  if(NOT is_installing)
    set_property(GLOBAL APPEND PROPERTY SWIFT_BUILDTREE_EXPORTS ${name})
  else()
    set_property(GLOBAL APPEND PROPERTY SWIFT_EXPORTS ${name})
  endif()
endfunction()

macro(add_swift_tool_subdirectory name)
  add_llvm_subdirectory(SWIFT TOOL ${name})
endmacro()

macro(add_swift_lib_subdirectory name)
  add_llvm_subdirectory(SWIFT LIB ${name})
endmacro()

function(add_swift_host_tool executable)
  set(options)
  set(single_parameter_options SWIFT_COMPONENT)
  set(multiple_parameter_options LLVM_LINK_COMPONENTS)

  cmake_parse_arguments(ASHT
    "${options}"
    "${single_parameter_options}"
    "${multiple_parameter_options}"
    ${ARGN})

  precondition(ASHT_SWIFT_COMPONENT
               MESSAGE "Swift Component is required to add a host tool")


  add_executable(${executable} ${ASHT_UNPARSED_ARGUMENTS})
  _add_host_variant_c_compile_flags(${executable})
  _add_host_variant_link_flags(${executable})
  target_link_directories(${executable} PRIVATE
    ${SWIFTLIB_DIR}/${SWIFT_SDK_${SWIFT_HOST_VARIANT_SDK}_LIB_SUBDIR})
  add_dependencies(${executable} ${LLVM_COMMON_DEPENDS})

  set_target_properties(${executable} PROPERTIES
    FOLDER "Swift executables")
  if(SWIFT_PARALLEL_LINK_JOBS)
    set_target_properties(${executable} PROPERTIES
      JOB_POOL_LINK swift_link_job_pool)
  endif()
  if(${SWIFT_HOST_VARIANT_SDK} IN_LIST SWIFT_APPLE_PLATFORMS)
    set_target_properties(${executable} PROPERTIES
      BUILD_WITH_INSTALL_RPATH YES
      INSTALL_RPATH "@executable_path/../lib/swift/${SWIFT_SDK_${SWIFT_HOST_VARIANT_SDK}_LIB_SUBDIR}")
  endif()

  llvm_update_compile_flags(${executable})
  swift_common_llvm_config(${executable} ${ASHT_LLVM_LINK_COMPONENTS})
  set_output_directory(${executable}
    BINARY_DIR ${SWIFT_RUNTIME_OUTPUT_INTDIR}
    LIBRARY_DIR ${SWIFT_LIBRARY_OUTPUT_INTDIR})

  if(SWIFT_HOST_VARIANT_SDK STREQUAL WINDOWS)
    swift_windows_include_for_arch(${SWIFT_HOST_VARIANT_ARCH}
      ${SWIFT_HOST_VARIANT_ARCH}_INCLUDE)
    target_include_directories(${executable} SYSTEM PRIVATE
      ${${SWIFT_HOST_VARIANT_ARCH}_INCLUDE})

    if(NOT ${CMAKE_C_COMPILER_ID} STREQUAL MSVC)
      # MSVC doesn't support -Xclang. We don't need to manually specify
      # the dependent libraries as `cl` does so.
      target_compile_options(${executable} PRIVATE
        "SHELL:-Xclang --dependent-lib=oldnames"
        # TODO(compnerd) handle /MT, /MTd
        "SHELL:-Xclang --dependent-lib=msvcrt$<$<CONFIG:Debug>:d>")
    endif()
  endif()

  add_dependencies(${ASHT_SWIFT_COMPONENT} ${executable})
  swift_install_in_component(TARGETS ${executable}
                             RUNTIME
                               DESTINATION bin
                               COMPONENT ${ASHT_SWIFT_COMPONENT})

  swift_is_installing_component(${ASHT_SWIFT_COMPONENT} is_installing)

  if(NOT is_installing)
    set_property(GLOBAL APPEND PROPERTY SWIFT_BUILDTREE_EXPORTS ${executable})
  else()
    set_property(GLOBAL APPEND PROPERTY SWIFT_EXPORTS ${executable})
  endif()
endfunction()

# This declares a swift host tool that links with libfuzzer.
function(add_swift_fuzzer_host_tool executable)
  # First create our target. We do not actually parse the argument since we do
  # not care about the arguments, we just pass them all through to
  # add_swift_host_tool.
  add_swift_host_tool(${executable} ${ARGN})

  # Then make sure that we pass the -fsanitize=fuzzer flag both on the cflags
  # and cxx flags line.
  target_compile_options(${executable} PRIVATE "-fsanitize=fuzzer")
  target_link_libraries(${executable} PRIVATE "-fsanitize=fuzzer")
endfunction()

macro(add_swift_tool_symlink name dest component)
  add_llvm_tool_symlink(${name} ${dest} ALWAYS_GENERATE)
  llvm_install_symlink(${name} ${dest} ALWAYS_GENERATE COMPONENT ${component})
endmacro()
