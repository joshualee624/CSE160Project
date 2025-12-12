/*
 * ANDES Lab - University of California, Merced
 * This class provides the basic functions of a network node.
 *
 * @author UCM ANDES Lab
 * @date   2013/09/03
 *
 */
#include <Timer.h>
#include "includes/command.h"
#include "includes/packet.h"
#include "includes/CommandMsg.h"
#include "includes/sendInfo.h"
#include "includes/channels.h"
#include "includes/socket.h"

module Node {
   uses interface Boot;
   uses interface SplitControl as AMControl;
   uses interface Receive;

   uses interface SimpleSend as Sender;
   uses interface NeighborDiscovery;
   uses interface CommandHandler;
   uses interface Flooding;
   uses interface LinkState;
   uses interface Transport;
   uses interface Timer<TMilli> as ServerReadTimer;
   uses interface Timer<TMilli> as ClientWriteTimer;
}

implementation {
   pack sendPackage;
   uint16_t sequenceNumber = 0;

   socket_t serverSocket = NULL_SOCKET;
   socket_t clientSocket = NULL_SOCKET;
   socket_t acceptedSockets[MAX_NUM_OF_SOCKETS];
   uint8_t numAcceptedSockets = 0;
   uint16_t clientTransfer = 0;
   uint16_t clientDataSent = 0;
   bool clientCloseWarned = FALSE;
   uint16_t clientNextValue = 1;

   socket_t chatSock = NULL_SOCKET;
   socket_t serverSock = NULL_SOCKET;
   bool chatConnected = FALSE;
   bool isChatClient = FALSE;
   bool isChatServer = FALSE;
   // simple outgoing queue for chat client (lines to send after ESTABLISHED)
   uint8_t chatSendHead = 0;
   uint8_t chatSendTail = 0;
   char chatSendQueue[8][64];
   uint8_t chatSendLen[8];
   char chatCliBuf[128];
   uint8_t chatCliLen = 0;
   bool chatCloseRequested = FALSE;
   bool chatFinSent = FALSE;
   bool chatPeerFinSeen = FALSE;



  // bounded copy helper to ensure null-terminated C strings from command payloads
  void copyBounded(char* dst, uint8_t dstSize, uint8_t* src) {
     uint8_t n = 0;
     if (dstSize == 0) {
        return;
     }
     while (n + 1 < dstSize && src[n] != 0) {
        dst[n] = (char)src[n];
        n++;
     }
     dst[n] = '\0';
  }

  void handleChatClientData(uint8_t *buf, uint16_t n) {
      uint16_t i;

      for (i = 0; i < n; i++) {
         // prevent overflow; if full, reset (or drop oldest)
         if (chatCliLen >= sizeof(chatCliBuf) - 1) {
            chatCliLen = 0;
         }

         chatCliBuf[chatCliLen++] = (char)buf[i];

         // end-of-line detected
         if (buf[i] == '\n') {
            chatCliBuf[chatCliLen] = '\0';
            dbg(TRANSPORT_CHANNEL, "Chat client line: %s", chatCliBuf);
            chatCliLen = 0;
         }
      }
   }


  typedef struct {
      socket_t sock;
      char username[16];
      bool inUse;
   } ChatUser_t;

   ChatUser_t chatUsers[MAX_NUM_OF_SOCKETS];

   //per-socket receive buffers for assembling lines
   char chatRecvBuf[MAX_NUM_OF_SOCKETS][64];
   uint8_t chatRecvLen[MAX_NUM_OF_SOCKETS];

   void closeAcceptedSocket(uint8_t idx);
   void resetAcceptedSockets();
   void cleanupServerSocket();
   void cleanupClientSocket();
   bool enqueueChatLine(const char* line);
   void flushChatQueue();
   void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t Protocol, uint16_t seq, uint8_t *payload, uint8_t length);

   event void Boot.booted() {
      uint8_t i;
      call AMControl.start();
      for(i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
         acceptedSockets[i] = NULL_SOCKET;
      }
      dbg(GENERAL_CHANNEL, "Booted\n");
   }

   event void AMControl.startDone(error_t err) {
      if(err == SUCCESS) {
         call NeighborDiscovery.findNeighbors();
         call Flooding.init();
         call LinkState.init();
         dbg(GENERAL_CHANNEL, "Radio On\n");
      } else {
         call AMControl.start();
      }
   }

   event void AMControl.stopDone(error_t err) {}

   event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len) {

      if(len == sizeof(pack)) {
         pack* myMsg = (pack*) payload;
         uint16_t nextHop;

         call NeighborDiscovery.handle(myMsg);
         
         if (myMsg->protocol == PROTOCOL_PING) {
            if (myMsg->dest == TOS_NODE_ID) {
               uint8_t replyPayload[PACKET_MAX_PAYLOAD_SIZE];
               uint8_t replyLen = strlen("reply");
               pack reply;
               memcpy(replyPayload, "reply", replyLen);
               replyPayload[replyLen] = '\0';
               dbg(GENERAL_CHANNEL, "Ping from %u payload: %s\n", myMsg->src, myMsg->payload);

               makePack(&reply, TOS_NODE_ID, myMsg->src, MAX_TTL,
                        PROTOCOL_PINGREPLY, ++sequenceNumber,
                        replyPayload, replyLen+1);
               dbg(GENERAL_CHANNEL, "Sending reply to %u\n", myMsg->src); 
               
               nextHop = call LinkState.getNextHop(myMsg->src);
               if(nextHop != 0xFFFF) {
                  call Sender.send(reply, nextHop);
               } else {
                  dbg(GENERAL_CHANNEL, "No route to %u, falling back to flood\n", myMsg->src);
                  call Flooding.floodPacket(&reply);
               }
            } else {
               nextHop = call LinkState.getNextHop(myMsg->dest);
               if(nextHop != 0xFFFF) {
                  dbg(GENERAL_CHANNEL, "Routing packet to %u via %u\n", myMsg->dest, nextHop);
                  call Sender.send(*myMsg, nextHop);
               } else {
                  dbg(GENERAL_CHANNEL, "No route to %u\n", myMsg->dest);
               }
            }
         } else if (myMsg->protocol == PROTOCOL_PINGREPLY) {
            if(myMsg->dest == TOS_NODE_ID) {
               dbg(GENERAL_CHANNEL, "Ping reply received from %u\n", myMsg->src);
            } else {
               nextHop = call LinkState.getNextHop(myMsg->dest);
               if(nextHop != 0xFFFF) {
                  dbg(GENERAL_CHANNEL, "Routing ping reply to %u via %u\n", myMsg->dest, nextHop);
                  call Sender.send(*myMsg, nextHop);
               } else {
                  dbg(GENERAL_CHANNEL, "No route to %u\n", myMsg->dest);
               }
            }
         } else if (myMsg->protocol == PROTOCOL_LINKEDSTATE) {
            call LinkState.handleAdvertisement(myMsg);
            call Flooding.handlePacket(myMsg);
         } else if (myMsg->protocol == PROTOCOL_TCP) {
            if(myMsg->dest == TOS_NODE_ID) {
               call Transport.receive(myMsg);
            } else {
               nextHop = call LinkState.getNextHop(myMsg->dest);
               if(nextHop != 0xFFFF) {
                  dbg(ROUTING_CHANNEL, "Forwarding TCP packet to %u via %u\n", myMsg->dest, nextHop);
                  call Sender.send(*myMsg, nextHop);
               } else {
                  dbg(GENERAL_CHANNEL, "No route to %u for TCP packet\n", myMsg->dest);
               }
            }
         }

         return msg;
      }

      dbg(GENERAL_CHANNEL, "Unknown Packet Type %d\n", len);
      return msg;
   }

   event void CommandHandler.ping(uint16_t destination, uint8_t *payload) {
      uint16_t nextHop;
      dbg(GENERAL_CHANNEL, "PING EVENT - sending to %d\n", destination);
      sequenceNumber++;
      makePack(&sendPackage, TOS_NODE_ID, destination, 16, 0, sequenceNumber, payload, PACKET_MAX_PAYLOAD_SIZE);
      
      nextHop = call LinkState.getNextHop(destination);
      if(nextHop != 0xFFFF) {
         dbg(GENERAL_CHANNEL, "Sending ping to %u via next hop %u\n", destination, nextHop);
         call Sender.send(sendPackage, nextHop);
      } else {
         dbg(GENERAL_CHANNEL, "No route to %u, falling back to flood\n", destination);
         call Flooding.floodPacket(&sendPackage);
      }
   }

   event void CommandHandler.printNeighbors() {
      call NeighborDiscovery.printNeighbors();
   }

   event void CommandHandler.printRouteTable() {
      call LinkState.printRoutingTable();
   }

   event void CommandHandler.printLinkState() {}
   event void CommandHandler.printDistanceVector() {}
   event void CommandHandler.setTestServer(uint8_t port) {
      socket_addr_t addr;
      uint8_t i;
      
      cleanupServerSocket();

      serverSocket = call Transport.socket();
      if(serverSocket == NULL_SOCKET) {
         dbg(TRANSPORT_CHANNEL, "Failed to create server socket\n");
         return;
      }
      
      addr.port = port;
      addr.addr = TOS_NODE_ID;
      
      if(call Transport.bind(serverSocket, &addr) == FAIL) {
         dbg(TRANSPORT_CHANNEL, "Failed to bind server socket\n");
         cleanupServerSocket();
         return;
      }
      
      if(call Transport.listen(serverSocket) == FAIL) {
         dbg(TRANSPORT_CHANNEL, "Failed to listen on server socket\n");
         cleanupServerSocket();
         return;
      }
      isChatServer = (port == 41);
      if (isChatServer) {
         isChatClient = FALSE;
         for (i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
            chatUsers[i].inUse = FALSE;
            chatUsers[i].username[0] = '\0';
            chatRecvLen[i] = 0;
         }
         resetAcceptedSockets();
         call ServerReadTimer.startPeriodic(200);
      } else {
         call ServerReadTimer.startPeriodic(1000);
      }
      
      dbg(TRANSPORT_CHANNEL, "Server started on port %d\n", port);
   }

   event void CommandHandler.setTestClient(uint16_t dest, uint8_t srcPort, uint8_t destPort, uint16_t transfer) {
      socket_addr_t myAddr;
      socket_addr_t destAddr;
      
      cleanupClientSocket();

      clientSocket = call Transport.socket();
      if(clientSocket == NULL_SOCKET) {
         dbg(TRANSPORT_CHANNEL, "Failed to create client socket\n");
         return;
      }
      
      myAddr.port = srcPort;
      myAddr.addr = TOS_NODE_ID;
      
      if(call Transport.bind(clientSocket, &myAddr) == FAIL) {
         dbg(TRANSPORT_CHANNEL, "Failed to bind client socket\n");
         cleanupClientSocket();
         return;
      }
      
      destAddr.port = destPort;
      destAddr.addr = dest;
      
      clientTransfer = transfer;
      clientDataSent = 0;
      clientNextValue = 1;
      
      if(call Transport.connect(clientSocket, &destAddr) == FAIL) {
         dbg(TRANSPORT_CHANNEL, "Failed to connect\n");
         cleanupClientSocket();
         return;
      }
      
      call ClientWriteTimer.startPeriodic(1000);
      
      dbg(TRANSPORT_CHANNEL, "Client connecting to %d:%d from port %d, transfer=%d bytes\n", 
          dest, destPort, srcPort, transfer);
   }

    void processChatCommand(uint8_t idx, socket_t sock, char* line);

   void handleChatServerData(uint8_t idx, socket_t sock, uint8_t* buf, uint16_t len) {
       uint8_t k;
       uint8_t remaining;
      //  dbg(TRANSPORT_CHANNEL,"Server data idx=%hhu sock=%hhu len=%u buf=\"%.*s\"\n",idx, sock, (unsigned)len, (int)len, buf);
      dbg(TRANSPORT_CHANNEL, "Server data idx=%d sock=%d len=%d\n", idx, sock, len);


       if (len > sizeof chatRecvBuf[idx]) {
          len = sizeof chatRecvBuf[idx];
       }

       // Append new bytes into this socket's line buffer
       if (chatRecvLen[idx] + len > sizeof chatRecvBuf[idx]) {
          // overflow protection: reset buffer
          chatRecvLen[idx] = 0;
      }
      memcpy(&chatRecvBuf[idx][chatRecvLen[idx]], buf, len);
      chatRecvLen[idx] += len;

      // Look for one or more "\r\n" sequences; process all complete commands
      while (1) {
         bool found = FALSE;
         for (k = 1; k < chatRecvLen[idx]; k++) {
            if (chatRecvBuf[idx][k - 1] == '\r' && chatRecvBuf[idx][k] == '\n') {
               // We have a complete command from 0..k
               chatRecvBuf[idx][k - 1] = '\0'; // terminate string at \r
               chatRecvBuf[idx][k] = '\0';

               // Process the command line
               processChatCommand(idx, sock, chatRecvBuf[idx]);

               // Shift any extra bytes (support multiple commands in one read)
               remaining = chatRecvLen[idx] - (k + 1);
               if (remaining > 0) {
                  memmove(chatRecvBuf[idx], &chatRecvBuf[idx][k + 1], remaining);
               }
               chatRecvLen[idx] = remaining;
               found = TRUE;
               break;
            }
         }
         if (!found) {
            break; // no more complete lines in buffer
         }
      }
    }



   event void ServerReadTimer.fired() {
      socket_t newSocket;
      uint8_t i;
      uint8_t buffer[128];
      uint16_t bytesRead;
      bool inserted;
      bool active;

      active = FALSE;

      // server section 
      if (isChatServer && serverSocket != NULL_SOCKET) {
         active = TRUE;

         // Accept as many pending connections as possible this tick
         while (1) {
            inserted = FALSE;
            newSocket = call Transport.accept(serverSocket);
            if (newSocket == NULL_SOCKET) {
            break;
            }

            for (i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
            if (acceptedSockets[i] == NULL_SOCKET) {
               acceptedSockets[i] = newSocket;
               chatRecvLen[i] = 0;
               if (numAcceptedSockets < MAX_NUM_OF_SOCKETS) {
                  numAcceptedSockets++;
               }
               inserted = TRUE;
               break;
            }
            }

            if (inserted) {
            dbg(TRANSPORT_CHANNEL, "New connection accepted: socket=%d\n", newSocket);
            } else {
            dbg(TRANSPORT_CHANNEL, "Connection table full, closing new socket=%d\n", newSocket);
            call Transport.close(newSocket);
            call Transport.release(newSocket);
            }
         }

      // Drain each accepted socket completely
      for (i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
         if (acceptedSockets[i] != NULL_SOCKET) {
            do {
               bytesRead = call Transport.read(acceptedSockets[i], buffer, 128);
               if (bytesRead > 0) {
                  handleChatServerData(i, acceptedSockets[i], buffer, bytesRead);
               }
            } while (bytesRead > 0);
         }
      }
      }

      // Client section 
      if (isChatClient && chatSock != NULL_SOCKET) {
         active = TRUE;

         if (call Transport.isEstablished(chatSock)) {
            if (!chatConnected) {
               dbg(TRANSPORT_CHANNEL, "Chat client connected\n");
            }
            chatConnected = TRUE;
            chatPeerFinSeen = FALSE;
            flushChatQueue();
         } else {
            chatConnected = FALSE;
            // if we've sent FIN and observed peer FIN, release now
            if (chatFinSent && chatPeerFinSeen) {
               dbg(TRANSPORT_CHANNEL, "Chat client: both FINs seen, releasing socket=%d\n", chatSock);
               call Transport.release(chatSock);
               chatSock = NULL_SOCKET;
               chatConnected = FALSE;
               chatFinSent = FALSE;
               chatPeerFinSeen = FALSE;
            }
         }
         if (chatCloseRequested && chatSock != NULL_SOCKET && call Transport.isEstablished(chatSock)) {
            if (call Transport.readyToClose(chatSock)) {
               error_t r = call Transport.close(chatSock);
               if (r == SUCCESS) {
                  dbg(TRANSPORT_CHANNEL, "Chat client: FIN sent on socket=%d\n", chatSock);
                  chatFinSent = TRUE;
                  chatCloseRequested = FALSE;
               }
               // if EBUSY, do nothing; retry next tick
            }
         }

         // Drain client receive too
         do {
            bytesRead = call Transport.read(chatSock, buffer, 127);
            if (bytesRead > 0) {
            // buffer[bytesRead] = '\0';
            handleChatClientData(buffer, bytesRead);
            // dbg(TRANSPORT_CHANNEL, "Chat client recv: %s\n", buffer);
            }

         } while (bytesRead > 0);
      }

      if (!active) {
         call ServerReadTimer.stop();
      }
   }


   // event void ClientWriteTimer.fired() {
   //    uint8_t buffer[20];
   //    uint16_t i;
   //    uint16_t bytesToWrite;
   //    uint16_t written;
   //    error_t res;
      
   //    if(clientSocket == NULL_SOCKET) {
   //       call ClientWriteTimer.stop();
   //       return;
   //    }

   //    if(clientDataSent >= clientTransfer) {
   //       dbg(TRANSPORT_CHANNEL, "Client transfer complete, initiating FIN\n");
   //       if (!call Transport.readyToClose(clientSocket)) {
   //          if (!clientCloseWarned) {
   //             dbg(TRANSPORT_CHANNEL, "Close deferred; pending data still flushing\n");
   //             clientCloseWarned = TRUE;
   //          }
   //          return;
   //       }
   //       clientCloseWarned = FALSE;
   //       res = call Transport.close(clientSocket);
   //       if(res == SUCCESS) {
   //          dbg(TRANSPORT_CHANNEL, "FIN sent for client socket %d\n", clientSocket);
   //          // Stop writes; wait for transport to finish and then you can release after CLOSED/TIME_WAIT
   //          call ClientWriteTimer.stop();
   //       } else {
   //          dbg(TRANSPORT_CHANNEL, "Close failed\n");
   //       }
   //       return;
   //    }
      
   //    bytesToWrite = (clientTransfer - clientDataSent > 20) ? 20 : (clientTransfer - clientDataSent);
      
   //    for(i = 0; i < bytesToWrite; i++) {
   //       // Keep payload bytes non-zero so the receiver counts the full length
   //       buffer[i] = (uint8_t)(((clientDataSent + i) % 255) + 1);
   //    }
      
   //    written = call Transport.write(clientSocket, buffer, bytesToWrite);
   //    clientDataSent += written;
      
   //    dbg(TRANSPORT_CHANNEL, "Client wrote %d bytes, total sent: %d/%d\n", 
   //        written, clientDataSent, clientTransfer);
      
   // }
   event void ClientWriteTimer.fired() {
      uint8_t  buffer[20];
      uint16_t bytesToWrite;
      uint16_t remaining;
      uint16_t i;
      uint16_t written;
      error_t  res;

      if (clientSocket == NULL_SOCKET) {
         call ClientWriteTimer.stop();
         return;
      }
      // Only write when the connection is fully established
      if (call Transport.isEstablished(clientSocket) == FALSE) {
         return;
      }

      // All requested bytes have been enqueued → begin graceful close
      if (clientDataSent >= clientTransfer) {
         dbg(TRANSPORT_CHANNEL, "Client transfer complete, initiating FIN\n");
         if (!call Transport.readyToClose(clientSocket)) {
            if (!clientCloseWarned) {
               dbg(TRANSPORT_CHANNEL,
                  "Close deferred; pending data still flushing\n");
                  clientCloseWarned = TRUE;
            }
            return;
         }   
         clientCloseWarned = FALSE;
         res = call Transport.close(clientSocket);
         if (res == SUCCESS) {
            dbg(TRANSPORT_CHANNEL, "FIN sent for client socket %d\n",
               clientSocket);
               call ClientWriteTimer.stop();
         } else {
            dbg(TRANSPORT_CHANNEL, "Close failed\n");
         }
        return;
      }

      // How many BYTES left to enqueue (based on transfer argument)
      remaining = clientTransfer - clientDataSent;
      // Enqueue a larger chunk per tick to allow multiple packets in flight
      {
         uint16_t maxChunk = 32;   // enqueue up to 32 bytes per tick
         bytesToWrite = (remaining > maxChunk) ? maxChunk : remaining;
      }

      // Only send full 16-bit values
      if (bytesToWrite & 0x1) {  // odd
         bytesToWrite--;
         if (bytesToWrite == 0) {
            return;
         }
      }

      // Fill buffer with consecutive uint16_t values starting from clientNextValue
      for (i = 0; i < bytesToWrite / 2; i++) {
         uint16_t value = clientNextValue++;  // 1,2,3,4,...

         uint8_t hi = (uint8_t)(value >> 8);
         uint8_t lo = (uint8_t)(value & 0xFF);

         // +1 to avoid 0 in payload (because your receive loop stops on 0 bytes)
         buffer[2 * i]     = hi + 1;
         buffer[2 * i + 1] = lo + 1;
      }

      // Write in a loop until we've enqueued the chunk or the buffer/window stops us
      written = 0;
      while (written < bytesToWrite) {
         uint16_t w = call Transport.write(clientSocket,
                                           &buffer[written],
                                           bytesToWrite - written);
         if (w == 0) {
            break; // no progress; likely window/buffer full
         }
         written += w;
         clientDataSent += w;
      }

      dbg(TRANSPORT_CHANNEL,
        "Client wrote %d bytes, total sent: %d/%d, nextValue=%hu\n",
        written, clientDataSent, clientTransfer, clientNextValue);
   }




   void closeAcceptedSocket(uint8_t idx) {
      if(idx >= MAX_NUM_OF_SOCKETS) {
         return;
      }
      if(acceptedSockets[idx] != NULL_SOCKET) {
         acceptedSockets[idx] = NULL_SOCKET;
         if(numAcceptedSockets > 0) {
            numAcceptedSockets--;
         }
      }
   }

   void resetAcceptedSockets() {
      uint8_t i;
      for(i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
         closeAcceptedSocket(i);
      }
      numAcceptedSockets = 0;
   }

   void cleanupServerSocket() {
      call ServerReadTimer.stop();
      resetAcceptedSockets();
      serverSocket = NULL_SOCKET;
   }

   void cleanupClientSocket() {
      call ClientWriteTimer.stop();
      clientSocket = NULL_SOCKET;
      clientTransfer = 0;
      clientDataSent = 0;
      clientCloseWarned = FALSE;
   }

   bool enqueueChatLine(const char* line) {
      uint8_t nextTail;
      uint8_t len;
      uint8_t idx;
      if (line == NULL) {
         return FALSE;
      }
      nextTail = (chatSendTail + 1) % 8;
      if (nextTail == chatSendHead) {
         return FALSE; // queue full
      }
      len = strlen(line);
      if (len >= sizeof chatSendQueue[0]) {
         len = sizeof chatSendQueue[0] - 1;
      }
      idx = chatSendTail;

      memcpy(chatSendQueue[chatSendTail], line, len);
      chatSendQueue[chatSendTail][len] = '\0';
      chatSendLen[chatSendTail] = len;
      chatSendTail = nextTail;
      dbg(TRANSPORT_CHANNEL, "enqueue stored len=%d (orig=%d) text='%s'\n",chatSendLen[idx], (uint8_t)strlen(line), chatSendQueue[idx]);

      return TRUE;
   }

   void flushChatQueue() {
      while (chatSendHead != chatSendTail) {
         uint8_t len;
         uint16_t written;
         uint8_t remaining;
         if (chatSock == NULL_SOCKET) {
            return;
         }
         if (!call Transport.isEstablished(chatSock)) {
            return;
         }
         len = chatSendLen[chatSendHead];
         written = call Transport.write(chatSock,
                                        (uint8_t*)chatSendQueue[chatSendHead],
                                        len);
         if (written == 0) {
            return;
         }
         if (written < len) {
            remaining = (uint8_t)(len - written);
            memmove(chatSendQueue[chatSendHead],
                    &chatSendQueue[chatSendHead][written],
                    remaining);
            chatSendQueue[chatSendHead][remaining] = '\0';
            chatSendLen[chatSendHead] = remaining;
            return;
         }
         chatSendHead = (chatSendHead + 1) % 8;
      }
   }

   event void CommandHandler.chatHello(uint8_t serverAddr, uint8_t clientPort, uint8_t *username) {
      socket_addr_t myAddr;
      socket_addr_t dest;
      char buf[32];
      uint8_t len;
      char uname[16];
      uint8_t ulen;

      ulen = strnlen((char*)username, sizeof(uname) - 1);
      memcpy(uname, username, ulen);
      uname[ulen] = '\0';

      chatSock = call Transport.socket();
      if (chatSock == NULL_SOCKET) {
         dbg(TRANSPORT_CHANNEL, "Node: chatHello no free socket\n");
         return;
      }
      isChatClient = TRUE;
      isChatServer = FALSE;
      chatSendHead = 0;
      chatSendTail = 0;

      myAddr.port = clientPort;
      myAddr.addr = TOS_NODE_ID;

      if (call Transport.bind(chatSock, &myAddr) == FAIL) {
         dbg(TRANSPORT_CHANNEL, "Node: chatHello bind failed\n");
         call Transport.release(chatSock);
         chatSock = NULL_SOCKET;
         return;
      }

      dest.port = 41;            // chat server port
      dest.addr = serverAddr;

      call Transport.connect(chatSock, &dest);
      chatConnected = FALSE;

      len = snprintf(buf, sizeof buf, "hello %s\r\n", uname);
      dbg(TRANSPORT_CHANNEL, "Client hello len=%d last2=%d,%d\n",len, buf[len-2], buf[len-1]);

      enqueueChatLine(buf);
      call ServerReadTimer.startPeriodic(200);
      
   }



   event void CommandHandler.chatMsg(uint8_t *message) {
      char buf[64];
      uint8_t len;
      char msg[48];
      uint8_t mlen;

      mlen = strnlen((char*)message, sizeof(msg) - 1);
      memcpy(msg, message, mlen);
      msg[mlen] = '\0';

      if (!chatConnected) {
         dbg(TRANSPORT_CHANNEL, "Chat not connected yet\n");
         return;
      }
      if (chatSock == NULL_SOCKET) {
         dbg(TRANSPORT_CHANNEL, "Node: chatMsg but chatSock is NULL\n");
         return;
      }



      len = snprintf(buf, sizeof buf, "msg %s\r\n", msg);
      dbg(TRANSPORT_CHANNEL, "Node: chat msg '%s'\n", buf);
      enqueueChatLine(buf);
      flushChatQueue();
   }

   event void CommandHandler.chatWhisper(uint8_t *username, uint8_t *message) {
      char buf[64];
      uint8_t len;
      char uname[16];
      char msg[48];
      uint8_t ulen;
      uint8_t mlen;

      if (!chatConnected) {
         dbg(TRANSPORT_CHANNEL, "Chat not connected yet\n");
         return;
      }
      if (chatSock == NULL_SOCKET) {
         dbg(TRANSPORT_CHANNEL, "Node: chatWhisper but chatSock is NULL\n");
         return;
      }
       // --- copy username into local C string ---
      ulen = strnlen((char*)username, sizeof(uname) - 1);
      memcpy(uname, username, ulen);
      uname[ulen] = '\0';

      // --- copy message into local C string ---
      mlen = strnlen((char*)message, sizeof(msg) - 1);
      memcpy(msg, message, mlen);
      msg[mlen] = '\0';

      len = snprintf(buf, sizeof buf, "whisper %s %s\r\n",
                     (char*)username, (char*)message);
      dbg(TRANSPORT_CHANNEL, "Node: chat whisper '%s'\n", buf);
      enqueueChatLine(buf);
      flushChatQueue();
   }

   event void CommandHandler.chatListusr() {
      char buf[16] = "listusr\r\n";

      if (!chatConnected) {
         dbg(TRANSPORT_CHANNEL, "Chat not connected yet\n");
         return;
      }
      if (chatSock == NULL_SOCKET) {
         dbg(TRANSPORT_CHANNEL, "Node: chatListusr but chatSock is NULL\n");
         return;
      }

      
      dbg(TRANSPORT_CHANNEL, "Node: chat listusr\n");
      enqueueChatLine(buf);
      chatCloseRequested = TRUE;
      flushChatQueue();
   }

   event void CommandHandler.setAppServer() {
      socket_addr_t addr;
      uint8_t i;

      cleanupServerSocket();        // if you have helper like that
      isChatServer = TRUE;
      isChatClient = FALSE;

      serverSocket = call Transport.socket();
      if (serverSocket == NULL_SOCKET) {
         dbg(TRANSPORT_CHANNEL, "Node: setAppServer failed to create socket\n");
         return;
      }

      addr.port = 41;
      addr.addr = TOS_NODE_ID;

      if (call Transport.bind(serverSocket, &addr) == FAIL) {
         dbg(TRANSPORT_CHANNEL, "Node: setAppServer bind failed\n");
         call Transport.release(serverSocket);
         serverSocket = NULL_SOCKET;
         return;
      }

      call Transport.listen(serverSocket);
      dbg(TRANSPORT_CHANNEL, "Node: chat server listening on port 41\n");
      for (i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
         chatUsers[i].inUse = FALSE;
         chatUsers[i].username[0] = '\0';
         chatRecvLen[i] = 0;
      }
      resetAcceptedSockets();
      call ServerReadTimer.startPeriodic(200);
   }



   event void CommandHandler.setAppClient() {
      dbg(TRANSPORT_CHANNEL, "Node: setAppClient\n");
      isChatClient = TRUE;
      isChatServer = FALSE;
      chatSendHead = 0;
      chatSendTail = 0;
      // clientSock/chatSock you already set in chatHello
   }

   ChatUser_t* findUserBySock(socket_t sock) {
      uint8_t i;
      for (i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
         if (chatUsers[i].inUse && chatUsers[i].sock == sock) {
            return &chatUsers[i];
         }
      }
      return NULL;
   }

   ChatUser_t* findUserByName(char* name) {
      uint8_t i;
      for (i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
         if (chatUsers[i].inUse && strcmp(chatUsers[i].username, name) == 0) {
            return &chatUsers[i];
         }
      }
      return NULL;
   }

   ChatUser_t* allocUser(socket_t sock) {
      uint8_t i;
      for (i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
         if (!chatUsers[i].inUse) {
            chatUsers[i].inUse = TRUE;
            chatUsers[i].sock = sock;
            chatUsers[i].username[0] = '\0';
            return &chatUsers[i];
         }
      }
      return NULL;
   }

   void processChatCommand(uint8_t idx, socket_t sock, char* line) {
      // line is something like:
      // "hello josh"
      // "msg Hello everyone!"
      // "whisper mike hi"
      // "listusr"

      ChatUser_t *sender;
      ChatUser_t *target;
      ChatUser_t *u;
      char out[80];
      uint8_t i;
      uint8_t pos;
      char *name;
      char *text;
      char *rest;
      char *space;
      char *targetName;

      if (strncmp(line, "hello ", 6) == 0) {
         name = line + 6;
         u = findUserBySock(sock);
         if (u == NULL) {
            u = allocUser(sock);
         }
         if (u != NULL) {
            strncpy(u->username, name, sizeof u->username - 1);
            u->username[sizeof u->username - 1] = '\0';
            dbg(TRANSPORT_CHANNEL,
               "Server: user '%s' registered on socket %d\n",
               u->username, sock);
         }
      }
      else if (strncmp(line, "msg ", 4) == 0) {
         text = line + 4;
         sender = findUserBySock(sock);

         if (sender == NULL) {
            dbg(TRANSPORT_CHANNEL,
               "Server: msg from unknown socket %d\n", sock);
            return;
         }

         snprintf(out, sizeof out, "%s: %s\r\n", sender->username, text);
         dbg(TRANSPORT_CHANNEL, "Server: msg from %s: %s\n", sender->username, text);
         // broadcast to all users
         for (i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
            if (chatUsers[i].inUse) {
            call Transport.write(chatUsers[i].sock,
                                 (uint8_t*) out,
                                 strlen(out));
            }
         }
      }
      else if (strncmp(line, "whisper ", 8) == 0) {
         rest = line + 8;
         space = strchr(rest, ' ');
         if (!space) {
            return;
         }

         *space = '\0';
         targetName = rest;
         text = space + 1;

         sender = findUserBySock(sock);
         target = findUserByName(targetName);
         
         if (sender == NULL || target == NULL) {
            dbg(TRANSPORT_CHANNEL, "Server: whisper missing sender/target (s=%p, t=%p)\n",sender, target);
            return;
         }
         dbg(TRANSPORT_CHANNEL, "Server: whisper %s -> %s: %s\n", sender->username, target->username, text);

         snprintf(out, sizeof out,
                  "(whisper from %s): %s\r\n",
                  sender->username, text);
         call Transport.write(target->sock,
                              (uint8_t*) out,
                              strlen(out));
      }
      else if (strcmp(line, "listusr") == 0) {
         pos = 0;

         pos += snprintf(out + pos, sizeof out - pos, "listUsrRply ");

         for (i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
            if (chatUsers[i].inUse) {
            if (pos > 13) { // already have at least one name
               if (pos < sizeof out - 2) {
                  out[pos++] = ',';
                  out[pos++] = ' ';
               }
            }
            pos += snprintf(out + pos,
                              sizeof out - pos,
                              "%s",
                              chatUsers[i].username);
            }
         }

         if (pos < sizeof out - 2) {
            out[pos++] = '\r';
            out[pos++] = '\n';
         }
         out[pos] = '\0';
         dbg(TRANSPORT_CHANNEL, "Server: listusr reply: %s\n", out);
         call Transport.write(sock, (uint8_t*) out, pos);
         // initiate server FIN once reply buffered; TransportP defers until send buffer drains
         call Transport.close(sock);
      }
   }








   // event void CommandHandler.setAppServer() {}
   // event void CommandHandler.setAppClient() {}

   void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t protocol, uint16_t seq, uint8_t* payload, uint8_t length) {
      Package->src = src;
      Package->dest = dest;
      Package->TTL = TTL;
      Package->seq = seq;
      Package->protocol = protocol;
      memcpy(Package->payload, payload, length);
   }
}
