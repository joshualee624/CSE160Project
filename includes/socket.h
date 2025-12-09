#ifndef __SOCKET_H__
#define __SOCKET_H__

enum{
    MAX_NUM_OF_SOCKETS = 10,
    ROOT_SOCKET_ADDR = 255,
    ROOT_SOCKET_PORT = 255,
    SOCKET_BUFFER_SIZE = 128,
    NULL_SOCKET = 0xFF,
};

enum socket_state{
    CLOSED = 0,
    LISTEN,
    SYN_SENT,
    SYN_RCVD,
    ESTABLISHED,
    FIN_WAIT_1,
    FIN_WAIT_2,
    CLOSE_WAIT,
    LAST_ACK,
    TIME_WAIT
};



typedef nx_uint8_t nx_socket_port_t;
typedef uint8_t socket_port_t;

// socket_addr_t is a simplified version of an IP connection.
typedef nx_struct socket_addr_t{
    nx_socket_port_t port;
    nx_uint16_t addr;
}socket_addr_t;


typedef struct socket_buffer_t{
    uint8_t buffer[SOCKET_BUFFER_SIZE];
    uint8_t head;
    uint8_t tail;
    // head and tail used to control window
} socket_buffer_t;

// File descripter id. Each id is associated with a socket_store_t
typedef uint8_t socket_t;

// State of a socket. 
typedef struct socket_store_t{
    uint8_t flag;
    enum socket_state state;
    socket_port_t src;
    socket_addr_t dest;

    // This is the sender portion.
    socket_buffer_t sendBuff;
    uint16_t lastWritten;
    uint16_t lastAck;
    uint16_t lastSent;

    // This is the receiver portion
    socket_buffer_t rcvdBuff;
    uint16_t lastRead;
    uint16_t lastRcvd;
    uint16_t nextExpected;

    uint16_t RTT;
    uint8_t effectiveWindow;
}socket_store_t;

#endif
