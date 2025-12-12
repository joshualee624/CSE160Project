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
    bool closeRequested[MAX_NUM_OF_SOCKETS];
    bool acceptedOnce[MAX_NUM_OF_SOCKETS]; //see which sockets were returned by accept()

    tcp_pack tcpPacket;
    pack ipPacket;
    
    // enum {
    //     CLOSED = 0,
    //     LISTEN = 1,
    //     SYN_SENT = 2,
    //     SYN_RCVD = 3,
    //     ESTABLISHED = 4,
    //     FIN_WAIT_1 = 5,
    //     FIN_WAIT_2 = 6,
    //     CLOSE_WAIT = 7,
    //     LAST_ACK = 8,
    //     TIME_WAIT = 9
    // }; declared in socket.h
    
    enum {
        DATA_FLAG = 0,
        ACK_FLAG = 1,
        SYN_FLAG = 2,
        FIN_FLAG = 4,
        SYN_ACK_FLAG = 3,
        FIN_ACK_FLAG = 5
    };
    
    void makeTCPPacket(tcp_pack *tcp,
                   uint8_t srcPort, uint8_t destPort,
                   uint16_t seq, uint16_t ack, uint8_t flag,
                   uint8_t advertisedWindow,
                   uint8_t *payload, nx_uint8_t len)
    {
        uint8_t copyLen;

        tcp->srcPort = srcPort;
        tcp->destPort = destPort;
        tcp->seq = seq;
        tcp->ack = ack;
        tcp->flag = flag;
        tcp->advertisedWindow = advertisedWindow;

        // Clamp length to max payload
        copyLen = len;
        if (copyLen > TCP_PACKET_MAX_PAYLOAD_SIZE) {
            copyLen = TCP_PACKET_MAX_PAYLOAD_SIZE;
        }
        tcp->len = copyLen;

        // Clear payload to avoid leftover bytes causing weird behavior
        memset((void*)tcp->payload, 0, TCP_PACKET_MAX_PAYLOAD_SIZE);

        if (copyLen > 0 && payload != NULL) {
            memcpy((void*)tcp->payload, payload, copyLen);
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
            closeRequested[fd] = FALSE;
            acceptedOnce[fd] = FALSE;
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
            if(!acceptedOnce[i] && sockets[i].state == ESTABLISHED && sockets[i].src == sockets[fd].src) {
                acceptedOnce[i] = TRUE;
                dbg(TRANSPORT_CHANNEL, "Connection accepted: new_fd=%d\n", i);
                return i;
            }
        }
        return NULL_SOCKET;
    }
    uint8_t getRecvWindow(socket_t fd); //forward declare
    
    command error_t Transport.connect(socket_t fd, socket_addr_t *addr) {
        if(fd >= MAX_NUM_OF_SOCKETS) {
            return FAIL;
        }
        
        sockets[fd].dest.port = addr->port;
        sockets[fd].dest.addr = addr->addr;
        sockets[fd].state = SYN_SENT;
        sockets[fd].flag = SYN_SENT;
        sockets[fd].lastSent = 0;
        sockets[fd].lastAck = 0;
        
        makeTCPPacket(&tcpPacket, sockets[fd].src, sockets[fd].dest.port,
                      sockets[fd].lastSent, 0, SYN_FLAG, 
                      getRecvWindow(fd), NULL, 0);
        
        makeIPPacket(&ipPacket, TOS_NODE_ID, sockets[fd].dest.addr, 
                     MAX_TTL, PROTOCOL_TCP, 0, (uint8_t*)&tcpPacket, 
                     sizeof(tcp_pack));
        
        call Sender.send(ipPacket, sockets[fd].dest.addr);
        
        dbg(TRANSPORT_CHANNEL, "SYN sent: fd=%d, dest=%d:%d, seq=%d\n", 
            fd, sockets[fd].dest.addr, sockets[fd].dest.port, sockets[fd].lastSent);
        
        return SUCCESS;
    }
    void trySendQueued(socket_t fd) {
        uint16_t queued;
        uint16_t inFlight;
        uint16_t advWin;
        uint16_t unsent;
        uint16_t sendCap;
        uint16_t dataLen;
        uint16_t readIdx;

        if (sockets[fd].state != ESTABLISHED) return;

        queued = (sockets[fd].sendBuff.tail >= sockets[fd].sendBuff.head)
              ? sockets[fd].sendBuff.tail - sockets[fd].sendBuff.head
              : SOCKET_BUFFER_SIZE - sockets[fd].sendBuff.head + sockets[fd].sendBuff.tail;
        if (queued == 0) return;

        inFlight = sockets[fd].lastSent - sockets[fd].lastAck;
        if (inFlight >= queued) return; // nothing new to send
        advWin = sockets[fd].effectiveWindow;
        if (advWin == 0) return; // peer window closed

        while (queued > inFlight && inFlight < advWin) {
            unsent = queued - inFlight;                 // bytes queued but not yet sent
            sendCap = advWin - inFlight;                // window space
            if (sendCap > TCP_PACKET_MAX_PAYLOAD_SIZE) sendCap = TCP_PACKET_MAX_PAYLOAD_SIZE;
            dataLen = (unsent < sendCap) ? unsent : sendCap;
            if (dataLen == 0) break;

            // start at head + inFlight (next unsent byte); 
            readIdx = (sockets[fd].sendBuff.head + inFlight) % SOCKET_BUFFER_SIZE;
            if (readIdx + dataLen > SOCKET_BUFFER_SIZE) {
                dataLen = SOCKET_BUFFER_SIZE - readIdx;
            }

            makeTCPPacket(&tcpPacket, sockets[fd].src, sockets[fd].dest.port,
                        sockets[fd].lastSent, sockets[fd].nextExpected,
                        DATA_FLAG, getRecvWindow(fd),
                        &sockets[fd].sendBuff.buffer[readIdx],
                        dataLen);


            makeIPPacket(&ipPacket, TOS_NODE_ID, sockets[fd].dest.addr,
                     MAX_TTL, PROTOCOL_TCP, 0, (uint8_t*)&tcpPacket, sizeof(tcp_pack));


            dbg(TRANSPORT_CHANNEL, "SEND DATA fd=%d seq=%u len=%u\n", fd, tcpPacket.seq, tcpPacket.len);

            call Sender.send(ipPacket, sockets[fd].dest.addr);
            sockets[fd].lastSent += dataLen;
            inFlight += dataLen;
        }
        if (inFlight > 0) {
            call RetransmitTimer.startOneShot(10000);
        }
    }
    

    void sendFin(socket_t fd) {
        uint16_t finSeq = sockets[fd].lastSent + 1;
        makeTCPPacket(&tcpPacket,
                  sockets[fd].src,
                  sockets[fd].dest.port,
                  finSeq,                    // FIN sequence number
                  sockets[fd].nextExpected,     // ACK what we received
                  FIN_FLAG,
                  getRecvWindow(fd),
                  NULL,
                  0);
        makeIPPacket(&ipPacket,
                 TOS_NODE_ID,
                 sockets[fd].dest.addr,
                 MAX_TTL,
                 PROTOCOL_TCP,
                 0,
                 (uint8_t*)&tcpPacket,
                 sizeof(tcp_pack));
        call Sender.send(ipPacket, sockets[fd].dest.addr);
        sockets[fd].state = FIN_WAIT_1;
        sockets[fd].lastSent = finSeq;
        call RetransmitTimer.startOneShot(10000); // or a dedicated FIN timer
    }
    void sendFinPassive(socket_t fd) {
        uint16_t finSeq = sockets[fd].lastSent + 1;
        makeTCPPacket(&tcpPacket,
                  sockets[fd].src,
                  sockets[fd].dest.port,
                  finSeq,
                  sockets[fd].nextExpected,
                  FIN_FLAG,
                  getRecvWindow(fd),
                  NULL,
                  0);
        makeIPPacket(&ipPacket,
                 TOS_NODE_ID,
                 sockets[fd].dest.addr,
                 MAX_TTL,
                 PROTOCOL_TCP,
                 0,
                 (uint8_t*)&tcpPacket,
                 sizeof(tcp_pack));
        call Sender.send(ipPacket, sockets[fd].dest.addr);
        sockets[fd].state = LAST_ACK;
        sockets[fd].lastSent = finSeq;
        call RetransmitTimer.startOneShot(10000);
    }
    uint8_t getRecvWindow(socket_t fd) {
        uint16_t head = sockets[fd].rcvdBuff.head;
        uint16_t tail = sockets[fd].rcvdBuff.tail;
        uint16_t used;
        uint16_t free;

        if (tail >= head) {
            used = tail - head;
        } else {
            used = SOCKET_BUFFER_SIZE - head + tail;
        }

        // free space in our receive buffer
        if (used >= SOCKET_BUFFER_SIZE) {
            free = 0;
        } else {
            free = SOCKET_BUFFER_SIZE - used;
        }

        if (free > 255) free = 255;  // field is uint8_t
        return (uint8_t)free;
    }



    
    command error_t Transport.close(socket_t fd) {
        if(fd >= MAX_NUM_OF_SOCKETS) {
            return FAIL;
        }
        if (sockets[fd].state != ESTABLISHED) return FAIL;

        // Try to push any queued data if nothing is in flight
        trySendQueued(fd);

        // Only close when send buffer is empty and nothing in flight
        if (sockets[fd].sendBuff.head != sockets[fd].sendBuff.tail) return EBUSY;   // still queued
        if (sockets[fd].lastSent != sockets[fd].lastAck) {
            closeRequested[fd] = TRUE;
            return EBUSY;
        }
        closeRequested[fd] = FALSE;
        sendFin(fd); // uses FIN_FLAG, seq = lastSent+1, updates state to FIN_WAIT_1
        return SUCCESS;
        
    }

    command bool Transport.isEstablished(socket_t fd) {
        if(fd >= MAX_NUM_OF_SOCKETS) {
            return FALSE;
        }
        return sockets[fd].state == ESTABLISHED;
    }
    
    command bool Transport.readyToClose(socket_t fd) {
        if(fd >= MAX_NUM_OF_SOCKETS) {
            return FALSE;
        }
        if (sockets[fd].state != ESTABLISHED) return FALSE;
        if (sockets[fd].sendBuff.head != sockets[fd].sendBuff.tail) return FALSE;
        if (sockets[fd].lastSent != sockets[fd].lastAck) return FALSE;
        return TRUE;
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
        sockets[fd].lastSent = 0;
        sockets[fd].lastAck = 0;
        sockets[fd].lastRead = 0;
        sockets[fd].lastRcvd = 0;
        sockets[fd].nextExpected = 0;
        acceptedOnce[fd] = FALSE;
        
        dbg(TRANSPORT_CHANNEL, "Socket released (hard close): fd=%d\n", fd);
        
        return SUCCESS;
    }
    
    command uint16_t Transport.write(socket_t fd, uint8_t *buff, uint16_t bufflen) {
        uint16_t i;
        uint16_t written = 0;
        
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
        
        trySendQueued(fd);
        if (closeRequested[fd] &&
            sockets[fd].sendBuff.head == sockets[fd].sendBuff.tail &&
            sockets[fd].lastSent == sockets[fd].lastAck) {
            closeRequested[fd] = FALSE;
            sendFin(fd);
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
                        sockets[newFd].lastSent = 0;
                        sockets[newFd].lastAck = 0;
                        
                        makeTCPPacket(&tcpPacket, sockets[newFd].src, sockets[newFd].dest.port,
                                      sockets[newFd].lastSent, sockets[newFd].nextExpected,
                                      SYN_ACK_FLAG, getRecvWindow(newFd), NULL, 0);
                        
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
        sockets[fd].effectiveWindow = tcpPack->advertisedWindow;
        
        if(tcpPack->flag == SYN_ACK_FLAG) {
            if(sockets[fd].state == SYN_SENT) {
                sockets[fd].state = ESTABLISHED;
                sockets[fd].flag = ESTABLISHED;
                sockets[fd].nextExpected = tcpPack->seq + 1;
                sockets[fd].lastAck = tcpPack->ack;   // cumulative ACK value
                
                makeTCPPacket(&tcpPacket, sockets[fd].src, sockets[fd].dest.port,
                              sockets[fd].lastSent + 1, sockets[fd].nextExpected,
                              ACK_FLAG, getRecvWindow(fd), NULL, 0);
                
                makeIPPacket(&ipPacket, TOS_NODE_ID, sockets[fd].dest.addr,
                             MAX_TTL, PROTOCOL_TCP, 0, (uint8_t*)&tcpPacket,
                             sizeof(tcp_pack));
                
                call Sender.send(ipPacket, sockets[fd].dest.addr);
                sockets[fd].lastSent += 1;
                sockets[fd].lastAck = sockets[fd].lastSent;

                dbg(TRANSPORT_CHANNEL, "Connection established: fd=%d\n", fd);
            }
            return SUCCESS;
        }
        
        if(tcpPack->flag == ACK_FLAG) {
            if(sockets[fd].state == SYN_RCVD) {
                sockets[fd].state = ESTABLISHED;
                sockets[fd].flag = ESTABLISHED;
                sockets[fd].lastAck = tcpPack->ack;
                sockets[fd].lastSent += 1;
                dbg(TRANSPORT_CHANNEL, "Connection established: fd=%d\n", fd);
            } else if (sockets[fd].state == ESTABLISHED) {
                uint16_t prevLastAck;
                uint16_t newLastAck;
                uint16_t delta;
                uint16_t buffered;

                if (tcpPack->ack == 0) {
                    return SUCCESS;
                }

                prevLastAck = sockets[fd].lastAck;
                newLastAck  = tcpPack->ack;

                // Only do work if the ACK advances (not a dup ACK)
                if (newLastAck > prevLastAck) {

                    delta = newLastAck - prevLastAck;

                    buffered = (sockets[fd].sendBuff.tail >= sockets[fd].sendBuff.head)
                        ? (sockets[fd].sendBuff.tail - sockets[fd].sendBuff.head)
                        : (SOCKET_BUFFER_SIZE - sockets[fd].sendBuff.head + sockets[fd].sendBuff.tail);

                    if (delta > buffered) delta = buffered;

                    sockets[fd].lastAck = prevLastAck + delta;
                    sockets[fd].sendBuff.head = (sockets[fd].sendBuff.head + delta) % SOCKET_BUFFER_SIZE;

                    // We made forward progress → stop timer (if running)
                    call RetransmitTimer.stop();

                    // Now that bytes are freed, try to send more queued data
                    trySendQueued(fd);
                }

                // If there is still outstanding data, ensure retransmit timer is running.
                // If no outstanding data, stop it.
                if (sockets[fd].lastSent > sockets[fd].lastAck) {
                    call RetransmitTimer.startOneShot(10000);
                } else {
                    call RetransmitTimer.stop();
                }

                // FIN logic should run after ACK processing, when we're possibly fully drained.
                if (closeRequested[fd] &&
                    sockets[fd].sendBuff.head == sockets[fd].sendBuff.tail &&
                    sockets[fd].lastAck == sockets[fd].lastSent) {

                    closeRequested[fd] = FALSE;
                    sendFin(fd);

                } else if (sockets[fd].state == CLOSE_WAIT &&
                        sockets[fd].sendBuff.head == sockets[fd].sendBuff.tail &&
                        sockets[fd].lastAck == sockets[fd].lastSent) {

                    sendFinPassive(fd);
                    dbg(TRANSPORT_CHANNEL,
                        "FIN sent (passive close): fd=%d, seq=%d\n",
                        fd, sockets[fd].lastSent);
                }

                dbg(TRANSPORT_CHANNEL, "ACK received: fd=%d, ack=%d\n", fd, tcpPack->ack);
            }
            else if (sockets[fd].state == FIN_WAIT_1) {
                // Check if this ACK covers the FIN
                if (tcpPack->ack > sockets[fd].lastSent) {
                    sockets[fd].state = FIN_WAIT_2;
                    call RetransmitTimer.stop(); // stop FIN retransmit
                }
            
            } else if (sockets[fd].state == LAST_ACK) {
                if (tcpPack->ack > sockets[fd].lastSent) {
                    sockets[fd].state = CLOSED;
                    call RetransmitTimer.stop();
                }
            }
            
            return SUCCESS;
        }

        if (tcpPack->flag == DATA_FLAG) {
            uint8_t segLen = tcpPack->len;

            if (segLen > TCP_PACKET_MAX_PAYLOAD_SIZE) segLen = TCP_PACKET_MAX_PAYLOAD_SIZE;

            // In-order segment
            if (tcpPack->seq == sockets[fd].nextExpected) {
                uint8_t k;
                for (k = 0; k < segLen; k++) {
                    sockets[fd].rcvdBuff.buffer[sockets[fd].rcvdBuff.tail] = tcpPack->payload[k];
                    sockets[fd].rcvdBuff.tail = (sockets[fd].rcvdBuff.tail + 1) % SOCKET_BUFFER_SIZE;
                }

                sockets[fd].nextExpected = tcpPack->seq + segLen;
            }

            // Always ACK the nextExpected (dup-ACK if out-of-order)
            makeTCPPacket(&tcpPacket,
                        sockets[fd].src, sockets[fd].dest.port,
                        sockets[fd].lastSent + 1,          // seq for pure ACK (ok)
                        sockets[fd].nextExpected,          // IMPORTANT
                        ACK_FLAG,
                        getRecvWindow(fd),
                        NULL,
                        0);

            makeIPPacket(&ipPacket, TOS_NODE_ID, sockets[fd].dest.addr,
                        MAX_TTL, PROTOCOL_TCP, 0, (uint8_t*)&tcpPacket, sizeof(tcp_pack));

            call Sender.send(ipPacket, sockets[fd].dest.addr);

            dbg(TRANSPORT_CHANNEL, "DATA fd=%d recv seq=%u len=%u -> ACK=%u\n",
                fd, tcpPack->seq, segLen, sockets[fd].nextExpected);

            return SUCCESS;
        }



        
        // if (tcpPack->flag == DATA_FLAG) {
        //     uint8_t segLen;

        //     // Clamp length for safety
        //     segLen = tcpPack->len;
        //     if (segLen > TCP_PACKET_MAX_PAYLOAD_SIZE) {
        //         segLen = TCP_PACKET_MAX_PAYLOAD_SIZE;
        //     }

        //     if (tcpPack->seq == sockets[fd].nextExpected) {
        //         for (i = 0; i < segLen; i++) {
        //             sockets[fd].rcvdBuff.buffer[sockets[fd].rcvdBuff.tail] = tcpPack->payload[i];
        //             sockets[fd].rcvdBuff.tail = (sockets[fd].rcvdBuff.tail + 1) % SOCKET_BUFFER_SIZE;
        //         }

        //         sockets[fd].nextExpected = tcpPack->seq + segLen;

        //         makeTCPPacket(&tcpPacket, sockets[fd].src, sockets[fd].dest.port,
        //                     sockets[fd].lastSent + 1, sockets[fd].nextExpected,
        //                     ACK_FLAG, getRecvWindow(fd), NULL, 0);

        //         makeIPPacket(&ipPacket, TOS_NODE_ID, sockets[fd].dest.addr,
        //                     MAX_TTL, PROTOCOL_TCP, 0, (uint8_t*)&tcpPacket,
        //                     sizeof(tcp_pack));
        //         dbg(TRANSPORT_CHANNEL, "RECV DATA fd=%d seq=%u len=%u nextExpected=%u\n",fd, tcpPack->seq, tcpPack->len, sockets[fd].nextExpected);

        //         call Sender.send(ipPacket, sockets[fd].dest.addr);

        //         dbg(TRANSPORT_CHANNEL, "Data received: fd=%d, bytes=%d, ACK sent=%d\n",
        //             fd, segLen, sockets[fd].nextExpected);
        //     }
        //     return SUCCESS;
        // }

        
        if(tcpPack->flag == FIN_FLAG) {
            
            makeTCPPacket(&tcpPacket, sockets[fd].src, sockets[fd].dest.port,
                          sockets[fd].lastSent, tcpPack->seq + 1,
                          ACK_FLAG, getRecvWindow(fd), NULL, 0);
            
            makeIPPacket(&ipPacket, TOS_NODE_ID, sockets[fd].dest.addr,
                         MAX_TTL, PROTOCOL_TCP, 0, (uint8_t*)&tcpPacket,
                         sizeof(tcp_pack));
            
            call Sender.send(ipPacket, sockets[fd].dest.addr);
            // Advance our receive side
            sockets[fd].nextExpected = tcpPack->seq + 1;

            // State transitions
            if (sockets[fd].state == ESTABLISHED) {
                sockets[fd].state = CLOSE_WAIT;
                // Auto close once our send side is drained
                if (sockets[fd].sendBuff.head == sockets[fd].sendBuff.tail &&
                    sockets[fd].lastAck >= sockets[fd].lastSent) {
                    sendFinPassive(fd);
                    dbg(TRANSPORT_CHANNEL,"FIN sent (passive close): fd=%d, seq=%d\n",fd, sockets[fd].lastSent);

                }
            }
            else if (sockets[fd].state == FIN_WAIT_1) {
                // Simultaneous close: if our FIN not ACKed yet, we're effectively in CLOSING/TIME_WAIT
                sockets[fd].state = TIME_WAIT;
                call RetransmitTimer.stop();
                call TransportTimer.startOneShot(5000); // TIME_WAIT duration
                dbg(TRANSPORT_CHANNEL, "FIN received during FIN_WAIT_1: entering TIME_WAIT\n");
            }
            else if (sockets[fd].state == FIN_WAIT_2) {
            sockets[fd].state = TIME_WAIT;
            call TransportTimer.startOneShot(5000);
            dbg(TRANSPORT_CHANNEL, "FIN received: fd=%d, entering TIME_WAIT\n", fd);
            }
            
            dbg(TRANSPORT_CHANNEL,"FIN received and ACKed: fd=%d, state=%d\n",fd, sockets[fd].state);

            return SUCCESS;
        }
        
        
        return SUCCESS;
    }
    event void RetransmitTimer.fired() {
        uint8_t i;

        for (i = 0; i < MAX_NUM_OF_SOCKETS; i++) {

            // Only retransmit if there is outstanding unacked data
            if (sockets[i].state == ESTABLISHED && sockets[i].lastSent > sockets[i].lastAck) {

            uint16_t unacked = sockets[i].lastSent - sockets[i].lastAck;
            uint16_t head = sockets[i].sendBuff.head;
            uint16_t contiguous = SOCKET_BUFFER_SIZE - head;
            uint8_t dataLen;

            // send at most one segment
            dataLen = (unacked > TCP_PACKET_MAX_PAYLOAD_SIZE) ? TCP_PACKET_MAX_PAYLOAD_SIZE : (uint8_t)unacked;
            if (dataLen > contiguous) dataLen = (uint8_t)contiguous;

            makeTCPPacket(&tcpPacket,
                sockets[i].src,
                sockets[i].dest.port,
                sockets[i].lastAck + 1,          // first unacked byte
                sockets[i].nextExpected,
                DATA_FLAG,
                getRecvWindow(i),
                &sockets[i].sendBuff.buffer[head],
                dataLen);

            makeIPPacket(&ipPacket,
                TOS_NODE_ID,
                sockets[i].dest.addr,
                MAX_TTL,
                PROTOCOL_TCP,
                0,
                (uint8_t*)&tcpPacket,
                sizeof(tcp_pack));

            call Sender.send(ipPacket, sockets[i].dest.addr);

            dbg(TRANSPORT_CHANNEL, "Retransmit: fd=%d, seq=%u, len=%u\n",
                i, sockets[i].lastAck + 1, dataLen);

            // re-arm timer once (don’t spam restart for every socket)
            call RetransmitTimer.startOneShot(10000);
            return;
            }
        }
    }

    
    
            // if((sockets[i].state == FIN_WAIT_1 || sockets[i].state == LAST_ACK)&& sockets[i].lastSent > sockets[i].lastAck) {
            //     // Retransmit FIN
            //     uint16_t finSeq = sockets[i].lastSent;
            //     makeTCPPacket(&tcpPacket,
            //               sockets[i].src,
            //               sockets[i].dest.port,
            //               finSeq,
            //               sockets[i].nextExpected,
            //               FIN_FLAG,
            //               getRecvWindow(i),
            //               NULL,
            //               0);
            //     makeIPPacket(&ipPacket,
            //              TOS_NODE_ID,
            //              sockets[i].dest.addr,
            //              MAX_TTL,
            //              PROTOCOL_TCP,
            //              0,
            //              (uint8_t*)&tcpPacket,
            //              sizeof(tcp_pack));
            //     call Sender.send(ipPacket, sockets[i].dest.addr);
                
            //     dbg(TRANSPORT_CHANNEL, "FIN Retransmit: fd=%d, seq=%d\n", i, finSeq);
                
            //     call RetransmitTimer.startOneShot(10000);
            // }

    
    event void TransportTimer.fired() {
        uint8_t i;
        for (i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
            if (sockets[i].state == TIME_WAIT) {
                sockets[i].state = CLOSED;
                // optionally clear dest/src/etc. or call release()
            }
        }
    }
}
