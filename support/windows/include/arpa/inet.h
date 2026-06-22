/*
    Project: Rebased local Windows build support
    --------------------------------------------

    File: inet.h

    Purpose:

        Provide the small arpa/inet.h compatibility surface needed by
        native dependencies when they are compiled with MinGW on Windows.

    Responsibilities:

        - expose the network-to-host byte-order helper through the
          POSIX-style include path expected by Unix-oriented C dependencies

    This file intentionally does NOT contain:

        - socket setup logic
        - networking wrappers
        - replacement implementations of socket APIs
*/

#ifndef REBASED_WINDOWS_ARPA_INET_H
#define REBASED_WINDOWS_ARPA_INET_H

#include <stdint.h>

/*
    MinGW does not provide arpa/inet.h, but the Majic port only needs ntohs()
    to decode the two-byte packet length used by Erlang external terms.

    This avoids including winsock2.h here because Windows headers define a
    global byte typedef, which collides with the dependency's local byte alias.
*/
static inline uint16_t rebased_windows_ntohs(uint16_t value)
{
    return (uint16_t)((value << 8) | (value >> 8));
}

#ifndef ntohs
#define ntohs(value) rebased_windows_ntohs(value)
#endif

#endif

/* end of inet.h */
