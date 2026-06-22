/*
    Project: Rebased local Windows build support
    --------------------------------------------

    File: socket.h

    Purpose:

        Satisfy Unix-oriented native dependency includes during local
        Windows builds when the source uses stdin/stdout port I/O rather
        than real sockets.

    Responsibilities:

        - provide a narrow include target for sys/socket.h
        - avoid pulling in Winsock names that collide with dependency code

    This file intentionally does NOT contain:

        - socket API declarations
        - Winsock setup
        - networking behavior
*/

#ifndef REBASED_WINDOWS_SYS_SOCKET_H
#define REBASED_WINDOWS_SYS_SOCKET_H

#endif

/* end of socket.h */
