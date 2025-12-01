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


   void closeAcceptedSocket(uint8_t idx);
   void resetAcceptedSockets();
   void cleanupServerSocket();
   void cleanupClientSocket();
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
      
      call ServerReadTimer.startPeriodic(1000);
      
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
      
      if(call Transport.connect(clientSocket, &destAddr) == FAIL) {
         dbg(TRANSPORT_CHANNEL, "Failed to connect\n");
         cleanupClientSocket();
         return;
      }
      
      call ClientWriteTimer.startPeriodic(1000);
      
      dbg(TRANSPORT_CHANNEL, "Client connecting to %d:%d from port %d, transfer=%d bytes\n", 
          dest, destPort, srcPort, transfer);
   }

   event void ServerReadTimer.fired() {
      socket_t newSocket;
      uint8_t i;
      uint8_t buffer[128];
      uint16_t bytesRead;
      bool inserted = FALSE;

      if(serverSocket == NULL_SOCKET) {
         call ServerReadTimer.stop();
         return;
      }
      
      newSocket = call Transport.accept(serverSocket);
      if(newSocket != NULL_SOCKET) {
         for(i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
            if(acceptedSockets[i] == NULL_SOCKET) {
               acceptedSockets[i] = newSocket;
               if(numAcceptedSockets < MAX_NUM_OF_SOCKETS) {
                  numAcceptedSockets++;
               }
               inserted = TRUE;
               break;
            }
         }
         if(inserted) {
            dbg(TRANSPORT_CHANNEL, "New connection accepted: socket=%d\n", newSocket);
         } else {
            dbg(TRANSPORT_CHANNEL, "Connection table full, closing new socket=%d\n", newSocket);
            call Transport.close(newSocket);
            call Transport.release(newSocket);
         }
      }
      
      for(i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
         if(acceptedSockets[i] != NULL_SOCKET) {
            bytesRead = call Transport.read(acceptedSockets[i], buffer, 128);
            if(bytesRead > 0) {
               dbg(TRANSPORT_CHANNEL, "Server read %d bytes from socket %d\n",
                   bytesRead, acceptedSockets[i]);
            }
         }
      }

   }

   event void ClientWriteTimer.fired() {
      uint8_t buffer[20];
      uint16_t i;
      uint16_t bytesToWrite;
      uint16_t written;
      error_t res;
      
      if(clientSocket == NULL_SOCKET) {
         call ClientWriteTimer.stop();
         return;
      }

      if(clientDataSent >= clientTransfer) {
         dbg(TRANSPORT_CHANNEL, "Client transfer complete, initiating FIN\n");
         if (!call Transport.readyToClose(clientSocket)) {
            if (!clientCloseWarned) {
               dbg(TRANSPORT_CHANNEL, "Close deferred; pending data still flushing\n");
               clientCloseWarned = TRUE;
            }
            return;
         }
         clientCloseWarned = FALSE;
         res = call Transport.close(clientSocket);
         if(res == SUCCESS) {
            dbg(TRANSPORT_CHANNEL, "FIN sent for client socket %d\n", clientSocket);
            // Stop writes; wait for transport to finish and then you can release after CLOSED/TIME_WAIT
            call ClientWriteTimer.stop();
         } else {
            dbg(TRANSPORT_CHANNEL, "Close failed\n");
         }
         return;
      }
      
      bytesToWrite = (clientTransfer - clientDataSent > 20) ? 20 : (clientTransfer - clientDataSent);
      
      for(i = 0; i < bytesToWrite; i++) {
         // Keep payload bytes non-zero so the receiver counts the full length
         buffer[i] = (uint8_t)(((clientDataSent + i) % 255) + 1);
      }
      
      written = call Transport.write(clientSocket, buffer, bytesToWrite);
      clientDataSent += written;
      
      dbg(TRANSPORT_CHANNEL, "Client wrote %d bytes, total sent: %d/%d\n", 
          written, clientDataSent, clientTransfer);
      
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

   event void CommandHandler.setAppServer() {}
   event void CommandHandler.setAppClient() {}

   void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t protocol, uint16_t seq, uint8_t* payload, uint8_t length) {
      Package->src = src;
      Package->dest = dest;
      Package->TTL = TTL;
      Package->seq = seq;
      Package->protocol = protocol;
      memcpy(Package->payload, payload, length);
   }
}
