
#include "../../includes/packet.h"

interface Flooding {
   // Initialize flooding system
   command void init();
   
   // Process received packet for flooding
   command void handlePacket(pack* msg);
   
   // Send packet using flooding
   command void floodPacket(pack* packet);
   
   // Check if packet has been seen before
   command bool hasSeenPacket(uint16_t src, uint16_t seq);
   
   // Add packet to seen packets list
   command void addSeenPacket(uint16_t src, uint16_t seq);
   
   // Clear seen packets list
   command void clearSeenPackets();
}