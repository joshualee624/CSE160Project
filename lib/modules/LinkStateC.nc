#include "../../includes/packet.h"

configuration LinkStateC {
   provides interface LinkState;
   uses interface NeighborDiscovery;
   uses interface Flooding;
}

implementation {
   components LinkStateP;
   LinkState = LinkStateP.LinkState;

   LinkStateP.NeighborDiscovery = NeighborDiscovery;
   LinkStateP.Flooding = Flooding;

   components new TimerMilliC() as linkStateTimer;
   LinkStateP.linkStateTimer -> linkStateTimer;
}
