/*
    Project: Rebased local Windows build support
    --------------------------------------------

    File: stat.h

    Purpose:

        Forward to MinGW's real sys/stat.h while filling small POSIX
        compatibility gaps needed by bundled native dependencies.

    Responsibilities:

        - include the platform sys/stat.h implementation
        - define missing POSIX file-type mode constants used by portable
          libraries during local Windows builds

    This file intentionally does NOT contain:

        - stat structure replacements
        - filesystem wrappers
        - runtime file classification logic
*/

#ifndef REBASED_WINDOWS_SYS_STAT_FORWARDING_H
#define REBASED_WINDOWS_SYS_STAT_FORWARDING_H

#include_next <sys/stat.h>

/*
    Lexbor checks these POSIX mode bits while compiling its filesystem helper.
    MinGW cannot report symlink or socket file modes through the same API, but
    the numeric constants are still safe to define for switch coverage.
*/
#ifndef S_IFLNK
#define S_IFLNK 0120000
#endif

#ifndef S_IFSOCK
#define S_IFSOCK 0140000
#endif

#endif

/* end of stat.h */
