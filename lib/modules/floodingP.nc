/*
 * ANDES Lab - University of California, Merced
 * Flooding module implementation
 *
 * @author UCM ANDES Lab
 * @date   2013/09/03
 */

#include "../../includes/packet.h"
#include "../../includes/channels.h"

module FloodingP {
   provides interface Flooding;
   uses interface SimpleSend as Sender;
   uses interface NeighborDiscovery;
}

implementation {
   // Flooding state - moved from Node.nc
   enum { MAX_SEEN_PACKETS = 100 };
   typedef struct {
      uint16_t src;
      uint16_t seq;
   } seen_packet_t;

   seen_packet_t seenPackets[MAX_SEEN_PACKETS];
   uint16_t seenPacketIndex = 0;

   // Initialize flooding system
   command void Flooding.init() {
      uint16_t i;
      seenPacketIndex = 0;
      
      // Clear seen packets array
      for(i = 0; i < MAX_SEEN_PACKETS; i++) {
         seenPackets[i].src = 0;
         seenPackets[i].seq = 0;
      }
      
      dbg(FLOODING_CHANNEL, "Flooding system initialized\n");
   }
   

   // Process received packet for flooding
   command void Flooding.handlePacket(pack* myMsg) {
      pack floodPacket;
      
      dbg(FLOODING_CHANNEL, "Packet received at Node %d from %d\n", TOS_NODE_ID, myMsg->src);

      // Check if TTL expired - drop packet
      if(myMsg->TTL == 0) {
         dbg(FLOODING_CHANNEL, "Packet dropped - TTL expired\n");
         return;
      }

      // Check if we've seen this packet before - drop if duplicate
      if(call Flooding.hasSeenPacket(myMsg->src, myMsg->seq)) {
         dbg(FLOODING_CHANNEL, "Packet dropped, already seen (src:%d, seq:%d)\n", myMsg->src, myMsg->seq);
         return;
      }
      
      // Add to seen packets list
      call Flooding.addSeenPacket(myMsg->src, myMsg->seq);

      // If packet is for this node, process it locally
      if(myMsg->dest == TOS_NODE_ID) {
         dbg(GENERAL_CHANNEL, "Packet for me. Payload: %s\n", myMsg->payload);
      } else {
         // Forward the packet if TTL allows
         floodPacket = *myMsg;
         floodPacket.TTL--;
         
         if(floodPacket.TTL > 0) {
            call Sender.send(floodPacket, AM_BROADCAST_ADDR);
            dbg(FLOODING_CHANNEL, "Packet flooded from Node %d (TTL:%d)\n", TOS_NODE_ID, floodPacket.TTL);
         } else {
            dbg(FLOODING_CHANNEL, "Packet not flooded - TTL would be 0\n");
         }
      }
   }

   // Send packet using flooding
   command void Flooding.floodPacket(pack* packet) {
      uint16_t i;
      if(packet->TTL > 0) {
         for(i = 0; i < call NeighborDiscovery.numNeighbors(); i++) {
            uint16_t neighborID = call NeighborDiscovery.getNeighbors(i);
            dbg(FLOODING_CHANNEL, "Flooding to neighbor %d\n", neighborID);
            call Sender.send(*packet, neighborID);
         }
         // call Sender.send(*packet, AM_BROADCAST_ADDR);
         // dbg(FLOODING_CHANNEL, "Flooding packet from Node %d (TTL:%d)\n", TOS_NODE_ID, packet->TTL);
         
         // Add to seen packets to prevent loopback
         call Flooding.addSeenPacket(packet->src, packet->seq);
      } else {
         dbg(FLOODING_CHANNEL, "Cannot flood packet - TTL is 0\n");
      }
   }

   // Check if packet has been seen before
   command bool Flooding.hasSeenPacket(uint16_t src, uint16_t seq) {
      uint16_t i;
      for(i = 0; i < MAX_SEEN_PACKETS && i < seenPacketIndex; i++) {
         if(seenPackets[i].src == src && seenPackets[i].seq == seq) {
            return TRUE;
         }
      }
      return FALSE;
   }

   // Add packet to seen packets list
   command void Flooding.addSeenPacket(uint16_t src, uint16_t seq) {
      seenPackets[seenPacketIndex % MAX_SEEN_PACKETS].src = src;
      seenPackets[seenPacketIndex % MAX_SEEN_PACKETS].seq = seq;
      seenPacketIndex++;
   }

   command void Flooding.pingReply(uint16_t src) {
      dbg(FLOODING_CHANNEL, "Ping reply helper invoked for src %d\n", src);
   }

   // Clear seen packets list
   command void Flooding.clearSeenPackets() {
      uint16_t i;
      seenPacketIndex = 0;
      
      for(i = 0; i < MAX_SEEN_PACKETS; i++) {
         seenPackets[i].src = 0;
         seenPackets[i].seq = 0;
      }
      
      dbg(FLOODING_CHANNEL, "Seen packets list cleared\n");
   }
}
