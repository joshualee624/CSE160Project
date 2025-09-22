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
}

implementation {
   pack sendPackage;

   // Flooding state
   enum { MAX_SEEN_PACKETS = 100 };
   typedef struct {
      uint16_t src;
      uint16_t seq;
   } seen_packet_t;

   seen_packet_t seenPackets[MAX_SEEN_PACKETS];
   uint16_t seenPacketIndex = 0;
   uint16_t sequenceNumber = 0;

   // Prototypes
   void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t Protocol, uint16_t seq, uint8_t *payload, uint8_t length);
   bool hasSeenPacket(uint16_t src, uint16_t seq);
   void addSeenPacket(uint16_t src, uint16_t seq);

   // Boot
   event void Boot.booted() {
      call AMControl.start();
      dbg(GENERAL_CHANNEL, "Booted\n");
   }

   event void AMControl.startDone(error_t err) {
      if(err == SUCCESS) {
         call NeighborDiscovery.findNeighbors();   // from NeighborDiscovery
         dbg(GENERAL_CHANNEL, "Radio On\n");
      } else {
         call AMControl.start();  // Retry until successful
      }
   }

   event void AMControl.stopDone(error_t err) {}

   // Receive
   event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len) {
      if(len == sizeof(pack)) {
         pack* myMsg = (pack*) payload;

         dbg(FLOODING_CHANNEL, "Packet received at Node %d from %d\n", TOS_NODE_ID, myMsg->src);

         // NeighborDiscovery hook
         call NeighborDiscovery.handle(myMsg);

         // Flooding checks
         if(myMsg->TTL == 0) {
            dbg(FLOODING_CHANNEL, "Packet dropped - TTL expired\n");
            return msg;
         }

         if(hasSeenPacket(myMsg->src, myMsg->seq)) {
            dbg(FLOODING_CHANNEL, "Packet dropped, already seen (src:%d, seq:%d)\n", myMsg->src, myMsg->seq);
            return msg;
         }
         addSeenPacket(myMsg->src, myMsg->seq);

         if(myMsg->dest == TOS_NODE_ID) {
            dbg(GENERAL_CHANNEL, "Packet for me. Payload: %s\n", myMsg->payload);
         } else {
            pack floodPacket = *myMsg;
            floodPacket.TTL--;
            if(floodPacket.TTL > 0) {
               call Sender.send(floodPacket, AM_BROADCAST_ADDR);
               dbg(FLOODING_CHANNEL, "Packet flooded from Node %d (TTL:%d)\n", TOS_NODE_ID, floodPacket.TTL);
            } else {
               dbg(FLOODING_CHANNEL, "Packet not flooded - TTL would be 0\n");
            }
         }

         return msg;
      }

      dbg(GENERAL_CHANNEL, "Unknown Packet Type %d\n", len);
      return msg;
   }

   // CommandHandler
   event void CommandHandler.ping(uint16_t destination, uint8_t *payload) {
      dbg(GENERAL_CHANNEL, "PING EVENT - sending to %d\n", destination);
      sequenceNumber++;
      makePack(&sendPackage, TOS_NODE_ID, destination, 15, 0, sequenceNumber, payload, PACKET_MAX_PAYLOAD_SIZE);
      call Sender.send(sendPackage, AM_BROADCAST_ADDR);  // flood out
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

   // Helpers
   bool hasSeenPacket(uint16_t src, uint16_t seq) {
      uint16_t i;
      for(i = 0; i < MAX_SEEN_PACKETS && i < seenPacketIndex; i++) {
         if(seenPackets[i].src == src && seenPackets[i].seq == seq) {
            return TRUE;
         }
      }
      return FALSE;
   }

   void addSeenPacket(uint16_t src, uint16_t seq) {
      seenPackets[seenPacketIndex % MAX_SEEN_PACKETS].src = src;
      seenPackets[seenPacketIndex % MAX_SEEN_PACKETS].seq = seq;
      seenPacketIndex++;
   }

   void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t protocol, uint16_t seq, uint8_t* payload, uint8_t length) {
      Package->src = src;
      Package->dest = dest;
      Package->TTL = TTL;
      Package->seq = seq;
      Package->protocol = protocol;
      memcpy(Package->payload, payload, length);
   }
}
