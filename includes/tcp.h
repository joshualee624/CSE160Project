#ifndef TCP_H
#define TCP_H

enum {
    TCP_PACKET_MAX_PAYLOAD_SIZE = 8
};

typedef nx_struct tcp_pack {
    nx_uint8_t srcPort;
    nx_uint8_t destPort;
    nx_uint16_t seq;
    nx_uint16_t ack;
    nx_uint8_t flag;
    nx_uint8_t advertisedWindow;
    nx_uint8_t payload[TCP_PACKET_MAX_PAYLOAD_SIZE];
} tcp_pack;

#endif