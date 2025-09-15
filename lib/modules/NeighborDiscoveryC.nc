#include "../../includes/am_types.h"

generic configuration NeighborDiscoveryC(int channel){
   provides interface NeighborDiscovery;
}

implementation{
    components new NeighborDiscoveryP();
    NeighborDiscovery = NeighborDiscoveryP.NeighborDiscovery;

    components new TimerMilliC() as sendTimer;
    NeighborDiscoveryP.neighborTimerTimer -> neighborTimer;

    components RandomC as Random;
    NeighborDiscoveryP.Random -> Random;

}