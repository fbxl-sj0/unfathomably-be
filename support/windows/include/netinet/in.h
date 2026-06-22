/*
    Project: Rebased local Windows build support
    --------------------------------------------

    File: in.h

    Purpose:

        Provide a narrow netinet/in.h compatibility include for native
        dependencies that only need fixed-width integer types on Windows.

    Responsibilities:

        - expose standard integer types used by packet framing code
        - avoid importing socket APIs that are not used by the dependency

    This file intentionally does NOT contain:

        - sockaddr structures
        - IP protocol constants
        - networking functions
*/

#ifndef REBASED_WINDOWS_NETINET_IN_H
#define REBASED_WINDOWS_NETINET_IN_H

#include <stdint.h>

#endif

/* end of in.h */
