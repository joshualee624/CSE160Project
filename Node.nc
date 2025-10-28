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

module Node {
   uses interface Boot;
   uses interface SplitControl as AMControl;
   uses interface Receive;

   uses interface SimpleSend as Sender;
   uses interface NeighborDiscovery;
   uses interface CommandHandler;
   uses interface Flooding;
   uses interface LinkState;
}

implementation {
   pack sendPackage;
   uint16_t sequenceNumber = 0;

   void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t Protocol, uint16_t seq, uint8_t *payload, uint8_t length);

   event void Boot.booted() {
      call AMControl.start();
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

         call NeighborDiscovery.handle(myMsg);
         if (myMsg -> protocol == PROTOCOL_PING){
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
               call Flooding.floodPacket(&reply);
            } else {
               call Flooding.handlePacket(myMsg);
            }
         } else if (myMsg -> protocol == PROTOCOL_PINGREPLY){
            call Flooding.handlePacket(myMsg);
         } else if (myMsg->protocol == PROTOCOL_LINKEDSTATE) {
            call LinkState.handleAdvertisement(myMsg);
            call Flooding.handlePacket(myMsg);
         }
         
         

         return msg;
      }

      dbg(GENERAL_CHANNEL, "Unknown Packet Type %d\n", len);
      return msg;
   }

   event void CommandHandler.ping(uint16_t destination, uint8_t *payload) {
      dbg(GENERAL_CHANNEL, "PING EVENT - sending to %d\n", destination);
      sequenceNumber++;
      makePack(&sendPackage, TOS_NODE_ID, destination, 16, 0, sequenceNumber, payload, PACKET_MAX_PAYLOAD_SIZE);
      call Flooding.floodPacket(&sendPackage);
   }

   event void CommandHandler.printNeighbors() {
      call NeighborDiscovery.printNeighbors();
   }
   event void CommandHandler.printRouteTable() {}
   event void CommandHandler.printLinkState() {}
   event void CommandHandler.printDistanceVector() {}
   event void CommandHandler.setTestServer() {}
   event void CommandHandler.setTestClient() {}
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
