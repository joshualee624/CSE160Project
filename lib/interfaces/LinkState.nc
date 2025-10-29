#include "../../includes/packet.h"

interface LinkState {
   command void init();
   command void handleAdvertisement(pack *msg);
   command uint16_t getNextHop(uint16_t dest);
   command void printRoutingTable();
}
