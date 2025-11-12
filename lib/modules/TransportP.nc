#include "../../includes/socket.h"
#include "../../includes/packet.h"
#include "../../includes/tcp.h"

module TransportP {
    provides interface Transport;
    uses interface SimpleSend as Sender;
    uses interface Timer<TMilli> as RetransmitTimer;
    uses interface Timer<TMilli> as TransportTimer;
    uses interface Random;
}

implementation {
    socket_store_t sockets[MAX_NUM_OF_SOCKETS];
    uint8_t numSockets = 0;
    
    tcp_pack tcpPacket;
    pack ipPacket;
    
    enum {
        CLOSED = 0,
        LISTEN = 1,
        SYN_SENT = 2,
        SYN_RCVD = 3,
        ESTABLISHED = 4,
        FIN_WAIT = 5,
        CLOSE_WAIT = 6,
        LAST_ACK = 7
    };
    
    enum {
        DATA_FLAG = 0,
        ACK_FLAG = 1,
        SYN_FLAG = 2,
        FIN_FLAG = 4,
        SYN_ACK_FLAG = 3,
        FIN_ACK_FLAG = 5
    };
    
    void makeTCPPacket(tcp_pack *tcp, uint8_t srcPort, uint8_t destPort, 
                       uint16_t seq, uint16_t ack, uint8_t flag, 
                       uint8_t advertisedWindow, uint8_t *payload, uint8_t len) {
        tcp->srcPort = srcPort;
        tcp->destPort = destPort;
        tcp->seq = seq;
        tcp->ack = ack;
        tcp->flag = flag;
        tcp->advertisedWindow = advertisedWindow;
        if(len > 0 && payload != NULL) {
            memcpy(tcp->payload, payload, len);
        }
    }
    
    void makeIPPacket(pack *pkg, uint16_t src, uint16_t dest, uint8_t TTL, 
                      uint8_t protocol, uint16_t seq, uint8_t *payload, uint8_t len) {
        pkg->src = src;
        pkg->dest = dest;
        pkg->TTL = TTL;
        pkg->protocol = protocol;
        pkg->seq = seq;
        memcpy(pkg->payload, payload, len);
    }
    
    socket_t getSocket(uint8_t srcPort, uint8_t destPort, uint16_t destAddr) {
        uint8_t i;
        for(i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
            if(sockets[i].flag != CLOSED &&
               sockets[i].src == srcPort &&
               sockets[i].dest.port == destPort &&
               sockets[i].dest.addr == destAddr) {
                return i;
            }
        }
        return NULL_SOCKET;
    }
    
    socket_t getFreeSocket() {
        uint8_t i;
        for(i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
            if(sockets[i].flag == CLOSED) {
                return i;
            }
        }
        return NULL_SOCKET;
    }
    
    command socket_t Transport.socket() {
        socket_t fd = getFreeSocket();
        if(fd != NULL_SOCKET) {
            sockets[fd].flag = CLOSED;
            sockets[fd].state = CLOSED;
            sockets[fd].src = 0;
            sockets[fd].dest.port = 0;
            sockets[fd].dest.addr = 0;
            sockets[fd].sendBuff.head = 0;
            sockets[fd].sendBuff.tail = 0;
            sockets[fd].rcvdBuff.head = 0;
            sockets[fd].rcvdBuff.tail = 0;
            sockets[fd].lastWritten = 0;
            sockets[fd].lastAck = 0;
            sockets[fd].lastSent = 0;
            sockets[fd].lastRead = 0;
            sockets[fd].lastRcvd = 0;
            sockets[fd].nextExpected = 0;
            sockets[fd].RTT = 0;
            sockets[fd].effectiveWindow = SOCKET_BUFFER_SIZE;
            dbg(TRANSPORT_CHANNEL, "Socket created: fd=%d\n", fd);
        }
        return fd;
    }
    
    command error_t Transport.bind(socket_t fd, socket_addr_t *addr) {
        if(fd >= MAX_NUM_OF_SOCKETS || sockets[fd].flag != CLOSED) {
            return FAIL;
        }
        sockets[fd].src = addr->port;
        dbg(TRANSPORT_CHANNEL, "Socket bound: fd=%d, port=%d\n", fd, addr->port);
        return SUCCESS;
    }
    
    command error_t Transport.listen(socket_t fd) {
        if(fd >= MAX_NUM_OF_SOCKETS) {
            return FAIL;
        }
        sockets[fd].state = LISTEN;
        dbg(TRANSPORT_CHANNEL, "Socket listening: fd=%d, port=%d\n", fd, sockets[fd].src);
        return SUCCESS;
    }
    
    command socket_t Transport.accept(socket_t fd) {
        uint8_t i;
        for(i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
            if(sockets[i].flag == SYN_RCVD && sockets[i].src == sockets[fd].src) {
                dbg(TRANSPORT_CHANNEL, "Connection accepted: new_fd=%d\n", i);
                return i;
            }
        }
        return NULL_SOCKET;
    }
    
    command error_t Transport.connect(socket_t fd, socket_addr_t *addr) {
        if(fd >= MAX_NUM_OF_SOCKETS) {
            return FAIL;
        }
        
        sockets[fd].dest.port = addr->port;
        sockets[fd].dest.addr = addr->addr;
        sockets[fd].state = SYN_SENT;
        sockets[fd].lastSent = call Random.rand16();
        
        makeTCPPacket(&tcpPacket, sockets[fd].src, sockets[fd].dest.port,
                      sockets[fd].lastSent, 0, SYN_FLAG, 
                      SOCKET_BUFFER_SIZE, NULL, 0);
        
        makeIPPacket(&ipPacket, TOS_NODE_ID, sockets[fd].dest.addr, 
                     MAX_TTL, PROTOCOL_TCP, 0, (uint8_t*)&tcpPacket, 
                     sizeof(tcp_pack));
        
        call Sender.send(ipPacket, sockets[fd].dest.addr);
        
        dbg(TRANSPORT_CHANNEL, "SYN sent: fd=%d, dest=%d:%d, seq=%d\n", 
            fd, sockets[fd].dest.addr, sockets[fd].dest.port, sockets[fd].lastSent);
        
        return SUCCESS;
    }
    
    command error_t Transport.close(socket_t fd) {
        if(fd >= MAX_NUM_OF_SOCKETS) {
            return FAIL;
        }
        
        sockets[fd].state = FIN_WAIT;
        
        makeTCPPacket(&tcpPacket, sockets[fd].src, sockets[fd].dest.port,
                      sockets[fd].lastSent, sockets[fd].nextExpected, 
                      FIN_FLAG, SOCKET_BUFFER_SIZE, NULL, 0);
        
        makeIPPacket(&ipPacket, TOS_NODE_ID, sockets[fd].dest.addr, 
                     MAX_TTL, PROTOCOL_TCP, 0, (uint8_t*)&tcpPacket, 
                     sizeof(tcp_pack));
        
        call Sender.send(ipPacket, sockets[fd].dest.addr);
        
        dbg(TRANSPORT_CHANNEL, "FIN sent: fd=%d\n", fd);
        
        return SUCCESS;
    }
    
    command error_t Transport.release(socket_t fd) {
        if(fd >= MAX_NUM_OF_SOCKETS) {
            return FAIL;
        }
        
        sockets[fd].state = CLOSED;
        sockets[fd].flag = CLOSED;
        sockets[fd].src = 0;
        sockets[fd].dest.port = 0;
        sockets[fd].dest.addr = 0;
        
        dbg(TRANSPORT_CHANNEL, "Socket released (hard close): fd=%d\n", fd);
        
        return SUCCESS;
    }
    
    command uint16_t Transport.write(socket_t fd, uint8_t *buff, uint16_t bufflen) {
        uint16_t i;
        uint16_t written = 0;
        uint8_t dataLen;
        
        if(fd >= MAX_NUM_OF_SOCKETS || sockets[fd].state != ESTABLISHED) {
            return 0;
        }
        
        for(i = 0; i < bufflen && written < bufflen; i++) {
            if((sockets[fd].sendBuff.tail + 1) % SOCKET_BUFFER_SIZE != sockets[fd].sendBuff.head) {
                sockets[fd].sendBuff.buffer[sockets[fd].sendBuff.tail] = buff[i];
                sockets[fd].sendBuff.tail = (sockets[fd].sendBuff.tail + 1) % SOCKET_BUFFER_SIZE;
                written++;
            } else {
                break;
            }
        }
        
        if(written > 0 && sockets[fd].lastSent == sockets[fd].lastAck) {
            dataLen = (written > TCP_PACKET_MAX_PAYLOAD_SIZE) ? 
                      TCP_PACKET_MAX_PAYLOAD_SIZE : written;
            
            makeTCPPacket(&tcpPacket, sockets[fd].src, sockets[fd].dest.port,
                          sockets[fd].lastSent + 1, sockets[fd].nextExpected,
                          DATA_FLAG, SOCKET_BUFFER_SIZE, 
                          &sockets[fd].sendBuff.buffer[sockets[fd].sendBuff.head], 
                          dataLen);
            
            makeIPPacket(&ipPacket, TOS_NODE_ID, sockets[fd].dest.addr,
                         MAX_TTL, PROTOCOL_TCP, 0, (uint8_t*)&tcpPacket,
                         sizeof(tcp_pack));
            
            call Sender.send(ipPacket, sockets[fd].dest.addr);
            sockets[fd].lastSent += dataLen;
            
            call RetransmitTimer.startOneShot(10000);
            
            dbg(TRANSPORT_CHANNEL, "Data sent: fd=%d, bytes=%d, seq=%d\n", 
                fd, dataLen, sockets[fd].lastSent);
        }
        
        return written;
    }
    
    command uint16_t Transport.read(socket_t fd, uint8_t *buff, uint16_t bufflen) {
        uint16_t i;
        uint16_t bytesRead = 0;
        
        if(fd >= MAX_NUM_OF_SOCKETS) {
            return 0;
        }
        
        while(sockets[fd].rcvdBuff.head != sockets[fd].rcvdBuff.tail && bytesRead < bufflen) {
            buff[bytesRead] = sockets[fd].rcvdBuff.buffer[sockets[fd].rcvdBuff.head];
            sockets[fd].rcvdBuff.head = (sockets[fd].rcvdBuff.head + 1) % SOCKET_BUFFER_SIZE;
            bytesRead++;
        }
        
        return bytesRead;
    }
    
    command error_t Transport.receive(pack* package) {
        tcp_pack *tcpPack = (tcp_pack*)(package->payload);
        socket_t fd;
        socket_t newFd;
        uint8_t i;
        
        dbg(TRANSPORT_CHANNEL, "TCP packet received: src=%d:%d, dest=%d:%d, flag=%d, seq=%d, ack=%d\n",
            package->src, tcpPack->srcPort, package->dest, tcpPack->destPort, 
            tcpPack->flag, tcpPack->seq, tcpPack->ack);
        
        if(tcpPack->flag == SYN_FLAG) {
            for(i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
                if(sockets[i].state == LISTEN && sockets[i].src == tcpPack->destPort) {
                    newFd = getFreeSocket();
                    if(newFd != NULL_SOCKET) {
                        sockets[newFd].flag = SYN_RCVD;
                        sockets[newFd].state = SYN_RCVD;
                        sockets[newFd].src = tcpPack->destPort;
                        sockets[newFd].dest.port = tcpPack->srcPort;
                        sockets[newFd].dest.addr = package->src;
                        sockets[newFd].nextExpected = tcpPack->seq + 1;
                        sockets[newFd].lastSent = call Random.rand16();
                        
                        makeTCPPacket(&tcpPacket, sockets[newFd].src, sockets[newFd].dest.port,
                                      sockets[newFd].lastSent, sockets[newFd].nextExpected,
                                      SYN_ACK_FLAG, SOCKET_BUFFER_SIZE, NULL, 0);
                        
                        makeIPPacket(&ipPacket, TOS_NODE_ID, sockets[newFd].dest.addr,
                                     MAX_TTL, PROTOCOL_TCP, 0, (uint8_t*)&tcpPacket,
                                     sizeof(tcp_pack));
                        
                        call Sender.send(ipPacket, sockets[newFd].dest.addr);
                        
                        dbg(TRANSPORT_CHANNEL, "SYN-ACK sent: new_fd=%d\n", newFd);
                    }
                    return SUCCESS;
                }
            }
        }
        
        fd = getSocket(tcpPack->destPort, tcpPack->srcPort, package->src);
        
        if(fd == NULL_SOCKET) {
            return FAIL;
        }
        
        if(tcpPack->flag == SYN_ACK_FLAG) {
            if(sockets[fd].state == SYN_SENT) {
                sockets[fd].state = ESTABLISHED;
                sockets[fd].flag = ESTABLISHED;
                sockets[fd].nextExpected = tcpPack->seq + 1;
                sockets[fd].lastAck = sockets[fd].lastSent;
                
                makeTCPPacket(&tcpPacket, sockets[fd].src, sockets[fd].dest.port,
                              sockets[fd].lastSent + 1, sockets[fd].nextExpected,
                              ACK_FLAG, SOCKET_BUFFER_SIZE, NULL, 0);
                
                makeIPPacket(&ipPacket, TOS_NODE_ID, sockets[fd].dest.addr,
                             MAX_TTL, PROTOCOL_TCP, 0, (uint8_t*)&tcpPacket,
                             sizeof(tcp_pack));
                
                call Sender.send(ipPacket, sockets[fd].dest.addr);
                
                dbg(TRANSPORT_CHANNEL, "Connection established: fd=%d\n", fd);
            }
            return SUCCESS;
        }
        
        if(tcpPack->flag == ACK_FLAG) {
            if(sockets[fd].state == SYN_RCVD) {
                sockets[fd].state = ESTABLISHED;
                sockets[fd].flag = ESTABLISHED;
                sockets[fd].lastAck = sockets[fd].lastSent;
                dbg(TRANSPORT_CHANNEL, "Connection established: fd=%d\n", fd);
            } else if(sockets[fd].state == ESTABLISHED) {
                call RetransmitTimer.stop();
                sockets[fd].lastAck = tcpPack->ack - 1;
                dbg(TRANSPORT_CHANNEL, "ACK received: fd=%d, ack=%d\n", fd, tcpPack->ack);
            } else if(sockets[fd].state == FIN_WAIT) {
                sockets[fd].state = CLOSED;
                sockets[fd].flag = CLOSED;
                dbg(TRANSPORT_CHANNEL, "Connection closed: fd=%d\n", fd);
            }
            return SUCCESS;
        }
        
        if(tcpPack->flag == DATA_FLAG) {
            if(tcpPack->seq == sockets[fd].nextExpected) {
                for(i = 0; i < TCP_PACKET_MAX_PAYLOAD_SIZE && tcpPack->payload[i] != 0; i++) {
                    sockets[fd].rcvdBuff.buffer[sockets[fd].rcvdBuff.tail] = tcpPack->payload[i];
                    sockets[fd].rcvdBuff.tail = (sockets[fd].rcvdBuff.tail + 1) % SOCKET_BUFFER_SIZE;
                }
                sockets[fd].nextExpected = tcpPack->seq + i;
                
                makeTCPPacket(&tcpPacket, sockets[fd].src, sockets[fd].dest.port,
                              sockets[fd].lastSent, sockets[fd].nextExpected,
                              ACK_FLAG, SOCKET_BUFFER_SIZE, NULL, 0);
                
                makeIPPacket(&ipPacket, TOS_NODE_ID, sockets[fd].dest.addr,
                             MAX_TTL, PROTOCOL_TCP, 0, (uint8_t*)&tcpPacket,
                             sizeof(tcp_pack));
                
                call Sender.send(ipPacket, sockets[fd].dest.addr);
                
                dbg(TRANSPORT_CHANNEL, "Data received: fd=%d, bytes=%d, ACK sent=%d\n", 
                    fd, i, sockets[fd].nextExpected);
            }
            return SUCCESS;
        }
        
        if(tcpPack->flag == FIN_FLAG) {
            sockets[fd].state = CLOSE_WAIT;
            
            makeTCPPacket(&tcpPacket, sockets[fd].src, sockets[fd].dest.port,
                          sockets[fd].lastSent, tcpPack->seq + 1,
                          ACK_FLAG, SOCKET_BUFFER_SIZE, NULL, 0);
            
            makeIPPacket(&ipPacket, TOS_NODE_ID, sockets[fd].dest.addr,
                         MAX_TTL, PROTOCOL_TCP, 0, (uint8_t*)&tcpPacket,
                         sizeof(tcp_pack));
            
            call Sender.send(ipPacket, sockets[fd].dest.addr);
            
            sockets[fd].state = CLOSED;
            sockets[fd].flag = CLOSED;
            
            dbg(TRANSPORT_CHANNEL, "FIN received and ACKed: fd=%d, connection closed\n", fd);
            return SUCCESS;
        }
        
        return SUCCESS;
    }
    
    event void RetransmitTimer.fired() {
        uint8_t i;
        uint8_t dataLen;
        
        for(i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
            if(sockets[i].state == ESTABLISHED && sockets[i].lastSent > sockets[i].lastAck) {
                dataLen = sockets[i].lastSent - sockets[i].lastAck;
                if(dataLen > TCP_PACKET_MAX_PAYLOAD_SIZE) {
                    dataLen = TCP_PACKET_MAX_PAYLOAD_SIZE;
                }
                
                makeTCPPacket(&tcpPacket, sockets[i].src, sockets[i].dest.port,
                              sockets[i].lastAck + 1, sockets[i].nextExpected,
                              DATA_FLAG, SOCKET_BUFFER_SIZE,
                              &sockets[i].sendBuff.buffer[sockets[i].sendBuff.head],
                              dataLen);
                
                makeIPPacket(&ipPacket, TOS_NODE_ID, sockets[i].dest.addr,
                             MAX_TTL, PROTOCOL_TCP, 0, (uint8_t*)&tcpPacket,
                             sizeof(tcp_pack));
                
                call Sender.send(ipPacket, sockets[i].dest.addr);
                
                dbg(TRANSPORT_CHANNEL, "Retransmit: fd=%d, seq=%d\n", i, sockets[i].lastAck + 1);
                
                call RetransmitTimer.startOneShot(10000);
            }
        }
    }
    
    event void TransportTimer.fired() {
    }
}