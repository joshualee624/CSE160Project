#include "../../includes/packet.h"

interface NeighborDiscovery{
   command error_t findNeighbors();
   // event void neighborFound(uint16_t id);
   command void printNeighbors();
   command void handle(pack *p);
}