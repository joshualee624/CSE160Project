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
      
      serverSocket = call Transport.socket();
      if(serverSocket == NULL_SOCKET) {
         dbg(TRANSPORT_CHANNEL, "Failed to create server socket\n");
         return;
      }
      
      addr.port = port;
      addr.addr = TOS_NODE_ID;
      
      if(call Transport.bind(serverSocket, &addr) == FAIL) {
         dbg(TRANSPORT_CHANNEL, "Failed to bind server socket\n");
         return;
      }
      
      if(call Transport.listen(serverSocket) == FAIL) {
         dbg(TRANSPORT_CHANNEL, "Failed to listen on server socket\n");
         return;
      }
      
      call ServerReadTimer.startPeriodic(1000);
      
      dbg(TRANSPORT_CHANNEL, "Server started on port %d\n", port);
   }

   event void CommandHandler.setTestClient(uint16_t dest, uint8_t srcPort, uint8_t destPort, uint16_t transfer) {
      socket_addr_t myAddr;
      socket_addr_t destAddr;
      
      clientSocket = call Transport.socket();
      if(clientSocket == NULL_SOCKET) {
         dbg(TRANSPORT_CHANNEL, "Failed to create client socket\n");
         return;
      }
      
      myAddr.port = srcPort;
      myAddr.addr = TOS_NODE_ID;
      
      if(call Transport.bind(clientSocket, &myAddr) == FAIL) {
         dbg(TRANSPORT_CHANNEL, "Failed to bind client socket\n");
         return;
      }
      
      destAddr.port = destPort;
      destAddr.addr = dest;
      
      clientTransfer = transfer;
      clientDataSent = 0;
      
      if(call Transport.connect(clientSocket, &destAddr) == FAIL) {
         dbg(TRANSPORT_CHANNEL, "Failed to connect\n");
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
      
      newSocket = call Transport.accept(serverSocket);
      if(newSocket != NULL_SOCKET) {
         if(numAcceptedSockets < MAX_NUM_OF_SOCKETS) {
            acceptedSockets[numAcceptedSockets++] = newSocket;
            dbg(TRANSPORT_CHANNEL, "New connection accepted: socket=%d\n", newSocket);
         }
      }
      
      for(i = 0; i < numAcceptedSockets; i++) {
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
      
      if(clientSocket == NULL_SOCKET || clientDataSent >= clientTransfer) {
         call ClientWriteTimer.stop();
         return;
      }
      
      bytesToWrite = (clientTransfer - clientDataSent > 20) ? 20 : (clientTransfer - clientDataSent);
      
      for(i = 0; i < bytesToWrite; i++) {
         buffer[i] = (clientDataSent + i) & 0xFF;
      }
      
      written = call Transport.write(clientSocket, buffer, bytesToWrite);
      clientDataSent += written;
      
      dbg(TRANSPORT_CHANNEL, "Client wrote %d bytes, total sent: %d/%d\n", 
          written, clientDataSent, clientTransfer);
      
      if(clientDataSent >= clientTransfer) {
         dbg(TRANSPORT_CHANNEL, "Client finished sending all data\n");
         call ClientWriteTimer.stop();
      }
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
