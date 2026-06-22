/*
    Project: Rebased local Windows build support
    --------------------------------------------

    File: ei.h

    Purpose:

        Forward to Erlang's real ei.h while avoiding a Windows header
        namespace collision during MinGW builds of Unix-oriented ports.

    Responsibilities:

        - include Erlang's real ei.h from the next include directory
        - keep Windows' global byte typedef from colliding with dependency
          source files that define their own byte alias

    This file intentionally does NOT contain:

        - Erlang external term interface declarations
        - replacement EI functions
        - dependency-specific build logic
*/

#ifndef REBASED_WINDOWS_EI_FORWARDING_H
#define REBASED_WINDOWS_EI_FORWARDING_H

/*
    Erlang's Windows ei.h path includes Winsock headers, and those headers
    define a global byte typedef. Majic also declares a local byte alias after
    including ei.h, which is valid on Unix but conflicts on Windows.
*/
#define byte rebased_windows_ei_byte
#include_next <ei.h>
#undef byte

/*
    Some port programs only use EI for external-term encode/decode over
    stdin/stdout. On MinGW, calling ei_init() pulls in EI's distributed-node
    connection objects, which are built with the Windows runtime used by the
    Erlang installer and do not link cleanly with the GNU dependency toolchain.
*/
#if defined(__MINGW32__) && !defined(REBASED_WINDOWS_ENABLE_EI_INIT)
#undef ei_init
#define ei_init() ((void)0)
#endif

#endif

/* end of ei.h */
