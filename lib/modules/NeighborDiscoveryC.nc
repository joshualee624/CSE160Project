#include "../../includes/am_types.h"

configuration NeighborDiscoveryC{
   provides interface NeighborDiscovery;
}

implementation{
    components NeighborDiscoveryP;
    NeighborDiscovery = NeighborDiscoveryP.NeighborDiscovery;

    components new TimerMilliC() as sendTimer;
    NeighborDiscoveryP.neighborTimer -> sendTimer;

    components RandomC as Random;
    NeighborDiscoveryP.Random -> Random;

    components new SimpleSendC(AM_PACK);
    NeighborDiscoveryP.SimpleSend -> SimpleSendC;
}