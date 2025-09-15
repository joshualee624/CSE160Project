#include<Timer.h>

generic module NeighborDiscoveryP(){
    provides interface NeighborDiscovery;

    uses interface Timer<TMilli> as neighborTimer;
    uses interface Random;
}

implementation {

    command void NeighborDiscovery.findNeighbors() {
        call neighborTimerTimer.startOneShot(100+ (call Random.rand16() %300));
    }

    task void search(){
        "logic sned the msg, if someone responds, save its id inside table"
        call neighborTimerTimer.startPeriodic(100+ (call Random.rand16() %300));
    }

    event void neighborTimerTimer.fired(){
      post search();
    }


    command void NeighborDiscovery.printNeighbors();


}